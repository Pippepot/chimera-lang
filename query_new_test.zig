const std = @import("std");
const codegen = @import("codegen_new.zig");
const query = @import("query_new.zig");
const query_structures = @import("query_structures.zig");
const runtime = @import("runtime.zig");
const structures = @import("structures.zig");

const Context = query.Context;
const Database = query.Database;
const Handle = query.Handle;
const testing = std.testing;

const Counter = struct {
    value: std.atomic.Value(usize) = .init(0),

    fn reset(counter: *Counter) void {
        counter.value.store(0, .monotonic);
    }

    fn increment(counter: *Counter) void {
        _ = counter.value.fetchAdd(1, .monotonic);
    }

    fn expect(counter: *Counter, expected: usize) !void {
        try testing.expectEqual(expected, counter.value.load(.monotonic));
    }
};

fn testDatabase(worker_count: usize) !*Database {
    return Database.init(testing.allocator, .{ .worker_count = worker_count });
}

fn addSource(db: *Database, file_id: structures.FileId, source: []const u8) !void {
    try db.addInput(query_structures.SourceText, file_id, source);
}

fn setSource(db: *Database, file_id: structures.FileId, source: []const u8) !void {
    try db.setInput(query_structures.SourceText, file_id, source);
}

fn freeDiagnostics(diagnostics: []structures.Diagnostic) void {
    for (diagnostics) |*diagnostic| diagnostic.deinit(testing.allocator);
    testing.allocator.free(diagnostics);
}

fn expectDirectCallSsa(ssa: structures.SsaFunction, target: structures.ItemId) !void {
    try testing.expectEqual(@as(usize, 1), ssa.instructions.len);
    try testing.expectEqual(structures.InstanceId{ .item = target }, ssa.instructions[0].call.target);
    try testing.expectEqual(@as(usize, 1), ssa.blocks.len);
    try testing.expectEqual(structures.SsaFunction.Terminator.return_unit, ssa.blocks[0].terminator);
}

fn expectDirectCallArtifact(artifact: structures.CompiledFunction, target: structures.ItemId) !void {
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0, 0, 0, 0, 0xC3 }, artifact.code);
    try testing.expectEqual(@as(u32, 1), artifact.required_alignment);
    try testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    try testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try testing.expectEqual(structures.CompiledFunction.RelocationKind.call_relative_32, artifact.relocations[0].kind);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(artifact.relocations[0].reference));
    try testing.expectEqual(@as(i64, 0), artifact.relocations[0].addend);
    try testing.expectEqualSlices(structures.InstanceId, &.{.{ .item = target }}, artifact.referenced_instances);
}

fn expectUnitSsa(ssa: structures.SsaFunction) !void {
    try testing.expectEqual(@as(usize, 0), ssa.instructions.len);
    try testing.expectEqual(@as(usize, 1), ssa.blocks.len);
    try testing.expectEqual(structures.SsaFunction.Terminator.return_unit, ssa.blocks[0].terminator);
}

fn expectIntegerReturnBody(body: structures.FunctionBodyAnalysis, expected: i32) !void {
    try testing.expectEqual(@as(usize, 1), body.instructions.len);
    try testing.expectEqual(expected, body.instructions[0].consti);
    try testing.expectEqual(@as(usize, 1), body.blocks.len);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.blocks[0].terminator.return_value));
}

fn expectUnitBody(body: structures.FunctionBodyAnalysis) !void {
    try testing.expectEqual(@as(usize, 0), body.instructions.len);
    try testing.expectEqual(@as(usize, 1), body.blocks.len);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, body.blocks[0].terminator);
}

fn expectCompiledFunctionResult(
    db: *Database,
    file_id: structures.FileId,
    function_name: []const u8,
    reachable_names: []const []const u8,
    expected: u8,
) !void {
    const scope = (try db.get(query_structures.BuildModuleScope, file_id)).*.?;
    const function_id: structures.InstanceId = .{ .item = scope.resolve(function_name).? };
    const entry_id: structures.InstanceId = .{ .item = (try db.get(query_structures.SelectEntry, file_id)).*.? };

    // Test-only process entry: call the selected function, copy its return
    // value into the Linux exit-status argument, then invoke the exit syscall.
    const exit_with_result_code = [_]u8{
        0xE8, 0,    0,    0,    0,
        0x89, 0xC7, 0xB8, 60,   0,
        0,    0,    0x0F, 0x05,
    };
    const exit_with_result_relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const exit_with_result_references = [_]structures.InstanceId{function_id};
    const exit_with_result: structures.CompiledFunction = .{
        .code = &exit_with_result_code,
        .required_alignment = 1,
        .relocations = &exit_with_result_relocations,
        .referenced_instances = &exit_with_result_references,
    };

    var functions: std.ArrayList(codegen.ReachableFunction) = .empty;
    defer functions.deinit(testing.allocator);
    try functions.append(testing.allocator, .{ .instance = entry_id, .artifact = exit_with_result });
    for (reachable_names) |name| {
        const instance: structures.InstanceId = .{ .item = scope.resolve(name).? };
        const artifact = (try db.get(query_structures.CompileFunction, instance)).*.?;
        try functions.append(testing.allocator, .{ .instance = instance, .artifact = artifact });
    }

    var executable = try codegen.buildExecutable(entry_id, functions.items, testing.allocator);
    defer executable.deinit(testing.allocator);
    const io = testing.io;
    runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(expected, runtime.runProg(io, testing.allocator, &.{}));
}

// Query fixtures expose otherwise-internal lifecycle and recomputation behavior.

const Square = struct {
    pub const Input = i32;
    pub const Output = i32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        _ = ctx;
        return input_value * input_value;
    }
};

const Pair = struct {
    a: i32,
    b: i32,
};

const SumSquares = struct {
    pub const Input = Pair;
    pub const Output = i32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const a = try ctx.spawn(Square, input_value.a);
        const b = try ctx.spawn(Square, input_value.b);
        return (try a.wait()).* + (try b.wait()).*;
    }
};

const CycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(CycleB, input_value)).*;
    }
};

const CycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(CycleA, input_value)).*;
    }
};

const NumberInput = struct {
    pub const Key = u32;
    pub const Value = u32;
};

const ReadNumber = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.input(NumberInput, input_value)).*;
    }
};

const Parity = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(structures.Diagnostic, .{ .file_id = input_value, .span = null, .message = "parity" });
        return value % 2;
    }
};

const ParityParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        return (try ctx.get(Parity, input_value)).*;
    }
};

const ParityWithDiagnostic = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(structures.Diagnostic, .{
            .file_id = input_value,
            .span = null,
            .message = if (value == 2) "two" else "four",
        });
        return value % 2;
    }
};

const DiagnosticParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        return (try ctx.get(ParityWithDiagnostic, input_value)).*;
    }
};

const SelectedNumber = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, selector_key: Input) anyerror!Output {
        executions.increment();
        const selected_key = (try ctx.input(NumberInput, selector_key)).*;
        return (try ctx.input(NumberInput, selected_key)).*;
    }
};

const OwnedOutput = struct {
    bytes: []u8,

    var deinits: Counter = .{};

    pub fn deinit(value: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(value.bytes);
        deinits.increment();
        value.* = undefined;
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

const OwnedParity = struct {
    pub const Input = u32;
    pub const Output = OwnedOutput;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const bytes = try ctx.allocator().alloc(u8, 1);
        bytes[0] = @intCast((try ctx.input(NumberInput, input_value)).* % 2);
        return .{ .bytes = bytes };
    }
};

const RetryableFailure = struct {
    pub const Input = u32;
    pub const Output = OwnedOutput;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(structures.Diagnostic, .{
            .file_id = input_value,
            .span = null,
            .message = if (value == 2) "initial" else "replacement",
        });
        if (value == 4) return error.TestInfrastructureFailure;

        const bytes = try ctx.allocator().alloc(u8, 1);
        bytes[0] = @intCast(value);
        return .{ .bytes = bytes };
    }
};

const CountedQuery = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        _ = ctx;
        executions.increment();
        return input_value;
    }
};

const InternItemLoc = struct {
    pub const Input = u32;
    pub const Output = structures.ItemId;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return ctx.intern(query_structures.ItemLocations, .{
            .file_id = 1,
            .kind = .function,
            .name = if (input_value % 2 == 0) "even" else "odd",
            .disambiguator = 0,
        });
    }
};

const DynamicCycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return if ((try ctx.input(NumberInput, 10)).* == 0)
            (try ctx.get(DynamicCycleB, input_value)).*
        else
            1;
    }
};

const DynamicCycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return if ((try ctx.input(NumberInput, 11)).* != 0)
            (try ctx.get(DynamicCycleA, input_value)).*
        else
            0;
    }
};

const EmitDiagnostic = struct {
    pub const Input = structures.FileId;
    pub const Output = u32;

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        try ctx.emit(structures.Diagnostic, .{
            .file_id = file_id,
            .span = .{ .start = 0, .end = 1 },
            .message = "leaf",
        });
        return 10;
    }
};

const CallEmitDiagnostic = struct {
    pub const Input = structures.FileId;
    pub const Output = u32;

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        try ctx.emit(structures.Diagnostic, .{
            .file_id = file_id,
            .span = null,
            .message = "root",
        });
        return (try ctx.get(EmitDiagnostic, file_id)).* + 1;
    }
};

const SelectEntryParent = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        executions.increment();
        return (try ctx.get(query_structures.SelectEntry, file_id)).*;
    }
};

const ModuleScopeParent = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        executions.increment();
        const scope = (try ctx.get(query_structures.BuildModuleScope, file_id)).* orelse return null;
        return scope.resolve("alpha");
    }
};

const SignatureParent = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?usize;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, item_id: Input) anyerror!Output {
        executions.increment();
        const signature = (try ctx.get(query_structures.FunctionSignature, item_id)).* orelse return null;
        return signature.parameter_types.len;
    }
};

const EntryCallParent = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        executions.increment();
        const entry_id = (try ctx.get(query_structures.SelectEntry, file_id)).* orelse return null;
        const body = (try ctx.get(query_structures.AnalyzeFunctionBody, entry_id)).* orelse return null;
        if (body.instructions.len != 1) return null;
        return switch (body.instructions[0]) {
            .call => |call| call.target,
            .consti,
            .negi,
            .addi,
            .subi,
            .muli,
            .divsi,
            => null,
        };
    }
};

// Query engine behavior.

