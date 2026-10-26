const std = @import("std");
const test_sources = @import("test_sources");
const SourceFixture = test_sources.SourceFixture;
const queries = test_sources.queries;
const structures = test_sources.structures;

fn expectPanic(source: []const u8, message: []const u8, frames: []const []const u8) !void {
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    const prefix = if (message.len == 0) try std.testing.allocator.dupe(u8, "panic\n") else try std.testing.allocator.print("panic: {s}\n", .{message});
    defer std.testing.allocator.free(prefix);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, prefix));
    var offset = prefix.len;
    for (frames) |frame| {
        offset = (std.mem.indexOfPos(u8, result.stderr, offset, frame) orelse {
            std.debug.print("missing frame {s} in:\n{s}", .{ frame, result.stderr });
            return error.TestUnexpectedResult;
        }) + frame.len;
    }
}

fn expectComptimePanic(fixture: SourceFixture, message: []const u8) !void {
    try fixture.expectDiagnostic(0, .compile_time_panic);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    var primary_count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .compile_time_panic) {
            primary_count += 1;
            const bytes = try fixture.db.lookupInterned(queries.ByteStrings, diagnostic.kind.compile_time_panic);
            try std.testing.expectEqualStrings(message, bytes.bytes);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), primary_count);
    const controls = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, std.testing.allocator);
    defer std.testing.allocator.free(controls);
    try std.testing.expectEqual(@as(usize, 0), controls.len);
}

test "bare panic and message panic report their source location" {
    try expectPanic("panic", "", &.{"<entry> (main.chi:1:1)"});
    try expectPanic("panic \"hé\\0world\"", "hé\x00world", &.{"<entry> (main.chi:1:1)"});
    try expectPanic("panic \"\"", "", &.{"<entry> (main.chi:1:1)"});
    try expectPanic("if 1 == 1 -> panic else panic \"other\"", "", &.{"<entry>"});
    try SourceFixture.expectSourceDiagnostic("panic 42", .call_argument_type_mismatch);
}

test "checked marking retains negative upper-bound and wrapping index panics" {
    for ([_]i32{ -1, 16, std.math.maxInt(i32) }) |first| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\func mark(first: int)
            \\    var values: List(int) = List(int).filled(0, 16) else return
            \\    var index = first
            \\    if first == 2147483647 -> index += 1
            \\    loop
            \\        if index > 16 -> break
            \\        values[index] = 1
            \\        index += 17
            \\mark({d})
        , .{first});
        defer std.testing.allocator.free(source);
        try expectPanic(source, "List index out of bounds", &.{"at mark "});
    }
}

test "panic traces direct indirect recursive and zero-sized frames" {
    try expectPanic(
        \\func stop() never -> panic "stopped"
        \\func forward() never -> stop()
        \\func recur(depth: int) never
        \\    if depth == 0 -> forward()
        \\    recur(depth - 1)
        \\const callback: func(int) never = recur
        \\callback(2)
    , "stopped", &.{ "at stop ", "at forward ", "at recur ", "at recur ", "at recur ", "at <entry> " });
}

test "panic bypasses ordinary failure handlers and user cleanup" {
    try expectPanic(
        \\struct Guard
        \\    value: String
        \\    drop = func(deinit self: Guard) -> print("dropped")
        \\func stop() int | none
        \\    const guard = Guard{value = "fatal"}
        \\    panic guard.value
        \\func run()
        \\    const value: int | none = stop()
        \\    print("caught")
        \\run()
    , "fatal", &.{ "at stop ", "at run ", "at <entry> " });
    try expectPanic(
        \\func accept(value: int) -> print("called")
        \\accept(panic "argument")
    , "argument", &.{"at <entry> "});
}

test "panic snapshots borrowed sliced and heap-backed text" {
    const source =
        \\func stop() never | none
        \\    var message = "prefix: hé"
        \\    const checked_value_1 = message.append("\0suffix")
        \\    if not (checked_value_1 is unit) -> return none
        \\    const view = message.view().slice(8..message.byte_length())
        \\    if not (view is StringView) -> return none
        \\    panic view
        \\stop()
    ;
    try expectPanic(source, "hé\x00suffix", &.{ "at stop ", "at <entry> " });
    const fixture = try SourceFixture.init(
        \\func stop() never | none
        \\    var message = "prefix: hé"
        \\    const checked_value_1 = message.append("\0suffix")
        \\    if not (checked_value_1 is unit) -> return none
        \\    const view = message.view().slice(8..message.byte_length())
        \\    if not (view is StringView) -> return none
        \\    panic view
        \\static result = stop()
        \\exit(result)
    );
    defer fixture.deinit();
    try expectComptimePanic(fixture, "hé\x00suffix");
}

