const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const x86 = @import("main.zig");
const writeProgram = x86.writeProgram;

fn runTestCapture(source: []const u8, args: []const []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, source);
    const prog_bytes = try db.compileBytes(0);

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
    const out = try runTestCapture(source, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

fn testProgramArgs(source: []const u8, expected: []const u8, args: []const []const u8) !void {
    const out = try runTestCapture(source, args);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "compile emits ELF executable bytes" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    const elf = try db.compileBytes(0);

    try testing.expect(elf.len >= 64);
    try testing.expectEqual(@as(u8, 0x7f), elf[0]);
    try testing.expectEqual(@as(u8, 'E'), elf[1]);
    try testing.expectEqual(@as(u8, 'L'), elf[2]);
    try testing.expectEqual(@as(u8, 'F'), elf[3]);
    try testing.expectEqual(@as(u8, 2), elf[4]);
    try testing.expectEqual(@as(u8, 1), elf[5]);

    const e_type = std.mem.readInt(u16, elf[16..][0..2], .little);
    const e_machine = std.mem.readInt(u16, elf[18..][0..2], .little);
    try testing.expectEqual(@as(u16, 2), e_type);
    try testing.expectEqual(@as(u16, 62), e_machine);
}

test "arithmetic" {
    try testProgram("print(42)", "42\n");
    try testProgram("print(3 + 4)", "7\n");
    try testProgram("print(10 - 3)", "7\n");
    try testProgram("print(5 * 6)", "30\n");
    try testProgram("print(20 / 4)", "5\n");
    try testProgram("print(10 - 6 * 2)", "-2\n");
}

test "arg" {
    try testProgramArgs("print(arg(1))", "42\n", &.{"42"});
}

test "comparisons" {
    try testProgram("print(3 < 4)", "true\n");
    try testProgram("print(4 < 3)", "false\n");
    try testProgram("print(4 > 3)", "true\n");
    try testProgram("print(4 <= 4)", "true\n");
    try testProgram("print(3 >= 4)", "false\n");
    try testProgram("print(-7 == -7)", "true\n");
    try testProgram("print(9 != 9)", "false\n");
}

test "if branches" {
    try testProgram("if 3 < 4 then print(11) else print(22)", "11\n");
    try testProgram("if 3 > 4 then print(33) else print(44)", "44\n");
}

test "if expression" {
    try testProgram("print(if 8 > 2 then 55 else 66)", "55\n");
    try testProgram("print(if 8 < 2 then 77 else 88)", "88\n");
    try testProgram("print((if 2 == 2 then 5 else 6) + 7)", "12\n");
}

test "float arithmetic and printing" {
    try testProgram("print(1.5)", "1.500000\n");
    try testProgram("print(1.5 + 2.25)", "3.750000\n");
    try testProgram("print(7.0 / 2.0)", "3.500000\n");
}

test "float comparisons with NaN semantics" {
    try testProgram("print((0.0 / 0.0) == 1.0)", "false\n");
    try testProgram("print((0.0 / 0.0) != 1.0)", "true\n");
}

test "const locals and multi-statement programs" {
    try testProgram(
        \\const x = 40 + 2
        \\print(x)
    , "42\n");
    try testProgram(
        \\const x = 2
        \\const y = x + 3
        \\print(y)
    , "5\n");
    try testProgram(
        \\const x = 2
        \\const y = x + 1
        \\print(x + y)
    , "5\n");
}

test "if without else requires unit in then branch" {
    try testProgram("if 3 < 4 then print(11)", "11\n");
}

test "type errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(1 + 2.0)");
    try testing.expectError(typecheck.TypeError.ArithmeticOperandMismatch, db.compileBytes(0));

    try db.setSource(0, "if 1 then 2 else 3");
    try testing.expectError(typecheck.TypeError.IfConditionMustBeBool, db.compileBytes(0));

    try db.setSource(0, "if 1 < 2 then 1 else 2.0");
    try testing.expectError(typecheck.TypeError.IfBranchTypeMismatch, db.compileBytes(0));

    try db.setSource(0, "if 1 < 2 then 1");
    try testing.expectError(typecheck.TypeError.IfWithoutElseRequiresUnit, db.compileBytes(0));

    try db.setSource(0, "print(if 1 < 2 then print(1) else print(2))");
    try testing.expectError(typecheck.TypeError.PrintUnitValue, db.compileBytes(0));

    try db.setSource(0, "print(x)");
    try testing.expectError(typecheck.TypeError.UnknownVariable, db.compileBytes(0));

    try db.setSource(0,
        \\const x = 1
        \\const x = 2
        \\print(x)
    );
    try testing.expectError(typecheck.TypeError.DuplicateVariable, db.compileBytes(0));

    try db.setSource(0,
        \\const x = 2
        \\(const y = 3
        \\print(y))
        \\print(x)
    );
    try testing.expectError(parser.ParseError.ExpectedExpression, db.compileBytes(0));
}