test "typed queries memoize and spawned dependencies can overlap" {
    const db = try testDatabase(4);
    defer db.deinit();

    try testing.expectEqual(@as(i32, 25), (try db.get(SumSquares, .{ .a = 3, .b = 4 })).*);
    try testing.expectEqual(@as(i32, 25), (try db.get(SumSquares, .{ .a = 3, .b = 4 })).*);
}

test "append-only inputs can be read by queries" {
    const db = try testDatabase(2);
    defer db.deinit();

    try db.addInput(NumberInput, 7, 42);
    try testing.expectError(error.DuplicateInput, db.addInput(NumberInput, 7, 99));
    try testing.expectEqual(@as(u32, 42), (try db.get(ReadNumber, 7)).*);
    try testing.expectError(error.InputNotFound, db.get(ReadNumber, 8));
}

test "dependency cycles are reported" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectError(error.QueryCycle, db.get(CycleA, 1));
}

test "typed accumulators expose direct and transitive diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectEqual(@as(u32, 11), (try db.get(CallEmitDiagnostic, 3)).*);

    const direct = try db.directAccumulatorValues(CallEmitDiagnostic, 3, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), direct.len);
    try testing.expectEqualStrings("root", direct[0].message);

    const all = try db.transitiveAccumulatorValues(CallEmitDiagnostic, 3, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("root", all[0].message);
    try testing.expectEqualStrings("leaf", all[1].message);
}

// Compiler pipeline query behavior.

test "ParseFile returns public Ast and emits parser diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source = "const x = 1";
    try addSource(db, 1, source);
    const parsed = try db.get(query_structures.ParseFile, 1);
    try testing.expect(parsed.* != null);
    try testing.expectEqual(@as(structures.FileId, 1), parsed.*.?.file_id);
    try testing.expectEqual(structures.Node.Tag.block, parsed.*.?.nodes[0].tag);
    const name_token = parsed.*.?.tokens[1];
    try testing.expectEqualStrings("x", source[name_token.loc.start..name_token.loc.end]);

    try addSource(db, 2, "const x 1");
    const failed = try db.get(query_structures.ParseFile, 2);
    try testing.expect(failed.* == null);

    const diagnostics = try db.transitiveAccumulatorValues(query_structures.ParseFile, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expect(diagnostics.len > 0);
    try testing.expectEqual(@as(structures.FileId, 2), diagnostics[0].file_id);
}

test "DiscoverItems owns names and disambiguates duplicate functions" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source =
        \\static duplicate = func() int -> return 1
        \\print(0)
        \\static duplicate = func() int -> return 2
        \\static value = 3
    ;
    try addSource(db, 1, source);
    const result = try db.get(query_structures.DiscoverItems, 1);
    const tree = result.*.?;

    try testing.expectEqual(@as(usize, 3), tree.items.len);
    try testing.expectEqual(structures.ItemKind.function, tree.items[0].loc.kind);
    try testing.expectEqualStrings("duplicate", tree.items[0].loc.name);
    try testing.expectEqual(@as(u32, 0), tree.items[0].loc.disambiguator);
    try testing.expectEqual(@as(u32, 1), tree.items[1].loc.disambiguator);
    try testing.expectEqual(structures.ItemKind.top_level_entry, tree.items[2].loc.kind);
    try testing.expectEqualStrings("$entry", tree.items[2].loc.name);

    try setSource(db, 1, "static replacement = func() int -> return 3");
    try testing.expectEqualStrings("duplicate", tree.items[0].loc.name);
}

test "DiscoverItems creates an entry for every parsed file" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "static f = func() int -> return 1");
    try addSource(db, 3, "static value = 1");

    const empty = (try db.get(query_structures.DiscoverItems, 1)).*;
    const function_only = (try db.get(query_structures.DiscoverItems, 2)).*;
    const static_only = (try db.get(query_structures.DiscoverItems, 3)).*;
    try testing.expectEqual(@as(usize, 1), empty.?.items.len);
    try testing.expectEqual(structures.ItemKind.top_level_entry, empty.?.items[0].loc.kind);
    try testing.expectEqual(@as(usize, 2), function_only.?.items.len);
    try testing.expectEqual(structures.ItemKind.function, function_only.?.items[0].loc.kind);
    try testing.expectEqual(structures.ItemKind.top_level_entry, function_only.?.items[1].loc.kind);
    try testing.expectEqual(@as(usize, 1), static_only.?.items.len);
    try testing.expectEqual(structures.ItemKind.top_level_entry, static_only.?.items[0].loc.kind);
}

test "item indexing handles empty malformed missing and distinct locations" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "const x 1");
    try addSource(db, 3,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    try addSource(db, 4, "static duplicate = func() int -> return 1");

    const empty = (try db.get(query_structures.IndexItems, 1)).*;
    try testing.expect(empty != null);
    try testing.expectEqual(@as(usize, 1), empty.?.count());
    try testing.expect((try db.get(query_structures.IndexItems, 2)).* == null);
    try testing.expectError(error.InputNotFound, db.get(query_structures.IndexItems, 99));

    const duplicates = (try db.get(query_structures.IndexItems, 3)).*.?;
    try testing.expectEqual(@as(usize, 3), duplicates.count());
    try testing.expect(duplicates.ids()[0] != duplicates.ids()[1]);
    const other_file = (try db.get(query_structures.IndexItems, 4)).*.?;
    try testing.expect(duplicates.ids()[0] != other_file.ids()[0]);

    const base: structures.ItemLoc = .{ .file_id = 8, .kind = .function, .name = "same", .disambiguator = 0 };
    const base_id = try db.intern(query_structures.ItemLocations, base);
    try testing.expectEqual(base_id, try db.intern(query_structures.ItemLocations, base));
    try testing.expect(base_id != try db.intern(query_structures.ItemLocations, .{ .file_id = 9, .kind = .function, .name = "same", .disambiguator = 0 }));
    try testing.expect(base_id != try db.intern(query_structures.ItemLocations, .{ .file_id = 8, .kind = .top_level_entry, .name = "same", .disambiguator = 0 }));
    try testing.expect(base_id != try db.intern(query_structures.ItemLocations, .{ .file_id = 8, .kind = .function, .name = "other", .disambiguator = 0 }));
    try testing.expect(base_id != try db.intern(query_structures.ItemLocations, .{ .file_id = 8, .kind = .function, .name = "same", .disambiguator = 1 }));
    try testing.expectError(error.InvalidInternId, db.lookupInterned(query_structures.ItemLocations, @enumFromInt(std.math.maxInt(u32))));
}

test "module scope owns sorted callable lookup and leaves bodies demand-driven" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static zeta = func() int -> return missing
        \\static value = 1
        \\print(0)
        \\static alpha = func() int -> return 1
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(@as(usize, 2), scope.entries.len);
    try testing.expectEqualStrings("alpha", scope.entries[0].name);
    try testing.expectEqualStrings("zeta", scope.entries[1].name);
    try testing.expectEqual(scope.entries[0].item_id, scope.resolve("alpha").?);
    try testing.expectEqual(scope.entries[1].item_id, scope.resolve("zeta").?);
    try testing.expect(scope.resolve("missing") == null);
    try testing.expect(scope.resolve("value") == null);
    try testing.expect(scope.resolve("$entry") == null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(query_structures.BuildModuleScope, 1, structures.Diagnostic)).len);

    try setSource(db, 1, "static replacement = func() int -> return 2");
    try testing.expectEqualStrings("alpha", scope.entries[0].name);
}

test "module scope classifies empty missing and malformed inputs" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "static value = 1");
    try addSource(db, 3, "const value 1");

    try testing.expectEqual(@as(usize, 0), (try db.get(query_structures.BuildModuleScope, 1)).*.?.entries.len);
    try testing.expectEqual(@as(usize, 0), (try db.get(query_structures.BuildModuleScope, 2)).*.?.entries.len);
    try testing.expect((try db.get(query_structures.BuildModuleScope, 3)).* == null);
    try testing.expectError(error.InputNotFound, db.get(query_structures.BuildModuleScope, 99));
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(query_structures.BuildModuleScope, 3, structures.Diagnostic)).len);
    const malformed = try db.transitiveAccumulatorValues(query_structures.BuildModuleScope, 3, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(malformed);
    try testing.expect(malformed.len > 0);
}

test "module scope diagnoses later duplicate functions and recovers" {
    const db = try testDatabase(2);
    defer db.deinit();

    const duplicate_source =
        \\static duplicate = func() int -> return 1
        \\static other = func() int -> return 0
        \\static duplicate = func() int -> return 2
        \\static duplicate = func() int -> return 3
    ;
    try addSource(db, 1, duplicate_source);
    try testing.expect((try db.get(query_structures.BuildModuleScope, 1)).* == null);
    const diagnostics = try db.directAccumulatorValues(query_structures.BuildModuleScope, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 2), diagnostics.len);
    var search_from = std.mem.indexOf(u8, duplicate_source, "duplicate").? + "duplicate".len;
    for (diagnostics) |diagnostic| {
        try testing.expectEqualStrings("duplicate top-level function name", diagnostic.message);
        const start = std.mem.indexOfPos(u8, duplicate_source, search_from, "duplicate").?;
        try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "duplicate".len }, diagnostic.span.?);
        search_from = start + "duplicate".len;
    }

    try setSource(db, 1,
        \\static other = func() int -> return 0
        \\static duplicate = func() int -> return 3
    );
    const recovered = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    try testing.expect(recovered.resolve("duplicate") != null);
    const loc = try db.lookupInterned(query_structures.ItemLocations, recovered.resolve("duplicate").?);
    try testing.expectEqual(@as(u32, 0), loc.disambiguator);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(query_structures.BuildModuleScope, 1, structures.Diagnostic)).len);
}

test "module scope refreshes duplicate spans when its index remains equal" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    const initial_index = try db.get(query_structures.IndexItems, 1);
    try testing.expect((try db.get(query_structures.BuildModuleScope, 1)).* == null);
    const initial_diagnostics = try db.directAccumulatorValues(query_structures.BuildModuleScope, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), initial_diagnostics.len);
    const initial_span = initial_diagnostics[0].span.?;

    try setSource(db, 1,
        \\static duplicate = func() int -> return 123456789
        \\static duplicate = func() int -> return 2
    );
    try testing.expectEqual(initial_index, try db.get(query_structures.IndexItems, 1));
    try testing.expect((try db.get(query_structures.BuildModuleScope, 1)).* == null);
    const updated_diagnostics = try db.directAccumulatorValues(query_structures.BuildModuleScope, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), updated_diagnostics.len);
    try testing.expect(initial_span.start != updated_diagnostics[0].span.?.start);
}