test "compile-time panic is a diagnostic with call traces and recomputes" {
    const source =
        \\func inner() int -> panic "first"
        \\func outer() int -> inner()
        \\static result = outer()
        \\exit(result)
    ;
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    try expectComptimePanic(fixture, "first");
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    var traces: usize = 0;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .compile_time_call_trace) traces += 1;
    }
    try std.testing.expect(traces >= 2);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "first", "second");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try expectComptimePanic(fixture, "second");
    const repaired = try std.mem.replaceOwned(u8, std.testing.allocator, source, "panic \"first\"", "42");
    defer std.testing.allocator.free(repaired);
    try fixture.db.setInput(queries.SourceText, 0, repaired);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try expectComptimePanic(fixture, "first");
}

test "panic ignores prelude exclusions and lexical names and remains execution lazy" {
    try expectPanic(
        \\import std.prelude.{}
        \\const panic_message = 42
        \\panic "keyword"
    , "keyword", &.{"at <entry> "});
    try SourceFixture.expectParity(
        \\func unused() -> panic 42
        \\func run() int
        \\    if 1 == 2 -> panic "unreached"
        \\    return 42
    , 42);
}

test "panic traces outlined initializers and imported functions" {
    try expectPanic(
        \\func accept(init value: int) int | none -> value
        \\match accept(panic "initializer")
        \\    value and value is int -> exit(value)
        \\    _ -> exit(91)
    , "initializer", &.{ "at <entry> ", "at accept ", "at <entry> " });
    const fixture = try SourceFixture.initFiles("import lib\nlib.stop()", &.{.{
        .path = "lib/stop.chi",
        .module_path = "lib",
        .source = "pub func stop() never -> panic \"imported\"",
    }});
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "at stop (lib/stop.chi:1:26)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "at <entry> (main.chi:2:") != null);
}

test "panic still terminates when stderr is a broken pipe" {
    var descriptors: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe2(&descriptors, .{ .CLOEXEC = true })));
    (std.Io.File{ .handle = descriptors[0], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    const stderr: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
    defer stderr.close(std.testing.io);
    const fixture = try SourceFixture.init("panic \"broken stderr\"");
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    var program = try test_sources.runtime.prepareProgram(std.testing.io, std.testing.allocator, executable.bytes);
    defer program.deinit(std.testing.io);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{program.path}, .stdin = .ignore, .stdout = .ignore, .stderr = .{ .file = stderr } });
    defer child.kill(std.testing.io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, try child.wait(std.testing.io));
}

test "bare compile-time panic and constraint panic are diagnostics" {
    const fixture = try SourceFixture.init("func stop() int -> panic\nstatic result = stop()\nexit(result)");
    defer fixture.deinit();
    try expectComptimePanic(fixture, "");
    const constraint = try SourceFixture.init("func calculate() int where (panic \"constraint\") -> 42\nexit(calculate())");
    defer constraint.deinit();
    try expectComptimePanic(constraint, "constraint");
}

test "panic snapshots inline byte-array backing" {
    const declarations =
        \\func stop() never | none
        \\    const bytes: Array(byte, 3) = [65, 0, 66]
        \\    const message = BytesView.from_array(3, bytes).validate_utf8()
        \\    if not (message is StringView) -> return none
        \\    panic message
    ;
    const native_source = try std.testing.allocator.print("{s}\nstop()", .{declarations});
    defer std.testing.allocator.free(native_source);
    try expectPanic(native_source, "A\x00B", &.{ "at stop ", "at <entry> " });
    const comptime_source = try std.testing.allocator.print("{s}\ncomptime -> stop()", .{declarations});
    defer std.testing.allocator.free(comptime_source);
    const fixture = try SourceFixture.init(comptime_source);
    defer fixture.deinit();
    try expectComptimePanic(fixture, "A\x00B");
}

test "ordinary failure while evaluating a panic message precedes panic" {
    try SourceFixture.expectParity(
        \\func message() StringView | none -> return none
        \\func stop() int | none -> panic ((match message()
        \\    _selected_result_0 and _selected_result_0 is StringView -> _selected_result_0
        \\    _ -> return none))
        \\func run() int
        \\    if (stop() is int) -> return 90
        \\    return 42
    , 42);
}