test "query cache hits within same revision" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(1)");
    _ = try db.parsedAst(0);
    _ = try db.typedAst(0);
    _ = try db.loweredProgram(0);
    _ = try db.compileBytes(0);

    db.resetStats();

    _ = try db.parsedAst(0);
    _ = try db.typedAst(0);
    _ = try db.loweredProgram(0);
    _ = try db.compileBytes(0);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 1), stats.parse_hits);
    try testing.expectEqual(@as(usize, 1), stats.type_hits);
    try testing.expectEqual(@as(usize, 1), stats.lower_hits);
    try testing.expectEqual(@as(usize, 1), stats.compile_hits);
    try testing.expectEqual(@as(usize, 0), stats.parse_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.type_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.lower_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.compile_recomputes);
}

test "source change invalidates parse lower compile" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(1)");
    _ = try db.compileBytes(0);

    const before = db.statsSnapshot().revision;
    db.resetStats();

    try db.setSource(0, "print(2)");
    _ = try db.compileBytes(0);

    const after = db.statsSnapshot();
    try testing.expectEqual(before + 1, after.revision);
    try testing.expectEqual(@as(usize, 1), after.source_sets);
    try testing.expectEqual(@as(usize, 1), after.parse_recomputes);
    try testing.expectEqual(@as(usize, 1), after.type_recomputes);
    try testing.expectEqual(@as(usize, 1), after.lower_recomputes);
    try testing.expectEqual(@as(usize, 1), after.compile_recomputes);
    try testing.expect(after.dependency_invalidations > 0);
}

test "source-specific invalidation" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(10)");
    _ = try db.compileBytes(0);

    try db.setSource(1, "print(20)");
    _ = try db.compileBytes(1);

    db.resetStats();

    try db.setSource(0, "print(30)");
    _ = try db.compileBytes(1);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 1), stats.source_sets);
    try testing.expectEqual(@as(usize, 0), stats.parse_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.lower_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.compile_recomputes);
    try testing.expect(stats.compile_hits > 0);
}

test "identical source does not advance revision" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(7)");
    const before = db.statsSnapshot().revision;

    db.resetStats();
    try db.setSource(0, "print(7)");

    const after = db.statsSnapshot();
    try testing.expectEqual(before, after.revision);
    try testing.expectEqual(@as(usize, 1), after.source_unchanged);
    try testing.expectEqual(@as(usize, 0), after.source_sets);
}

test "compile changed_at backdates on equal output" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(5)");
    _ = try db.compileBytes(0);
    const changed_before = db.changedAt(.compile, 0) orelse return error.TestFailed;

    try db.setSource(0, "print( 5 )");
    _ = try db.compileBytes(0);
    const changed_after = db.changedAt(.compile, 0) orelse return error.TestFailed;

    try testing.expectEqual(changed_before, changed_after);
}

test "debug query diagnostics format" {
    var buf = try std.ArrayList(u8).initCapacity(testing.allocator, 256);
    defer buf.deinit(testing.allocator);

    const stats = query.QueryStats{
        .revision = 7,
        .source_sets = 2,
        .parse_hits = 3,
        .type_hits = 4,
        .compile_recomputes = 1,
        .dependency_checks = 5,
    };
    try x86.appendQueryDiagnostics(&buf, testing.allocator, stats);

    try testing.expect(std.mem.indexOf(u8, buf.items, "; query diagnostics:") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   revision: 7") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   parse: hits=3 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   type: hits=4 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   compile: hits=0 recomputes=1") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   dependencies: checks=5 invalidations=0") != null);
}