test "module scope preserves stable identity and canonical equality" {
    const db = try testDatabase(1);
    defer db.deinit();

    ModuleScopeParent.executions.reset();
    const original =
        \\static beta = func() int -> return 2
        \\static alpha = func() int -> return 1
    ;
    try addSource(db, 1, original);
    const initial_scope = try db.get(query_structures.BuildModuleScope, 1);
    const alpha_id = (try db.get(ModuleScopeParent, 1)).*.?;

    try setSource(db, 1,
        \\static beta = func() int -> return 20
        \\static alpha = func() int -> return 10
    );
    try testing.expectEqual(initial_scope, try db.get(query_structures.BuildModuleScope, 1));
    try testing.expectEqual(alpha_id, (try db.get(ModuleScopeParent, 1)).*.?);

    try setSource(db, 1,
        \\static alpha = func() int -> return 10
        \\static beta = func() int -> return 20
    );
    try testing.expectEqual(initial_scope, try db.get(query_structures.BuildModuleScope, 1));
    try testing.expectEqual(alpha_id, (try db.get(ModuleScopeParent, 1)).*.?);
    try ModuleScopeParent.executions.expect(1);

    try setSource(db, 1,
        \\static gamma = func() int -> return 10
        \\static beta = func() int -> return 20
    );
    const renamed = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    try testing.expect(renamed.resolve("alpha") == null);
    try testing.expect(renamed.resolve("gamma") != null);

    try setSource(db, 1, original);
    const restored = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(alpha_id, restored.resolve("alpha").?);
}

test "module scope construction cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testModuleScopeAllocations, .{});
}

fn testModuleScopeAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try addSource(db, 1,
        \\static beta = func() int -> return 2
        \\static alpha = func() int -> return 1
    );
    try testing.expect((try db.get(query_structures.BuildModuleScope, 1)).* != null);
}

test "concurrent module scope requests share successful and duplicate results" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "static alpha = func() int -> return 1");
    var successful: [8]Handle(query_structures.BuildModuleScope) = undefined;
    for (&successful) |*handle| handle.* = try db.spawn(query_structures.BuildModuleScope, 1);
    const first = try successful[0].wait();
    for (successful[1..]) |handle| try testing.expectEqual(first, try handle.wait());

    try addSource(db, 2,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    var duplicate: [8]Handle(query_structures.BuildModuleScope) = undefined;
    for (&duplicate) |*handle| handle.* = try db.spawn(query_structures.BuildModuleScope, 2);
    const duplicate_first = try duplicate[0].wait();
    try testing.expect(duplicate_first.* == null);
    for (duplicate[1..]) |handle| try testing.expectEqual(duplicate_first, try handle.wait());
    try testing.expectEqual(@as(usize, 1), (try db.directAccumulatorValues(query_structures.BuildModuleScope, 2, structures.Diagnostic)).len);
}

test "resolution requested before interning retries after identity issuance" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static target = func() int -> return 1");
    const first_id: structures.ItemId = @enumFromInt(0);
    try testing.expectError(error.InvalidInternId, db.get(query_structures.ResolveItem, first_id));
    try testing.expectEqual(first_id, (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0]);
    try testing.expect((try db.get(query_structures.ResolveItem, first_id)).* != null);
}

test "item identity survives relocation and restoration" {
    const db = try testDatabase(1);
    defer db.deinit();

    const original = "static target = func() int -> return 1";
    try addSource(db, 1, original);
    const initial_index = (try db.get(query_structures.IndexItems, 1)).*.?;
    const target_id = initial_index.ids()[0];
    const initial_resolution = (try db.get(query_structures.ResolveItem, target_id)).*.?;

    try setSource(db, 1,
        \\static unrelated = func() int -> return 0
        \\static target = func() int -> return 2
    );
    const relocated_index = (try db.get(query_structures.IndexItems, 1)).*.?;
    try testing.expectEqual(target_id, relocated_index.ids()[1]);
    const relocated = (try db.get(query_structures.ResolveItem, target_id)).*.?;
    try testing.expect(initial_resolution.declaration != relocated.declaration);

    try setSource(db, 1, "static renamed = func() int -> return 3");
    try testing.expect((try db.get(query_structures.ResolveItem, target_id)).* == null);
    try setSource(db, 1, "const x 1");
    try testing.expect((try db.get(query_structures.ResolveItem, target_id)).* == null);

    try setSource(db, 1, original);
    const restored_index = (try db.get(query_structures.IndexItems, 1)).*.?;
    try testing.expectEqual(target_id, restored_index.ids()[0]);
    try testing.expect((try db.get(query_structures.ResolveItem, target_id)).* != null);
}

test "synthetic entry identity persists through top-level code changes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    const entry_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    try testing.expectEqual(structures.ItemKind.top_level_entry, (try db.lookupInterned(query_structures.ItemLocations, entry_id)).kind);
    try testing.expect((try db.get(query_structures.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "print(1)");
    try testing.expectEqual(entry_id, (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0]);
    try testing.expect((try db.get(query_structures.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "");
    try testing.expect((try db.get(query_structures.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "print(2)");
    try testing.expectEqual(entry_id, (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0]);
    try testing.expect((try db.get(query_structures.ResolveItem, entry_id)).* != null);
}

test "SelectEntry selects the indexed entry and handles invalid inputs" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    try addSource(db, 3, "const x 1");
    try addSource(db, 4, "");
    try addSource(db, 5, "static f = func() int -> return 1");

    for ([_]structures.FileId{ 1, 2, 4, 5 }) |file_id| {
        const selected = (try db.get(query_structures.SelectEntry, file_id)).*.?;
        const index = (try db.get(query_structures.IndexItems, file_id)).*.?;
        var matching_entries: usize = 0;
        for (index.ids()) |item_id| {
            const loc = try db.lookupInterned(query_structures.ItemLocations, item_id);
            if (loc.kind != .top_level_entry) continue;
            matching_entries += 1;
            try testing.expectEqual(item_id, selected);
        }
        try testing.expectEqual(@as(usize, 1), matching_entries);
    }

    const first_entry = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const other_entry = (try db.get(query_structures.SelectEntry, 4)).*.?;
    try testing.expect(first_entry != other_entry);
    try testing.expect((try db.get(query_structures.SelectEntry, 3)).* == null);
    try testing.expectError(error.InputNotFound, db.get(query_structures.SelectEntry, 99));
}

test "SelectEntry restores stable identity after malformed source" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 1";
    try addSource(db, 1, valid);
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;

    try setSource(db, 1, "const x 1");
    try testing.expect((try db.get(query_structures.SelectEntry, 1)).* == null);

    try setSource(db, 1, valid);
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
}

test "equal SelectEntry result does not recompute its parent" {
    const db = try testDatabase(1);
    defer db.deinit();

    SelectEntryParent.executions.reset();
    try addSource(db, 1, "");
    const entry_id = (try db.get(SelectEntryParent, 1)).*.?;
    try testing.expectEqual(@as(usize, 1), (try db.get(query_structures.IndexItems, 1)).*.?.count());

    try setSource(db, 1, "static f = func() int -> return 1");
    try testing.expectEqual(entry_id, (try db.get(SelectEntryParent, 1)).*.?);
    try testing.expectEqual(@as(usize, 2), (try db.get(query_structures.IndexItems, 1)).*.?.count());
    try SelectEntryParent.executions.expect(1);
}

test "SelectEntry exposes changed diagnostics while remaining null" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const x 1");
    try testing.expect((try db.get(query_structures.SelectEntry, 1)).* == null);
    const initial = try db.transitiveAccumulatorValues(query_structures.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(initial);

    try setSource(db, 1, "const longer_name 1");
    try testing.expect((try db.get(query_structures.SelectEntry, 1)).* == null);
    const updated = try db.transitiveAccumulatorValues(query_structures.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(updated);

    try testing.expect(initial.len > 0);
    try testing.expectEqual(initial.len, updated.len);
    try testing.expect(!structures.Diagnostic.eql(initial[0], updated[0]));
}

test "BuildExecutable runs empty entry sources" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "static f = func() int -> return 1");
    try addSource(db, 3, "static value = 1");

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for ([_]structures.FileId{ 1, 2, 3 }) |file_id| {
        const executable = (try db.get(query_structures.BuildExecutable, file_id)).*.?;
        runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "BuildExecutable follows compiled entry diagnostics and recovers" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);

    try setSource(db, 1, "print(1)");
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* == null);
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* == null);
    const direct = try db.directAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), direct.len);
    const diagnostics = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("unknown function", diagnostics[0].message);

    try setSource(db, 1, "");
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "BuildExecutable exposes changed malformed diagnostics while remaining null" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const x 1");
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* == null);
    const initial = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(initial);

    try setSource(db, 1, "const longer_name 1");
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* == null);
    const updated = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(updated);

    try testing.expect(initial.len > 0);
    try testing.expectEqual(initial.len, updated.len);
    try testing.expect(!structures.Diagnostic.eql(initial[0], updated[0]));
}

test "BuildExecutable retries missing input and retains equal output" {
    const db = try testDatabase(1);
    defer db.deinit();

    try testing.expectError(error.InputNotFound, db.get(query_structures.BuildExecutable, 1));
    try addSource(db, 1, "");
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    const initial_artifact = try db.get(query_structures.CompileFunction, entry_instance);
    try testing.expect(initial_artifact.* != null);
    const initial = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(initial.* != null);

    try setSource(db, 1, "static f = func() int -> return 1");
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expectEqual(initial_artifact, try db.get(query_structures.CompileFunction, entry_instance));
    const updated = try db.get(query_structures.BuildExecutable, 1);
    try testing.expectEqual(initial, updated);
}

test "concurrent BuildExecutable requests share one owned result" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "");
    var handles: [16]Handle(query_structures.BuildExecutable) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(query_structures.BuildExecutable, 1);
    const first = try handles[0].wait();
    try testing.expect(first.* != null);
    for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
}

test "function signature and body analysis support inline and block literal returns" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static inline_fn = func() int -> return 7");
    try addSource(db, 2,
        \\static block_fn = func() int
        \\  return 9
    );
    try addSource(db, 3, "static max_int = func() int -> return 2147483647");

    for ([_]struct { file_id: structures.FileId, expected: i32 }{
        .{ .file_id = 1, .expected = 7 },
        .{ .file_id = 2, .expected = 9 },
        .{ .file_id = 3, .expected = std.math.maxInt(i32) },
    }) |case| {
        const function_id = (try db.get(query_structures.IndexItems, case.file_id)).*.?.ids()[0];
        const signature = (try db.get(query_structures.FunctionSignature, function_id)).*.?;
        try testing.expectEqual(@as(usize, 0), signature.parameter_types.len);
        try testing.expectEqual(structures.Type.int, signature.return_type);
        try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, function_id)).*.?, case.expected);
    }
}