test "function names render static values types callables and aggregates" {
    for ([_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "func show(static value: int) never -> panic\nshow(-7)", .name = "show(-7)" },
        .{ .source = "func show(static value: bool) never -> panic\nshow(true)", .name = "show(true)" },
        .{ .source = "func show(static value: byte) never -> panic\nshow(42)", .name = "show(42)" },
        .{ .source = "func show(static value: int_literal) never -> panic\nshow(3000000000)", .name = "show(3000000000)" },
        .{ .source = "func show(static value: string_literal) never -> panic\nshow(\"line\\n\\\"\")", .name = "show(\"line\\n\\\"\")" },
        .{ .source = "func show(static value: unit) never -> panic\nshow(())", .name = "show(())" },
        .{ .source = "func show(static value: none) never -> panic\nshow(none)", .name = "show(none)" },
        .{ .source = "static selected: int | none = 7\nfunc show(static value: int | none) never -> panic\nshow(selected)", .name = "show(7 as int)" },
        .{ .source = "func show(static T: type) never -> panic\nshow(int | none)", .name = "show(int | none)" },
        .{ .source = "struct Item(T: type)\n  value: T\nfunc show(static T: type) never -> panic\nshow(Item(int))", .name = "show(Item(int))" },
        .{ .source = "struct Item(T: type)\n  pub func callback(value: T) T -> unknown\nstruct Callback\n  copy = trivial\n  operation: func(int) int\nfunc show(static value: Callback) never -> panic\nshow(Callback{operation = Item(int).callback})", .name = "show(Callback{operation = Item(int).callback})" },
        .{ .source = "struct Item\n  copy = trivial\n  value: int\nfunc show(static value: Item) never -> panic\nshow(Item{value = 7})", .name = "show(Item{value = 7})" },
        .{ .source = "func show(static value: Array(int, 2)) never -> panic\nshow([1, 2])", .name = "show([1, 2])" },
        .{ .source = "func show(static value: (int, bool)) never -> panic\nshow((7, true))", .name = "show((7, true))" },
    }) |case| {
        try expectPanic(case.source, "", &.{case.name});
    }
}

test "function names retain inherited static arguments on their owners" {
    try expectPanic(
        \\struct Item(T: type)
        \\    pub func stop(static N: int) never -> panic
        \\Item(int).stop(7)
    , "", &.{"Item(int).stop(7)"});
    try expectPanic(
        \\func recur(static N: int) never
        \\    if N < 4 -> recur(N * 2)
        \\    panic
        \\recur(1)
    , "", &.{ "recur(4)", "recur(2)", "recur(1)" });
}

test "SSA names use the same source-style specializations as native traces" {
    const source = "func target(static N: int, value: int) int -> N\nexit(target(7, 0))";
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    _ = try fixture.executable(0);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try test_sources.debug.renderReachableSsa(test_sources.queries.AnalyzeFunctionInstance, fixture.db, 0, &.{.{ .file_id = 0, .path = "main.chi", .source = source }}, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "fn target(7)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@target(7)(") != null);
}

test "general function diagnostics retain specialization context" {
    for ([_]struct { source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind), context: []const u8, detail: ?[]const u8 = null }{
        .{ .source = "func invalid(static N: int) int -> true\nexit(invalid(7))", .kind = .return_type_mismatch, .context = "in invalid(7)" },
        .{ .source = "func invalid(static N: int) int -> unknown\nexit(invalid(7))", .kind = .unknown_value, .context = "in invalid(7)" },
        .{ .source = "func invalid(static N: int) int where N > 0 -> 42\nexit(invalid(-1))", .kind = .where_condition_failed, .context = "in invalid(-1)" },
        .{ .source = "func inner(static N: int) int -> N / 0\nfunc outer(static N: int) int -> inner(N)\nstatic result = outer(7)\nexit(result)", .kind = .compile_time_division_by_zero, .context = "in inner(7)", .detail = "in outer(7)" },
        .{ .source = "struct Item(T: type)\n  value: T\nfunc invalid(value: Item(int)) bool -> value\ninvalid(Item(int){value = 7})", .kind = .return_type_mismatch, .context = "in invalid", .detail = "found `Item(int)`" },
    }) |case| {
        const fixture = try SourceFixture.init(case.source);
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.kind);
        const issues = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(issues);
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try test_sources.diagnostic_rendering.renderDiagnostics(queries.TypeFacts(@TypeOf(fixture.db)){ .ctx = fixture.db }, &output.writer, &.{.{ .file_id = 0, .path = "main.chi", .source = case.source }}, issues);
        try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), case.context) != null);
        if (case.detail) |detail| try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), detail) != null);
    }
}