test "declared unit functions analyze lower compile and execute as ordinary callables" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func(value: int) unit
        \\  return
        \\static caller = func() unit
        \\  const done: unit = leaf(7)
        \\  return done
        \\caller()
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const leaf_id = scope.resolve("leaf").?;
    const caller_id = scope.resolve("caller").?;

    const leaf_signature = (try db.get(query_structures.FunctionSignature, leaf_id)).*.?;
    try testing.expectEqualSlices(structures.Type, &.{.int}, leaf_signature.parameter_types);
    try testing.expectEqual(structures.Type.unit, leaf_signature.return_type);
    const leaf_body = (try db.get(query_structures.AnalyzeFunctionBody, leaf_id)).*.?;
    try testing.expectEqualSlices(structures.Type, &.{.int}, leaf_body.block_argument_types);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, leaf_body.blocks[0].terminator);

    const caller_body = (try db.get(query_structures.AnalyzeFunctionBody, caller_id)).*.?;
    try testing.expectEqual(@as(usize, 2), caller_body.instructions.len);
    try testing.expectEqual(@as(i32, 7), caller_body.instructions[0].consti);
    try testing.expectEqual(leaf_id, caller_body.instructions[1].call.target);
    try testing.expectEqual(structures.Type.unit, caller_body.instructions[1].call.return_type);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, caller_body.blocks[0].terminator);

    const caller_ssa = (try db.get(query_structures.LowerToSSA, .{ .item = caller_id })).*.?;
    try testing.expectEqual(structures.Type.unit, caller_ssa.instructions[1].call.return_type);
    try testing.expectEqual(structures.SsaFunction.Terminator.return_unit, caller_ssa.blocks[0].terminator);
    const leaf_artifact = (try db.get(query_structures.CompileFunction, .{ .item = leaf_id })).*.?;
    try testing.expectEqualSlices(u8, &.{0xC3}, leaf_artifact.code);

    const executable = (try db.get(query_structures.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "unit values are rejected at int boundaries" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        message: []const u8,
    }{
        .{ .file_id = 1, .source = "static bad = func() int -> return", .message = "function returning int must return a value" },
        .{ .file_id = 2, .source = "static bad = func() unit -> return 1", .message = "return type does not match function signature" },
        .{ .file_id = 3, .source = "static noop = func() unit\n  return\nstatic bad = func() int -> return noop()", .message = "return type does not match function signature" },
        .{ .file_id = 4, .source = "static noop = func() unit\n  return\nstatic bad = func() int -> return noop() + 1", .message = "integer operation requires int operands" },
        .{ .file_id = 5, .source = "static noop = func() unit\n  return\nstatic take = func(value: int) int -> return value\nstatic bad = func() int -> return take(noop())", .message = "call argument type does not match function signature" },
        .{ .file_id = 6, .source = "static noop = func() unit\n  return\nstatic bad = func() unit\n  const done: int = noop()\n  return", .message = "local binding type does not match initializer" },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const scope = (try db.get(query_structures.BuildModuleScope, case.file_id)).*.?;
        const bad_id = scope.resolve("bad").?;
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, bad_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqualStrings(case.message, diagnostics[0].message);
    }
}

test "function expressions analyze nested arithmetic and calls as one typed value graph" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> return 6
        \\static expression = func() int -> return -(-(120 / leaf() - (2 + 3) * 1))
        \\expression()
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const expression_id = scope.resolve("expression").?;
    const body = (try db.get(query_structures.AnalyzeFunctionBody, expression_id)).*.?;

    try testing.expectEqual(@as(usize, 11), body.instructions.len);
    try testing.expectEqual(@as(i32, 120), body.instructions[0].consti);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[1].call.target);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[2].divsi.lhs));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(body.instructions[2].divsi.rhs));
    try testing.expectEqual(@as(i32, 2), body.instructions[3].consti);
    try testing.expectEqual(@as(i32, 3), body.instructions[4].consti);
    try testing.expectEqual(@as(u32, 3), @intFromEnum(body.instructions[5].addi.lhs));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(body.instructions[5].addi.rhs));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(body.instructions[7].muli.lhs));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(body.instructions[8].subi.lhs));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(body.instructions[8].subi.rhs));
    try testing.expectEqual(@as(u32, 8), @intFromEnum(body.instructions[9].negi));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(body.instructions[10].negi));
    try testing.expectEqual(@as(u32, 10), @intFromEnum(body.blocks[0].terminator.return_value));
    const lowered = (try db.get(query_structures.LowerToSSA, .{ .item = expression_id })).*.?;
    try testing.expectEqual(@as(u32, 9), @intFromEnum(lowered.instructions[10].negi));
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "parameters and nested call arguments form one typed value graph" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static add = func(a: int, b: int) int -> return a + b
        \\static twice = func(value: int) int -> return add(value, value)
        \\static answer = func() int
        \\  const base = add(20, 1)
        \\  return add(twice(base), base)
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const add_id = scope.resolve("add").?;
    const twice_id = scope.resolve("twice").?;

    const add_signature = (try db.get(query_structures.FunctionSignature, add_id)).*.?;
    try testing.expectEqualSlices(structures.Type, &.{ .int, .int }, add_signature.parameter_types);
    const add = (try db.get(query_structures.AnalyzeFunctionBody, add_id)).*.?;
    try testing.expectEqualSlices(structures.Type, &.{ .int, .int }, add.block_argument_types);
    try testing.expectEqual(@as(u32, 0), add.blocks[0].argument_start);
    try testing.expectEqual(@as(u32, 2), add.blocks[0].argument_end);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(add.instructions[0].addi.lhs));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(add.instructions[0].addi.rhs));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(add.blocks[0].terminator.return_value));

    const twice = (try db.get(query_structures.AnalyzeFunctionBody, twice_id)).*.?;
    try testing.expectEqualSlices(structures.FunctionValueId, &.{ @enumFromInt(0), @enumFromInt(0) }, twice.call_arguments);
    try testing.expectEqual(add_id, twice.instructions[0].call.target);
    try testing.expectEqual(structures.FunctionValueRange{ .start = 0, .end = 2 }, twice.instructions[0].call.arguments);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(twice.blocks[0].terminator.return_value));

    const answer = (try db.get(query_structures.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try testing.expectEqualSlices(structures.FunctionValueId, &.{
        @enumFromInt(0),
        @enumFromInt(1),
        @enumFromInt(2),
        @enumFromInt(3),
        @enumFromInt(2),
    }, answer.call_arguments);
    try testing.expectEqual(structures.FunctionValueRange{ .start = 0, .end = 2 }, answer.instructions[2].call.arguments);
    try testing.expectEqual(structures.FunctionValueRange{ .start = 2, .end = 3 }, answer.instructions[3].call.arguments);
    try testing.expectEqual(structures.FunctionValueRange{ .start = 3, .end = 5 }, answer.instructions[4].call.arguments);
}

test "call arity and parameter scope diagnostics are reported at their owning boundary" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        function_name: []const u8,
        message: []const u8,
    }{
        .{
            .file_id = 1,
            .source = "static target = func(x: int) int -> return x\nstatic caller = func() int -> return target()",
            .function_name = "caller",
            .message = "call argument count does not match function signature",
        },
        .{
            .file_id = 2,
            .source = "static target = func(x: int) int -> return x\nstatic caller = func() int -> return target(1, 2)",
            .function_name = "caller",
            .message = "call argument count does not match function signature",
        },
        .{
            .file_id = 3,
            .source = "static caller = func(x: int) int\n  const x = 1\n  return x",
            .function_name = "caller",
            .message = "duplicate local binding",
        },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const function_id = (try db.get(query_structures.BuildModuleScope, case.file_id)).*.?.resolve(case.function_name).?;
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqualStrings(case.message, diagnostics[0].message);
    }
}

test "parameter arity edits invalidate callers and recovery restores them" {
    const db = try testDatabase(1);
    defer db.deinit();

    SignatureParent.executions.reset();
    try addSource(db, 1,
        \\static target = func(x: int) int -> return x
        \\static caller = func() int -> return target(7)
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const target_id = scope.resolve("target").?;
    const caller_id = scope.resolve("caller").?;
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, caller_id)).* != null);

    try setSource(db, 1,
        \\static target = func(x: int, y: int) int -> return x + y
        \\static caller = func() int -> return target(7)
    );
    try testing.expectEqual(@as(?usize, 2), (try db.get(SignatureParent, target_id)).*);
    try testing.expectEqualSlices(structures.Type, &.{ .int, .int }, (try db.get(query_structures.FunctionSignature, target_id)).*.?.parameter_types);
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, caller_id)).* == null);

    try setSource(db, 1,
        \\static target = func(renamed: int) int -> return renamed
        \\static caller = func() int -> return target(7)
    );
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, caller_id)).* != null);

    try setSource(db, 1,
        \\static target = func(again: int) int -> return again
        \\static caller = func() int -> return target(7)
    );
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try SignatureParent.executions.expect(3);
}

test "immutable locals name typed values without adding binding instructions" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> return 7
        \\static locals = func() int
        \\  const base = leaf()
        \\  leaf()
        \\  const adjustment: int = 2 + 1
        \\  const scaled = base * adjustment
        \\  const alias = scaled
        \\  return alias + base
        \\locals()
    );
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const body = (try db.get(query_structures.AnalyzeFunctionBody, scope.resolve("locals").?)).*.?;

    try testing.expectEqual(@as(usize, 7), body.instructions.len);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[0].call.target);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[1].call.target);
    try testing.expectEqual(@as(i32, 2), body.instructions[2].consti);
    try testing.expectEqual(@as(i32, 1), body.instructions[3].consti);
    try testing.expectEqual(@as(u32, 2), @intFromEnum(body.instructions[4].addi.lhs));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(body.instructions[4].addi.rhs));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[5].muli.lhs));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(body.instructions[5].muli.rhs));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(body.instructions[6].addi.lhs));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[6].addi.rhs));
    try testing.expectEqual(@as(u32, 6), @intFromEnum(body.blocks[0].terminator.return_value));
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "compiled immutable locals preserve reused values across a call" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> return 7
        \\static answer = func() int
        \\  const base = leaf()
        \\  const doubled = base * 2
        \\  return doubled + base * 4
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "leaf" }, 42);
}

test "compiled parameters and nested calls preserve every argument" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static sum3 = func(a: int, b: int, c: int) int -> return a + b + c
        \\static twice = func(value: int) int -> return value * 2
        \\static answer = func() int -> return sum3(twice(10), 20, 2)
        \\sum3(1, 2, 3)
    );
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "sum3", "twice" }, 42);
}

test "local binding diagnostics follow lexical scope and declared type" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        marker: []const u8,
        message: []const u8,
    }{
        .{ .file_id = 1, .source = "static f = func() int\n  const duplicate = 1\n  const duplicate = 2\n  return 1", .marker = "duplicate", .message = "duplicate local binding" },
        .{ .file_id = 2, .source = "static f = func() int\n  const x = missing\n  return x", .marker = "missing", .message = "unknown value" },
        .{ .file_id = 3, .source = "static f = func() int\n  const x: float = 1\n  return x", .marker = "float", .message = "only int and unit local bindings are supported yet" },
        .{ .file_id = 4, .source = "static f = func() int\n  const leaf = 1\n  return leaf()", .marker = "leaf", .message = "value is not callable" },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const function_id = (try db.get(query_structures.IndexItems, case.file_id)).*.?.ids()[0];
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqualStrings(case.message, diagnostics[0].message);
        const start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + case.marker.len }, diagnostics[0].span.?);
    }
}

test "local initializer calls are typed through the callee signature" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static bad = func() float -> return 1
        \\static user = func() int
        \\  const value = bad()
        \\  return value
    );
    const user_id = (try db.get(query_structures.BuildModuleScope, 1)).*.?.resolve("user").?;
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, user_id)).* == null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, user_id, structures.Diagnostic)).len);
    const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, user_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("only int and unit return types are supported yet", diagnostics[0].message);
}

test "body edits preserve signature consumers and update body analysis" {
    const db = try testDatabase(1);
    defer db.deinit();

    SignatureParent.executions.reset();
    try addSource(db, 1, "static f = func() int\n  const value = 7\n  return value");
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    try testing.expect((try db.get(SignatureParent, function_id)).* != null);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, function_id)).*.?, 7);

    try setSource(db, 1, "static f = func() int\n  const value = 8\n  return value");
    try testing.expect((try db.get(SignatureParent, function_id)).* != null);
    try SignatureParent.executions.expect(1);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, function_id)).*.?, 8);

    try setSource(db, 1, "static f = func() foo -> return 8");
    try testing.expect((try db.get(query_structures.FunctionSignature, function_id)).* == null);
}

test "function signature rejects invalid parameter and return types without duplicate body diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static missing = func() -> return 1");
    try addSource(db, 2, "static unknown = func() foo -> return 1");
    try addSource(db, 3, "static missing_param = func(x) int -> return 1");
    try addSource(db, 4, "static bad_param = func(x: float) int -> return 1");
    try addSource(db, 5, "static duplicate = func(x: int, x: int) int -> return 1");
    try addSource(db, 6, "static mode = func(read x: int) int -> return 1");
    try addSource(db, 7, "static unit_param = func(x: unit) unit -> return");

    for ([_]structures.FileId{ 1, 2, 3, 4, 5, 6, 7 }) |file_id| {
        const function_id = (try db.get(query_structures.IndexItems, file_id)).*.?.ids()[0];
        try testing.expect((try db.get(query_structures.FunctionSignature, function_id)).* == null);
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, function_id)).* == null);
        const direct = try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic);
        try testing.expectEqual(@as(usize, 0), direct.len);
        const transitive = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(transitive);
        try testing.expectEqual(@as(usize, 1), transitive.len);
    }
}

test "function body analysis rejects unsupported body forms and literals" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static nonliteral = func() int -> return true");
    try addSource(db, 2, "static bare_return = func() int -> return");
    try addSource(db, 3, "static expression = func() int -> 7");
    try addSource(db, 4,
        \\static extra = func() int
        \\  var x = 1
        \\  return 2
    );
    try addSource(db, 5, "static float = func() int -> return 1.5");
    try addSource(db, 6, "static overflow = func() int -> return 2147483648");

    for ([_]structures.FileId{ 1, 2, 3, 4, 5, 6 }) |file_id| {
        const function_id = (try db.get(query_structures.IndexItems, file_id)).*.?.ids()[0];
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        if (file_id == 5) try testing.expectEqualStrings("only decimal integer literals are supported yet", diagnostics[0].message);
        if (file_id == 6) try testing.expectEqualStrings("integer literal does not fit i32", diagnostics[0].message);
    }
}

test "function analysis distinguishes entry stale restored and invalid identities" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 7";
    try addSource(db, 1, valid);
    const index = (try db.get(query_structures.IndexItems, 1)).*.?;
    const function_id = index.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(query_structures.FunctionSignature, entry_id)).* == null);
    try expectUnitBody((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).*.?);

    try setSource(db, 1, "");
    try testing.expect((try db.get(query_structures.FunctionSignature, function_id)).* == null);
    try setSource(db, 1, valid);
    try testing.expect((try db.get(query_structures.FunctionSignature, function_id)).* != null);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, function_id)).*.?, 7);

    const invalid: structures.ItemId = @enumFromInt(std.math.maxInt(u32));
    try testing.expectError(error.InvalidInternId, db.get(query_structures.FunctionSignature, invalid));
    try testing.expectError(error.InvalidInternId, db.get(query_structures.AnalyzeFunctionBody, invalid));
}

test "duplicate function ordinals analyze independently across reorder" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    const ids = (try db.get(query_structures.IndexItems, 1)).*.?.ids();
    const first_id = ids[0];
    const second_id = ids[1];
    SignatureParent.executions.reset();
    try testing.expect((try db.get(SignatureParent, first_id)).* != null);
    try testing.expect((try db.get(SignatureParent, second_id)).* != null);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, first_id)).*.?, 1);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, second_id)).*.?, 2);

    try setSource(db, 1,
        \\static duplicate = func() int -> return 2
        \\static duplicate = func() int -> return 1
    );
    try testing.expect((try db.get(SignatureParent, first_id)).* != null);
    try testing.expect((try db.get(SignatureParent, second_id)).* != null);
    try SignatureParent.executions.expect(2);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, first_id)).*.?, 2);
    try expectIntegerReturnBody((try db.get(query_structures.AnalyzeFunctionBody, second_id)).*.?, 1);
}

test "malformed function diagnostics remain parse-only and top-level return stays rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static f = func() int -> return 1");
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    try setSource(db, 1, "static f = func() int");
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, function_id)).* == null);
    const direct = try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), direct.len);
    const diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expect(diagnostics.len > 0);

    try addSource(db, 2, "return 7");
    const entry_id = (try db.get(query_structures.SelectEntry, 2)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
    try testing.expect((try db.get(query_structures.LowerToSSA, entry_instance)).* == null);
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* == null);
    try testing.expect((try db.get(query_structures.BuildExecutable, 2)).* == null);
    const return_span: structures.SourceSpan = .{ .start = 0, .end = "return".len };
    const entry_message = "runtime top-level statements are not supported yet";
    try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, entry_id, true, 2, return_span, entry_message);
    try expectSingleQueryDiagnostic(db, query_structures.LowerToSSA, entry_instance, false, 2, return_span, entry_message);
    try expectSingleQueryDiagnostic(db, query_structures.CompileFunction, entry_instance, false, 2, return_span, entry_message);
    const entry_diagnostics = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(entry_diagnostics);
    try testing.expectEqual(@as(usize, 1), entry_diagnostics.len);
    try testing.expectEqualStrings(entry_message, entry_diagnostics[0].message);
}

test "entry analysis rejects every runtime root" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        source: []const u8,
        marker: []const u8,
    }{
        .{ .source = "return", .marker = "return" },
        .{ .source = "const x = 1", .marker = "x" },
        .{ .source = "var x = 1", .marker = "x" },
        .{ .source = "1", .marker = "1" },
        .{ .source = "if true -> 1", .marker = "if" },
        .{ .source = "x = 1", .marker = "=" },
        .{ .source = "comptime -> return 7", .marker = "comptime" },
        .{ .source = "static ok = 1\nreturn 7\nprint(1)", .marker = "return" },
    };
    const entry_message = "runtime top-level statements are not supported yet";

    for (cases, 10..) |case, file_id| {
        try addSource(db, file_id, case.source);
        const entry_id = (try db.get(query_structures.SelectEntry, file_id)).*.?;
        const entry_instance: structures.InstanceId = .{ .item = entry_id };
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
        try testing.expect((try db.get(query_structures.LowerToSSA, entry_instance)).* == null);
        try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* == null);
        try testing.expect((try db.get(query_structures.BuildExecutable, file_id)).* == null);
        const start = std.mem.indexOf(u8, case.source, case.marker).?;
        const span: structures.SourceSpan = .{ .start = start, .end = start + case.marker.len };
        try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, entry_id, true, file_id, span, entry_message);
        try expectSingleQueryDiagnostic(db, query_structures.LowerToSSA, entry_instance, false, file_id, span, entry_message);
        try expectSingleQueryDiagnostic(db, query_structures.CompileFunction, entry_instance, false, file_id, span, entry_message);
        try expectSingleQueryDiagnostic(db, query_structures.BuildExecutable, file_id, false, file_id, span, entry_message);
    }
}

test "entry analysis resolves one direct call without analyzing its callee body" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\broken()
    );
    const index = (try db.get(query_structures.IndexItems, 1)).*.?;
    const callee_id = index.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;

    const entry_body = (try db.get(query_structures.AnalyzeFunctionBody, entry_id)).*.?;
    try testing.expectEqual(@as(usize, 1), entry_body.instructions.len);
    try testing.expectEqual(callee_id, entry_body.instructions[0].call.target);
    try testing.expect((try db.get(query_structures.FunctionSignature, callee_id)).* != null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, entry_id, structures.Diagnostic)).len);

    // The invalid body is diagnosed only when it is independently demanded.
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, callee_id)).* == null);
}

test "entry analysis validates all root syntax before resolving a call" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        source: []const u8,
        marker: []const u8,
        message: []const u8,
    }{
        .{ .source = "static bad = func() foo -> return 1\nbad()\nreturn", .marker = "return", .message = "runtime top-level statements are not supported yet" },
        .{ .source = "static f = func() int -> return 1\nf()()", .marker = "(", .message = "expression is not supported yet" },
    };

    for (cases, 10..) |case, file_id| {
        try addSource(db, file_id, case.source);
        const entry_id = (try db.get(query_structures.SelectEntry, file_id)).*.?;
        try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
        const start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, entry_id, true, file_id, .{
            .start = start,
            .end = start + case.marker.len,
        }, case.message);
    }
}

test "entry call lookup reports only the demanded resolution failure" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "missing()");
    const missing_entry = (try db.get(query_structures.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, missing_entry)).* == null);
    try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, missing_entry, true, 1, .{
        .start = 0,
        .end = "missing".len,
    }, "unknown function");

    const unsupported = "static bad = func() foo -> return 1\nbad()";
    try addSource(db, 2, unsupported);
    const unsupported_entry = (try db.get(query_structures.SelectEntry, 2)).*.?;
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, unsupported_entry)).* == null);
    const unsupported_diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, unsupported_entry, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(unsupported_diagnostics);
    try testing.expectEqual(@as(usize, 1), unsupported_diagnostics.len);
    try testing.expectEqualStrings("only int and unit return types are supported yet", unsupported_diagnostics[0].message);

    try addSource(db, 3,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
        \\duplicate()
    );
    const duplicate_entry = (try db.get(query_structures.SelectEntry, 3)).*.?;
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, duplicate_entry)).* == null);
    const duplicate_diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, duplicate_entry, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(duplicate_diagnostics);
    try testing.expectEqual(@as(usize, 1), duplicate_diagnostics.len);
    try testing.expectEqualStrings("duplicate top-level function name", duplicate_diagnostics[0].message);

    const value_source = "static value = 1\nvalue()";
    try addSource(db, 4, value_source);
    const value_entry = (try db.get(query_structures.SelectEntry, 4)).*.?;
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, value_entry)).* == null);
    const value_start = std.mem.lastIndexOf(u8, value_source, "value").?;
    try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, value_entry, true, 4, .{
        .start = value_start,
        .end = value_start + "value".len,
    }, "unknown function");
}

test "entry call dependencies follow spelling identity and runtime shape" {
    const db = try testDatabase(1);
    defer db.deinit();

    EntryCallParent.executions.reset();
    const alpha_source =
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\alpha()
    ;
    try addSource(db, 1, alpha_source);
    const initial_parse = try db.get(query_structures.ParseFile, 1);
    const initial_scope = try db.get(query_structures.BuildModuleScope, 1);
    const alpha_id = initial_scope.*.?.resolve("alpha").?;
    const bravo_id = initial_scope.*.?.resolve("bravo").?;
    try testing.expectEqual(alpha_id, (try db.get(EntryCallParent, 1)).*.?);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try testing.expectEqual(initial_parse, try db.get(query_structures.ParseFile, 1));
    try testing.expectEqual(initial_scope, try db.get(query_structures.BuildModuleScope, 1));
    try testing.expectEqual(bravo_id, (try db.get(EntryCallParent, 1)).*.?);

    try setSource(db, 1,
        \\static bravo = func() int -> return 20
        \\static alpha = func() int -> return 10
        \\bravo()
    );
    try testing.expectEqual(bravo_id, (try db.get(EntryCallParent, 1)).*.?);
    try EntryCallParent.executions.expect(2);

    // Removing the runtime call removes the scope dependency as well. Duplicate
    // names therefore remain undiagnosed until a later query demands the scope.
    try setSource(db, 1,
        \\static duplicate = func() int -> return 20
        \\static duplicate = func() int -> return 10
    );
    try testing.expect((try db.get(EntryCallParent, 1)).* == null);
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    try expectUnitBody((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).*.?);
    const empty_diagnostics = try db.transitiveAccumulatorValues(query_structures.AnalyzeFunctionBody, entry_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(empty_diagnostics);
    try testing.expectEqual(@as(usize, 0), empty_diagnostics.len);

    try setSource(db, 1, alpha_source);
    try testing.expectEqual(alpha_id, (try db.get(EntryCallParent, 1)).*.?);
}

test "call result types track signature changes while equal artifacts are retained" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() unit
        \\  return
        \\target()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const initial_body = try db.get(query_structures.AnalyzeFunctionBody, entry_id);
    const initial_ssa = try db.get(query_structures.LowerToSSA, instance);
    const initial_artifact = try db.get(query_structures.CompileFunction, instance);
    try testing.expectEqual(structures.Type.unit, initial_body.*.?.instructions[0].call.return_type);
    try testing.expectEqual(structures.Type.unit, initial_ssa.*.?.instructions[0].call.return_type);

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const updated_body = try db.get(query_structures.AnalyzeFunctionBody, entry_id);
    const updated_ssa = try db.get(query_structures.LowerToSSA, instance);
    try testing.expect(initial_body != updated_body);
    try testing.expect(initial_ssa != updated_ssa);
    try testing.expectEqual(structures.Type.int, updated_body.*.?.instructions[0].call.return_type);
    try testing.expectEqual(structures.Type.int, updated_ssa.*.?.instructions[0].call.return_type);
    try testing.expectEqual(initial_artifact, try db.get(query_structures.CompileFunction, instance));
}

test "entry call diagnostics and downstream refusal update and recover" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static value = 1\nmissing()");
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
    const initial = try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, entry_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), initial.len);
    const initial_span = initial[0].span.?;

    try setSource(db, 1, "static longer = 1\nmissing()");
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
    const moved = try db.directAccumulatorValues(query_structures.AnalyzeFunctionBody, entry_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), moved.len);
    try testing.expect(initial_span.start != moved[0].span.?.start);

    const unsupported_signature =
        \\static target = func() foo -> return 1
        \\target()
    ;
    try setSource(db, 1, unsupported_signature);
    const unsupported_parse = try db.get(query_structures.ParseFile, 1);
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    try testing.expectEqual(unsupported_parse, try db.get(query_structures.ParseFile, 1));
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* != null);
    const lowered = (try db.get(query_structures.LowerToSSA, instance)).*.?;
    const target_id = (try db.get(query_structures.BuildModuleScope, 1)).*.?.resolve("target").?;
    try expectDirectCallSsa(lowered, target_id);
    const lowering_diagnostics = try db.directAccumulatorValues(query_structures.LowerToSSA, instance, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), lowering_diagnostics.len);
    try expectDirectCallArtifact((try db.get(query_structures.CompileFunction, instance)).*.?, target_id);
    const compile_diagnostics = try db.directAccumulatorValues(query_structures.CompileFunction, instance, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), compile_diagnostics.len);
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);

    try setSource(db, 1, "");
    try testing.expect((try db.get(query_structures.LowerToSSA, instance)).* != null);
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "BuildExecutable links a direct call while keeping the entry artifact independent of the callee's value" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };

    const entry_artifact = try db.get(query_structures.CompileFunction, entry_instance);
    try testing.expect(entry_artifact.* != null);
    const initial_executable = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(initial_executable.* != null);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    runtime.writeProgram(io, initial_executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));

    // Editing only the callee's return value changes the callee's compiled
    // artifact and the linked executable, but not the caller's own artifact:
    // direct-call compilation stays independent of the callee body.
    try setSource(db, 1,
        \\static target = func() int -> return 99
        \\target()
    );
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expectEqual(entry_artifact, try db.get(query_structures.CompileFunction, entry_instance));

    const updated_executable = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(updated_executable.* != null);
    try testing.expect(!structures.Executable.eql(initial_executable.*.?, updated_executable.*.?));

    runtime.writeProgram(io, updated_executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "BuildExecutable links and runs transitively reachable calls" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> return 7
        \\static middle = func() int -> return leaf()
        \\middle()
    );
    const executable = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(executable.* != null);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    runtime.writeProgram(io, executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "BuildExecutable collects cyclic reachability without recursive compilation" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static first = func() int -> return second()
        \\static second = func() int -> return first()
        \\first()
    );
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "BuildExecutable places a shared reachable function once" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static shared = func() int -> return 305419896
        \\static left = func() int
        \\  shared()
        \\  return 1
        \\static right = func() int
        \\  shared()
        \\  return 2
        \\left()
        \\right()
    );
    const executable = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(executable.* != null);

    const shared_code = [_]u8{ 0xB8, 0x78, 0x56, 0x34, 0x12, 0xC3 };
    var occurrences: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, executable.*.?.bytes, search_from, &shared_code)) |offset| {
        occurrences += 1;
        search_from = offset + shared_code.len;
    }
    try testing.expectEqual(@as(usize, 1), occurrences);
}

test "BuildExecutable drops dependencies that become unreachable" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> return 1
        \\static middle = func() int -> return leaf()
        \\middle()
    );
    const with_leaf = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(with_leaf.* != null);

    try setSource(db, 1,
        \\static leaf = func() int -> return 1
        \\static middle = func() int -> return 9
        \\middle()
    );
    const without_leaf = try db.get(query_structures.BuildExecutable, 1);
    try testing.expect(without_leaf.* != null);
    try testing.expect(!structures.Executable.eql(with_leaf.*.?, without_leaf.*.?));

    try setSource(db, 1,
        \\static leaf = func() int -> return true
        \\static middle = func() int -> return 9
        \\middle()
    );
    try testing.expectEqual(without_leaf, try db.get(query_structures.BuildExecutable, 1));
    const diagnostics = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "BuildExecutable surfaces a callee compile failure as null with its diagnostic" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return true
        \\target()
    );
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(query_structures.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("expression is not supported yet", diagnostics[0].message);

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    try testing.expect((try db.get(query_structures.BuildExecutable, 1)).* != null);
}

test "concurrent entry call analysis shares one stable result" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    var handles: [16]Handle(query_structures.AnalyzeFunctionBody) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(query_structures.AnalyzeFunctionBody, entry_id);
    const first = try handles[0].wait();
    try testing.expect(first.* != null);
    for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
}

fn expectSingleQueryDiagnostic(
    db: *Database,
    comptime Q: type,
    input: Q.Input,
    owns_direct_diagnostic: bool,
    file_id: structures.FileId,
    span: structures.SourceSpan,
    message: []const u8,
) !void {
    const direct = try db.directAccumulatorValues(Q, input, structures.Diagnostic);
    try testing.expectEqual(@as(usize, if (owns_direct_diagnostic) 1 else 0), direct.len);

    const transitive = try db.transitiveAccumulatorValues(Q, input, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(transitive);
    try testing.expectEqual(@as(usize, 1), transitive.len);
    try testing.expectEqual(file_id, transitive[0].file_id);
    try testing.expectEqual(span, transitive[0].span.?);
    try testing.expectEqualStrings(message, transitive[0].message);
}

test "direct entry call SSA remains demand driven across callee edits and reorder" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\static other = func() int -> return 2
        \\broken()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const broken_id = (try db.get(query_structures.BuildModuleScope, 1)).*.?.resolve("broken").?;
    const initial = try db.get(query_structures.LowerToSSA, instance);
    try expectDirectCallSsa(initial.*.?, broken_id);

    // Independently demanding the invalid callee body must not create a caller
    // lowering dependency on it.
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, broken_id)).* == null);
    try setSource(db, 1,
        \\static broken = func() int -> return false
        \\static other = func() int -> return 20
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(query_structures.LowerToSSA, instance));

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(query_structures.LowerToSSA, instance));
}

test "direct entry call SSA tracks target changes removal and restoration" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\alpha()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const alpha_id = scope.resolve("alpha").?;
    const bravo_id = scope.resolve("bravo").?;
    try expectDirectCallSsa((try db.get(query_structures.LowerToSSA, instance)).*.?, alpha_id);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try expectDirectCallSsa((try db.get(query_structures.LowerToSSA, instance)).*.?, bravo_id);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
    );
    const unit = (try db.get(query_structures.LowerToSSA, instance)).*.?;
    try expectUnitSsa(unit);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try expectDirectCallSsa((try db.get(query_structures.LowerToSSA, instance)).*.?, bravo_id);
}

test "LowerToSSA produces owned value-equal functions for distinct instances" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static first = func() int -> return 7");
    try addSource(db, 2, "static second = func() int -> return 7");
    const first_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const second_id = (try db.get(query_structures.IndexItems, 2)).*.?.ids()[0];
    const first = try db.get(query_structures.LowerToSSA, .{ .item = first_id });
    const second = try db.get(query_structures.LowerToSSA, .{ .item = second_id });

    try testing.expect(first != second);
    try testing.expect(first.*.?.instructions.ptr != second.*.?.instructions.ptr);
    try testing.expect(structures.SsaFunction.eql(first.*.?, second.*.?));
    try testing.expectEqual(@as(usize, 1), first.*.?.instructions.len);
    try testing.expectEqual(@as(i32, 7), first.*.?.instructions[0].consti);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(first.*.?.blocks[0].terminator.return_value));
}

test "LowerToSSA changes with its body and retains equal results" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 7
        \\static unrelated = func() int -> return 1
    );
    const target_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const instance: structures.InstanceId = .{ .item = target_id };
    try testing.expectEqual(@as(i32, 7), (try db.get(query_structures.LowerToSSA, instance)).*.?.instructions[0].consti);

    try setSource(db, 1,
        \\static target = func() int -> return 8
        \\static unrelated = func() int -> return 1
    );
    const changed = try db.get(query_structures.LowerToSSA, instance);
    try testing.expectEqual(@as(i32, 8), changed.*.?.instructions[0].consti);

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 1
    );
    const equal_shape = try db.get(query_structures.LowerToSSA, instance);
    try testing.expectEqual(changed, equal_shape);

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 2
    );
    try testing.expectEqual(equal_shape, try db.get(query_structures.LowerToSSA, instance));
}

test "LowerToSSA exposes semantic diagnostics without duplicating them" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static header = func() foo -> return 1");
    try addSource(db, 2, "static body = func() int -> return true");
    for ([_]structures.FileId{ 1, 2 }) |file_id| {
        const item_id = (try db.get(query_structures.IndexItems, file_id)).*.?.ids()[0];
        const instance: structures.InstanceId = .{ .item = item_id };
        try testing.expect((try db.get(query_structures.LowerToSSA, instance)).* == null);
        const direct = try db.directAccumulatorValues(query_structures.LowerToSSA, instance, structures.Diagnostic);
        try testing.expectEqual(@as(usize, 0), direct.len);
        const transitive = try db.transitiveAccumulatorValues(query_structures.LowerToSSA, instance, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(transitive);
        try testing.expectEqual(@as(usize, 1), transitive.len);
    }
}

test "LowerToSSA supports entry retention failure restoration and invalid instances" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 7";
    try addSource(db, 1, valid);
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const function_instance: structures.InstanceId = .{ .item = function_id };
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    const initial_entry = try db.get(query_structures.LowerToSSA, entry_instance);
    try expectUnitSsa(initial_entry.*.?);

    try setSource(db, 1, "static value = 1");
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expectEqual(initial_entry, try db.get(query_structures.LowerToSSA, entry_instance));

    try setSource(db, 1, "");
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    try testing.expectEqual(initial_entry, try db.get(query_structures.LowerToSSA, entry_instance));
    try testing.expect((try db.get(query_structures.LowerToSSA, function_instance)).* == null);

    try setSource(db, 1, "return 7");
    try testing.expect((try db.get(query_structures.LowerToSSA, entry_instance)).* == null);
    try setSource(db, 1, "const x 1");
    try testing.expect((try db.get(query_structures.LowerToSSA, entry_instance)).* == null);
    try testing.expect((try db.get(query_structures.AnalyzeFunctionBody, entry_id)).* == null);
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* == null);
    const parse_span: structures.SourceSpan = .{ .start = 8, .end = 9 };
    const parse_message = "expected .equal, found .number_literal";
    try expectSingleQueryDiagnostic(db, query_structures.AnalyzeFunctionBody, entry_id, false, 1, parse_span, parse_message);
    try expectSingleQueryDiagnostic(db, query_structures.LowerToSSA, entry_instance, false, 1, parse_span, parse_message);
    try expectSingleQueryDiagnostic(db, query_structures.CompileFunction, entry_instance, false, 1, parse_span, parse_message);

    try setSource(db, 1, valid);
    try testing.expectEqual(entry_id, (try db.get(query_structures.SelectEntry, 1)).*.?);
    const restored_entry = (try db.get(query_structures.LowerToSSA, entry_instance)).*.?;
    try expectUnitSsa(restored_entry);
    try testing.expect((try db.get(query_structures.LowerToSSA, function_instance)).* != null);

    const invalid: structures.InstanceId = .{ .item = @enumFromInt(std.math.maxInt(u32)) };
    try testing.expectError(error.InvalidInternId, db.get(query_structures.LowerToSSA, invalid));
}

test "concurrent LowerToSSA requests share function and entry results" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "static f = func() int -> return 7\nf()");
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    for ([_]structures.InstanceId{ .{ .item = function_id }, .{ .item = entry_id } }) |instance| {
        var handles: [16]Handle(query_structures.LowerToSSA) = undefined;
        for (&handles) |*handle| handle.* = try db.spawn(query_structures.LowerToSSA, instance);
        const first = try handles[0].wait();
        for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
        if (instance.item == entry_id) {
            try expectDirectCallSsa(first.*.?, function_id);
        }
    }
}

test "CompileFunction produces owned value-equal artifacts for distinct instances" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static first = func() int -> return 7");
    try addSource(db, 2, "static second = func() int -> return 7");
    const first_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const second_id = (try db.get(query_structures.IndexItems, 2)).*.?.ids()[0];
    const first = try db.get(query_structures.CompileFunction, .{ .item = first_id });
    const second = try db.get(query_structures.CompileFunction, .{ .item = second_id });

    try testing.expect(first != second);
    try testing.expect(first.*.?.code.ptr != second.*.?.code.ptr);
    try testing.expect(structures.CompiledFunction.eql(first.*.?, second.*.?));
    try testing.expectEqualSlices(u8, &.{ 0xB8, 7, 0, 0, 0, 0xC3 }, first.*.?.code);
    try testing.expectEqual(@as(u32, 1), first.*.?.required_alignment);
    try testing.expectEqual(@as(usize, 0), first.*.?.relocations.len);
    try testing.expectEqual(@as(usize, 0), first.*.?.referenced_instances.len);
}

test "CompileFunction changes with machine code and retains equal results" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 7
        \\static unrelated = func() int -> return 1
    );
    const target_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const instance: structures.InstanceId = .{ .item = target_id };
    const initial = try db.get(query_structures.CompileFunction, instance);

    try setSource(db, 1,
        \\static target = func() int -> return 8
        \\static unrelated = func() int -> return 1
    );
    const changed = try db.get(query_structures.CompileFunction, instance);
    try testing.expect(initial != changed);
    try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, changed.*.?.code[1..5], .little));

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 1
    );
    const equal_shape = try db.get(query_structures.CompileFunction, instance);
    try testing.expectEqual(changed, equal_shape);

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 2
    );
    try testing.expectEqual(equal_shape, try db.get(query_structures.CompileFunction, instance));
}

test "direct call artifacts follow target identity without demanding the callee" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\static other = func() int -> return 2
        \\broken()
    );
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const scope = (try db.get(query_structures.BuildModuleScope, 1)).*.?;
    const broken_id = scope.resolve("broken").?;
    const other_id = scope.resolve("other").?;
    const initial = try db.get(query_structures.CompileFunction, instance);
    try expectDirectCallArtifact(initial.*.?, broken_id);
    try testing.expect((try db.get(query_structures.CompileFunction, .{ .item = broken_id })).* == null);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(query_structures.CompileFunction, instance));

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\other()
    );
    const changed = (try db.get(query_structures.CompileFunction, instance)).*.?;
    try expectDirectCallArtifact(changed, other_id);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
    );
    const unit = (try db.get(query_structures.CompileFunction, instance)).*.?;
    try testing.expectEqualSlices(u8, &.{0xC3}, unit.code);
    try testing.expectEqual(@as(usize, 0), unit.relocations.len);
    try testing.expectEqual(@as(usize, 0), unit.referenced_instances.len);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\other()
    );
    try expectDirectCallArtifact((try db.get(query_structures.CompileFunction, instance)).*.?, other_id);
}

test "CompileFunction exposes semantic diagnostics without duplicating them" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static header = func() foo -> return 1");
    try addSource(db, 2, "static body = func() int -> return true");
    for ([_]structures.FileId{ 1, 2 }) |file_id| {
        const item_id = (try db.get(query_structures.IndexItems, file_id)).*.?.ids()[0];
        const instance: structures.InstanceId = .{ .item = item_id };
        try testing.expect((try db.get(query_structures.CompileFunction, instance)).* == null);
        const direct = try db.directAccumulatorValues(query_structures.CompileFunction, instance, structures.Diagnostic);
        try testing.expectEqual(@as(usize, 0), direct.len);
        const transitive = try db.transitiveAccumulatorValues(query_structures.CompileFunction, instance, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(transitive);
        try testing.expectEqual(@as(usize, 1), transitive.len);
    }
}

test "CompileFunction supports entry retention stale restoration and invalid instances" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 7";
    try addSource(db, 1, valid);
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    const function_instance: structures.InstanceId = .{ .item = function_id };
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    const initial_entry = try db.get(query_structures.CompileFunction, entry_instance);
    try testing.expectEqualSlices(u8, &.{0xC3}, initial_entry.*.?.code);

    try setSource(db, 1, "static f = func() foo -> return true");
    try testing.expectEqual(initial_entry, try db.get(query_structures.CompileFunction, entry_instance));
    try testing.expect((try db.get(query_structures.CompileFunction, function_instance)).* == null);

    try setSource(db, 1, "");
    try testing.expectEqual(initial_entry, try db.get(query_structures.CompileFunction, entry_instance));
    try testing.expect((try db.get(query_structures.CompileFunction, function_instance)).* == null);
    try setSource(db, 1, valid);
    try testing.expect((try db.get(query_structures.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(query_structures.CompileFunction, function_instance)).* != null);

    const invalid: structures.InstanceId = .{ .item = @enumFromInt(std.math.maxInt(u32)) };
    try testing.expectError(error.InvalidInternId, db.get(query_structures.CompileFunction, invalid));
}

test "concurrent CompileFunction requests share function and entry results" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "static f = func() int -> return 7\nf()");
    const function_id = (try db.get(query_structures.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(query_structures.SelectEntry, 1)).*.?;
    for ([_]structures.InstanceId{ .{ .item = function_id }, .{ .item = entry_id } }) |instance| {
        var handles: [16]Handle(query_structures.CompileFunction) = undefined;
        for (&handles) |*handle| handle.* = try db.spawn(query_structures.CompileFunction, instance);
        const first = try handles[0].wait();
        for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
        if (instance.item == entry_id) try expectDirectCallArtifact(first.*.?, function_id);
    }
}

test "item locations survive body and unrelated-index edits but not renames" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static target = func() int -> return 1");
    const initial_result = try db.get(query_structures.DiscoverItems, 1);
    const initial_tree = initial_result.*.?;
    const initial_name = try testing.allocator.dupe(u8, initial_tree.items[0].loc.name);
    defer testing.allocator.free(initial_name);
    const initial_loc: structures.ItemLoc = .{
        .file_id = initial_tree.items[0].loc.file_id,
        .kind = initial_tree.items[0].loc.kind,
        .name = initial_name,
        .disambiguator = initial_tree.items[0].loc.disambiguator,
    };
    const initial_declaration = initial_tree.items[0].declaration;

    const updated_source =
        \\static unrelated = func() int -> return 0
        \\static target = func() int
        \\  const x = 1
        \\  return x + 1
    ;
    try setSource(db, 1, updated_source);
    const updated_result = try db.get(query_structures.DiscoverItems, 1);
    const updated_tree = updated_result.*.?;
    const target = findItemByName(updated_tree.items, "target").?;
    try testing.expect(structures.ItemLoc.eql(initial_loc, target.loc));
    try testing.expect(initial_declaration != target.declaration);

    try setSource(db, 1, "static renamed = func() int -> return 2");
    const renamed_result = try db.get(query_structures.DiscoverItems, 1);
    const renamed_tree = renamed_result.*.?;
    try testing.expect(!structures.ItemLoc.eql(initial_loc, renamed_tree.items[0].loc));
}

fn findItemByName(items: []const structures.DiscoveredItem, name: []const u8) ?structures.DiscoveredItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.loc.name, name)) return item;
    }
    return null;
}

// Incremental engine behavior.

test "source update recomputes only dependent file" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const old_name = 1");
    try addSource(db, 2, "const unchanged = 2");

    _ = try db.get(query_structures.ParseFile, 1);
    const unchanged_before = try db.get(query_structures.ParseFile, 2);

    const updated_source = "const new_name = 1";
    try setSource(db, 1, updated_source);

    const updated = try db.get(query_structures.ParseFile, 1);
    const unchanged_after = try db.get(query_structures.ParseFile, 2);

    try testing.expect(updated.* != null);
    const name_token = updated.*.?.tokens[1];
    try testing.expectEqualStrings("new_name", updated_source[name_token.loc.start..name_token.loc.end]);
    try testing.expectEqual(unchanged_before, unchanged_after);
}

test "equal recomputed child does not recompute parent" {
    const db = try testDatabase(1);
    defer db.deinit();

    Parity.executions.reset();
    ParityParent.executions.reset();

    try db.addInput(NumberInput, 1, 2);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    const diagnostics_before = try db.directAccumulatorValues(Parity, 1, structures.Diagnostic);

    try db.setInput(NumberInput, 1, 2);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    try Parity.executions.expect(1);
    try ParityParent.executions.expect(1);

    try db.setInput(NumberInput, 1, 4);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    const diagnostics_after = try db.directAccumulatorValues(Parity, 1, structures.Diagnostic);

    try Parity.executions.expect(2);
    try ParityParent.executions.expect(1);
    try testing.expectEqual(diagnostics_before.ptr, diagnostics_after.ptr);
}

test "changed diagnostic makes an equal value observable" {
    const db = try testDatabase(1);
    defer db.deinit();

    DiagnosticParent.executions.reset();
    try db.addInput(NumberInput, 1, 2);
    _ = try db.get(DiagnosticParent, 1);

    try db.setInput(NumberInput, 1, 4);
    _ = try db.get(DiagnosticParent, 1);
    try DiagnosticParent.executions.expect(2);

    const diagnostics = try db.transitiveAccumulatorValues(DiagnosticParent, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("four", diagnostics[0].message);
}

test "recomputation replaces dynamic input dependencies" {
    const db = try testDatabase(1);
    defer db.deinit();

    SelectedNumber.executions.reset();
    try db.addInput(NumberInput, 0, 1);
    try db.addInput(NumberInput, 1, 10);
    try db.addInput(NumberInput, 2, 20);
    try testing.expectEqual(@as(u32, 10), (try db.get(SelectedNumber, 0)).*);

    try db.setInput(NumberInput, 0, 2);
    try testing.expectEqual(@as(u32, 20), (try db.get(SelectedNumber, 0)).*);

    try db.setInput(NumberInput, 1, 11);
    try testing.expectEqual(@as(u32, 20), (try db.get(SelectedNumber, 0)).*);
    try SelectedNumber.executions.expect(2);
}

test "owned outputs are retained or replaced exactly once" {
    const db = try testDatabase(1);
    var db_live = true;
    defer if (db_live) db.deinit();

    OwnedOutput.deinits.reset();
    try db.addInput(NumberInput, 1, 2);
    const first = try db.get(OwnedParity, 1);

    try db.setInput(NumberInput, 1, 4);
    const equal = try db.get(OwnedParity, 1);
    try testing.expectEqual(first, equal);
    try OwnedOutput.deinits.expect(1);

    try db.setInput(NumberInput, 1, 5);
    const changed = try db.get(OwnedParity, 1);
    try testing.expect(first != changed);
    try OwnedOutput.deinits.expect(2);

    db.deinit();
    db_live = false;
    try OwnedOutput.deinits.expect(3);
}

test "failed recomputation preserves retained state and is retryable" {
    const db = try testDatabase(1);
    var db_live = true;
    defer if (db_live) db.deinit();

    OwnedOutput.deinits.reset();
    RetryableFailure.executions.reset();
    try db.addInput(NumberInput, 1, 2);
    const initial = try db.get(RetryableFailure, 1);

    try db.setInput(NumberInput, 1, 4);
    try testing.expectError(error.TestInfrastructureFailure, db.get(RetryableFailure, 1));
    try testing.expectError(error.TestInfrastructureFailure, db.get(RetryableFailure, 1));
    try RetryableFailure.executions.expect(3);
    try OwnedOutput.deinits.expect(0);

    try db.setInput(NumberInput, 1, 6);
    const replacement = try db.get(RetryableFailure, 1);
    try testing.expect(initial != replacement);
    try RetryableFailure.executions.expect(4);
    try OwnedOutput.deinits.expect(1);

    const diagnostics = try db.directAccumulatorValues(RetryableFailure, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("replacement", diagnostics[0].message);

    db.deinit();
    db_live = false;
    try OwnedOutput.deinits.expect(2);
}

test "concurrent requests observe one committed result" {
    const db = try testDatabase(4);
    defer db.deinit();

    CountedQuery.executions.reset();
    var handles: [16]Handle(CountedQuery) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(CountedQuery, 7);
    for (handles) |handle| try testing.expectEqual(@as(u32, 7), (try handle.wait()).*);
    try CountedQuery.executions.expect(1);
}

test "typed interning canonicalizes concurrent distinct queries" {
    const db = try testDatabase(4);
    defer db.deinit();

    var handles: [16]Handle(InternItemLoc) = undefined;
    for (&handles, 0..) |*handle, i| handle.* = try db.spawn(InternItemLoc, @intCast(i));

    const even_id = (try handles[0].wait()).*;
    const odd_id = (try handles[1].wait()).*;
    try testing.expect(even_id != odd_id);
    for (handles, 0..) |handle, i| {
        try testing.expectEqual(if (i % 2 == 0) even_id else odd_id, (try handle.wait()).*);
    }
}

test "failed interning publishes no partial identity" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(failing.allocator(), .{ .worker_count = 1 });
    var db_live = true;
    defer if (db_live) db.deinit();

    failing.fail_index = failing.alloc_index + 3;
    const loc: structures.ItemLoc = .{ .file_id = 1, .kind = .function, .name = "owned", .disambiguator = 0 };
    try testing.expectError(error.OutOfMemory, db.intern(query_structures.ItemLocations, loc));
    try testing.expect(failing.has_induced_failure);
    try testing.expectError(error.InvalidInternId, db.lookupInterned(query_structures.ItemLocations, @enumFromInt(0)));

    failing.fail_index = std.math.maxInt(usize);
    const id = try db.intern(query_structures.ItemLocations, loc);
    try testing.expectEqualStrings("owned", (try db.lookupInterned(query_structures.ItemLocations, id)).name);

    db.deinit();
    db_live = false;
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "stale dependencies do not create false cycles" {
    const db = try testDatabase(2);
    defer db.deinit();

    try db.addInput(NumberInput, 10, 0);
    try db.addInput(NumberInput, 11, 0);
    try testing.expectEqual(@as(u32, 0), (try db.get(DynamicCycleA, 1)).*);

    try db.setInput(NumberInput, 10, 1);
    try db.setInput(NumberInput, 11, 1);
    try testing.expectEqual(@as(u32, 1), (try db.get(DynamicCycleB, 1)).*);
}

test "database initialization frees state when worker allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, Database.init(failing.allocator(), .{ .worker_count = 1 }));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
