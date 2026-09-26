const std = @import("std");
const test_sources = @import("test_sources");
const codegen = test_sources.codegen;
const query = test_sources.query;
const queries = test_sources.queries;
const runtime = test_sources.runtime;
const structures = test_sources.structures;

const Context = query.Context;
const Database = query.Database;
const Handle = query.Handle;
const testing = std.testing;
const DiagnosticKind = std.meta.Tag(structures.Diagnostic.Kind);

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
    const db = try Database.init(testing.allocator, .{ .worker_count = worker_count });
    errdefer db.deinit();
    const sources = [_]struct { path: []const u8, text: []const u8 }{
        .{ .path = "std.exit", .text = "pub extern func exit(code: int) never" },
        .{ .path = "std.prelude", .text = "pub import std.exit.{exit}" },
    };
    for (sources, 0..) |source, index| {
        const file_id: structures.FileId = 100_000 + index;
        const module = try db.intern(queries.ModulePaths, .{ .path = source.path });
        try db.addInput(queries.FileModule, file_id, module);
        try db.addInput(queries.SourceText, file_id, source.text);
        try db.addInput(queries.ModuleMembers, module, &.{file_id});
        if (index == 0) try db.addInput(queries.StandardFile, queries.standardFileKey("exit.chi"), file_id);
    }
    return db;
}

fn addSource(db: *Database, file_id: structures.FileId, source: []const u8) !void {
    try enableExitPrelude(db, source);
    try db.addInput(queries.SourceText, file_id, source);
    const name = try std.fmt.allocPrint(testing.allocator, "test-module-{d}", .{file_id});
    defer testing.allocator.free(name);
    const module = try db.intern(queries.ModulePaths, .{ .path = name });
    try db.addInput(queries.FileModule, file_id, module);
    try db.addInput(queries.ModuleMembers, module, &.{file_id});
}

fn enableExitPrelude(db: *Database, source: []const u8) !void {
    if (std.mem.indexOf(u8, source, "exit(") != null) {
        const prelude = try db.intern(queries.ModulePaths, .{ .path = "std.prelude" });
        db.addInput(queries.StandardPreludeModule, {}, prelude) catch |err| switch (err) {
            error.DuplicateInput => {},
            else => return err,
        };
    }
}

fn addModuleFile(db: *Database, file_id: structures.FileId, module_path: []const u8, source: []const u8) !structures.ModuleId {
    try enableExitPrelude(db, source);
    const module = try db.intern(queries.ModulePaths, .{ .path = module_path });
    try db.addInput(queries.FileModule, file_id, module);
    try db.addInput(queries.SourceText, file_id, source);
    return module;
}

const ReadModuleCatalog = struct {
    pub const Input = void;
    pub const Output = struct {
        modules: []structures.ModuleId,

        pub fn eql(a: @This(), b: @This()) bool {
            return std.mem.eql(structures.ModuleId, a.modules, b.modules);
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.modules);
            self.* = undefined;
        }
    };

    pub fn run(ctx: anytype, _: void) !Output {
        return .{ .modules = try ctx.allocator().dupe(structures.ModuleId, (try ctx.input(queries.ModuleCatalog, {})).*) };
    }
};

fn addModuleMembers(db: *Database, module: structures.ModuleId, files: []const structures.FileId) !void {
    try db.addInput(queries.ModuleMembers, module, files);
    db.addInput(queries.ModuleCatalog, {}, &.{module}) catch |err| switch (err) {
        error.DuplicateInput => {
            const catalog = (try db.get(ReadModuleCatalog, {})).modules;
            const updated = try db.allocator.alloc(structures.ModuleId, catalog.len + 1);
            defer db.allocator.free(updated);
            @memcpy(updated[0..catalog.len], catalog);
            updated[catalog.len] = module;
            try db.setInput(queries.ModuleCatalog, {}, updated);
        },
        else => return err,
    };
}

fn setSource(db: *Database, file_id: structures.FileId, source: []const u8) !void {
    try enableExitPrelude(db, source);
    try db.setInput(queries.SourceText, file_id, source);
}

fn lookupCompileTimeValue(db: *Database, value_id: structures.CompileTimeValueId) !structures.CompileTimeValue {
    return (try db.lookupInterned(queries.CompileTimeValues, value_id)).*;
}

fn resolvedStaticValue(db: *Database, item_id: structures.ItemId) !structures.CompileTimeValue {
    const value_id = (try db.get(queries.ResolveStatic, item_id)).*.?;
    return lookupCompileTimeValue(db, value_id);
}

fn resolvedStaticType(db: *Database, item_id: structures.ItemId) !structures.TypeId {
    return switch (try resolvedStaticValue(db, item_id)) {
        .type => |type_id| type_id,
        .runtime => unreachable,
    };
}

fn freeDiagnostics(diagnostics: []structures.Diagnostic) void {
    testing.allocator.free(diagnostics);
}

/// Synthetic accumulator payload with an owned message, used to exercise the
/// engine's clone, equality, and cleanup paths for owned accumulators.
const OwnedDiagnostic = struct {
    file_id: structures.FileId,
    span: ?structures.SourceSpan,
    message: []const u8,

    pub fn clone(gpa: std.mem.Allocator, value: OwnedDiagnostic) !OwnedDiagnostic {
        return .{
            .file_id = value.file_id,
            .span = value.span,
            .message = try gpa.dupe(u8, value.message),
        };
    }

    pub fn deinit(self: *OwnedDiagnostic, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
        self.* = undefined;
    }

    pub fn eql(a: OwnedDiagnostic, b: OwnedDiagnostic) bool {
        return a.file_id == b.file_id and std.meta.eql(a.span, b.span) and std.mem.eql(u8, a.message, b.message);
    }
};

fn freeOwnedDiagnostics(diagnostics: []OwnedDiagnostic) void {
    for (diagnostics) |*diagnostic| diagnostic.deinit(testing.allocator);
    testing.allocator.free(diagnostics);
}

fn expectDirectCallBody(ssa: structures.FunctionBodyAnalysis, target: structures.ItemId) !void {
    try testing.expectEqual(@as(usize, 1), ssa.instructions.len);
    try testing.expectEqual(target, ssa.instructions[0].call.target);
    try testing.expectEqual(@as(usize, 1), ssa.blocks.len);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, ssa.blocks[0].terminator);
}

fn expectDirectCallArtifact(artifact: structures.CompiledFunction, target: structures.ItemId) !void {
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0, 0, 0, 0, 0xBA, 1, 0, 0, 0, 0xC3 }, artifact.code);
    try testing.expectEqual(@as(u32, 1), artifact.required_alignment);
    try testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    try testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try testing.expectEqual(structures.CompiledFunction.RelocationKind.call_relative_32, artifact.relocations[0].kind);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(artifact.relocations[0].reference));
    try testing.expectEqual(@as(i64, 0), artifact.relocations[0].addend);
    try testing.expectEqualSlices(structures.InstanceId, &.{.{ .item = target }}, artifact.referenced_instances);
}

fn expectIntegerReturnBody(body: structures.FunctionBodyAnalysis, expected: i32) !void {
    try testing.expectEqual(@as(usize, 1), body.instructions.len);
    try testing.expectEqual(expected, body.instructions[0].const_int);
    try testing.expectEqual(@as(usize, 1), body.blocks.len);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.blocks[0].terminator.return_value.value));
}

fn expectDirectValueUses(expected: []const structures.FunctionValueId, actual: []const structures.FunctionValueUse) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_use| {
        try testing.expectEqual(expected_value, actual_use.value);
        try testing.expectEqual(@as(?structures.TypeId, null), actual_use.coerce_to);
    }
}

fn expectImmParameters(expected: []const structures.TypeId, actual: []const structures.CallableParameter) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_type, parameter| {
        try testing.expectEqual(structures.ParameterMode.imm, parameter.mode);
        try testing.expectEqual(expected_type, parameter.type_id);
    }
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
    const scope = (try db.get(queries.BuildModuleScope, file_id)).*.?;
    const function_id: structures.InstanceId = .{ .item = scope.resolve(function_name).? };
    const entry_id: structures.InstanceId = .{ .item = (try db.get(queries.SelectEntry, file_id)).*.? };

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
        const artifact = (try db.get(queries.CompileFunction, instance)).*.?;
        try functions.append(testing.allocator, .{ .instance = instance, .artifact = artifact });
    }

    var next: usize = 1;
    while (next < functions.items.len) : (next += 1) {
        for (functions.items[next].artifact.referenced_instances) |instance| {
            for (functions.items) |function| {
                if (std.meta.eql(function.instance, instance)) break;
            } else {
                const artifact = (try db.get(queries.CompileFunction, instance)).*.?;
                try functions.append(testing.allocator, .{ .instance = instance, .artifact = artifact });
            }
        }
    }

    var executable = try codegen.buildExecutable(entry_id, functions.items, testing.allocator);
    defer executable.deinit(testing.allocator);
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(expected, runtime.runProg(io, testing.allocator, &.{}));
}

// Inspect the return ABI of eight-byte variants.
// The process status exposes the low byte of the selected tag or payload word.
fn expectCompiledVariantWord(
    db: *Database,
    file_id: structures.FileId,
    function_name: []const u8,
    reachable_names: []const []const u8,
    byte_offset: u8,
    expected: u8,
) !void {
    std.debug.assert(byte_offset == 0 or byte_offset == 4);
    const scope = (try db.get(queries.BuildModuleScope, file_id)).*.?;
    const function_id: structures.InstanceId = .{ .item = scope.resolve(function_name).? };
    const entry_id: structures.InstanceId = .{ .item = (try db.get(queries.SelectEntry, file_id)).*.? };

    const exit_with_word_code = [_]u8{
        0x48, 0x81,        0xEC, 8, 0, 0,    0,
        0xE8, 0,           0,    0, 0, 0x8B, 0x84,
        0x24, byte_offset, 0,    0, 0, 0x48, 0x81,
        0xC4, 8,           0,    0, 0, 0x89, 0xC7,
        0xB8, 60,          0,    0, 0, 0x0F, 0x05,
    };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 8,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{function_id};
    const entry: structures.CompiledFunction = .{
        .code = &exit_with_word_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };

    var functions: std.ArrayList(codegen.ReachableFunction) = .empty;
    defer functions.deinit(testing.allocator);
    try functions.append(testing.allocator, .{ .instance = entry_id, .artifact = entry });
    for (reachable_names) |name| {
        const instance: structures.InstanceId = .{ .item = scope.resolve(name).? };
        const artifact = (try db.get(queries.CompileFunction, instance)).*.?;
        try functions.append(testing.allocator, .{ .instance = instance, .artifact = artifact });
    }

    var executable = try codegen.buildExecutable(entry_id, functions.items, testing.allocator);
    defer executable.deinit(testing.allocator);
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
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

const ReadFileModule = struct {
    pub const Input = structures.FileId;
    pub const Output = structures.ModuleId;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.input(queries.FileModule, input_value)).*;
    }
};

const Parity = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(OwnedDiagnostic, .{ .file_id = input_value, .span = null, .message = "parity" });
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
        try ctx.emit(OwnedDiagnostic, .{
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

const ConditionalControlLeaf = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        const value = (try ctx.input(NumberInput, input_value)).*;
        if (value != 0) try ctx.emit(structures.CompilerControl, .{ .exit = @intCast(value) });
        return 1;
    }
};

const ConditionalControlMiddle = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        return (try ctx.get(ConditionalControlLeaf, input_value)).*;
    }
};

const ConditionalControlRoot = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        return (try ctx.get(ConditionalControlMiddle, input_value)).*;
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
        const value = (try ctx.input(NumberInput, input_value)).*;
        const bytes = try ctx.allocator().alloc(u8, 1);
        bytes[0] = @intCast(value % 2);
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
        try ctx.emit(OwnedDiagnostic, .{
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

const AwaitedLeaf = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(_: *Context, input_value: Input) anyerror!Output {
        return input_value;
    }
};

const WaitingParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var started: std.atomic.Value(bool) = .init(false);
    var may_wait: std.atomic.Value(bool) = .init(false);

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const leaf = try ctx.spawn(AwaitedLeaf, input_value);
        started.store(true, .release);
        while (!may_wait.load(.acquire)) std.atomic.spinLoopHint();
        return (try leaf.wait()).*;
    }
};

const ParentDependentSibling = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(WaitingParent, input_value)).*;
    }
};

const InternItemLoc = struct {
    pub const Input = u32;
    pub const Output = structures.ItemId;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const module = try ctx.intern(queries.ModulePaths, .{ .path = "" });
        return ctx.intern(queries.ItemLocations, .{
            .origin = .{ .module = module },
            .kind = .function,
            .name = if (input_value % 2 == 0) "even" else "odd",
        });
    }
};

const InternVariantPair = struct {
    pub const Input = [2]structures.TypeId;
    pub const Output = structures.InternVariantResult;

    pub fn run(ctx: *Context, members: Input) anyerror!Output {
        return queries.internVariantType(ctx, &members);
    }
};

const InternVariantTriple = struct {
    pub const Input = [3]structures.TypeId;
    pub const Output = structures.InternVariantResult;

    pub fn run(ctx: *Context, members: Input) anyerror!Output {
        return queries.internVariantType(ctx, &members);
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
        try ctx.emit(OwnedDiagnostic, .{
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
        try ctx.emit(OwnedDiagnostic, .{
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
        return (try ctx.get(queries.SelectEntry, file_id)).*;
    }
};

const ModuleScopeParent = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        executions.increment();
        const scope = (try ctx.get(queries.BuildModuleScope, file_id)).* orelse return null;
        return scope.resolve("alpha");
    }
};

const SignatureParent = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?usize;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, item_id: Input) anyerror!Output {
        executions.increment();
        const signature = (try ctx.get(queries.FunctionSignature, item_id)).* orelse return null;
        return signature.parameters.len;
    }
};

const EntryCallParent = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        executions.increment();
        const entry_id = (try ctx.get(queries.SelectEntry, file_id)).* orelse return null;
        const body = (try ctx.get(queries.AnalyzeFunctionBody, entry_id)).* orelse return null;
        if (body.instructions.len != 1) return null;
        return switch (body.instructions[0]) {
            .call => |call| call.target,
            else => null,
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

test "module paths intern by contents and files map to modules" {
    const db = try testDatabase(1);
    defer db.deinit();

    const entry = try db.intern(queries.ModulePaths, .{ .path = "" });
    try testing.expectEqual(entry, try db.intern(queries.ModulePaths, .{ .path = "" }));
    const physics = try db.intern(queries.ModulePaths, .{ .path = "physics" });
    const collision = try db.intern(queries.ModulePaths, .{ .path = "physics.collision" });
    try testing.expect(entry != physics);
    try testing.expect(physics != collision);
    try testing.expectEqualStrings("", (try db.lookupInterned(queries.ModulePaths, entry)).path);
    try testing.expectEqualStrings("physics.collision", (try db.lookupInterned(queries.ModulePaths, collision)).path);

    try db.addInput(queries.FileModule, 1, entry);
    try db.addInput(queries.FileModule, 2, physics);
    try testing.expectEqual(entry, (try db.get(ReadFileModule, 1)).*);
    try testing.expectEqual(physics, (try db.get(ReadFileModule, 2)).*);
    try testing.expectError(error.InputNotFound, db.get(ReadFileModule, 3));
}

test "same-module declarations are visible across files" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "static answer = 40");
    _ = try addModuleFile(db, 2, "physics", "exit(answer)");
    try addModuleMembers(db, module, &.{ 1, 2 });
    const entry_id = (try db.get(queries.SelectEntry, 2)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
    const executable = (try db.get(queries.BuildExecutable, 2)).*.?;
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(@as(u8, 40), runtime.runProg(io, testing.allocator, &.{}));
}

test "cross-file duplicates blame the second file" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "static dup = 1");
    _ = try addModuleFile(db, 2, "physics", "static dup = 2");
    try addModuleMembers(db, module, &.{ 1, 2 });
    try testing.expect((try db.get(queries.BuildModuleScope, 1)).* == null);
    const source = "static dup = 2";
    const start = std.mem.indexOf(u8, source, "dup").?;
    try expectSingleQueryDiagnostic(db, queries.BuildModuleScope, 1, false, 2, .{
        .start = start,
        .end = start + "dup".len,
    }, .duplicate_top_level_declaration);
}

test "relocating a declaration between files preserves identity" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "static answer = 40");
    _ = try addModuleFile(db, 2, "physics", "exit(answer)");
    try addModuleMembers(db, module, &.{ 1, 2 });
    const before = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    const entry_id = (try db.get(queries.SelectEntry, 2)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);

    try setSource(db, 1, "static filler = 0");
    try setSource(db, 2, "static answer = 40\nexit(answer)");
    const after = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    try testing.expectEqual(before, after);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "removed files stop resolving declarations" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "static answer = 40");
    _ = try addModuleFile(db, 2, "physics", "exit(answer)");
    try addModuleMembers(db, module, &.{ 1, 2 });
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    try testing.expectEqual(@as(structures.FileId, 1), (try db.get(queries.ResolveItem, answer)).*.?.file_id);

    try db.setInput(queries.ModuleMembers, module, &.{});
    try testing.expect((try db.get(queries.ResolveItem, answer)).* == null);
}

test "module membership updates change the visible scope" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "static answer = 40");
    _ = try addModuleFile(db, 2, "physics", "exit(answer)");
    const entry_id = (try db.get(queries.SelectEntry, 2)).*.?;
    try testing.expectError(error.InputNotFound, db.get(queries.AnalyzeFunctionBody, entry_id));

    try addModuleMembers(db, module, &.{ 1, 2 });
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
}

test "entries stay file-specific within one module" {
    const db = try testDatabase(1);
    defer db.deinit();

    const module = try addModuleFile(db, 1, "physics", "exit(1)");
    _ = try addModuleFile(db, 2, "physics", "exit(2)");
    try addModuleMembers(db, module, &.{ 1, 2 });
    const first = (try db.get(queries.SelectEntry, 1)).*.?;
    const second = (try db.get(queries.SelectEntry, 2)).*.?;
    try testing.expect(first != second);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, first)).* != null);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, second)).* != null);
}

test "registered empty modules exist without members" {
    const db = try testDatabase(1);
    defer db.deinit();

    const empty = try db.intern(queries.ModulePaths, .{ .path = "empty" });
    try addModuleMembers(db, empty, &.{});
    const declarations = (try db.get(queries.ModuleDeclarations, empty)).*.?;
    try testing.expectEqual(@as(usize, 0), declarations.entries.len);

    const missing = try db.intern(queries.ModulePaths, .{ .path = "missing" });
    try testing.expectError(error.InputNotFound, db.get(queries.ModuleDeclarations, missing));
}

test "import forms bind namespaces and declarations" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics",
        \\pub static Pub = 1
        \\static Priv = 2
    );
    const entry = try addModuleFile(db, 2, "",
        \\import physics
        \\import physics as phys
        \\import physics.{Pub}
        \\import physics.{Pub as Renamed}
    );
    try addModuleMembers(db, physics, &.{1});
    try addModuleMembers(db, entry, &.{2});
    const bindings = (try db.get(queries.ResolveFileImports, 2)).*.?;
    try testing.expectEqual(@as(usize, 1), bindings.modules.len);
    try testing.expectEqual(physics, bindings.modules[0]);
    try testing.expectEqual(@as(usize, 4), bindings.imports.len);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const pub_id = scope.resolve("Pub").?;
    try testing.expectEqualStrings("phys", bindings.imports[2].name);
    try testing.expectEqual(structures.ImportTarget{ .namespace = .{ .module = physics } }, bindings.imports[2].target);
    try testing.expectEqualStrings("Pub", bindings.imports[0].name);
    try testing.expectEqual(structures.ImportTarget{ .declaration = pub_id }, bindings.imports[0].target);
    try testing.expectEqualStrings("Renamed", bindings.imports[1].name);
    try testing.expectEqual(structures.ImportTarget{ .declaration = pub_id }, bindings.imports[1].target);
    for (bindings.imports) |binding| try testing.expect(!binding.reexport);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveFileImports, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "unknown modules and names are rejected at the import" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics", "pub static Pub = 1");
    const entry = try addModuleFile(db, 2, "", "import nosuch");
    try addModuleMembers(db, physics, &.{1});
    try addModuleMembers(db, entry, &.{2});
    try testing.expect((try db.get(queries.ResolveFileImports, 2)).* == null);
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 2, true, 2, .{
        .start = "import ".len,
        .end = "import nosuch".len,
    }, .unknown_module);

    try setSource(db, 2, "import physics.{Nope}");
    try testing.expect((try db.get(queries.ResolveFileImports, 2)).* == null);
    const source = "import physics.{Nope}";
    const start = std.mem.indexOf(u8, source, "Nope").?;
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 2, true, 2, .{
        .start = start,
        .end = start + "Nope".len,
    }, .unknown_imported_name);
}

test "private declarations are rejected at the import" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics", "static Priv = 2");
    const entry = try addModuleFile(db, 2, "", "import physics.{Priv}");
    try addModuleMembers(db, physics, &.{1});
    try addModuleMembers(db, entry, &.{2});
    try testing.expect((try db.get(queries.ResolveFileImports, 2)).* == null);
    const source = "import physics.{Priv}";
    const start = std.mem.indexOf(u8, source, "Priv").?;
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 2, true, 2, .{
        .start = start,
        .end = start + "Priv".len,
    }, .private_access);
}

test "conflicting imports are rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics", "pub static Pub = 1");
    const other = try addModuleFile(db, 2, "other", "pub static Pub = 2");
    const entry = try addModuleFile(db, 3, "", "static Pub = 0\nimport physics.{Pub}");
    try addModuleMembers(db, physics, &.{1});
    try addModuleMembers(db, other, &.{2});
    try addModuleMembers(db, entry, &.{3});
    try testing.expect((try db.get(queries.ResolveFileImports, 3)).* == null);
    const start = ("static Pub = 0\n").len + std.mem.indexOf(u8, "import physics.{Pub}", "Pub").?;
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 3, true, 3, .{
        .start = start,
        .end = start + "Pub".len,
    }, .import_conflict);

    try setSource(db, 3, "import physics.{Pub}\nimport other.{Pub}");
    try testing.expect((try db.get(queries.ResolveFileImports, 3)).* == null);
    const second = "import other.{Pub}";
    const other_start = ("import physics.{Pub}\n").len + std.mem.indexOf(u8, second, "Pub").?;
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 3, true, 3, .{
        .start = other_start,
        .end = other_start + "Pub".len,
    }, .import_conflict);
}

test "exact duplicate imports merge harmlessly" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics", "pub static Pub = 1");
    const entry = try addModuleFile(db, 2, "",
        \\import physics
        \\import physics
        \\import physics.{Pub}
        \\import physics.{Pub}
        \\pub import physics.{Pub}
    );
    try addModuleMembers(db, physics, &.{1});
    try addModuleMembers(db, entry, &.{2});
    const bindings = (try db.get(queries.ResolveFileImports, 2)).*.?;
    try testing.expectEqual(@as(usize, 1), bindings.modules.len);
    try testing.expectEqual(@as(usize, 2), bindings.imports.len);
    try testing.expectEqualStrings("Pub", bindings.imports[0].name);
    try testing.expect(bindings.imports[0].reexport);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveFileImports, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "reexport chains share declaration identity" {
    const db = try testDatabase(1);
    defer db.deinit();

    const inner = try addModuleFile(db, 1, "inner", "pub static X = 1");
    const middle = try addModuleFile(db, 2, "middle", "pub import inner.{X}");
    const entry = try addModuleFile(db, 3, "", "import middle.{X}");
    try addModuleMembers(db, inner, &.{1});
    try addModuleMembers(db, middle, &.{2});
    try addModuleMembers(db, entry, &.{3});
    const bindings = (try db.get(queries.ResolveFileImports, 3)).*.?;
    const expected = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("X").?;
    try testing.expectEqual(@as(usize, 1), bindings.imports.len);
    try testing.expectEqual(structures.ImportTarget{ .declaration = expected }, bindings.imports[0].target);
}

test "reexported modules bind namespaces" {
    const db = try testDatabase(1);
    defer db.deinit();

    const inner = try addModuleFile(db, 1, "inner", "pub static X = 1");
    const middle = try addModuleFile(db, 2, "middle", "pub import inner\npub import inner as See");
    const entry = try addModuleFile(db, 3, "", "import middle.{inner}\nimport middle.{See}");
    try addModuleMembers(db, inner, &.{1});
    try addModuleMembers(db, middle, &.{2});
    try addModuleMembers(db, entry, &.{3});
    const bindings = (try db.get(queries.ResolveFileImports, 3)).*.?;
    try testing.expectEqual(@as(usize, 2), bindings.imports.len);
    try testing.expectEqual(structures.ImportTarget{ .namespace = .{ .module = inner } }, bindings.imports[0].target);
    try testing.expectEqual(structures.ImportTarget{ .namespace = .{ .module = inner } }, bindings.imports[1].target);
}

test "cyclic module imports resolve without semantic cycles" {
    const db = try testDatabase(1);
    defer db.deinit();

    const first = try addModuleFile(db, 1, "first", "import second\npub static X = 1");
    const second = try addModuleFile(db, 2, "second", "import first\npub static Y = 2");
    try addModuleMembers(db, first, &.{1});
    try addModuleMembers(db, second, &.{2});
    const first_bindings = (try db.get(queries.ResolveFileImports, 1)).*.?;
    try testing.expectEqual(@as(usize, 1), first_bindings.modules.len);
    try testing.expectEqual(second, first_bindings.modules[0]);
    const second_bindings = (try db.get(queries.ResolveFileImports, 2)).*.?;
    try testing.expectEqual(first, second_bindings.modules[0]);
    for ([2]structures.FileId{ 1, 2 }) |file_id| {
        const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveFileImports, file_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 0), diagnostics.len);
    }
}

test "conflicting reexports from different files are rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    const a = try addModuleFile(db, 1, "a", "pub static X = 1");
    const b = try addModuleFile(db, 2, "b", "pub static X = 2");
    const middle = try addModuleFile(db, 3, "middle", "pub import a.{X}");
    _ = try addModuleFile(db, 4, "middle", "pub import b.{X}");
    const entry = try addModuleFile(db, 5, "", "import middle.{X}");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, b, &.{2});
    try addModuleMembers(db, middle, &.{ 3, 4 });
    try addModuleMembers(db, entry, &.{5});
    const source = "import middle.{X}";
    const start = std.mem.indexOf(u8, source, "X}").?;
    const span = structures.SourceSpan{ .start = start, .end = start + 1 };
    try testing.expect((try db.get(queries.ResolveFileImports, 5)).* == null);
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 5, true, 5, span, .import_conflict);

    try db.setInput(queries.ModuleMembers, middle, &.{ 4, 3 });
    try testing.expect((try db.get(queries.ResolveFileImports, 5)).* == null);
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 5, true, 5, span, .import_conflict);
}

test "reexport loops are declaration cycles" {
    const db = try testDatabase(1);
    defer db.deinit();

    const cycle = try addModuleFile(db, 1, "cycle", "pub import cycle.{X}");
    _ = try addModuleFile(db, 2, "cycle", "import cycle.{X}");
    try addModuleMembers(db, cycle, &.{ 1, 2 });
    try testing.expect((try db.get(queries.ResolveFileImports, 2)).* == null);
    const source = "import cycle.{X}";
    const start = std.mem.indexOf(u8, source, "X}").?;
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 2, true, 2, .{
        .start = start,
        .end = start + 1,
    }, .declaration_cycle);
}

test "self imports bind uniformly" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics = try addModuleFile(db, 1, "physics", "import physics\npub static Pub = 1");
    try addModuleMembers(db, physics, &.{1});
    const bindings = (try db.get(queries.ResolveFileImports, 1)).*.?;
    try testing.expectEqual(@as(usize, 1), bindings.modules.len);
    try testing.expectEqual(physics, bindings.modules[0]);
    try testing.expectEqual(@as(usize, 1), bindings.imports.len);
}

test "module catalog additions and removals invalidate missing imports" {
    const db = try testDatabase(1);
    defer db.deinit();
    const entry = try addModuleFile(db, 1, "", "import missing");
    try addModuleMembers(db, entry, &.{1});
    try testing.expect((try db.get(queries.ResolveFileImports, 1)).* == null);
    const missing = try db.intern(queries.ModulePaths, .{ .path = "missing" });
    try addModuleMembers(db, missing, &.{});
    try testing.expect((try db.get(queries.ResolveFileImports, 1)).* != null);
    try db.setInput(queries.ModuleCatalog, {}, &.{entry});
    try testing.expect((try db.get(queries.ResolveFileImports, 1)).* == null);
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 1, true, 1, .{ .start = 7, .end = 14 }, .unknown_module);
}

test "empty selective imports neither bind nor reexport a namespace" {
    const db = try testDatabase(1);
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "");
    const middle = try addModuleFile(db, 2, "middle", "pub import a.{}");
    const entry = try addModuleFile(db, 3, "", "import middle.{a}");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, middle, &.{2});
    try addModuleMembers(db, entry, &.{3});
    const empty = (try db.get(queries.ResolveFileImports, 2)).*.?;
    try testing.expectEqual(@as(usize, 0), empty.modules.len);
    try testing.expectEqual(@as(usize, 0), empty.imports.len);
    try testing.expect((try db.get(queries.ResolveFileImports, 3)).* == null);
    try expectSingleQueryDiagnostic(db, queries.ResolveFileImports, 3, true, 3, .{ .start = 15, .end = 16 }, .unknown_imported_name);
}

test "whole module imports obey the same conflicts as aliases" {
    const db = try testDatabase(1);
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "");
    const b = try addModuleFile(db, 2, "b", "");
    const entry = try addModuleFile(db, 3, "", "");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, b, &.{2});
    try addModuleMembers(db, entry, &.{3});
    for ([_][]const u8{
        "import a\nimport b as a",
        "import b as a\nimport a",
        "static a = 1\nimport a",
    }) |source| {
        try setSource(db, 3, source);
        try testing.expect((try db.get(queries.ResolveFileImports, 3)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveFileImports, 3, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.import_conflict, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "namespace prefixes do not grant parent members and imports merge permissions" {
    const db = try testDatabase(2);
    defer db.deinit();
    const physics = try db.intern(queries.ModulePaths, .{ .path = "physics" });
    const collision = try db.intern(queries.ModulePaths, .{ .path = "physics.collision" });
    const world = try db.intern(queries.ModulePaths, .{ .path = "physics.world" });
    const entry = try addModuleFile(db, 1, "", "pub import physics.collision\nimport physics.world");
    try addModuleMembers(db, physics, &.{});
    try addModuleMembers(db, collision, &.{});
    try addModuleMembers(db, world, &.{});
    try addModuleMembers(db, entry, &.{1});
    const before = (try db.get(queries.ResolveFileImports, 1)).*.?;
    try testing.expectEqual(@as(usize, 2), before.modules.len);
    try testing.expectEqual(@as(usize, 1), before.imports.len);
    try testing.expectEqualStrings("physics", before.imports[0].name);
    try testing.expectEqual(structures.ImportTarget{ .namespace = .{ .module = physics, .members_visible = false } }, before.imports[0].target);
    // A namespace alias to the same root explicitly grants its members.
    try setSource(db, 1, "import physics.collision\nimport physics as physics");
    const after = (try db.get(queries.ResolveFileImports, 1)).*.?;
    try testing.expectEqual(structures.ImportTarget{ .namespace = .{ .module = physics } }, after.imports[0].target);
    try testing.expectEqual(@as(usize, 1), after.imports.len);
}

test "equivalent import order retains the resolved allocation" {
    const db = try testDatabase(1);
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "pub static X = 1\npub static Y = 2");
    const entry = try addModuleFile(db, 2, "", "import a\nimport a.{X, Y}");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, entry, &.{2});
    const before = try db.get(queries.ResolveFileImports, 2);
    try setSource(db, 2, "import a.{Y}\nimport a.{X}\nimport a\nimport a");
    try testing.expectEqual(before, try db.get(queries.ResolveFileImports, 2));
}

test "reexport diamonds merge equal identities without false cycles" {
    const db = try testDatabase(2);
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "pub struct X\n  value: int");
    const b = try addModuleFile(db, 2, "b", "pub import a.{X}");
    const c = try addModuleFile(db, 3, "c", "pub import a.{X}");
    const middle = try addModuleFile(db, 4, "middle", "pub import b.{X}\npub import c.{X}");
    const entry = try addModuleFile(db, 5, "", "import middle.{X}");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, b, &.{2});
    try addModuleMembers(db, c, &.{3});
    try addModuleMembers(db, middle, &.{4});
    try addModuleMembers(db, entry, &.{5});
    const expected = (try db.get(queries.ModuleDeclarations, a)).*.?.resolve("X").?;
    const resolved = (try db.get(queries.ResolveFileImports, 5)).*.?;
    try testing.expectEqual(structures.ImportTarget{ .declaration = expected }, resolved.imports[0].target);
}

test "reexport failures never publish a successful partial binding" {
    const db = try testDatabase(1);
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "pub static X = 1\npub static Y = 2");
    const middle = try addModuleFile(db, 2, "middle", "");
    const entry = try addModuleFile(db, 3, "", "import middle.{X}");
    try addModuleMembers(db, a, &.{1});
    try addModuleMembers(db, middle, &.{2});
    try addModuleMembers(db, entry, &.{3});
    for ([_]struct { source: []const u8, kind: DiagnosticKind }{
        .{ .source = "pub import a.{X as X, Y as X}", .kind = .import_conflict },
        .{ .source = "pub static X = 0\npub import a.{X}", .kind = .import_conflict },
        .{ .source = "pub import a.{X}\npub import middle.{X}", .kind = .declaration_cycle },
        .{ .source = "pub import middle.{X}\npub import a.{X}", .kind = .declaration_cycle },
        .{ .source = "pub import a.{X}\npub import absent.{X}", .kind = .unknown_module },
        .{ .source = "pub import a.{Missing as X}", .kind = .unknown_imported_name },
    }) |case| {
        try setSource(db, 2, case.source);
        try testing.expect((try db.get(queries.ResolveFileImports, 3)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveFileImports, 3, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "item relocation drops dependencies on removed source files" {
    const db = try testDatabase(1);
    defer db.deinit();
    const module = try addModuleFile(db, 1, "a", "static X = 1");
    _ = try addModuleFile(db, 2, "a", "");
    try addModuleMembers(db, module, &.{1});
    const item = (try db.get(queries.ModuleDeclarations, module)).*.?.resolve("X").?;
    try testing.expectEqual(@as(structures.FileId, 1), (try db.get(queries.ResolveItem, item)).*.?.file_id);
    try setSource(db, 1, "static =");
    try setSource(db, 2, "static X = 1");
    try db.setInput(queries.ModuleMembers, module, &.{2});
    try testing.expectEqual(@as(structures.FileId, 2), (try db.get(queries.ResolveItem, item)).*.?.file_id);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveItem, item, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
    const other = try db.intern(queries.ModulePaths, .{ .path = "other" });
    try db.setInput(queries.FileModule, 2, other);
    try db.setInput(queries.ModuleMembers, module, &.{});
    try addModuleMembers(db, other, &.{2});
    try testing.expect((try db.get(queries.ResolveItem, item)).* == null);
    const moved = (try db.get(queries.ModuleDeclarations, other)).*.?.resolve("X").?;
    try testing.expect(item != moved);
}

test "import resolution cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testImportAllocations, .{});
}

fn testImportAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    const a = try addModuleFile(db, 1, "a", "pub static X = 1");
    const middle = try addModuleFile(db, 2, "middle", "pub import a.{X}");
    const entry = try addModuleFile(db, 3, "", "import a\nimport a as Alias\nimport middle.{X as Value}");
    try db.addInput(queries.ModuleMembers, a, &.{1});
    try db.addInput(queries.ModuleMembers, middle, &.{2});
    try db.addInput(queries.ModuleMembers, entry, &.{3});
    try db.addInput(queries.ModuleCatalog, {}, &.{ a, middle, entry });
    try testing.expect((try db.get(queries.ResolveFileImports, 3)).* != null);
}

test "dependency cycles are reported" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectError(error.QueryCycle, db.get(CycleA, 1));
}

test "waiting workers run the demanded dependency instead of unrelated queued work" {
    const db = try testDatabase(1);
    defer db.deinit();

    WaitingParent.started.store(false, .monotonic);
    WaitingParent.may_wait.store(false, .monotonic);
    const parent = try db.spawn(WaitingParent, 42);
    while (!WaitingParent.started.load(.acquire)) std.atomic.spinLoopHint();
    const sibling = try db.spawn(ParentDependentSibling, 42);
    WaitingParent.may_wait.store(true, .release);

    try testing.expectEqual(@as(u32, 42), (try sibling.wait()).*);
    try testing.expectEqual(@as(u32, 42), (try parent.wait()).*);
}

test "typed accumulators expose direct and transitive diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectEqual(@as(u32, 11), (try db.get(CallEmitDiagnostic, 3)).*);

    const direct = try db.directAccumulatorValues(CallEmitDiagnostic, 3, OwnedDiagnostic);
    try testing.expectEqual(@as(usize, 1), direct.len);
    try testing.expectEqualStrings("root", direct[0].message);

    const all = try db.transitiveAccumulatorValues(CallEmitDiagnostic, 3, OwnedDiagnostic, testing.allocator);
    defer freeOwnedDiagnostics(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("root", all[0].message);
    try testing.expectEqualStrings("leaf", all[1].message);
}

test "verified ancestors expose newly emitted transitive accumulators" {
    const db = try testDatabase(1);
    defer db.deinit();

    try db.addInput(NumberInput, 1, 0);
    try testing.expectEqual(@as(u32, 1), (try db.get(ConditionalControlRoot, 1)).*);
    try db.setInput(NumberInput, 1, 42);

    const controls = try db.transitiveAccumulatorValues(
        ConditionalControlRoot,
        1,
        structures.CompilerControl,
        testing.allocator,
    );
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);

    try db.setInput(NumberInput, 1, 0);
    const cleared = try db.transitiveAccumulatorValues(
        ConditionalControlRoot,
        1,
        structures.CompilerControl,
        testing.allocator,
    );
    defer testing.allocator.free(cleared);
    try testing.expectEqual(@as(usize, 0), cleared.len);
}

// Compiler pipeline query behavior.

test "ParseFile returns public Ast and emits parser diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source = "const x = 1";
    try addSource(db, 1, source);
    const parsed = try db.get(queries.ParseFile, 1);
    try testing.expect(parsed.* != null);
    try testing.expectEqual(@as(structures.FileId, 1), parsed.*.?.file_id);
    try testing.expectEqual(structures.Node.Tag.block, parsed.*.?.nodes[0].tag);
    const name_token = parsed.*.?.tokens[1];
    try testing.expectEqualStrings("x", source[name_token.loc.start..name_token.loc.end]);

    try addSource(db, 2, "const x 1");
    const failed = try db.get(queries.ParseFile, 2);
    try testing.expect(failed.* == null);

    const diagnostics = try db.transitiveAccumulatorValues(queries.ParseFile, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expect(diagnostics.len > 0);
    try testing.expectEqual(@as(structures.FileId, 2), diagnostics[0].file_id);
}

test "DiscoverItems owns names across source edits" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source =
        \\static first = func() int -> return 1
        \\print(0)
        \\static second = func() int -> return 2
        \\static value = 3
    ;
    try addSource(db, 1, source);
    const result = try db.get(queries.DiscoverItems, 1);
    const tree = result.*.?;

    try testing.expectEqual(@as(usize, 4), tree.items.len);
    try testing.expectEqual(structures.ItemKind.function, tree.items[0].loc.kind);
    try testing.expectEqualStrings("first", tree.items[0].loc.name);
    try testing.expectEqual(structures.ItemKind.static, tree.items[2].loc.kind);
    try testing.expectEqualStrings("value", tree.items[2].loc.name);
    try testing.expectEqual(structures.ItemKind.top_level_entry, tree.items[3].loc.kind);
    try testing.expectEqualStrings("$entry", tree.items[3].loc.name);

    try setSource(db, 1, "static replacement = func() int -> return 3");
    try testing.expectEqualStrings("first", tree.items[0].loc.name);
}

test "discovery rejects duplicate top-level names across declaration kinds" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source =
        \\static duplicate = func() int -> return 1
        \\static other = func() int -> return 0
        \\static duplicate = 2
    ;
    try addSource(db, 1, source);
    try testing.expect((try db.get(queries.DiscoverItems, 1)).* == null);
    const diagnostics = try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, diagnostics[0].kind);
    const start = std.mem.lastIndexOf(u8, source, "duplicate").?;
    try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "duplicate".len }, diagnostics[0].span.?);

    // The rejected tree reaches no downstream query.
    try testing.expect((try db.get(queries.IndexItems, 1)).* == null);
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);
    try testing.expect((try db.get(queries.BuildModuleScope, 1)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);

    try setSource(db, 1,
        \\static other = func() int -> return 0
        \\static duplicate = func() int -> return 2
    );
    const recovered = (try db.get(queries.DiscoverItems, 1)).*.?;
    try testing.expectEqual(@as(usize, 3), recovered.items.len);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic)).len);
}

test "DiscoverItems creates an entry for every parsed file" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "static f = func() int -> return 1");
    try addSource(db, 3, "static value = 1");

    const empty = (try db.get(queries.DiscoverItems, 1)).*;
    const function_only = (try db.get(queries.DiscoverItems, 2)).*;
    const static_only = (try db.get(queries.DiscoverItems, 3)).*;
    try testing.expectEqual(@as(usize, 1), empty.?.items.len);
    try testing.expectEqual(structures.ItemKind.top_level_entry, empty.?.items[0].loc.kind);
    try testing.expectEqual(@as(usize, 2), function_only.?.items.len);
    try testing.expectEqual(structures.ItemKind.function, function_only.?.items[0].loc.kind);
    try testing.expectEqual(structures.ItemKind.top_level_entry, function_only.?.items[1].loc.kind);
    try testing.expectEqual(@as(usize, 2), static_only.?.items.len);
    try testing.expectEqual(structures.ItemKind.static, static_only.?.items[0].loc.kind);
    try testing.expectEqual(structures.ItemKind.top_level_entry, static_only.?.items[1].loc.kind);
}

test "struct hook items have stable owner-qualified identities" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Left = struct
        \\  copy = func(imm self: Left) Left -> self
        \\  value: int
        \\static Right = struct
        \\  copy = func(imm self: Right) Right -> self
        \\  value: int
    );
    var scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const left = scope.resolveStatic("Left").?;
    const right = scope.resolveStatic("Right").?;
    const first_index = (try db.get(queries.IndexItems, 1)).*.?;
    var left_copy: ?structures.ItemId = null;
    var right_copy: ?structures.ItemId = null;
    for (first_index.ids()) |item_id| {
        const loc = try db.lookupInterned(queries.ItemLocations, item_id);
        if (!std.mem.eql(u8, loc.name, "copy")) continue;
        if (loc.owner == left) left_copy = item_id;
        if (loc.owner == right) right_copy = item_id;
    }
    try testing.expect(left_copy != null and right_copy != null);
    try testing.expect(left_copy.? != right_copy.?);
    try testing.expect(scope.resolve("copy") == null);
    const left_type = try resolvedStaticType(db, left);
    const right_type = try resolvedStaticType(db, right);
    const left_signature = (try db.get(queries.FunctionSignature, left_copy.?)).*.?;
    try testing.expectEqual(@as(usize, 1), left_signature.parameters.len);
    try testing.expectEqual(structures.CallableParameter{ .mode = .imm, .type_id = left_type }, left_signature.parameters[0]);
    try testing.expectEqual(left_type, left_signature.return_type);
    const right_signature = (try db.get(queries.FunctionSignature, right_copy.?)).*.?;
    try testing.expectEqual(structures.CallableParameter{ .mode = .imm, .type_id = right_type }, right_signature.parameters[0]);
    try testing.expectEqual(right_type, right_signature.return_type);

    try setSource(db, 1,
        \\static Left = struct
        \\  prefix: bool
        \\  copy = func(imm self: Left) Left -> self
        \\  value: int
        \\static Right = struct
        \\  copy = func(imm self: Right) Right -> self
        \\  value: int
    );
    scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(left, scope.resolveStatic("Left").?);
    try testing.expectEqual(right, scope.resolveStatic("Right").?);
    const relocated_index = (try db.get(queries.IndexItems, 1)).*.?;
    try testing.expect(relocated_index.resolve(left_copy.?) != null);
    try testing.expect(relocated_index.resolve(right_copy.?) != null);
}

test "captureless struct hook items reuse function queries" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource)
        \\    return
        \\  value: int
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const resource = scope.resolveStatic("Resource").?;
    const resource_type = try resolvedStaticType(db, resource);
    const index = (try db.get(queries.IndexItems, 1)).*.?;
    const drop = for (index.ids()) |item_id| {
        const loc = try db.lookupInterned(queries.ItemLocations, item_id);
        if (loc.owner == resource and std.mem.eql(u8, loc.name, "drop")) break item_id;
    } else unreachable;

    const signature = (try db.get(queries.FunctionSignature, drop)).*.?;
    try testing.expectEqualSlices(structures.CallableParameter, &.{.{ .mode = .deinit, .type_id = resource_type }}, signature.parameters);
    try testing.expectEqual(structures.TypeId.unit, signature.return_type);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, drop)).* != null);
}

test "struct declarations are nominal and aliases preserve identity" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Left = struct
        \\  value: int
        \\static Right = struct
        \\  value: int
        \\static Alias = Left
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const left_item = scope.resolveStatic("Left").?;
    const right_item = scope.resolveStatic("Right").?;
    const alias_item = scope.resolveStatic("Alias").?;
    try testing.expectEqual(structures.ItemKind.structure, (try db.lookupInterned(queries.ItemLocations, left_item)).kind);

    const left = try resolvedStaticValue(db, left_item);
    const right = try resolvedStaticValue(db, right_item);
    const alias = try resolvedStaticValue(db, alias_item);
    const left_type = switch (left) {
        .type => |type_id| type_id,
        .runtime => unreachable,
    };
    const right_type = switch (right) {
        .type => |type_id| type_id,
        .runtime => unreachable,
    };
    const alias_type = switch (alias) {
        .type => |type_id| type_id,
        .runtime => unreachable,
    };
    try testing.expect(left_type != right_type);
    try testing.expectEqual(left_type, alias_type);
}

test "struct declarations require meta-type annotations" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Valid: type = struct
        \\  value: int
        \\static Invalid: int = struct
        \\  value: int
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect((try db.get(queries.StructDefinition, scope.resolveStatic("Valid").?)).* != null);
    const invalid = scope.resolveStatic("Invalid").?;
    try testing.expect((try db.get(queries.StructDefinition, invalid)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, invalid, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.static_initializer_not_supported, std.meta.activeTag(diagnostics[0].kind));
}

test "struct definitions own ordered resolved fields" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Count = int
        \\static Pair = struct
        \\  right: Count
        \\  left: bool
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const pair = scope.resolveStatic("Pair").?;
    const definition = (try db.get(queries.StructDefinition, pair)).*.?;
    try testing.expectEqual(@as(usize, 2), definition.fields.len);
    try testing.expectEqualStrings("right", definition.fields[0].name);
    try testing.expectEqual(structures.TypeId.int, definition.fields[0].type_id);
    try testing.expectEqualStrings("left", definition.fields[1].name);
    try testing.expectEqual(structures.TypeId.bool, definition.fields[1].type_id);
}

test "struct definitions reject duplicate and unsupported members" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Duplicate = struct
        \\  value: int
        \\  value: bool
        \\static Unsupported = struct
        \\  const nested = 1
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const duplicate = scope.resolveStatic("Duplicate").?;
    try testing.expect((try db.get(queries.StructDefinition, duplicate)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, duplicate, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.duplicate_struct_member, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    const unsupported = scope.resolveStatic("Unsupported").?;
    try testing.expect((try db.get(queries.StructDefinition, unsupported)).* == null);
    diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, unsupported, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.struct_member_not_supported, std.meta.activeTag(diagnostics[0].kind));
}

test "struct definitions own ownership property overrides" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Configured = struct
        \\  move = trivial
        \\  copy = fieldwise
        \\  drop = explicit
        \\  value: int
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const definition = (try db.get(queries.StructDefinition, scope.resolveStatic("Configured").?)).*.?;
    try testing.expectEqual(structures.MoveCapability.trivial, definition.ownership.move.?.capability);
    try testing.expectEqual(structures.CopyCapability.fieldwise, definition.ownership.copy.?.capability);
    try testing.expectEqual(structures.DropCapability.explicit, definition.ownership.drop.?.capability);
}

test "struct ownership properties have precise definition diagnostics" {
    const cases = [_]struct {
        member: []const u8,
        kind: DiagnosticKind,
        invalid_property: ?structures.Diagnostic.InvalidStructPropertyValue = null,
    }{
        .{ .member = "copy = trivial\n  copy = fieldwise", .kind = .duplicate_struct_property },
        .{ .member = "clone = trivial", .kind = .unknown_struct_property },
        .{ .member = "move = explicit", .kind = .invalid_struct_property_value, .invalid_property = .move },
        .{ .member = "copy = explicit", .kind = .invalid_struct_property_value, .invalid_property = .copy },
        .{ .member = "drop = none", .kind = .invalid_struct_property_value, .invalid_property = .drop },
        .{ .member = "copy = func(imm self: int) int -> self", .kind = .struct_ownership_hook_signature_mismatch },
        .{ .member = "move = func(imm self: Invalid) Invalid -> self", .kind = .struct_ownership_hook_signature_mismatch },
        .{ .member = "drop = func(deinit self: Invalid) int -> return 0", .kind = .struct_ownership_hook_signature_mismatch },
        .{ .member = "drop = fallible(deinit self: Invalid) -> return", .kind = .struct_ownership_hook_signature_mismatch },
        .{ .member = "copy = func(imm self: Invalid, other: int) Invalid -> self", .kind = .struct_ownership_hook_signature_mismatch },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator, "static Invalid = struct\n  {s}\n  value: int", .{case.member});
        defer testing.allocator.free(source);
        try addSource(db, file_id, source);
        const item = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveStatic("Invalid").?;
        try testing.expect((try db.get(queries.StructDefinition, item)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, item, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
        if (case.invalid_property) |property| {
            try testing.expectEqual(property, diagnostics[0].kind.invalid_struct_property_value);
        }
    }
}

test "struct hook signature validation updates incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();
    const valid =
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
    ;
    try addSource(db, 1, valid);
    var item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Resource").?;
    var definition = (try db.get(queries.StructDefinition, item)).*.?;
    try testing.expectEqual(structures.DropCapability.custom, definition.ownership.drop.?.capability);
    try testing.expect(definition.ownership.drop.?.hook != null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, item, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = func(imm self: Resource) -> return
        \\  value: int
    );
    item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Resource").?;
    try testing.expect((try db.get(queries.StructDefinition, item)).* == null);
    diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, item, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.struct_ownership_hook_signature_mismatch, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1, valid);
    item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Resource").?;
    definition = (try db.get(queries.StructDefinition, item)).*.?;
    try testing.expectEqual(structures.DropCapability.custom, definition.ownership.drop.?.capability);
    diagnostics = try db.transitiveAccumulatorValues(queries.StructDefinition, item, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "custom ownership hooks execute without active-hook redispatch" {
    const cases = [_]struct {
        source: []const u8,
        expected: u8,
    }{
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const copied = source
            \\  return copied.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const selected = if 0 < 1 -> source else Box{value = 40}
            \\  return selected.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const selected = if 1 < 0 -> source else Box{value = 40}
            \\  return selected.value
            \\exit(answer())
            ,
            .expected = 40,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const selected = if 0 < 1 -> if 1 < 0 -> source else Box{value = 40} else Box{value = 39}
            \\  return selected.value
            \\exit(answer())
            ,
            .expected = 40,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> exit(self.value)
            \\  value: int
            \\static Token = struct
            \\  value: int
            \\func answer()
            \\  const source = Box{value = 42}
            \\  const selected: Box | Token = if 0 < 1 -> source else Token{value = 40}
            \\answer()
            \\exit(40)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> exit(self.value)
            \\  value: int
            \\static Token = struct
            \\  value: int
            \\func answer()
            \\  const source = Box{value = 42}
            \\  const selected: Box | Token = if 1 < 0 -> source else Token{value = 40}
            \\answer()
            \\exit(40)
            ,
            .expected = 40,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const selected = loop
            \\    if 0 < 1 -> break source
            \\    break Box{value = 40}
            \\  return selected.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const selected = loop
            \\    if 1 < 0 -> break source
            \\    break Box{value = 40}
            \\  return selected.value
            \\exit(answer())
            ,
            .expected = 40,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> exit(self.value)
            \\  value: int
            \\static Token = struct
            \\  value: int
            \\func answer()
            \\  const source = Box{value = 42}
            \\  const selected: Box | Token = loop
            \\    if 0 < 1 -> break source
            \\    break Token{value = 40}
            \\answer()
            \\exit(40)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> exit(self.value)
            \\  value: int
            \\static Token = struct
            \\  value: int
            \\func answer()
            \\  const source = Box{value = 42}
            \\  const selected: Box | Token = loop
            \\    if 1 < 0 -> break source
            \\    break Token{value = 40}
            \\answer()
            \\exit(40)
            ,
            .expected = 40,
        },
        .{
            .source =
            \\static Box = struct
            \\  copy = func(imm self: Box) Box -> self
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 42}
            \\  const copied = source
            \\  return copied.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> return
            \\  value: int
            \\func answer() int
            \\  const resource = Resource{value = 42}
            \\  return resource.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Box = struct
            \\  move = func(var self: Box) Box
            \\    self.value += 1
            \\    return self^
            \\  value: int
            \\func answer() int
            \\  const source = Box{value = 41}
            \\  const moved = source^
            \\  return moved.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  const resource = Resource{value = 42}
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Leaf = struct
            \\  copy = func(imm self: Leaf) Leaf -> Leaf{value = self.value + 1}
            \\  value: int
            \\static Middle = struct
            \\  copy = fieldwise
            \\  leaf: Leaf
            \\static Outer = struct
            \\  copy = fieldwise
            \\  first: Middle
            \\  second: Middle
            \\func answer() int
            \\  const source = Outer{first = Middle{leaf = Leaf{value = 19}}, second = Middle{leaf = Leaf{value = 21}}}
            \\  const copied = source
            \\  return copied.first.leaf.value + copied.second.leaf.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\static Pair = struct
            \\  first: Resource
            \\  second: Resource
            \\func answer()
            \\  const pair = Pair{first = Resource{value = 41}, second = Resource{value = 42}}
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Inner = struct
            \\  copy = func(imm self: Inner) Inner -> Inner{value = self.value + 1}
            \\  value: int
            \\static Outer = struct
            \\  copy = fieldwise
            \\  inner: Inner
            \\func answer() int
            \\  const source = Outer{inner = Inner{value = 41}}
            \\  const copied = source
            \\  return copied.inner.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Inner = struct
            \\  copy = func(imm self: Inner) Inner -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  const source: Inner | int = Inner{value = 42}
            \\  const copied = source
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Inner = struct
            \\  move = func(var self: Inner) Inner -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  const source: Inner | int = Inner{value = 42}
            \\  const moved = source^
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Inner = struct
            \\  drop = func(deinit self: Inner) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  const value: Inner | int = Inner{value = 42}
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  var resource = Resource{value = 42}
            \\  resource = Resource{value = 43}
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  Resource{value = 42}
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func inspect(imm resource: Resource) -> return
            \\func answer() -> inspect(Resource{value = 42})
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  copy = trivial
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer() int -> return Resource{value = 42}.value
            \\exit(answer())
            ,
            .expected = 42,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const executable = (try db.get(queries.BuildExecutable, file_id)).*.?;
        const io = testing.io;
        try runtime.writeProgram(io, executable.bytes);
        defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "ownership effects compose across calls joins scopes and partial aggregates" {
    const cases = [_]struct { source: []const u8, expected: u8 }{
        .{
            .source =
            \\struct Box
            \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
            \\  value: int
            \\func take(var box: Box) int -> box.value
            \\const box = Box{value = 41}
            \\exit(take(box))
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\fallible fail() int
            \\  1 < 0
            \\  return 1
            \\fallible attempt() int
            \\  const resource = Resource{}
            \\  const value = fail()
            \\  return value
            \\if attempt() -> exit(1) else exit(0)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  copy = func(imm self: Resource) Resource -> exit(41)
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\const selected = if 1 < 2
            \\  const resource = Resource{}
            \\  resource
            \\else Resource{}
            \\exit(0)
            ,
            .expected = 41,
        },
        .{
            .source =
            \\struct Resource
            \\  copy = func(imm self: Resource) Resource -> exit(41)
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\const outer = Resource{}
            \\const selected = if 1 < 2
            \\  const inner = Resource{}
            \\  if 1 < 2 -> inner else outer
            \\else outer
            \\exit(0)
            ,
            .expected = 41,
        },
        .{
            .source =
            \\struct Resource
            \\  copy = trivial
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\func inspect(imm resource: Resource) -> return
            \\const resource = Resource{}
            \\inspect(if 1 < 2 -> resource else Resource{})
            \\exit(0)
            ,
            .expected = 0,
        },
        .{
            .source =
            \\struct Resource
            \\  copy = func(imm self: Resource) Resource -> Resource{}
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\func inspect(imm resource: Resource) -> return
            \\const resource = Resource{}
            \\inspect(if 1 > 2 -> resource else Resource{})
            \\exit(0)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  value: int
            \\  copy = trivial
            \\  drop = func(deinit self: Resource)
            \\    if self.value == 2 -> exit(42)
            \\    return
            \\var resource = Resource{value = 1}
            \\resource = if 1 < 2
            \\  resource = Resource{value = 2}
            \\  Resource{value = 3}
            \\else Resource{value = 4}
            \\exit(0)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\fallible make() Resource -> Resource{}
            \\if make() -> exit(0) else exit(1)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\struct Pair
            \\  first: Resource
            \\  second: int
            \\fallible fail() int
            \\  1 < 0
            \\  return 1
            \\fallible attempt() Pair -> Pair{first = Resource{}, second = fail()}
            \\if attempt() -> exit(1) else exit(0)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  copy = func(imm self: Resource) Resource -> exit(42)
            \\func later() int -> exit(41)
            \\func take(var resource: Resource, value: int) -> return
            \\const resource = Resource{}
            \\take(resource, later())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Resource
            \\  drop = func(deinit self: Resource) -> exit(42)
            \\func make() Resource | int -> Resource{}
            \\if make() is Resource -> exit(0) else exit(1)
            ,
            .expected = 42,
        },
        .{
            .source =
            \\struct Leaf
            \\  copy = trivial
            \\  value: int
            \\struct Wrap
            \\  copy = trivial
            \\  drop = func(deinit self: Wrap) -> exit(42)
            \\  leaf: Leaf
            \\func inspect(imm leaf: Leaf) -> return
            \\const wrap = Wrap{leaf = Leaf{value = 1}}
            \\inspect((if 1 > 2 -> wrap else Wrap{leaf = Leaf{value = 2}}).leaf)
            \\exit(0)
            ,
            .expected = 42,
        },
    };
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const executable = (try db.get(queries.BuildExecutable, file_id)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "failure and condition results enforce explicit drop" {
    const cases = [_][]const u8{
        \\struct Resource
        \\  drop = explicit
        \\fallible fail() int
        \\  1 < 0
        \\  return 1
        \\fallible attempt() int
        \\  const resource = Resource{}
        \\  const value = fail()
        \\  return value
        \\if attempt() -> exit(1) else exit(0)
        ,
        \\struct Resource
        \\  drop = explicit
        \\fallible make() Resource -> Resource{}
        \\if make() -> exit(0) else exit(1)
        ,
    };
    for (cases, 1..) |source, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, source);
        try testing.expect((try db.get(queries.BuildExecutable, file_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, file_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.value_requires_explicit_drop, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "custom hook body edits rebuild executable behavior" {
    const db = try testDatabase(1);
    defer db.deinit();
    const initial =
        \\static Box = struct
        \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
        \\  value: int
        \\func answer() int
        \\  const source = Box{value = 40}
        \\  const copied = source
        \\  return copied.value
        \\exit(answer())
    ;
    try addSource(db, 1, initial);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const owner = scope.resolveStatic("Box").?;
    const index = (try db.get(queries.IndexItems, 1)).*.?;
    const hook = for (index.ids()) |item_id| {
        const loc = try db.lookupInterned(queries.ItemLocations, item_id);
        if (loc.owner == owner and std.mem.eql(u8, loc.name, "copy")) break item_id;
    } else unreachable;

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    var executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 41), try runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static Box = struct
        \\  copy = func(imm self: Box) Box -> Box{value = self.value + 2}
        \\  value: int
        \\func answer() int
        \\  const source = Box{value = 40}
        \\  const copied = source
        \\  return copied.value
        \\exit(answer())
    );
    const updated_scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(owner, updated_scope.resolveStatic("Box").?);
    const updated_index = (try db.get(queries.IndexItems, 1)).*.?;
    try testing.expect(updated_index.resolve(hook) != null);
    executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "conditional transfer drops the remaining owned path" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
        \\func bad(flag: int)
        \\  const resource = Resource{value = 42}
        \\  if flag < 1
        \\    const moved = resource^
    );
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* != null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "last use cleanup runs before a later unrelated exit" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\  value: int
        \\func answer()
        \\  const resource = Resource{value = 42}
        \\  _ = resource
        \\  exit(1)
        \\answer()
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "last-use edits move cleanup and retain equivalent restored output" {
    const db = try testDatabase(1);
    defer db.deinit();
    const initial =
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\  value: int
        \\func later() -> exit(41)
        \\func answer()
        \\  const resource = Resource{value = 42}
        \\  _ = resource
        \\  later()
        \\answer()
    ;
    try addSource(db, 1, initial);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const answer = scope.resolveFunction("answer").?;
    const instance: structures.InstanceId = .{ .item = answer };
    const initial_body = try db.get(queries.AnalyzeFunctionBody, answer);
    const initial_artifact = try db.get(queries.CompileFunction, instance);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    var executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\  value: int
        \\func later() -> exit(41)
        \\func answer()
        \\  const resource = Resource{value = 42}
        \\  later()
        \\  _ = resource
        \\answer()
    );
    try testing.expect(initial_body != try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expect(initial_artifact != try db.get(queries.CompileFunction, instance));
    executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 41), try runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1, initial);
    const restored_body = try db.get(queries.AnalyzeFunctionBody, answer);
    const restored_artifact = try db.get(queries.CompileFunction, instance);
    executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\  value: int
        \\func later() -> exit(41)
        \\func answer()
        \\  const resource = Resource{value = 42}
        \\  _ = (resource)
        \\  later()
        \\answer()
    );
    try testing.expectEqual(restored_body, try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expectEqual(restored_artifact, try db.get(queries.CompileFunction, instance));
}

test "custom drop body edits update linking without changing caller analysis" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(41)
        \\func answer()
        \\  const resource = Resource{}
        \\answer()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const answer = scope.resolveFunction("answer").?;
    const caller_body = try db.get(queries.AnalyzeFunctionBody, answer);
    const reachable = try db.get(queries.CollectReachableInstances, 1);
    const executable = try db.get(queries.BuildExecutable, 1);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 41), try runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(42)
        \\func answer()
        \\  const resource = Resource{}
        \\answer()
    );
    try testing.expectEqual(caller_body, try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expectEqual(reachable, try db.get(queries.CollectReachableInstances, 1));
    const updated_executable = try db.get(queries.BuildExecutable, 1);
    try testing.expect(executable != updated_executable);
    try runtime.writeProgram(io, updated_executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "ASAP cleanup follows initialization replacement branches loops and returns" {
    const cases = [_]struct { source: []const u8, expected: u8 }{
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  const resource = Resource{value = 42}
            \\  exit(1)
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  copy = trivial
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  var resource = Resource{value = 41}
            \\  resource = Resource{value = resource.value + 1}
            \\  exit(1)
            \\answer()
            ,
            .expected = 41,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func inspect(imm resource: Resource) -> return
            \\func answer()
            \\  const resource = Resource{value = 42}
            \\  if 1 > 2
            \\    inspect(resource)
            \\  else exit(41)
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  var resource = Resource{value = 41}
            \\  var iteration = 0
            \\  loop
            \\    if iteration < 1
            \\      iteration += 1
            \\      continue
            \\    resource.value += 1
            \\    break
            \\  exit(1)
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  loop
            \\    const resource = Resource{value = 42}
            \\    break
            \\  exit(1)
            \\answer()
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer()
            \\  var iteration = 0
            \\  loop
            \\    const resource = Resource{value = 41}
            \\    if iteration < 1
            \\      iteration += 1
            \\      continue
            \\    _ = resource
            \\    break
            \\  exit(1)
            \\answer()
            ,
            .expected = 41,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource) -> exit(self.value)
            \\  value: int
            \\func answer() int
            \\  const resource = Resource{value = 42}
            \\  return resource.value
            \\exit(answer())
            ,
            .expected = 42,
        },
        .{
            .source =
            \\static Resource = struct
            \\  drop = func(deinit self: Resource)
            \\    if self.value == 42 -> exit(42)
            \\    return
            \\  value: int
            \\func inspect(imm first: Resource, imm second: Resource) -> return
            \\func answer()
            \\  const first = Resource{value = 41}
            \\  const second = Resource{value = 42}
            \\  inspect(first, second)
            \\  exit(1)
            \\answer()
            ,
            .expected = 42,
        },
    };

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const executable = (try db.get(queries.BuildExecutable, file_id)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "struct layouts preserve declaration order alignment and nesting" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: bool
        \\static Outer = struct
        \\  prefix: bool
        \\  pair: Pair
        \\  callback: func() unit
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const pair_type = try resolvedStaticType(db, scope.resolveStatic("Pair").?);
    const outer_type = try resolvedStaticType(db, scope.resolveStatic("Outer").?);

    const pair = (try db.get(queries.StructLayout, pair_type)).*.?;
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 8, .byte_alignment = 4 }, pair.layout);
    try testing.expectEqualSlices(u32, &.{ 0, 4 }, pair.field_offsets);

    const outer = (try db.get(queries.StructLayout, outer_type)).*.?;
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 24, .byte_alignment = 8 }, outer.layout);
    try testing.expectEqualSlices(u32, &.{ 0, 4, 16 }, outer.field_offsets);
    try testing.expectEqual(outer.layout, (try db.get(queries.HostTypeLayout, outer_type)).*);
    try testing.expectEqual(structures.AllocationLayout{ .byte_size = 48, .byte_alignment = 8 }, try structures.AllocationLayout.forElements(outer.layout, 2));
    try testing.expectEqual(structures.AllocationLayout{ .byte_size = 0, .byte_alignment = 8 }, try structures.AllocationLayout.forElements(outer.layout, 0));
}

test "byte literals, layout, calls, fields and static values" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Byte = byte
        \\static high: byte = 255
        \\static Pair = struct
        \\  left: byte
        \\  middle: int
        \\  right: byte
        \\func identity(value: byte) byte -> return value
        \\func answer() byte
        \\  var pair = Pair{left = 0, middle = 3, right = high}
        \\  pair.left = identity(255)
        \\  return pair.left
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(structures.TypeId.byte, try resolvedStaticType(db, scope.resolveStatic("Byte").?));
    const high = try resolvedStaticValue(db, scope.resolveStatic("high").?);
    try testing.expectEqual(structures.TypeId.byte, high.runtime.type_id);
    try testing.expectEqual(@as(u8, 255), high.runtime.value.byte);
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 1, .byte_alignment = 1 }, (try db.get(queries.HostTypeLayout, .byte)).*);
    const pair_type = try resolvedStaticType(db, scope.resolveStatic("Pair").?);
    const pair_layout = (try db.get(queries.StructLayout, pair_type)).*.?;
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 12, .byte_alignment = 4 }, pair_layout.layout);
    try testing.expectEqualSlices(u32, &.{ 0, 4, 8 }, pair_layout.field_offsets);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "identity" }, 255);
}

test "byte literals reject out of range and int values do not convert implicitly" {
    const cases = [_]struct { source: []const u8, kind: DiagnosticKind }{
        .{ .source = "func answer() byte -> return 256", .kind = .integer_literal_out_of_range },
        .{ .source = "func answer() byte\n  var value: byte = 256\n  return value", .kind = .integer_literal_out_of_range },
        .{ .source = "func identity(value: byte) byte -> return value\nfunc answer() byte -> return identity(256)", .kind = .integer_literal_out_of_range },
        .{ .source = "static Pair = struct\n  field: byte\nfunc answer() byte -> return Pair{field = 256}.field", .kind = .integer_literal_out_of_range },
        .{ .source = "func answer() byte\n  const value = 255\n  return value", .kind = .return_type_mismatch },
        .{ .source = "func answer() byte -> return -1", .kind = .return_type_mismatch },
    };
    for (cases) |case| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, 1, case.source);
        const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "static byte literal edits invalidate and recover" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1, "static high: byte = 255");
    const high = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("high").?;
    try testing.expectEqual(@as(u8, 255), (try resolvedStaticValue(db, high)).runtime.value.byte);

    try setSource(db, 1, "static high: byte = 256");
    try testing.expect((try db.get(queries.ResolveStatic, high)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, high, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.integer_literal_out_of_range, diagnostics[0].kind);

    try setSource(db, 1, "static high: byte = 0");
    try testing.expectEqual(@as(u8, 0), (try resolvedStaticValue(db, high)).runtime.value.byte);
}

test "compile-time literal thunks distinguish expected types" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1, "static high: byte = 255");
    const high = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("high").?;
    const resolved = (try db.get(queries.ResolveItem, high)).*.?;
    const parsed = (try db.get(queries.ParseFile, 1)).*.?;
    const initializer = parsed.nodes[resolved.declaration].data.node_node.b.unwrap().?;
    const site: structures.CompileTimeSite = .{ .owner = .{ .item = high }, .node = initializer };
    const inferred = (try db.get(queries.AnalyzeComptimeThunk, site)).*.?;
    const expected = (try db.get(queries.AnalyzeComptimeThunk, .{ .owner = site.owner, .node = site.node, .expected_type = .byte })).*.?;
    try testing.expectEqual(structures.TypeId.int, inferred.return_type);
    try testing.expectEqual(structures.TypeId.byte, expected.return_type);
}

test "static byte parameter accepts a context-typed literal" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func select(static value: byte) byte -> return value
        \\func answer() byte -> return select(255)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 255);
}

test "static literal types resolve aliases and prior type arguments" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Byte = byte
        \\static high: Byte = 255
        \\func select(static T: type, static value: T) T -> return value
        \\func answer() byte -> return select(Byte, high)
        \\func literal() byte -> return select(Byte, 254)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 255);
    try expectCompiledFunctionResult(db, 1, "literal", &.{"literal"}, 254);
}

test "static literal typing uses the callee file scope" {
    const db = try testDatabase(1);
    defer db.deinit();
    const library = try addModuleFile(db, 1, "library",
        \\static LocalByte = byte
        \\pub func select(static value: LocalByte) byte -> return value
    );
    const root = try addModuleFile(db, 2, "",
        \\import library.{select}
        \\func answer() byte -> return select(255)
    );
    try addModuleMembers(db, library, &.{1});
    try addModuleMembers(db, root, &.{2});
    try expectCompiledFunctionResult(db, 2, "answer", &.{"answer"}, 255);
}

test "static byte parameter rejects an out-of-range literal" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func select(static value: byte) byte -> return value
        \\func answer() byte -> return select(256)
    );
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.integer_literal_out_of_range, diagnostics[0].kind);
}

test "static byte parameter does not convert an int value" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static number: int = 255
        \\func select(static value: byte) byte -> return value
        \\func answer() byte -> return select(number)
    );
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.static_argument_type_mismatch, diagnostics[0].kind);
}

test "static alias parameter does not retype a named int" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Byte = byte
        \\static number: int = 255
        \\func select(static value: Byte) Byte -> return value
        \\func answer() Byte -> return select(number)
    );
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.static_argument_type_mismatch, diagnostics[0].kind);
}

test "struct layouts reject direct and variant-mediated containment cycles" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Direct = struct
        \\  next: Direct
        \\static First = struct
        \\  second: Second | none
        \\static Second = struct
        \\  first: First
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const direct_type = try resolvedStaticType(db, scope.resolveStatic("Direct").?);
    try testing.expect((try db.get(queries.StructLayout, direct_type)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.StructLayout, direct_type, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.recursive_struct_containment, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    const first_type = try resolvedStaticType(db, scope.resolveStatic("First").?);
    try testing.expect((try db.get(queries.StructLayout, first_type)).* == null);
    diagnostics = try db.transitiveAccumulatorValues(queries.StructLayout, first_type, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.recursive_struct_containment, std.meta.activeTag(diagnostics[0].kind));
}

test "callable signatures do not recursively contain structs by value" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Node = struct
        \\  next: func() Node
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const node_type = try resolvedStaticType(db, scope.resolveStatic("Node").?);
    const layout = (try db.get(queries.StructLayout, node_type)).*.?;
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 8, .byte_alignment = 8 }, layout.layout);
    try testing.expectEqualSlices(u32, &.{0}, layout.field_offsets);
}

test "ownership capabilities compose across callable variant and struct types" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Callback: type = func(int) int
        \\static MaybeInt = int | none
        \\static Pair = struct
        \\  left: int
        \\  right: bool
        \\static Wrapped = struct
        \\  pair: Pair
        \\static MaybePair = Pair | none
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const callback_type = try resolvedStaticType(db, scope.resolveStatic("Callback").?);
    const maybe_int_type = try resolvedStaticType(db, scope.resolveStatic("MaybeInt").?);
    const pair_type = try resolvedStaticType(db, scope.resolveStatic("Pair").?);
    const wrapped_type = try resolvedStaticType(db, scope.resolveStatic("Wrapped").?);
    const maybe_pair_type = try resolvedStaticType(db, scope.resolveStatic("MaybePair").?);

    const trivial = structures.OwnershipCapabilities{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    try testing.expectEqual(trivial, (try db.get(queries.OwnershipCapabilities, .int)).*.?);
    try testing.expectEqual(trivial, (try db.get(queries.OwnershipCapabilities, callback_type)).*.?);
    try testing.expectEqual(
        structures.OwnershipCapabilities{ .move = .fieldwise, .copy = .fieldwise, .drop = .trivial },
        (try db.get(queries.OwnershipCapabilities, maybe_int_type)).*.?,
    );

    const default_struct = structures.OwnershipCapabilities{ .move = .fieldwise, .copy = .none, .drop = .trivial };
    try testing.expectEqual(default_struct, (try db.get(queries.OwnershipCapabilities, pair_type)).*.?);
    try testing.expectEqual(default_struct, (try db.get(queries.OwnershipCapabilities, wrapped_type)).*.?);
    try testing.expectEqual(default_struct, (try db.get(queries.OwnershipCapabilities, maybe_pair_type)).*.?);
}

test "argument passing follows ownership and invalidates with type edits" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Direct = struct
        \\  value: int
        \\static Immovable = struct
        \\  move = none
        \\static Custom = struct
        \\  value: int
        \\  move = func(var self: Custom) Custom -> Custom{value = self.value}
        \\static Nested = struct
        \\  value: Custom
        \\static Invalid = struct
        \\  move = fieldwise
        \\  value: Immovable
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const direct = try resolvedStaticType(db, scope.resolveStatic("Direct").?);
    const immovable = try resolvedStaticType(db, scope.resolveStatic("Immovable").?);
    const custom = try resolvedStaticType(db, scope.resolveStatic("Custom").?);
    const nested = try resolvedStaticType(db, scope.resolveStatic("Nested").?);
    const invalid = try resolvedStaticType(db, scope.resolveStatic("Invalid").?);

    const types: queries.TypeInterner(*Database) = .{ .ctx = db };

    try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(.int));
    try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(direct));
    try testing.expectEqual(structures.ArgumentPassing.indirect, try types.argumentPassing(immovable));
    try testing.expectEqual(structures.ArgumentPassing.indirect, try types.argumentPassing(custom));
    try testing.expectEqual(structures.ArgumentPassing.indirect, try types.argumentPassing(nested));
    try testing.expectError(error.Unavailable, types.argumentPassing(invalid));

    try setSource(db, 1,
        \\static Direct = struct
        \\  move = none
        \\  value: int
    );
    try testing.expectEqual(structures.ArgumentPassing.indirect, try types.argumentPassing(direct));
}

test "struct ownership properties override defaults and validate fields" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Configured = struct
        \\  move = trivial
        \\  copy = fieldwise
        \\  drop = explicit
        \\  value: int
        \\static Immovable = struct
        \\  move = none
        \\  value: int
        \\static Invalid = struct
        \\  move = fieldwise
        \\  value: Immovable
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const configured = try resolvedStaticType(db, scope.resolveStatic("Configured").?);
    try testing.expectEqual(
        structures.OwnershipCapabilities{
            .move = .trivial,
            .copy = .fieldwise,
            .drop = .explicit,
            .requires_explicit_drop = true,
        },
        (try db.get(queries.OwnershipCapabilities, configured)).*.?,
    );
    const invalid_item = scope.resolveStatic("Invalid").?;
    const invalid = try resolvedStaticType(db, invalid_item);
    try testing.expect((try db.get(queries.OwnershipCapabilities, invalid)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, invalid, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(
        structures.Diagnostic.Kind{ .struct_ownership_property_incompatible_with_fields = .fieldwise_move },
        diagnostics[0].kind,
    );
}

test "incompatible ownership diagnostics retain the failed field rule" {
    const cases = [_]struct {
        source: []const u8,
        reason: structures.Diagnostic.IncompatibleStructOwnershipProperty,
    }{
        .{ .source = "static Field = struct\n  move = fieldwise\n  value: int\nstatic Invalid = struct\n  move = trivial\n  value: Field", .reason = .trivial_move },
        .{ .source = "static Field = struct\n  move = none\n  value: int\nstatic Invalid = struct\n  move = fieldwise\n  value: Field", .reason = .fieldwise_move },
        .{ .source = "static Field = struct\n  move = none\n  value: int\nstatic Invalid = struct\n  move = func(var self: Invalid) Invalid -> self^\n  value: Field", .reason = .custom_move },
        .{ .source = "static Field = struct\n  value: int\nstatic Invalid = struct\n  copy = trivial\n  value: Field", .reason = .trivial_copy },
        .{ .source = "static Field = struct\n  value: int\nstatic Invalid = struct\n  copy = fieldwise\n  value: Field", .reason = .fieldwise_copy },
        .{ .source = "static Field = struct\n  drop = explicit\nstatic Invalid = struct\n  drop = trivial\n  value: Field", .reason = .trivial_drop },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const item = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveStatic("Invalid").?;
        const type_id = try resolvedStaticType(db, item);
        try testing.expect((try db.get(queries.OwnershipCapabilities, type_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, type_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.reason, diagnostics[0].kind.struct_ownership_property_incompatible_with_fields);
    }
}

test "ownership capabilities reject recursive structs and recover incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Node = struct
        \\  next: Node
    );
    const node_item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Node").?;
    const node_type = try resolvedStaticType(db, node_item);
    try testing.expect((try db.get(queries.OwnershipCapabilities, node_type)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, node_type, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.recursive_struct_containment, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static Node = struct
        \\  next: int
    );
    const first = try db.get(queries.OwnershipCapabilities, node_type);
    try testing.expectEqual(
        structures.OwnershipCapabilities{ .move = .fieldwise, .copy = .none, .drop = .trivial },
        first.*.?,
    );

    try setSource(db, 1,
        \\static Node = struct
        \\  next: bool
    );
    try testing.expectEqual(first, try db.get(queries.OwnershipCapabilities, node_type));
    diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, node_type, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "struct values initialize project pass return and execute" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\static Outer = struct
        \\  pair: Pair
        \\  bonus: int
        \\func make(value: int) Pair -> Pair{right = 2, left = value}
        \\func sum(pair: Pair) int -> pair.left + pair.right
        \\func answer() int
        \\  const outer = Outer{bonus = 1, pair = make(39)}
        \\  return sum(outer.pair) + outer.bonus
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const make = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("make").?)).*.?;
    try testing.expectEqual(@as(usize, 2), make.struct_field_values.len);
    try testing.expectEqual(@as(u32, 1), make.struct_field_values[0].field_index);
    try testing.expectEqual(@as(u32, 0), make.struct_field_values[1].field_index);
    try testing.expectEqual(.struct_init, std.meta.activeTag(make.instructions[1]));
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "make", "sum" }, 42);
}

test "struct initializer fields evaluate in source order" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int -> Pair{right = exit(42), left = exit(24)}.left
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "nested struct initializers keep independent field ranges" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Inner = struct
        \\  value: int
        \\static Outer = struct
        \\  inner: Inner
        \\  bonus: int
        \\func answer() int -> Outer{inner = Inner{value = 40}, bonus = 2}.inner.value + 2
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "generic struct initializers infer static arguments from field types" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Box(T: type)
        \\  value: T
        \\struct Wrapper(T: type)
        \\  box: Box(T)
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return Wrapper{box = box^}.box.value
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "generic struct inference honors independent field types" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Record(T: type)
        \\  tag: byte
        \\  value: T
        \\func answer() int -> Record{tag = 1, value = 42}.value
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "generic struct inference recovers non-type static arguments" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Tagged(N: int)
        \\  value: int
        \\struct Holder(N: int)
        \\  tag: Tagged(N)
        \\func answer() int -> Holder{tag = Tagged(3){value = 42}}.tag.value
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "mutable struct fields update the root value" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int
        \\  var pair = Pair{left = 40, right = 1}
        \\  pair.right += 1
        \\  return pair.left + pair.right
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "nested field assignments keep independent target ranges" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int
        \\  var outer = Pair{left = 0, right = 0}
        \\  var inner = Pair{left = 0, right = 0}
        \\  outer.left = inner.right = 42
        \\  return outer.left + inner.right - 42
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "nested field assignments rebuild from the latest root value" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int
        \\  var pair = Pair{left = 0, right = 0}
        \\  pair.left = pair.right = 21
        \\  return pair.left + pair.right
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "compound field assignments read before and rebuild after the right hand side" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int
        \\  var pair = Pair{left = 1, right = 0}
        \\  pair.left += pair.right = 21
        \\  return pair.left + pair.right
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 43);
}

test "nested field updates flow through branch state" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Inner = struct
        \\  value: int
        \\static Outer = struct
        \\  inner: Inner
        \\  bonus: int
        \\func mutate(flag: int) int
        \\  var outer = Outer{inner = Inner{value = 20}, bonus = 0}
        \\  if flag == 0
        \\    outer.inner.value += 1
        \\  else
        \\    outer.bonus = 1
        \\  return outer.inner.value + outer.bonus
        \\func answer() int -> mutate(0) + mutate(1)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "mutate" }, 42);
}

test "field updates flow through loop state" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func answer() int
        \\  var pair = Pair{left = 0, right = 0}
        \\  loop
        \\    pair.left += 1
        \\    if pair.left == 21 -> break
        \\    pair.right += 1
        \\  return pair.left + pair.right
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 41);
}

test "field assignment widens to the declared field type" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Holder = struct
        \\  value: int | none
        \\func answer() int
        \\  var holder = Holder{value = none}
        \\  holder.value = 42
        \\  return if const value = holder.value as int -> value else 0
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "field assignment diagnostics validate roots paths and values" {
    const cases = [_]struct { source: []const u8, expected: DiagnosticKind }{
        .{ .source = "static Pair = struct\n  value: int\nfunc bad() int\n  const pair = Pair{value = 1}\n  pair.value = 2\n  return pair.value", .expected = .assignment_to_immutable },
        .{ .source = "static Pair = struct\n  value: int\nfunc bad(pair: Pair) int\n  pair.value = 2\n  return pair.value", .expected = .assignment_to_immutable },
        .{ .source = "func bad() int\n  var value = 1\n  value.field = 2\n  return value", .expected = .field_access_not_struct },
        .{ .source = "static Pair = struct\n  value: int\nfunc bad() int\n  var pair = Pair{value = 1}\n  pair.missing = 2\n  return pair.value", .expected = .unknown_field },
        .{ .source = "static Pair = struct\n  value: int\nfunc bad() int\n  var pair = Pair{value = 1}\n  pair.value = none\n  return pair.value", .expected = .assignment_type_mismatch },
        .{ .source = "static Pair = struct\n  value: int\nfunc bad() int\n  Pair{value = 1}.value = 2\n  return 0", .expected = .assignment_target_not_local },
        .{ .source = "static Flags = struct\n  value: bool\nfunc bad() bool\n  var flags = Flags{value = true}\n  flags.value += 1\n  return flags.value", .expected = .arithmetic_operand_not_int },
    };
    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.expected, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "nested field assignment highlights the non-struct parent" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static Outer = struct
        \\  count: int
        \\func bad()
        \\  var outer = Outer{count = 0}
        \\  outer.count.value = 1
    ;
    try addSource(db, 1, source);
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const start = std.mem.lastIndexOf(u8, source, "count").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, bad, true, 1, .{
        .start = start,
        .end = start + "count".len,
    }, .{ .field_access_not_struct = .int });
}

test "field assignment tracks definition edits and recovers" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid =
        \\static Pair = struct
        \\  value: int
        \\func answer() int
        \\  var pair = Pair{value = 1}
        \\  pair.value = 42
        \\  return pair.value
    ;
    try addSource(db, 1, valid);
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    try setSource(db, 1,
        \\static Pair = struct
        \\  renamed: int
        \\func answer() int
        \\  var pair = Pair{renamed = 1}
        \\  pair.value = 42
        \\  return pair.renamed
    );
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.unknown_field, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1, valid);
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "struct value diagnostics reject invalid fields and targets" {
    const cases = [_]struct { source: []const u8, expected: DiagnosticKind }{
        .{ .source = "func bad() int -> int{}", .expected = .struct_initializer_not_struct },
        .{ .source = "struct Foo(T: type)\n  r: int\nfunc bad() unit -> Foo{r = 1}", .expected = .static_argument_cannot_be_inferred },
        .{ .source = "struct Foo(T: type)\n  first: T\n  second: T\nfunc bad() unit -> Foo{first = 1, second = true}", .expected = .static_argument_inference_conflict },
        .{ .source = "static makeBox = func() type\n  return struct\n    value: int\nfunc bad() unit -> makeBox{value = 1}", .expected = .type_factory_requires_call },
        .{ .source = "func ordinary() int -> 1\nfunc bad() unit -> ordinary{}", .expected = .value_used_as_type },
        .{ .source = "static Pair = struct\n  left: int\n  right: int\nfunc bad() Pair -> Pair{left = 1, nope = 2}", .expected = .unknown_struct_field },
        .{ .source = "static Pair = struct\n  left: int\n  right: int\nfunc bad() Pair -> Pair{left = 1, left = 2, right = 3}", .expected = .duplicate_struct_initializer_field },
        .{ .source = "static Pair = struct\n  left: int\n  right: int\nfunc bad() Pair -> Pair{left = 1}", .expected = .missing_struct_initializer_field },
        .{ .source = "static Pair = struct\n  left: int\n  right: int\nfunc bad() Pair -> Pair{left = true, right = 2}", .expected = .struct_initializer_field_type_mismatch },
        .{ .source = "func bad() int -> (1).value", .expected = .field_access_not_struct },
        .{ .source = "static Pair = struct\n  left: int\n  right: int\nfunc bad() int -> Pair{left = 1, right = 2}.nope", .expected = .unknown_field },
    };
    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.expected, std.meta.activeTag(diagnostics[0].kind));
        switch (case.expected) {
            .struct_initializer_not_struct => {
                const start = std.mem.lastIndexOf(u8, case.source, "int").?;
                try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "int".len }, diagnostics[0].span.?);
            },
            .generic_struct_requires_specialization => {
                const start = std.mem.lastIndexOf(u8, case.source, "Foo").?;
                try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "Foo".len }, diagnostics[0].span.?);
            },
            .missing_struct_initializer_field => {
                const start = std.mem.lastIndexOf(u8, case.source, "Pair").?;
                try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "Pair".len }, diagnostics[0].span.?);
                const missing = diagnostics[0].kind.missing_struct_initializer_field;
                const types: queries.TypeInterner(*Database) = .{ .ctx = db };
                const definition = (try types.structDefinition(missing.type_id)).?;
                try testing.expectEqualStrings("right", definition.fields[missing.field_index].name);
            },
            else => {},
        }
    }
}

test "struct value analysis tracks definition edits and recovers" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  value: int
        \\func answer() int -> Pair{value = 42}.value
    );
    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    const first = try db.get(queries.AnalyzeFunctionBody, answer);
    try testing.expect(first.* != null);

    try setSource(db, 1,
        \\static Pair = struct
        \\  renamed: int
        \\func answer() int -> Pair{value = 42}.value
    );
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.unknown_struct_field, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static Pair = struct
        \\  value: int
        \\func answer() int -> Pair{value = 42}.value
    );
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* != null);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "struct identity definitions and layouts recompute incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: bool
    );
    const pair_item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Pair").?;
    const first_identity = try db.get(queries.ResolveStatic, pair_item);
    const pair_type = try resolvedStaticType(db, pair_item);
    const first_definition = try db.get(queries.StructDefinition, pair_item);
    const first_layout = try db.get(queries.StructLayout, pair_type);

    try setSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: bool
        \\func unrelated() int -> 1
    );
    try testing.expectEqual(pair_item, (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Pair").?);
    try testing.expectEqual(first_identity, try db.get(queries.ResolveStatic, pair_item));
    try testing.expectEqual(first_definition, try db.get(queries.StructDefinition, pair_item));
    try testing.expectEqual(first_layout, try db.get(queries.StructLayout, pair_type));

    try setSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
    );
    try testing.expectEqual(first_identity, try db.get(queries.ResolveStatic, pair_item));
    try testing.expect(first_definition != try db.get(queries.StructDefinition, pair_item));
    try testing.expectEqual(first_layout, try db.get(queries.StructLayout, pair_type));

    try setSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: func() unit
    );
    try testing.expect(first_layout != try db.get(queries.StructLayout, pair_type));
}

test "recursive struct layout recovers after a field edit" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Node = struct
        \\  next: Node
    );
    const node_item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Node").?;
    const node_type = try resolvedStaticType(db, node_item);
    try testing.expect((try db.get(queries.StructLayout, node_type)).* == null);

    try setSource(db, 1,
        \\static Node = struct
        \\  next: int
    );
    try testing.expectEqual(node_item, (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Node").?);
    try testing.expectEqual(node_type, try resolvedStaticType(db, node_item));
    const layout = (try db.get(queries.StructLayout, node_type)).*.?;
    try testing.expectEqual(structures.TypeLayout{ .byte_size = 4, .byte_alignment = 4 }, layout.layout);
    const diagnostics = try db.transitiveAccumulatorValues(queries.StructLayout, node_type, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "item indexing handles empty malformed missing and duplicate inputs" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "const x 1");
    try addSource(db, 3,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    try addSource(db, 4, "static duplicate = func() int -> return 1");
    try addSource(db, 5, "static duplicate = func() int -> return 2");

    const empty = (try db.get(queries.IndexItems, 1)).*;
    try testing.expect(empty != null);
    try testing.expectEqual(@as(usize, 1), empty.?.count());
    try testing.expect((try db.get(queries.IndexItems, 2)).* == null);
    try testing.expectError(error.InputNotFound, db.get(queries.IndexItems, 99));

    // Discovery rejects duplicate top-level names before indexing.
    try testing.expect((try db.get(queries.IndexItems, 3)).* == null);
    const first_file = (try db.get(queries.IndexItems, 4)).*.?;
    const other_file = (try db.get(queries.IndexItems, 5)).*.?;
    try testing.expect(first_file.ids()[0] != other_file.ids()[0]);

    const entry_module = try db.intern(queries.ModulePaths, .{ .path = "" });
    const other_module = try db.intern(queries.ModulePaths, .{ .path = "other" });
    const base: structures.ItemLoc = .{ .origin = .{ .module = entry_module }, .kind = .function, .name = "same" };
    const base_id = try db.intern(queries.ItemLocations, base);
    try testing.expectEqual(base_id, try db.intern(queries.ItemLocations, base));
    try testing.expectEqual(base_id, try db.intern(queries.ItemLocations, .{ .origin = .{ .module = entry_module }, .kind = .function, .name = "same" }));
    try testing.expect(base_id != try db.intern(queries.ItemLocations, .{ .origin = .{ .module = other_module }, .kind = .function, .name = "same" }));
    try testing.expect(base_id != try db.intern(queries.ItemLocations, .{ .origin = .{ .entry = 8 }, .kind = .top_level_entry, .name = "same" }));
    try testing.expect(base_id != try db.intern(queries.ItemLocations, .{ .origin = .{ .module = entry_module }, .kind = .function, .name = "other" }));
    const entry_id = try db.intern(queries.ItemLocations, .{ .origin = .{ .entry = 8 }, .kind = .top_level_entry, .name = "$entry" });
    try testing.expectEqual(entry_id, try db.intern(queries.ItemLocations, .{ .origin = .{ .entry = 8 }, .kind = .top_level_entry, .name = "$entry" }));
    try testing.expect(entry_id != try db.intern(queries.ItemLocations, .{ .origin = .{ .entry = 9 }, .kind = .top_level_entry, .name = "$entry" }));
    try testing.expectError(error.InvalidInternId, db.lookupInterned(queries.ItemLocations, @enumFromInt(std.math.maxInt(u32))));
}

test "variant types are structurally interned in canonical member order" {
    const db = try testDatabase(2);
    defer db.deinit();

    const int_or_unit = switch ((try db.get(InternVariantPair, .{ .unit, .int })).*) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
    const reordered = switch ((try db.get(InternVariantPair, .{ .int, .unit })).*) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
    try testing.expectEqual(int_or_unit, reordered);
    try testing.expect(int_or_unit.interned() != null);
    try testing.expect(structures.TypeId.int.interned() == null);
    try testing.expect(structures.TypeId.unit.interned() == null);
    try testing.expect(structures.TypeId.none.interned() == null);
    try testing.expect(structures.TypeId.never.interned() == null);
    try testing.expect(structures.TypeId.type.interned() == null);

    const variant = try db.lookupInterned(queries.Types, int_or_unit.interned().?);
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .unit }, variant.variant.members);

    try testing.expect((try db.lookupInternedAs(
        queries.ItemLocations,
        @enumFromInt(@intFromEnum(int_or_unit.interned().?)),
    )) == null);
    try testing.expectError(
        error.InvalidInternId,
        db.lookupInternedAs(queries.ItemLocations, @enumFromInt(std.math.maxInt(u32))),
    );

    const widened = switch ((try db.get(InternVariantPair, .{ int_or_unit, .none })).*) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
    const widened_variant = try db.lookupInterned(queries.Types, widened.interned().?);
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .unit, .none }, widened_variant.variant.members);

    try testing.expectEqual(
        structures.InternVariantResult{ .duplicate = .int },
        (try db.get(InternVariantPair, .{ .int, .int })).*,
    );
    try testing.expectEqual(
        structures.InternVariantResult{ .duplicate = .int },
        (try db.get(InternVariantPair, .{ int_or_unit, .int })).*,
    );
    try testing.expectEqual(
        structures.InternVariantResult{ .duplicate = .unit },
        (try db.get(InternVariantTriple, .{ .none, .unit, int_or_unit })).*,
    );
    try testing.expectEqual(
        structures.InternVariantResult{ .type_id = .int },
        (try db.get(InternVariantPair, .{ .int, .never })).*,
    );
}

test "compile-time values and ordered tuples have canonical identities" {
    const db = try testDatabase(2);
    defer db.deinit();

    const type_int = try db.intern(queries.CompileTimeValues, structures.CompileTimeValue{ .type = .int });
    const same_type_int = try db.intern(queries.CompileTimeValues, structures.CompileTimeValue{ .type = .int });
    const value_int = try db.intern(queries.CompileTimeValues, structures.CompileTimeValue{ .runtime = .{
        .type_id = .int,
        .value = .{ .int = 1 },
    } });
    try testing.expectEqual(type_int, same_type_int);
    try testing.expect(type_int != value_int);

    var values = [_]structures.CompileTimeValueId{ type_int, value_int };
    const tuple = try db.intern(queries.CompileTimeValueTuples, .{ .values = &values });
    try testing.expectEqual(tuple, try db.intern(queries.CompileTimeValueTuples, .{ .values = &values }));
    values[0] = value_int;
    const retained = try db.lookupInterned(queries.CompileTimeValueTuples, tuple);
    try testing.expectEqualSlices(structures.CompileTimeValueId, &.{ type_int, value_int }, retained.values);
    try testing.expect(tuple != try db.intern(queries.CompileTimeValueTuples, .{ .values = &values }));
}

test "variant interning owns canonical members" {
    const db = try testDatabase(1);
    defer db.deinit();

    var members = [_]structures.TypeId{ .int, .unit };
    const variant_id = try db.intern(queries.Types, .{ .variant = .{ .members = &members } });
    members[0] = .none;

    const retained = try db.lookupInterned(queries.Types, variant_id);
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .unit }, retained.variant.members);
}

test "host type layout reports size and alignment for variants" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectEqual(
        structures.TypeLayout{ .byte_size = 4, .byte_alignment = 4 },
        (try db.get(queries.HostTypeLayout, .int)).*,
    );
    try testing.expectEqual(
        structures.TypeLayout{ .byte_size = 4, .byte_alignment = 4 },
        (try db.get(queries.HostTypeLayout, .bool)).*,
    );
    try testing.expectEqual(
        structures.TypeLayout{ .byte_size = 0, .byte_alignment = 1 },
        (try db.get(queries.HostTypeLayout, .unit)).*,
    );
    try testing.expectEqual(
        structures.TypeLayout{ .byte_size = 0, .byte_alignment = 1 },
        (try db.get(queries.HostTypeLayout, .none)).*,
    );
    try testing.expectEqual(
        structures.TypeLayout{ .byte_size = 0, .byte_alignment = 1 },
        (try db.get(queries.HostTypeLayout, .never)).*,
    );

    const int_or_none = switch ((try db.get(InternVariantPair, .{ .int, .none })).*) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
    try testing.expectEqual(
        structures.TypeLayout{
            .byte_size = 8,
            .byte_alignment = 4,
        },
        (try db.get(queries.HostTypeLayout, int_or_none)).*,
    );

    const variant_layout = (try db.get(queries.VariantLayout, int_or_none)).*;
    try testing.expectEqual(@as(u32, 4), variant_layout.payload_offset);
    try testing.expectEqual((try db.get(queries.HostTypeLayout, int_or_none)).*, variant_layout.layout);

    const unit_or_none = switch ((try db.get(InternVariantPair, .{ .unit, .none })).*) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
    const first_layout = try db.get(queries.HostTypeLayout, unit_or_none);
    try testing.expectEqual(
        structures.TypeLayout{
            .byte_size = 4,
            .byte_alignment = 4,
        },
        first_layout.*,
    );
    try testing.expectEqual(first_layout, try db.get(queries.HostTypeLayout, unit_or_none));
}

test "module scope owns sorted declaration lookup and leaves bodies demand-driven" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static zeta = func() int -> return missing
        \\static value = 1
        \\print(0)
        \\static alpha = func() int -> return 1
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(@as(usize, 3), scope.entries.len);
    try testing.expectEqualStrings("alpha", scope.entries[0].name);
    try testing.expectEqualStrings("value", scope.entries[1].name);
    try testing.expectEqualStrings("zeta", scope.entries[2].name);
    try testing.expectEqual(scope.entries[0].item_id, scope.resolve("alpha").?);
    try testing.expectEqual(scope.entries[1].item_id, scope.resolve("value").?);
    try testing.expectEqual(scope.entries[2].item_id, scope.resolve("zeta").?);
    try testing.expectEqual(scope.entries[0].item_id, scope.resolveFunction("alpha").?);
    try testing.expectEqual(scope.entries[1].item_id, scope.resolveStatic("value").?);
    try testing.expect(scope.resolveStatic("alpha") == null);
    try testing.expect(scope.resolveFunction("value") == null);
    try testing.expect(scope.resolve("missing") == null);
    try testing.expect(scope.resolve("$entry") == null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.BuildModuleScope, 1, structures.Diagnostic)).len);

    try setSource(db, 1, "static replacement = func() int -> return 2");
    try testing.expectEqualStrings("alpha", scope.entries[0].name);
}

test "named type aliases and integer statics resolve on demand" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static Empty: type = none
        \\static Result = int | Empty
        \\static default_value = 40
        \\func choose(value: Result) int
        \\  return if const number = value as int -> number else default_value
        \\func answer() int -> choose(default_value) + 2
    );

    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const empty = try resolvedStaticValue(db, scope.resolveStatic("Empty").?);
    try testing.expectEqual(structures.CompileTimeValue{ .type = .none }, empty);
    const result = try resolvedStaticValue(db, scope.resolveStatic("Result").?);
    const result_type = result.type;
    const members = (try db.lookupInterned(queries.Types, result_type.interned().?)).variant.members;
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .none }, members);

    const default_value = try resolvedStaticValue(db, scope.resolveStatic("default_value").?);
    try testing.expectEqual(structures.CompileTimeValue{ .runtime = .{
        .type_id = .int,
        .value = .{ .int = 40 },
    } }, default_value);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "choose" }, 42);
}

test "bool values cross static local call return and variant boundaries" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static Flag = bool
        \\static enabled: Flag = true
        \\static disabled: bool = false
        \\static maybe: bool | none = enabled
        \\func identity(value: Flag) Flag -> value
        \\func score(value: bool | none) int
        \\  return if const flag = value as bool
        \\    if flag == true -> 10 else 0
        \\  else 12
        \\func answer() int
        \\  var selected = identity(enabled)
        \\  selected = disabled
        \\  const direct = if selected == false -> 10 else 0
        \\  const unequal = if enabled <> disabled -> 10 else 0
        \\  return direct + unequal + score(maybe) + score(none)
    );

    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .type = .bool },
        try resolvedStaticValue(db, scope.resolveStatic("Flag").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .bool, .value = .{ .bool = true } } },
        try resolvedStaticValue(db, scope.resolveStatic("enabled").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .bool, .value = .{ .bool = false } } },
        try resolvedStaticValue(db, scope.resolveStatic("disabled").?),
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "identity", "score" }, 42);
}

test "bool static edits invalidate consumers and retain equal results" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static flag = true
        \\func answer() int -> if flag == true -> 42 else 24
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const flag = scope.resolveStatic("flag").?;
    const answer = scope.resolveFunction("answer").?;
    const first_flag = try db.get(queries.ResolveStatic, flag);
    const first_body = try db.get(queries.AnalyzeFunctionBody, answer);
    const first_artifact = try db.get(queries.CompileFunction, .{ .item = answer });

    try setSource(db, 1,
        \\static flag = (true)
        \\func answer() int -> if flag == true -> 42 else 24
    );
    try testing.expectEqual(first_flag, try db.get(queries.ResolveStatic, flag));
    try testing.expectEqual(first_body, try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expectEqual(first_artifact, try db.get(queries.CompileFunction, .{ .item = answer }));

    try setSource(db, 1,
        \\static flag = false
        \\func answer() int -> if flag == true -> 42 else 24
    );
    try testing.expect(first_flag != try db.get(queries.ResolveStatic, flag));
    try testing.expect(first_body != try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expect(first_artifact != try db.get(queries.CompileFunction, .{ .item = answer }));
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 24);
}

test "static annotations widen values and reject mismatches when demanded" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static widened: int | none = 40
        \\static absent: int | none = none
        \\static completed: int | unit = unit
        \\func answer() int
        \\  const number = if const value = widened as int -> value else 0
        \\  const missing = if absent is none -> 1 else 0
        \\  const done = if completed is unit -> 1 else 0
        \\  return number + missing + done
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    try addSource(db, 2,
        \\static bad: none = 40
        \\func answer() int -> bad
    );
    const bad = (try db.get(queries.BuildModuleScope, 2)).*.?.resolveStatic("bad").?;
    try testing.expect((try db.get(queries.ResolveStatic, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.static_initializer_type_mismatch, std.meta.activeTag(diagnostics[0].kind));
}

test "scalar static expressions stay dormant and execute as typed thunks when demanded" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static unused = 1 + 2
        \\func answer() int -> 42
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    const unused = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("unused").?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 3 } } },
        try resolvedStaticValue(db, unused),
    );
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, unused, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "inferred statics share the typed thunk publication path" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static base = 40
        \\static alias = base
        \\static Int = int
        \\static identity = func(value: int) int -> value
        \\static callable = identity
        \\func answer() int -> callable(alias + 2)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const parsed = (try db.get(queries.ParseFile, 1)).*.?;
    for ([_]struct { name: []const u8, instruction: std.meta.Tag(structures.FunctionInstruction) }{
        .{ .name = "base", .instruction = .const_int },
        .{ .name = "alias", .instruction = .const_int },
        .{ .name = "Int", .instruction = .const_type },
        .{ .name = "callable", .instruction = .function_ref },
    }) |expected| {
        const item = scope.resolveStatic(expected.name).?;
        const resolved = (try db.get(queries.ResolveItem, item)).*.?;
        const initializer = parsed.nodes[resolved.declaration].data.node_node.b.unwrap() orelse unreachable;
        const body = (try db.get(queries.AnalyzeComptimeThunk, .{ .owner = .{ .item = item }, .node = initializer })).*.?;
        try testing.expectEqual(@as(usize, 1), body.instructions.len);
        try testing.expectEqual(expected.instruction, std.meta.activeTag(body.instructions[0]));
    }
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "identity" }, 42);
}

test "runtime static annotations reject interpreted type values" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static makeType = func() type -> int
        \\static invalid: int = makeType()
    ;
    try addSource(db, 1, source);
    const invalid = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("invalid").?;
    try testing.expect((try db.get(queries.ResolveStatic, invalid)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, invalid, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_value_used_as_runtime_value, std.meta.activeTag(diagnostics[0].kind));
    try testing.expectEqualStrings("makeType", source[diagnostics[0].span.?.start..diagnostics[0].span.?.end]);
}

test "compile-time scalar interpreter executes control flow, locals, loops, and wrapping arithmetic" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = if 2 < 3 -> 40 + 2 else 0
        \\static wrapped = 2147483647 + 1
        \\static looped = comptime
        \\  var value = 0
        \\  loop
        \\    value += 1
        \\    if value == 42 -> break value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("selected").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = std.math.minInt(i32) } } },
        try resolvedStaticValue(db, scope.resolveStatic("wrapped").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("looped").?),
    );
}

test "scalar thunk results retain equal identities and invalidate on value changes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static computed = 40 + 2
        \\func answer() int -> computed
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const computed = scope.resolveStatic("computed").?;
    const first = try db.get(queries.ResolveStatic, computed);

    try setSource(db, 1,
        \\static computed = 41 + 1
        \\func answer() int -> computed
    );
    try testing.expectEqual(computed, (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("computed").?);
    try testing.expectEqual(first, try db.get(queries.ResolveStatic, computed));

    try setSource(db, 1,
        \\static computed = 41 + 2
        \\func answer() int -> computed
    );
    try testing.expect(first != try db.get(queries.ResolveStatic, computed));
}

test "compile-time interpreter memoizes direct and recursive scalar calls" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static add = func(left: int, right: int) int -> left + right
        \\static sum_to = func(value: int) int -> if value == 0 -> 0 else value + sum_to(value - 1)
        \\static first = add(20, 22)
        \\static second = add(20, 22)
        \\static recursive = sum_to(6)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("first").?),
    );
    try testing.expectEqual(
        (try db.get(queries.ResolveStatic, scope.resolveStatic("first").?)).*,
        (try db.get(queries.ResolveStatic, scope.resolveStatic("second").?)).*,
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 21 } } },
        try resolvedStaticValue(db, scope.resolveStatic("recursive").?),
    );
}

test "compile-time call results retain across unrelated edits and invalidate with callees" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static add = func(left: int, right: int) int -> left + right
        \\static result = add(20, 22)
        \\func unrelated() int -> 1
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const result = scope.resolveStatic("result").?;
    const first = try db.get(queries.ResolveStatic, result);

    try setSource(db, 1,
        \\static add = func(left: int, right: int) int -> left + right
        \\static result = add(20, 22)
        \\func unrelated() int -> 2
    );
    try testing.expectEqual(first, try db.get(queries.ResolveStatic, result));

    try setSource(db, 1,
        \\static add = func(left: int, right: int) int -> left + right + 1
        \\static result = add(20, 22)
        \\func unrelated() int -> 2
    );
    const changed = try db.get(queries.ResolveStatic, result);
    try testing.expect(first != changed);
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 43 } } },
        (try db.lookupInterned(queries.CompileTimeValues, changed.*.?)).*,
    );
}

test "compile-time interpreter executes concrete callable values" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static increment = func(value: int) int -> value + 1
        \\static apply = func(operation: func(int) int, value: int) int -> operation(value)
        \\static result = apply(increment, 41)
    );
    const result = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("result").?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, result),
    );
}

test "compile-time interpreter propagates fallible call outcomes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible positive(value: int) int
        \\  value > 0
        \\  return value
        \\static identity = func(value: int) int -> value
        \\static checked: fallible(int) int = identity
        \\static good = positive(42)
        \\static bad = positive(0)
        \\static indirect = checked(42)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("good").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("indirect").?),
    );
    const bad = scope.resolveStatic("bad").?;
    try testing.expect((try db.get(queries.ResolveStatic, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.compile_time_unhandled_failure, std.meta.activeTag(diagnostics[0].kind));
}

test "compile-time call cycles diagnose the reached call site" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static recurse = func(value: int) int -> recurse(value)
        \\static result = recurse(1)
    ;
    try addSource(db, 1, source);
    const result = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("result").?;
    try testing.expect((try db.get(queries.ResolveStatic, result)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, result, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 2), diagnostics.len);
    const primary = if (std.meta.activeTag(diagnostics[0].kind) == .compile_time_call_cycle) diagnostics[0] else diagnostics[1];
    const trace = if (std.meta.activeTag(diagnostics[0].kind) == .compile_time_call_trace) diagnostics[0] else diagnostics[1];
    try testing.expectEqual(DiagnosticKind.compile_time_call_cycle, std.meta.activeTag(primary.kind));
    try testing.expectEqualStrings("recurse", source[primary.span.?.start..primary.span.?.end]);
    try testing.expectEqual(DiagnosticKind.compile_time_call_trace, std.meta.activeTag(trace.kind));
    const initial_call = std.mem.lastIndexOf(u8, source, "recurse").?;
    try testing.expectEqual(structures.SourceSpan{ .start = initial_call, .end = initial_call + "recurse".len }, trace.span);
}

test "deep terminating compile-time recursion has no fixed depth limit" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static down = func(value: int) int -> if value == 0 -> 42 else down(value - 1)
        \\static deep = down(130)
        \\static shallow = down(3)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("deep").?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic("shallow").?),
    );
}

test "static value arguments execute arbitrary scalar thunks" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static select = func(static value: int) int -> value
        \\static add = func(left: int, right: int) int -> left + right
        \\static result = select(add(20, 22))
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const result_item = scope.resolveStatic("result").?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, result_item),
    );
}

test "compile-time interpreter executes structs variants and mutable aggregate calls" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\static sum = func(pair: Pair) int -> pair.left + pair.right
        \\static increment = func(mut pair: Pair)
        \\  pair.left += 1
        \\static adjust = fallible(mut value: int) int
        \\  value += 1
        \\  value > 0
        \\  return value
        \\static Maybe = int | none
        \\static unwrap = func(value: Maybe) int -> return if const number = value as int -> number else 0
        \\static aggregate = sum(Pair{right = 2, left = 40})
        \\static narrowed = unwrap(42)
        \\static mutated = comptime
        \\  var pair = Pair{left = 40, right = 1}
        \\  increment(pair)
        \\  pair.left + pair.right
        \\static mutable_success = comptime
        \\  var value = 0
        \\  if adjust(value) -> value + 41 else 0
        \\static mutable_failure = comptime
        \\  var value = -1
        \\  if adjust(value) -> 0 else value + 42
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    for ([_][]const u8{ "aggregate", "narrowed", "mutated", "mutable_success", "mutable_failure" }) |name| {
        try testing.expectEqual(
            structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
            try resolvedStaticValue(db, scope.resolveStatic(name).?),
        );
    }
}

test "compile-time interpreter executes custom aggregate ownership hooks" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Box = struct
        \\  copy = func(imm self: Box) Box -> Box{value = self.value + 1}
        \\  value: int
        \\static MovedBox = struct
        \\  move = func(var self: MovedBox) MovedBox
        \\    self.value += 1
        \\    return self^
        \\  value: int
        \\static result = comptime
        \\  const source = Box{value = 41}
        \\  const copied = source
        \\  copied.value
        \\static moved = comptime
        \\  const source = MovedBox{value = 41}
        \\  const destination = source^
        \\  destination.value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    for ([_][]const u8{ "result", "moved" }) |name| try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic(name).?),
    );
}

test "compile-time aggregate results are canonical and cleanup preserves reverse field order" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  copy = trivial
        \\  left: int
        \\  right: int
        \\static pair = Pair{right = 2, left = 40}
        \\static sum = func(value: Pair) int -> value.left + value.right
        \\static select = func(static value: Pair) int -> value.left + value.right
        \\static reused = sum(pair)
        \\static specialized = select(pair)
        \\static Maybe = int | none
        \\static direct: Maybe = 42
        \\static interpreted: Maybe = if 0 < 1 -> 42 else none
        \\static MaybePair = Pair | none
        \\static boxed: MaybePair = Pair{left = 40, right = 2}
        \\static boxed_alias: MaybePair = pair
        \\static unbox = func(value: MaybePair) int -> return if const pair_value = value as Pair -> sum(pair_value) else 0
        \\static boxed_sum = unbox(boxed)
        \\static boxed_alias_sum = unbox(boxed_alias)
        \\func answer() int -> sum(pair)
        \\static Resource = struct
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\  value: int
        \\static Resources = struct
        \\  first: Resource
        \\  second: Resource
        \\static stopped = comptime
        \\  const resources = Resources{first = Resource{value = 41}, second = Resource{value = 42}}
        \\  unit
        \\static safe = comptime
        \\  const selected: Resource | int = if 1 < 0 -> Resource{value = 42} else 0
        \\  unit
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const pair = try resolvedStaticValue(db, scope.resolveStatic("pair").?);
    const fields = try db.lookupInterned(queries.CompileTimeValueTuples, pair.runtime.value.structure);
    try testing.expectEqual(@as(usize, 2), fields.values.len);
    try testing.expectEqual(@as(i32, 40), (try lookupCompileTimeValue(db, fields.values[0])).runtime.value.int);
    try testing.expectEqual(@as(i32, 2), (try lookupCompileTimeValue(db, fields.values[1])).runtime.value.int);
    try testing.expectEqual(
        (try db.get(queries.ResolveStatic, scope.resolveStatic("direct").?)).*.?,
        (try db.get(queries.ResolveStatic, scope.resolveStatic("interpreted").?)).*.?,
    );
    for ([_][]const u8{ "reused", "specialized", "boxed_sum", "boxed_alias_sum" }) |name| try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 42 } } },
        try resolvedStaticValue(db, scope.resolveStatic(name).?),
    );
    try testing.expectEqual(
        structures.CompileTimeValue{ .runtime = .{ .type_id = .unit, .value = .unit } },
        try resolvedStaticValue(db, scope.resolveStatic("safe").?),
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "sum" }, 42);

    const stopped = scope.resolveStatic("stopped").?;
    try testing.expect((try db.get(queries.ResolveStatic, stopped)).* == null);
    const controls = try db.transitiveAccumulatorValues(queries.ResolveStatic, stopped, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "compile-time aggregate results retain across unrelated edits and invalidate with constructors" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\static make = func(value: int) Pair -> Pair{left = value, right = 2}
        \\static result = make(40)
        \\func unrelated() int -> 1
    );
    const result = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("result").?;
    const first = try db.get(queries.ResolveStatic, result);

    try setSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\static make = func(value: int) Pair -> Pair{left = value, right = 2}
        \\static result = make(40)
        \\func unrelated() int -> 2
    );
    try testing.expectEqual(first, try db.get(queries.ResolveStatic, result));

    try setSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\static make = func(value: int) Pair -> Pair{left = value, right = 3}
        \\static result = make(40)
        \\func unrelated() int -> 2
    );
    const changed = try db.get(queries.ResolveStatic, result);
    try testing.expect(first != changed);
    const value = (try db.lookupInterned(queries.CompileTimeValues, changed.*.?)).*.runtime;
    const fields = try db.lookupInterned(queries.CompileTimeValueTuples, value.value.structure);
    try testing.expectEqual(@as(i32, 3), (try lookupCompileTimeValue(db, fields.values[1])).runtime.value.int);
}

test "type-valued functions execute in aliases signatures and struct fields" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static choose = func(flag: bool) type
        \\  const selected = if flag == true -> int else bool
        \\  return selected
        \\static select = func(static T: type) type -> if T == int -> bool else int
        \\static primitiveType = func() type -> int
        \\static Primitive: type = primitiveType()
        \\static unitType = func() type -> unit
        \\static noneType = func() type -> none
        \\static Unit: type = unitType()
        \\static None: type = noneType()
        \\static Selected: type = choose(true)
        \\static Inferred = choose(false)
        \\static Maybe = int | none
        \\static maybeType = func() type -> Maybe
        \\static Callback: type = func(int) int
        \\static callbackType = func() type -> Callback
        \\static Box = struct
        \\  value: select(bool)
        \\func take(value: Selected, box: Box) int -> value + box.value
        \\func takeBool(value: Inferred) bool -> value
        \\func inspect(value: maybeType(), callback: callbackType()) int -> 0
        \\func zero(value: Primitive) int -> value
        \\func answer() int -> zero(take(40, Box{value = 2}))
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const canonical_int = try db.intern(queries.CompileTimeValues, structures.CompileTimeValue{ .type = .int });
    try testing.expectEqual(canonical_int, (try db.get(queries.ResolveStatic, scope.resolveStatic("Selected").?)).*.?);
    try testing.expectEqual(structures.CompileTimeValue{ .type = .unit }, try resolvedStaticValue(db, scope.resolveStatic("Unit").?));
    try testing.expectEqual(structures.CompileTimeValue{ .type = .none }, try resolvedStaticValue(db, scope.resolveStatic("None").?));
    const primitive_type = scope.resolveFunction("primitiveType").?;
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = primitive_type })).* == null);
    const compile_diagnostics = try db.transitiveAccumulatorValues(queries.CompileFunction, .{ .item = primitive_type }, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(compile_diagnostics);
    try testing.expectEqual(@as(usize, 0), compile_diagnostics.len);

    const box_type = (try resolvedStaticValue(db, scope.resolveStatic("Box").?)).type;
    const box = (try db.get(queries.StructDefinition, scope.resolveStatic("Box").?)).*.?;
    try testing.expectEqual(structures.TypeId.int, box.fields[0].type_id);
    const take = (try db.get(queries.FunctionSignature, scope.resolveFunction("take").?)).*.?;
    try testing.expectEqualSlices(structures.CallableParameter, &.{
        .{ .mode = .imm, .type_id = .int },
        .{ .mode = .imm, .type_id = box_type },
    }, take.parameters);
    const take_bool = (try db.get(queries.FunctionSignature, scope.resolveFunction("takeBool").?)).*.?;
    try testing.expectEqual(structures.TypeId.bool, take_bool.parameters[0].type_id);

    const maybe = (try resolvedStaticValue(db, scope.resolveStatic("Maybe").?)).type;
    const callback = (try resolvedStaticValue(db, scope.resolveStatic("Callback").?)).type;
    const inspect = (try db.get(queries.FunctionSignature, scope.resolveFunction("inspect").?)).*.?;
    try testing.expectEqual(maybe, inspect.parameters[0].type_id);
    try testing.expectEqual(callback, inspect.parameters[1].type_id);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "zero", "take" }, 42);
}

test "type-valued functions keep unit literals in runtime argument context" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static consume = func(value: unit) int -> 42
        \\static make = func() type
        \\  const result = consume(unit)
        \\  return int
        \\static T = make()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        structures.CompileTimeValue{ .type = .int },
        try resolvedStaticValue(db, scope.resolveStatic("T").?),
    );
}

test "callable widening has one canonical compile-time representation" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static identity = func(value: int) int -> value
        \\static direct: fallible(int) int = identity
        \\static make = func() fallible(int) int -> identity
        \\static computed = make()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(
        (try db.get(queries.ResolveStatic, scope.resolveStatic("direct").?)).*.?,
        (try db.get(queries.ResolveStatic, scope.resolveStatic("computed").?)).*.?,
    );
}

test "type-valued functions generate canonical specialized nominal structs" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Count = int
        \\static makeBox = func(static T: type) type
        \\  return struct
        \\    value: T
        \\    count: Count
        \\static IntBox: type = makeBox(int)
        \\static Same = makeBox(int)
        \\static BoolBox: type = makeBox(bool)
        \\static makeValueBox = func(flag: bool) type
        \\  return struct
        \\    value: int
        \\static FirstValueBox = makeValueBox(true)
        \\static SecondValueBox = makeValueBox(false)
        \\func add(left: IntBox, right: Same) int -> left.value + left.count + right.value + right.count
        \\func answer() int -> add(makeBox(int){value = 19, count = 1}, Same{value = 21, count = 1})
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const int_box = (try resolvedStaticValue(db, scope.resolveStatic("IntBox").?)).type;
    const same = (try resolvedStaticValue(db, scope.resolveStatic("Same").?)).type;
    const bool_box = (try resolvedStaticValue(db, scope.resolveStatic("BoolBox").?)).type;
    try testing.expectEqual(int_box, same);
    try testing.expect(int_box != bool_box);
    try testing.expectEqual(
        (try resolvedStaticValue(db, scope.resolveStatic("FirstValueBox").?)).type,
        (try resolvedStaticValue(db, scope.resolveStatic("SecondValueBox").?)).type,
    );

    const int_identity = (try db.lookupInterned(queries.Types, int_box.interned().?)).structure;
    const bool_identity = (try db.lookupInterned(queries.Types, bool_box.interned().?)).structure;
    const int_definition = (try db.get(queries.GeneratedStructDefinition, int_identity.generated)).*.?;
    const bool_definition = (try db.get(queries.GeneratedStructDefinition, bool_identity.generated)).*.?;
    try testing.expectEqual(@as(usize, 2), int_definition.fields.len);
    try testing.expectEqualStrings("value", int_definition.fields[0].name);
    try testing.expectEqual(structures.TypeId.int, int_definition.fields[0].type_id);
    try testing.expectEqual(structures.TypeId.bool, bool_definition.fields[0].type_id);
    try testing.expectEqual(structures.TypeId.int, int_definition.fields[1].type_id);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "add" }, 42);
}

test "parameterized struct declarations are static type factories" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\struct Box(T: type, Tag: int)
        \\  value: T
        \\static IntBox = Box(int, 1)
        \\static Same = Box(int, 1)
        \\static OtherTag = Box(int, 2)
        \\static BoolBox = Box(bool, 1)
        \\const boxed = Box(int, 1){value = 42}
        \\exit(boxed.value)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const int_box_item = scope.resolveStatic("IntBox").?;
    const int_box_result = try db.get(queries.ResolveStatic, int_box_item);
    const int_box = (try lookupCompileTimeValue(db, int_box_result.*.?)).type;
    const same = try resolvedStaticType(db, scope.resolveStatic("Same").?);
    const other_tag = try resolvedStaticType(db, scope.resolveStatic("OtherTag").?);
    const bool_box = try resolvedStaticType(db, scope.resolveStatic("BoolBox").?);
    try testing.expectEqual(int_box, same);
    try testing.expect(int_box != other_tag);
    try testing.expect(int_box != bool_box);

    const int_identity = (try db.lookupInterned(queries.Types, int_box.interned().?)).structure;
    const bool_identity = (try db.lookupInterned(queries.Types, bool_box.interned().?)).structure;
    const int_definition = (try db.get(queries.GeneratedStructDefinition, int_identity.generated)).*.?;
    const bool_definition = (try db.get(queries.GeneratedStructDefinition, bool_identity.generated)).*.?;
    try testing.expectEqual(structures.TypeId.int, int_definition.fields[0].type_id);
    try testing.expectEqual(structures.TypeId.bool, bool_definition.fields[0].type_id);

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static unrelated = 0
        \\struct Box(T: type, Tag: int)
        \\  value: T
        \\static IntBox = Box(int, 1)
        \\static Same = Box(int, 1)
        \\static OtherTag = Box(int, 2)
        \\static BoolBox = Box(bool, 1)
        \\const boxed = Box(int, 1){value = 42}
        \\exit(boxed.value)
    );
    try testing.expectEqual(int_box_result, try db.get(queries.ResolveStatic, int_box_item));
}

test "generated struct identity survives relocation and changes with specialization" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static makeBox = func(static T: type) type
        \\  return struct
        \\    value: T
        \\static Box = makeBox(int)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const box = scope.resolveStatic("Box").?;
    const initial = try db.get(queries.ResolveStatic, box);
    const initial_type = (try db.lookupInterned(queries.CompileTimeValues, initial.*.?)).type;
    const identity = (try db.lookupInterned(queries.Types, initial_type.interned().?)).structure.generated;

    try setSource(db, 1,
        \\static unrelated = 42
        \\static makeBox = func(static T: type) type
        \\  return struct
        \\    value: T
        \\static Box = makeBox(int)
    );
    try testing.expectEqual(initial, try db.get(queries.ResolveStatic, box));
    const relocated_definition = try db.get(queries.GeneratedStructDefinition, identity);
    try testing.expectEqual(structures.TypeId.int, relocated_definition.*.?.fields[0].type_id);

    try setSource(db, 1,
        \\static unrelated = 42
        \\static makeBox = func(static T: type) type
        \\  return struct
        \\    value: bool
        \\static Box = makeBox(int)
    );
    try testing.expectEqual(initial, try db.get(queries.ResolveStatic, box));
    const changed_definition = try db.get(queries.GeneratedStructDefinition, identity);
    try testing.expect(relocated_definition != changed_definition);
    try testing.expectEqual(structures.TypeId.bool, changed_definition.*.?.fields[0].type_id);

    try setSource(db, 1,
        \\static unrelated = 42
        \\static makeBox = func(static T: type) type
        \\  return struct
        \\    value: bool
        \\static Box = makeBox(bool)
    );
    const changed = try db.get(queries.ResolveStatic, box);
    try testing.expect(initial != changed);
    try testing.expect(initial_type != (try db.lookupInterned(queries.CompileTimeValues, changed.*.?)).type);
}

test "generated structs do not capture comptime locals" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static makeBox = func() type
        \\  const Local = int
        \\  return struct
        \\    value: Local
        \\const value = makeBox(){value = 1}
        \\exit(value.value)
    ;
    try addSource(db, 1, source);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.unknown_type, std.meta.activeTag(diagnostics[0].kind));
    try testing.expectEqualStrings("Local", source[diagnostics[0].span.?.start..diagnostics[0].span.?.end]);
}

test "generated structs accept ownership properties" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static makeBox = func() type
        \\  return struct
        \\    copy = trivial
        \\    value: int
        \\const value = makeBox(){value = 1}
        \\exit(value.value)
    ;
    try addSource(db, 1, source);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "generated struct ownership hooks inherit the type specialization" {
    const db = try testDatabase(1);
    defer db.deinit();

    const initial =
        \\struct Box(T: type)
        \\  copy = func(imm self: Box(T)) Box(T) -> Box(T){value = self.value + 1}
        \\  value: T
        \\const original = Box(int){value = 41}
        \\const copied = original
        \\exit(copied.value)
    ;
    try addSource(db, 1, initial);
    var executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\struct Box(T: type)
        \\  copy = func(imm self: Box(T)) Box(T) -> Box(T){value = self.value + 2}
        \\  value: T
        \\const original = Box(int){value = 41}
        \\const copied = original
        \\exit(copied.value)
    );
    executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 43), runtime.runProg(io, testing.allocator, &.{}));
}

test "public parameterized struct hooks execute" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\pub struct Box(T: type)
        \\  copy = func(imm self: Box(T)) Box(T) -> Box(T){value = self.value + 1}
        \\  value: T
        \\const original = Box(int){value = 41}
        \\const copied = original
        \\exit(copied.value)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "generated struct ownership declarations validate field capabilities" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Field = struct
        \\  value: int
        \\static makeInvalid = func() type
        \\  return struct
        \\    copy = trivial
        \\    value: Field
        \\static Invalid = makeInvalid()
    );
    const invalid = try resolvedStaticType(db, (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("Invalid").?);
    try testing.expect((try db.get(queries.OwnershipCapabilities, invalid)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, invalid, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(
        structures.Diagnostic.Kind{ .struct_ownership_property_incompatible_with_fields = .trivial_copy },
        diagnostics[0].kind,
    );
}

test "anonymous struct expressions are compile-time-only" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\const invalid = struct
        \\  value: int
        \\exit(0)
    ;
    try addSource(db, 1, source);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_value_used_as_runtime_value, std.meta.activeTag(diagnostics[0].kind));
    try testing.expectEqualStrings("struct", source[diagnostics[0].span.?.start..diagnostics[0].span.?.end]);
}

test "generated struct containment rejects recursive nominal identity" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static makeNode = func() type
        \\  return struct
        \\    next: makeNode()
        \\static Node = makeNode()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const node_type = (try resolvedStaticValue(db, scope.resolveStatic("Node").?)).type;
    try testing.expect((try db.get(queries.OwnershipCapabilities, node_type)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.OwnershipCapabilities, node_type, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.recursive_struct_containment, std.meta.activeTag(diagnostics[0].kind));
}

test "type-valued calls are compile-time-only" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static choose = func() type -> int
        \\func invalid() int -> choose()
    ;
    try addSource(db, 1, source);
    const invalid = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("invalid").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, invalid)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, invalid, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_value_used_as_runtime_value, std.meta.activeTag(diagnostics[0].kind));
    try testing.expectEqualStrings("choose", source[diagnostics[0].span.?.start..diagnostics[0].span.?.end]);
}

test "type-valued call results retain equal signatures and invalidate on type changes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = func() type -> int
        \\func consume(value: selected()) int -> 1
    );
    const consume = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("consume").?;
    const initial = try db.get(queries.FunctionSignature, consume);
    try testing.expectEqual(structures.TypeId.int, initial.*.?.parameters[0].type_id);

    try setSource(db, 1,
        \\static selected = func() type
        \\  return int
        \\func consume(value: selected()) int -> 1
    );
    try testing.expectEqual(initial, try db.get(queries.FunctionSignature, consume));

    try setSource(db, 1,
        \\static selected = func() type -> bool
        \\func consume(value: selected()) int -> 1
    );
    const changed = try db.get(queries.FunctionSignature, consume);
    try testing.expect(initial != changed);
    try testing.expectEqual(structures.TypeId.bool, changed.*.?.parameters[0].type_id);
}

test "explicit comptime expressions publish constants into runtime bodies" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\func answer() int
        \\  const base = comptime
        \\    var value = 39
        \\    value += 2
        \\    value
        \\  return base + 1
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "comptime thunks inherit enclosing static specialization arguments" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static increment = func(static N: int) int -> comptime -> N + 1
        \\func answer() int -> increment(41)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const answer = scope.resolveFunction("answer").?;
    const answer_body = (try db.get(queries.AnalyzeFunctionBody, answer)).*.?;
    const increment = answer_body.instructions[0].call.instance();
    const increment_body = (try db.get(queries.AnalyzeFunctionInstance, increment)).*.?;
    try testing.expectEqual(@as(usize, 2), increment_body.instructions.len);
    try testing.expectEqual(@as(i32, 42), increment_body.instructions[1].const_int);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(increment_body.blocks[0].terminator.return_value.value));
}

test "comptime expressions cannot capture runtime locals" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "func bad(value: int) int -> comptime -> value + 1");
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.comptime_runtime_capture, std.meta.activeTag(diagnostics[0].kind));
}

test "compile-time division errors point at the executed instruction" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static bad = 42 / 0");
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("bad").?;
    try testing.expect((try db.get(queries.ResolveStatic, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.compile_time_division_by_zero, std.meta.activeTag(diagnostics[0].kind));
    try testing.expectEqual(structures.SourceSpan{ .start = 16, .end = 17 }, diagnostics[0].span);
}

test "compile-time execution errors include every call site" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static fail = func() int -> 42 / 0
        \\static middle = func() int -> fail()
        \\static bad = middle()
    ;
    try addSource(db, 1, source);
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("bad").?;
    try testing.expect((try db.get(queries.ResolveStatic, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 3), diagnostics.len);

    var primary_count: usize = 0;
    var trace_count: usize = 0;
    for (diagnostics) |diagnostic| switch (std.meta.activeTag(diagnostic.kind)) {
        .compile_time_division_by_zero => primary_count += 1,
        .compile_time_call_trace => trace_count += 1,
        else => return error.UnexpectedDiagnostic,
    };
    try testing.expectEqual(@as(usize, 1), primary_count);
    try testing.expectEqual(@as(usize, 2), trace_count);
}

test "compile-time exit propagates through interpreted calls as compiler control" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static stop = func() int -> exit(42)
        \\static stopped = stop()
        \\func answer() int -> stopped
    );
    const stopped = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("stopped").?;
    try testing.expect((try db.get(queries.ResolveStatic, stopped)).* == null);
    const controls = try db.transitiveAccumulatorValues(queries.ResolveStatic, stopped, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ResolveStatic, stopped, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "static declaration cycles are diagnosed and recover after edits" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static First = Second
        \\static Second = First
        \\func use(value: First) int -> 42
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const use = scope.resolveFunction("use").?;
    try testing.expect((try db.get(queries.FunctionSignature, use)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, use, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.declaration_cycle, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static First = int | none
        \\static Second = First
        \\func use(value: First) int -> 42
    );
    try testing.expect((try db.get(queries.FunctionSignature, use)).* != null);
    diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, use, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "static declaration edits invalidate actual consumers and retain equal results" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static Result = int | none
        \\static default_value = 40
        \\func answer(value: Result) int -> default_value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const result = scope.resolveStatic("Result").?;
    const default_value = scope.resolveStatic("default_value").?;
    const answer = scope.resolveFunction("answer").?;
    const first_result = try db.get(queries.ResolveStatic, result);
    const first_default = try db.get(queries.ResolveStatic, default_value);
    const first_signature = try db.get(queries.FunctionSignature, answer);
    const first_body = try db.get(queries.AnalyzeFunctionBody, answer);
    const first_artifact = try db.get(queries.CompileFunction, .{ .item = answer });

    try setSource(db, 1,
        \\static Result = none | int
        \\static default_value = 40
        \\func answer(value: Result) int -> default_value
    );
    try testing.expectEqual(first_result, try db.get(queries.ResolveStatic, result));
    try testing.expectEqual(first_default, try db.get(queries.ResolveStatic, default_value));
    try testing.expectEqual(first_signature, try db.get(queries.FunctionSignature, answer));
    try testing.expectEqual(first_body, try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expectEqual(first_artifact, try db.get(queries.CompileFunction, .{ .item = answer }));

    try setSource(db, 1,
        \\static Result = none | int
        \\static default_value = 41
        \\func answer(value: Result) int -> default_value
    );
    try testing.expect(first_default != try db.get(queries.ResolveStatic, default_value));
    try testing.expect(first_body != try db.get(queries.AnalyzeFunctionBody, answer));
    try testing.expect(first_artifact != try db.get(queries.CompileFunction, .{ .item = answer }));
}

test "static declaration resolution cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testStaticDeclarationAllocations, .{});
}

fn testStaticDeclarationAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try addSource(db, 1,
        \\static Empty: type = none
        \\static Result = int | Empty
        \\static value: Result = 40
        \\static enabled = true
        \\static selectedType = func() type -> int
        \\static Selected: type = selectedType()
        \\static generatedBox = func(static T: type) type
        \\  return struct
        \\    value: T
        \\static GeneratedBox = generatedBox(int)
        \\static generated = GeneratedBox{value = 1}
        \\static Pair = struct
        \\  copy = trivial
        \\  left: int
        \\  right: int
        \\static MaybePair = Pair | none
        \\static boxed: MaybePair = Pair{left = 1, right = 2}
        \\static sum = func(pair: Pair) int -> pair.left + pair.right
        \\static unbox = func(value: MaybePair) int -> return if const pair = value as Pair -> sum(pair) else 0
        \\static computed = unbox(boxed)
        \\func answer() int -> return if enabled == true
        \\  if const number = value as int -> number + computed + generated.value - 2 else 1
        \\else 0
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect((try db.get(queries.ResolveStatic, scope.resolveStatic("Selected").?)).* != null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "module scope classifies empty missing and malformed inputs" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "");
    try addSource(db, 2, "static value = 1");
    try addSource(db, 3, "const value 1");

    try testing.expectEqual(@as(usize, 0), (try db.get(queries.BuildModuleScope, 1)).*.?.entries.len);
    try testing.expectEqual(@as(usize, 1), (try db.get(queries.BuildModuleScope, 2)).*.?.entries.len);
    try testing.expect((try db.get(queries.BuildModuleScope, 3)).* == null);
    try testing.expectError(error.InputNotFound, db.get(queries.BuildModuleScope, 99));
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.BuildModuleScope, 3, structures.Diagnostic)).len);
    const malformed = try db.transitiveAccumulatorValues(queries.BuildModuleScope, 3, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(malformed);
    try testing.expect(malformed.len > 0);
}

test "discovery diagnoses later duplicate functions and scope recovers" {
    const db = try testDatabase(2);
    defer db.deinit();

    const duplicate_source =
        \\static duplicate = func() int -> return 1
        \\static other = func() int -> return 0
        \\static duplicate = func() int -> return 2
        \\static duplicate = func() int -> return 3
    ;
    try addSource(db, 1, duplicate_source);
    try testing.expect((try db.get(queries.DiscoverItems, 1)).* == null);
    try testing.expect((try db.get(queries.BuildModuleScope, 1)).* == null);
    const diagnostics = try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 2), diagnostics.len);
    var search_from = std.mem.indexOf(u8, duplicate_source, "duplicate").? + "duplicate".len;
    for (diagnostics) |diagnostic| {
        try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, diagnostic.kind);
        const start = std.mem.indexOfPos(u8, duplicate_source, search_from, "duplicate").?;
        try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + "duplicate".len }, diagnostic.span.?);
        search_from = start + "duplicate".len;
    }

    try setSource(db, 1,
        \\static other = func() int -> return 0
        \\static duplicate = func() int -> return 3
    );
    const recovered = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect(recovered.resolve("duplicate") != null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic)).len);
}

test "discovery refreshes duplicate spans when its index remains equal" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    const initial_index = try db.get(queries.IndexItems, 1);
    try testing.expect((try db.get(queries.DiscoverItems, 1)).* == null);
    const initial_diagnostics = try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), initial_diagnostics.len);
    const initial_span = initial_diagnostics[0].span.?;

    try setSource(db, 1,
        \\static duplicate = func() int -> return 123456789
        \\static duplicate = func() int -> return 2
    );
    try testing.expectEqual(initial_index, try db.get(queries.IndexItems, 1));
    try testing.expect((try db.get(queries.DiscoverItems, 1)).* == null);
    const updated_diagnostics = try db.directAccumulatorValues(queries.DiscoverItems, 1, structures.Diagnostic);
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
    const initial_scope = try db.get(queries.BuildModuleScope, 1);
    const alpha_id = (try db.get(ModuleScopeParent, 1)).*.?;

    try setSource(db, 1,
        \\static beta = func() int -> return 20
        \\static alpha = func() int -> return 10
    );
    try testing.expectEqual(initial_scope, try db.get(queries.BuildModuleScope, 1));
    try testing.expectEqual(alpha_id, (try db.get(ModuleScopeParent, 1)).*.?);

    try setSource(db, 1,
        \\static alpha = func() int -> return 10
        \\static beta = func() int -> return 20
    );
    try testing.expectEqual(initial_scope, try db.get(queries.BuildModuleScope, 1));
    try testing.expectEqual(alpha_id, (try db.get(ModuleScopeParent, 1)).*.?);
    try ModuleScopeParent.executions.expect(1);

    try setSource(db, 1,
        \\static gamma = func() int -> return 10
        \\static beta = func() int -> return 20
    );
    const renamed = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect(renamed.resolve("alpha") == null);
    try testing.expect(renamed.resolve("gamma") != null);

    try setSource(db, 1, original);
    const restored = (try db.get(queries.BuildModuleScope, 1)).*.?;
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
    try testing.expect((try db.get(queries.BuildModuleScope, 1)).* != null);
}

test "concurrent module scope requests share successful and duplicate results" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "static alpha = func() int -> return 1");
    var successful: [8]Handle(queries.BuildModuleScope) = undefined;
    for (&successful) |*handle| handle.* = try db.spawn(queries.BuildModuleScope, 1);
    const first = try successful[0].wait();
    for (successful[1..]) |handle| try testing.expectEqual(first, try handle.wait());

    try addSource(db, 2,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    var duplicate: [8]Handle(queries.BuildModuleScope) = undefined;
    for (&duplicate) |*handle| handle.* = try db.spawn(queries.BuildModuleScope, 2);
    const duplicate_first = try duplicate[0].wait();
    try testing.expect(duplicate_first.* == null);
    for (duplicate[1..]) |handle| try testing.expectEqual(duplicate_first, try handle.wait());
    const duplicate_diagnostics = try db.transitiveAccumulatorValues(queries.BuildModuleScope, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(duplicate_diagnostics);
    try testing.expectEqual(@as(usize, 1), duplicate_diagnostics.len);
}

test "resolution requested before interning retries after identity issuance" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static target = func() int -> return 1");
    const unissued: structures.ItemId = @enumFromInt(std.math.maxInt(u32));
    try testing.expectError(error.InvalidInternId, db.get(queries.ResolveItem, unissued));
    const issued = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    try testing.expect((try db.get(queries.ResolveItem, issued)).* != null);
}

test "item identity survives relocation and restoration" {
    const db = try testDatabase(1);
    defer db.deinit();

    const original = "static target = func() int -> return 1";
    try addSource(db, 1, original);
    const initial_index = (try db.get(queries.IndexItems, 1)).*.?;
    const target_id = initial_index.ids()[0];
    const initial_resolution = (try db.get(queries.ResolveItem, target_id)).*.?;

    try setSource(db, 1,
        \\static unrelated = func() int -> return 0
        \\static target = func() int -> return 2
    );
    const relocated_index = (try db.get(queries.IndexItems, 1)).*.?;
    try testing.expectEqual(target_id, relocated_index.ids()[1]);
    const relocated = (try db.get(queries.ResolveItem, target_id)).*.?;
    try testing.expect(initial_resolution.declaration != relocated.declaration);

    try setSource(db, 1, "static renamed = func() int -> return 3");
    try testing.expect((try db.get(queries.ResolveItem, target_id)).* == null);
    try setSource(db, 1, "const x 1");
    try testing.expect((try db.get(queries.ResolveItem, target_id)).* == null);

    try setSource(db, 1, original);
    const restored_index = (try db.get(queries.IndexItems, 1)).*.?;
    try testing.expectEqual(target_id, restored_index.ids()[0]);
    try testing.expect((try db.get(queries.ResolveItem, target_id)).* != null);
}

test "synthetic entry identity persists through top-level code changes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    const entry_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    try testing.expectEqual(structures.ItemKind.top_level_entry, (try db.lookupInterned(queries.ItemLocations, entry_id)).kind);
    try testing.expect((try db.get(queries.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "print(1)");
    try testing.expectEqual(entry_id, (try db.get(queries.IndexItems, 1)).*.?.ids()[0]);
    try testing.expect((try db.get(queries.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "");
    try testing.expect((try db.get(queries.ResolveItem, entry_id)).* != null);

    try setSource(db, 1, "print(2)");
    try testing.expectEqual(entry_id, (try db.get(queries.IndexItems, 1)).*.?.ids()[0]);
    try testing.expect((try db.get(queries.ResolveItem, entry_id)).* != null);
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

    for ([_]structures.FileId{ 1, 4, 5 }) |file_id| {
        const selected = (try db.get(queries.SelectEntry, file_id)).*.?;
        const index = (try db.get(queries.IndexItems, file_id)).*.?;
        var matching_entries: usize = 0;
        for (index.ids()) |item_id| {
            const loc = try db.lookupInterned(queries.ItemLocations, item_id);
            if (loc.kind != .top_level_entry) continue;
            matching_entries += 1;
            try testing.expectEqual(item_id, selected);
        }
        try testing.expectEqual(@as(usize, 1), matching_entries);
    }

    const first_entry = (try db.get(queries.SelectEntry, 1)).*.?;
    const other_entry = (try db.get(queries.SelectEntry, 4)).*.?;
    try testing.expect(first_entry != other_entry);
    // File 2's duplicate top-level names are rejected before indexing.
    try testing.expect((try db.get(queries.SelectEntry, 2)).* == null);
    try testing.expect((try db.get(queries.SelectEntry, 3)).* == null);
    try testing.expectError(error.InputNotFound, db.get(queries.SelectEntry, 99));
}

test "SelectEntry restores stable identity after malformed source" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 1";
    try addSource(db, 1, valid);
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;

    try setSource(db, 1, "const x 1");
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);

    try setSource(db, 1, valid);
    try testing.expectEqual(entry_id, (try db.get(queries.SelectEntry, 1)).*.?);
}

test "equal SelectEntry result does not recompute its parent" {
    const db = try testDatabase(1);
    defer db.deinit();

    SelectEntryParent.executions.reset();
    try addSource(db, 1, "");
    const entry_id = (try db.get(SelectEntryParent, 1)).*.?;
    try testing.expectEqual(@as(usize, 1), (try db.get(queries.IndexItems, 1)).*.?.count());

    try setSource(db, 1, "static f = func() int -> return 1");
    try testing.expectEqual(entry_id, (try db.get(SelectEntryParent, 1)).*.?);
    try testing.expectEqual(@as(usize, 2), (try db.get(queries.IndexItems, 1)).*.?.count());
    try SelectEntryParent.executions.expect(1);
}

test "SelectEntry exposes changed diagnostics while remaining null" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const x 1");
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);
    const initial = try db.transitiveAccumulatorValues(queries.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(initial);

    try setSource(db, 1, "const longer_name 1");
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);
    const updated = try db.transitiveAccumulatorValues(queries.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(updated);

    try testing.expect(initial.len > 0);
    try testing.expectEqual(initial.len, updated.len);
    try testing.expect(!std.meta.eql(initial[0], updated[0]));
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
        const executable = (try db.get(queries.BuildExecutable, file_id)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "BuildExecutable follows compiled entry diagnostics and recovers" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);

    try setSource(db, 1, "print(1)");
    try testing.expectEqual(entry_id, (try db.get(queries.SelectEntry, 1)).*.?);
    try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const direct = try db.directAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), direct.len);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.unknown_function, diagnostics[0].kind);

    try setSource(db, 1, "");
    try testing.expectEqual(entry_id, (try db.get(queries.SelectEntry, 1)).*.?);
    try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "BuildExecutable exposes changed malformed diagnostics while remaining null" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const x 1");
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const initial = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(initial);

    try setSource(db, 1, "const longer_name 1");
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const updated = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(updated);

    try testing.expect(initial.len > 0);
    try testing.expectEqual(initial.len, updated.len);
    try testing.expect(!std.meta.eql(initial[0], updated[0]));
}

test "BuildExecutable retries missing input and retains equal output" {
    const db = try testDatabase(1);
    defer db.deinit();

    try testing.expectError(error.InputNotFound, db.get(queries.BuildExecutable, 1));
    try addSource(db, 1, "");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    const initial_artifact = try db.get(queries.CompileFunction, entry_instance);
    try testing.expect(initial_artifact.* != null);
    const initial = try db.get(queries.BuildExecutable, 1);
    try testing.expect(initial.* != null);

    try setSource(db, 1, "static f = func() int -> return 1");
    try testing.expectEqual(entry_id, (try db.get(queries.SelectEntry, 1)).*.?);
    try testing.expectEqual(initial_artifact, try db.get(queries.CompileFunction, entry_instance));
    const updated = try db.get(queries.BuildExecutable, 1);
    try testing.expectEqual(initial, updated);
}

test "concurrent BuildExecutable requests share one owned result" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "");
    var handles: [16]Handle(queries.BuildExecutable) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(queries.BuildExecutable, 1);
    const first = try handles[0].wait();
    try testing.expect(first.* != null);
    for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
}

test "function signatures intern canonical variant annotations" {
    const db = try testDatabase(2);
    defer db.deinit();

    SignatureParent.executions.reset();
    try addSource(db, 1, "static target = func(value: int | none) int | unit -> return 1");
    const target_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("target").?;
    const first_signature = try db.get(queries.FunctionSignature, target_id);
    try testing.expect(first_signature.* != null);
    const first_parameter = first_signature.*.?.parameters[0].type_id;
    const first_return = first_signature.*.?.return_type;
    try testing.expectEqualSlices(
        structures.TypeId,
        &.{ .int, .none },
        (try db.lookupInterned(queries.Types, first_parameter.interned().?)).variant.members,
    );
    try testing.expectEqualSlices(
        structures.TypeId,
        &.{ .int, .unit },
        (try db.lookupInterned(queries.Types, first_return.interned().?)).variant.members,
    );
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);

    const reordered_source = "static target = func(value: none | int) unit | int -> return 1";
    try setSource(db, 1, reordered_source);
    const reordered_signature = try db.get(queries.FunctionSignature, target_id);
    try testing.expectEqual(first_signature, reordered_signature);
    try testing.expectEqual(first_parameter, reordered_signature.*.?.parameters[0].type_id);
    try testing.expectEqual(first_return, reordered_signature.*.?.return_type);
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try SignatureParent.executions.expect(1);

    const body = (try db.get(queries.AnalyzeFunctionBody, target_id)).*.?;
    try testing.expectEqual(first_return, body.return_type);
    try testing.expectEqual(first_return, body.blocks[0].terminator.return_value.coerce_to.?);
    const diagnostics = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, target_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = target_id })).* != null);
}

test "variant annotation diagnostics belong to their semantic boundary" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        query_signature: bool,
        marker: []const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{ .file_id = 1, .source = "static target = func(value: int | int) unit -> return", .query_signature = true, .marker = "int", .kind = .duplicate_variant_member_type },
        .{ .file_id = 2, .source = "static target = func() unit | unit -> return", .query_signature = true, .marker = "unit", .kind = .duplicate_variant_member_type },
        .{ .file_id = 3, .source = "static target = func() int\n  const value: none | none = 1\n  return 1", .query_signature = false, .marker = "none", .kind = .duplicate_variant_member_type },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const target_id = (try db.get(queries.IndexItems, case.file_id)).*.?.ids()[0];
        const diagnostics = if (case.query_signature) blk: {
            try testing.expect((try db.get(queries.FunctionSignature, target_id)).* == null);
            break :blk try db.directAccumulatorValues(queries.FunctionSignature, target_id, structures.Diagnostic);
        } else blk: {
            try testing.expect((try db.get(queries.FunctionSignature, target_id)).* != null);
            try testing.expect((try db.get(queries.AnalyzeFunctionBody, target_id)).* == null);
            break :blk try db.directAccumulatorValues(queries.AnalyzeFunctionBody, target_id, structures.Diagnostic);
        };
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, diagnostics[0].kind);
        const start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + case.marker.len }, diagnostics[0].span.?);
    }
}

test "variant values cross calls and subset widening remaps their tag" {
    const db = try testDatabase(2);
    defer db.deinit();

    const source =
        \\static producer = func() int | none -> return none
        \\static accept = func(value: int | none | unit) int | none | unit -> return value
        \\static caller = func() int | none | unit -> return accept(producer())
    ;
    try addSource(db, 1, source);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const producer_id = scope.resolve("producer").?;
    const caller_id = scope.resolve("caller").?;
    const producer = (try db.get(queries.AnalyzeFunctionBody, producer_id)).*.?;
    try testing.expect(producer.blocks[0].terminator.return_value.coerce_to != null);
    const caller = (try db.get(queries.AnalyzeFunctionBody, caller_id)).*.?;
    try testing.expect(caller.call_arguments[0].coerce_to != null);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, caller_id)).* != null);
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = caller_id })).* != null);
    try expectCompiledVariantWord(db, 1, "caller", &.{ "caller", "producer", "accept" }, 0, 2);
}

test "variant subset widening at bindings and returns preserves tags and payloads" {
    const cases = [_]struct { variant: []const u8, value: []const u8, tag: u8, payload: ?u8 }{
        .{ .variant = "int | none", .value = "none", .tag = 2, .payload = null },
        .{ .variant = "int | none", .value = "42", .tag = 0, .payload = 42 },
        .{ .variant = "unit | none", .value = "none", .tag = 2, .payload = null },
        .{ .variant = "unit | none", .value = "", .tag = 1, .payload = null },
    };
    for (cases) |case| {
        const db = try testDatabase(2);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator,
            \\static producer = func() {s} -> return {s}
            \\static local = func() int | none | unit
            \\  const widened: int | none | unit = producer()
            \\  return widened
            \\static returned = func() int | none | unit -> return producer()
            \\const narrow = producer()
            \\const wide: int | none | unit = narrow
            \\local()
            \\returned()
        , .{ case.variant, case.value });
        defer testing.allocator.free(source);
        try addSource(db, 1, source);
        try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
        for ([_][]const u8{ "local", "returned" }) |name| {
            try expectCompiledVariantWord(db, 1, name, &.{ name, "producer" }, 0, case.tag);
            if (case.payload) |payload| try expectCompiledVariantWord(db, 1, name, &.{ name, "producer" }, 4, payload);
        }
    }
}

test "variant coercion rejects narrowing and non-containing variants at every boundary" {
    const boundaries = [_]struct { source: []const u8, kind: DiagnosticKind }{
        .{ .source = "static target = func(value: {s}) unit\n  const narrowed: {s} = value\n  return", .kind = .local_type_mismatch },
        .{ .source = "static target = func(value: {s}) {s} -> return value", .kind = .return_type_mismatch },
        .{ .source = "static target = func(value: {s}) unit -> return accept(value)\nstatic accept = func(value: {s}) unit -> return", .kind = .call_argument_type_mismatch },
    };
    const types = [_]struct { actual: []const u8, expected: []const u8 }{
        .{ .actual = "int | none | unit", .expected = "int | none" },
        .{ .actual = "int | none", .expected = "int | unit" },
        .{ .actual = "int | none", .expected = "int" },
    };
    inline for (boundaries) |boundary| {
        for (types) |pair| {
            const db = try testDatabase(2);
            defer db.deinit();
            const source = try std.fmt.allocPrint(testing.allocator, boundary.source, .{ pair.actual, pair.expected });
            defer testing.allocator.free(source);
            try addSource(db, 1, source);
            const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
            const target = scope.resolve("target").?;
            try testing.expect((try db.get(queries.CompileFunction, .{ .item = target })).* == null);
            const diagnostics = try db.transitiveAccumulatorValues(queries.CompileFunction, .{ .item = target }, structures.Diagnostic, testing.allocator);
            defer freeDiagnostics(diagnostics);
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(boundary.kind, std.meta.activeTag(diagnostics[0].kind));
        }
    }
}

test "variant widening annotations retain equal results and recover after invalid edits" {
    const boundaries = [_]struct { source: []const u8, kind: DiagnosticKind }{
        .{ .source = "static target = func(value: int | none) int | none | unit\n  const widened: {s} = value\n  return widened\ntarget(none)", .kind = .local_type_mismatch },
        .{ .source = "static target = func(value: int | none) {s} -> return value\ntarget(none)", .kind = .return_type_mismatch },
    };
    inline for (boundaries) |boundary| {
        const db = try testDatabase(2);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator, boundary.source, .{"int | none | unit"});
        defer testing.allocator.free(source);
        try addSource(db, 1, source);
        const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
        const target = scope.resolve("target").?;
        const instance: structures.InstanceId = .{ .item = target };
        const body = try db.get(queries.AnalyzeFunctionBody, target);
        try testing.expect(body.* != null);
        const compiled = try db.get(queries.CompileFunction, instance);
        try testing.expect(compiled.* != null);
        const executable = try db.get(queries.BuildExecutable, 1);
        try testing.expect(executable.* != null);

        const reordered = try std.fmt.allocPrint(testing.allocator, boundary.source, .{"unit | none | int"});
        defer testing.allocator.free(reordered);
        try setSource(db, 1, reordered);
        try testing.expectEqual(body, try db.get(queries.AnalyzeFunctionBody, target));
        try testing.expectEqual(compiled, try db.get(queries.CompileFunction, instance));
        try testing.expectEqual(executable, try db.get(queries.BuildExecutable, 1));

        const invalid = try std.fmt.allocPrint(testing.allocator, boundary.source, .{"int | unit"});
        defer testing.allocator.free(invalid);
        try setSource(db, 1, invalid);
        try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(boundary.kind, std.meta.activeTag(diagnostics[0].kind));

        try setSource(db, 1, source);
        try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
        const recovered = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(recovered);
        try testing.expectEqual(@as(usize, 0), recovered.len);
    }
}

test "variant branch joins inject members and preserve the selected tag" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static choose = func() int | none
        \\  return if 7 > 6 -> none else 7
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("choose").?)).*.?;
    try testing.expectEqual(@as(usize, 2), body.branch_arguments.len);
    try testing.expect(body.branch_arguments[0].coerce_to != null);
    try testing.expect(body.branch_arguments[1].coerce_to != null);
    try expectCompiledVariantWord(db, 1, "choose", &.{"choose"}, 0, 1);
}

test "variant branch joins form structural unions and preserve selected values" {
    const cases = [_]struct { left_type: []const u8, right_type: []const u8, right_value: []const u8, members: []const structures.TypeId, right_tag: u8 }{
        .{ .left_type = "int | none", .right_type = "int | unit", .right_value = "42", .members = &.{ .int, .unit, .none }, .right_tag = 0 },
        .{ .left_type = "int | none", .right_type = "int | unit | none", .right_value = "42", .members = &.{ .int, .unit, .none }, .right_tag = 0 },
        .{ .left_type = "int | none", .right_type = "none | int", .right_value = "42", .members = &.{ .int, .none }, .right_tag = 0 },
        .{ .left_type = "int | none", .right_type = "int", .right_value = "42", .members = &.{ .int, .none }, .right_tag = 0 },
        .{ .left_type = "int | none", .right_type = "unit", .right_value = "noop()", .members = &.{ .int, .unit, .none }, .right_tag = 1 },
        .{ .left_type = "unit | none", .right_type = "int", .right_value = "42", .members = &.{ .int, .unit, .none }, .right_tag = 0 },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |reverse| {
            for ([_]bool{ false, true }) |select_left| {
                const db = try testDatabase(2);
                defer db.deinit();
                const source = try std.fmt.allocPrint(testing.allocator,
                    \\static noop = func() unit -> return
                    \\static choose = func() int | unit | none
                    \\  const left: {s} = none
                    \\  const right: {s} = {s}
                    \\  return if 1 {s} 2 -> {s} else {s}
                    \\choose()
                , .{ case.left_type, case.right_type, case.right_value, if (select_left != reverse) "<" else ">", if (reverse) "right" else "left", if (reverse) "left" else "right" });
                defer testing.allocator.free(source);
                try addSource(db, 1, source);
                const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
                const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("choose").?)).*;
                try testing.expect(body != null);
                const joined = body.?.block_argument_types[0];
                const variant = try db.lookupInterned(queries.Types, joined.interned().?);
                try testing.expectEqualSlices(structures.TypeId, case.members, variant.variant.members);
                try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
                try expectCompiledVariantWord(db, 1, "choose", &.{ "choose", "noop" }, 0, if (select_left) 2 else case.right_tag);
                if (!select_left and case.right_tag == 0) try expectCompiledVariantWord(db, 1, "choose", &.{ "choose", "noop" }, 4, 42);
            }
        }
    }
}

test "variant branch joins retain equal results and track changed member sets" {
    const db = try testDatabase(2);
    defer db.deinit();
    const format =
        \\static noop = func() unit -> return unit
        \\static choose = func() int | unit | none
        \\  return if 1 < 2 -> (if 1 < 2 -> none else 42) else {s}
        \\choose()
    ;
    const source = try std.fmt.allocPrint(testing.allocator, format, .{"noop()"});
    defer testing.allocator.free(source);
    try addSource(db, 1, source);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const target = scope.resolve("choose").?;
    const instance: structures.InstanceId = .{ .item = target };
    const body = try db.get(queries.AnalyzeFunctionBody, target);
    try testing.expect(body.* != null);
    const joined = body.*.?.block_argument_types[1];
    try testing.expectEqual(body.*.?.return_type, joined);
    const compiled = try db.get(queries.CompileFunction, instance);
    try testing.expect(compiled.* != null);

    const equivalent = try std.fmt.allocPrint(testing.allocator, format, .{"(noop())"});
    defer testing.allocator.free(equivalent);
    try setSource(db, 1, equivalent);
    try testing.expectEqual(body, try db.get(queries.AnalyzeFunctionBody, target));
    try testing.expectEqual(compiled, try db.get(queries.CompileFunction, instance));

    const changed = try std.fmt.allocPrint(testing.allocator, format, .{"42"});
    defer testing.allocator.free(changed);
    try setSource(db, 1, changed);
    const updated = (try db.get(queries.AnalyzeFunctionBody, target)).*.?;
    const narrower = updated.block_argument_types[1];
    try testing.expect(narrower != joined);
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .none }, (try db.lookupInterned(queries.Types, narrower.interned().?)).variant.members);
    try expectCompiledVariantWord(db, 1, "choose", &.{ "choose", "noop" }, 0, 2);

    try setSource(db, 1, source);
    const restored = (try db.get(queries.AnalyzeFunctionBody, target)).*.?;
    try testing.expectEqual(joined, restored.block_argument_types[1]);
    try expectCompiledVariantWord(db, 1, "choose", &.{ "choose", "noop" }, 0, 2);
}

test "variant branch join analysis cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariantJoinAllocations, .{});
}

fn testVariantJoinAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try addSource(db, 1,
        \\static choose = func() int | unit | none
        \\  const left: int | none = none
        \\  const right: int | unit = 42
        \\  return if 1 < 2 -> left else right
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, scope.resolve("choose").?)).* != null);
}

test "variant local annotations explicitly inject exact members" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int | none
        \\  const value: int | none = none
        \\  return value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try testing.expectEqual(@as(usize, 2), body.instructions.len);
    try testing.expectEqual(body.return_type, body.instructions[1].variant_coerce.target_type);
    try expectCompiledVariantWord(db, 1, "answer", &.{"answer"}, 0, 1);
}

test "bare return injects unit into a containing variant" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static answer = func() int | unit -> return");
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try testing.expectEqual(structures.FunctionBodyAnalysis.Instruction.const_unit, body.instructions[0]);
    try testing.expect(body.blocks[0].terminator.return_value.coerce_to != null);
    try expectCompiledVariantWord(db, 1, "answer", &.{"answer"}, 0, 1);
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
        const function_id = (try db.get(queries.IndexItems, case.file_id)).*.?.ids()[0];
        const signature = (try db.get(queries.FunctionSignature, function_id)).*.?;
        try testing.expectEqual(@as(usize, 0), signature.parameters.len);
        try testing.expectEqual(structures.TypeId.int, signature.return_type);
        try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, function_id)).*.?, case.expected);
    }
}

test "ordinary function spellings retain equivalent semantic and compiled results" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static identity = func(value: int) int -> return value
        \\static noop = func() unit -> return
        \\noop()
        \\identity(7)
    );
    const first_scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const identity_id = first_scope.resolve("identity").?;
    const noop_id = first_scope.resolve("noop").?;
    const identity_signature = try db.get(queries.FunctionSignature, identity_id);
    const identity_body = try db.get(queries.AnalyzeFunctionBody, identity_id);
    const identity_artifact = try db.get(queries.CompileFunction, .{ .item = identity_id });
    const noop_signature = try db.get(queries.FunctionSignature, noop_id);
    const noop_artifact = try db.get(queries.CompileFunction, .{ .item = noop_id });
    const executable = try db.get(queries.BuildExecutable, 1);

    try setSource(db, 1,
        \\func identity(value: int) int -> value
        \\func noop() -> ()
        \\noop()
        \\identity(7)
    );
    const updated_scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expectEqual(identity_id, updated_scope.resolve("identity").?);
    try testing.expectEqual(noop_id, updated_scope.resolve("noop").?);
    try testing.expectEqual(identity_signature, try db.get(queries.FunctionSignature, identity_id));
    try testing.expectEqual(identity_body, try db.get(queries.AnalyzeFunctionBody, identity_id));
    try testing.expectEqual(identity_artifact, try db.get(queries.CompileFunction, .{ .item = identity_id }));
    try testing.expectEqual(noop_signature, try db.get(queries.FunctionSignature, noop_id));
    try testing.expectEqual(noop_artifact, try db.get(queries.CompileFunction, .{ .item = noop_id }));
    try testing.expectEqual(executable, try db.get(queries.BuildExecutable, 1));
}

test "zero-sized values cross direct binding call and return boundaries" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\func pass_unit(value: unit) unit -> value
        \\func pass_none(value: none) none -> value
        \\func widen_unit(value: unit) int | unit | none -> value
        \\func widen_none(value: none) int | unit | none -> value
        \\func unit_word() unit -> unit
        \\func unit_parens() unit -> ()
        \\func choose_unit() int | unit | none
        \\  const saved: unit = pass_unit(())
        \\  return widen_unit(saved)
        \\func choose_none() int | unit | none
        \\  const saved: none = pass_none(none)
        \\  return widen_none(saved)
        \\unit_word()
        \\unit_parens()
        \\choose_unit()
        \\choose_none()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const pass_unit = scope.resolve("pass_unit").?;
    const pass_none = scope.resolve("pass_none").?;
    const unit_signature = (try db.get(queries.FunctionSignature, pass_unit)).*.?;
    const none_signature = (try db.get(queries.FunctionSignature, pass_none)).*.?;
    try expectImmParameters(&.{.unit}, unit_signature.parameters);
    try testing.expectEqual(structures.TypeId.unit, unit_signature.return_type);
    try expectImmParameters(&.{.none}, none_signature.parameters);
    try testing.expectEqual(structures.TypeId.none, none_signature.return_type);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);

    try expectCompiledVariantWord(db, 1, "choose_unit", &.{ "choose_unit", "pass_unit", "widen_unit" }, 0, 1);
    try expectCompiledVariantWord(db, 1, "choose_none", &.{ "choose_none", "pass_none", "widen_none" }, 0, 2);
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
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const leaf_id = scope.resolve("leaf").?;
    const caller_id = scope.resolve("caller").?;

    const leaf_signature = (try db.get(queries.FunctionSignature, leaf_id)).*.?;
    try expectImmParameters(&.{.int}, leaf_signature.parameters);
    try testing.expectEqual(structures.TypeId.unit, leaf_signature.return_type);
    const leaf_body = (try db.get(queries.AnalyzeFunctionBody, leaf_id)).*.?;
    try testing.expectEqualSlices(structures.TypeId, &.{.int}, leaf_body.block_argument_types);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, leaf_body.blocks[0].terminator);

    const caller_body = (try db.get(queries.AnalyzeFunctionBody, caller_id)).*.?;
    try testing.expectEqual(@as(usize, 2), caller_body.instructions.len);
    try testing.expectEqual(@as(i32, 7), caller_body.instructions[0].const_int);
    try testing.expectEqual(leaf_id, caller_body.instructions[1].call.target);
    try testing.expectEqual(structures.TypeId.unit, caller_body.instructions[1].call.return_type);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.return_unit, caller_body.blocks[0].terminator);

    const leaf_artifact = (try db.get(queries.CompileFunction, .{ .item = leaf_id })).*.?;
    try testing.expectEqualSlices(u8, &.{ 0xBA, 1, 0, 0, 0, 0xC3 }, leaf_artifact.code);

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "a local exit shadows the prelude function" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static caller = func(value: int) unit
        \\  const exit = 1
        \\  return exit(value)
        \\caller(42)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const caller_id = scope.resolve("caller").?;
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, caller_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.value_not_callable, diagnostics[0].kind);
}

test "exit validates its one int argument at the typed boundary" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{ .file_id = 1, .source = "exit()", .kind = .call_argument_count_mismatch },
        .{ .file_id = 2, .source = "exit(1, 2)", .kind = .call_argument_count_mismatch },
        .{
            .file_id = 3,
            .source = "static noop = func() unit -> return\nexit(noop())",
            .kind = .call_argument_type_mismatch,
        },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const entry_id = (try db.get(queries.SelectEntry, case.file_id)).*.?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "call type diagnostics point to the argument use rather than its definition" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\const b = none
        \\exit(b)
    ;
    try addSource(db, 1, source);
    const entry = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind{ .call_argument_type_mismatch = .{
        .expected = .int,
        .found = .none,
    } }, diagnostics[0].kind);
    const use = std.mem.lastIndexOf(u8, source, "b").?;
    try testing.expectEqual(structures.SourceSpan{ .start = use, .end = use + 1 }, diagnostics[0].span.?);
}

test "exit callers recompute when a shadowing declaration changes" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static exit = func() int -> return 1\nexit(42)");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    try testing.expect((try db.get(queries.CompileFunction, instance)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);

    try setSource(db, 1, "static exit = func(value: int) unit -> return\nexit(42)");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
    try testing.expect((try db.get(queries.CompileFunction, instance)).* != null);
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "unit values are rejected at int boundaries" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{ .file_id = 1, .source = "static bad = func() int -> return", .kind = .missing_return_value },
        .{ .file_id = 2, .source = "static bad = func() unit -> return 1", .kind = .return_type_mismatch },
        .{ .file_id = 3, .source = "static noop = func() unit\n  return\nstatic bad = func() int -> return noop()", .kind = .return_type_mismatch },
        .{ .file_id = 4, .source = "static noop = func() unit\n  return\nstatic bad = func() int -> return noop() + 1", .kind = .arithmetic_operand_not_int },
        .{ .file_id = 5, .source = "static noop = func() unit\n  return\nstatic take = func(value: int) int -> return value\nstatic bad = func() int -> return take(noop())", .kind = .call_argument_type_mismatch },
        .{ .file_id = 6, .source = "static noop = func() unit\n  return\nstatic bad = func() unit\n  const done: int = noop()\n  return", .kind = .local_type_mismatch },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const scope = (try db.get(queries.BuildModuleScope, case.file_id)).*.?;
        const bad_id = scope.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
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
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const expression_id = scope.resolve("expression").?;
    const body = (try db.get(queries.AnalyzeFunctionBody, expression_id)).*.?;

    try testing.expectEqual(@as(usize, 11), body.instructions.len);
    try testing.expectEqual(@as(i32, 120), body.instructions[0].const_int);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[1].call.target);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[2].divsi.lhs));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(body.instructions[2].divsi.rhs));
    try testing.expectEqual(@as(i32, 2), body.instructions[3].const_int);
    try testing.expectEqual(@as(i32, 3), body.instructions[4].const_int);
    try testing.expectEqual(@as(u32, 3), @intFromEnum(body.instructions[5].addi.lhs));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(body.instructions[5].addi.rhs));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(body.instructions[7].muli.lhs));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(body.instructions[8].subi.lhs));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(body.instructions[8].subi.rhs));
    try testing.expectEqual(@as(u32, 8), @intFromEnum(body.instructions[9].negi));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(body.instructions[10].negi));
    try testing.expectEqual(@as(u32, 10), @intFromEnum(body.blocks[0].terminator.return_value.value));
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "fallible integer if joins branch values through a block argument" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static choose = func(value: int) int
        \\  return if value < 0
        \\    20
        \\  else
        \\    22
        \\static answer = func() int -> return choose(-1) + choose(1)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const choose_id = scope.resolve("choose").?;
    const body = (try db.get(queries.AnalyzeFunctionBody, choose_id)).*.?;

    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .int }, body.block_argument_types);
    try testing.expectEqual(@as(usize, 4), body.blocks.len);
    try testing.expectEqual(@as(usize, 2), body.branch_arguments.len);
    const predicate = body.blocks[0].terminator.predicate_branch;
    try testing.expectEqual(structures.PredicateOperation.lti, predicate.operation);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(predicate.operands.lhs));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(predicate.operands.rhs));
    try testing.expectEqual(@as(u32, 1), body.blocks[3].argument_start);
    try testing.expectEqual(@as(u32, 2), body.blocks[3].argument_end);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(body.blocks[3].terminator.return_value.value));

    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "choose" }, 42);
}

test "fallible function signatures distinguish declarations" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static ordinary = func(value: int) int -> value
        \\static checked = fallible(value: int) int -> value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const ordinary = (try db.get(queries.FunctionSignature, scope.resolve("ordinary").?)).*.?;
    const checked = (try db.get(queries.FunctionSignature, scope.resolve("checked").?)).*.?;

    try testing.expect(!ordinary.is_fallible);
    try testing.expect(checked.is_fallible);
    try testing.expect(!structures.FunctionSignature.eql(ordinary, checked));
}

test "explicit imm parameters use the default callable identity" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\func implicit(value: int) int -> value
        \\func explicit(imm value: int) int -> value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const implicit = (try db.get(queries.FunctionSignature, scope.resolve("implicit").?)).*.?;
    const explicit = (try db.get(queries.FunctionSignature, scope.resolve("explicit").?)).*.?;

    try expectImmParameters(&.{.int}, explicit.parameters);
    try testing.expect(structures.FunctionSignature.eql(implicit, explicit));
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, scope.resolve("explicit").?)).* != null);
}

test "callable identity includes parameter modes" {
    const db = try testDatabase(1);
    defer db.deinit();

    const imm_id = try db.intern(queries.Types, .{ .callable = .{
        .parameters = &.{.{ .mode = .imm, .type_id = .int }},
        .return_type = .unit,
        .is_fallible = false,
    } });
    const mutable_id = try db.intern(queries.Types, .{ .callable = .{
        .parameters = &.{.{ .mode = .mut, .type_id = .int }},
        .return_type = .unit,
        .is_fallible = false,
    } });

    try testing.expect(imm_id != mutable_id);
}

test "callable values bind pass return and execute through indirect calls" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\func increment(value: int) int -> value + 1
        \\func choose() func(int) int -> increment
        \\func apply(callable: func(int) int, value: int) int
        \\  const selected: func(int) int = callable
        \\  return selected(value)
        \\func answer() int
        \\  const selected = choose()
        \\  return apply(selected, 41)
        \\exit(answer())
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const apply = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("apply").?)).*.?;
    try testing.expectEqual(.indirect_call, std.meta.activeTag(apply.instructions[0]));
    const choose = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("choose").?)).*.?;
    try testing.expectEqual(.function_ref, std.meta.activeTag(choose.instructions[0]));
    try testing.expectEqual(.return_value, std.meta.activeTag(choose.blocks[0].terminator));

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "call results can be called directly" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\func increment(value: int) int -> value + 1
        \\func choose() func(int) int -> increment
        \\exit(choose()(41))
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "ordinary callables widen to fallible aliases and calls" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\func identity(value: int) int -> value
        \\static checked: fallible(int) int = identity
        \\if checked(42) -> exit(42) else exit(1)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const checked = try resolvedStaticValue(db, scope.resolve("checked").?);
    const checked_type = (try db.lookupInterned(queries.Types, checked.runtime.type_id.interned().?)).callable;
    try expectImmParameters(&.{.int}, checked_type.parameters);
    try testing.expectEqual(structures.TypeId.int, checked_type.return_type);
    try testing.expect(checked_type.is_fallible);
    const entry = (try db.get(queries.AnalyzeFunctionBody, (try db.get(queries.SelectEntry, 1)).*.?)).*.?;
    try testing.expectEqual(.fallible_indirect_call, std.meta.activeTag(entry.blocks[0].terminator));

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "variant coercions map compatible callable members during typing" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\func identity(value: int) int -> value
        \\func inject() none | fallible(int) int -> identity
        \\func produce() none | func(int) int -> identity
        \\func widen() unit | none | fallible(int) int -> produce()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;

    const inject_id = scope.resolve("inject").?;
    const inject = (try db.get(queries.AnalyzeFunctionBody, inject_id)).*.?;
    const inject_use = inject.blocks[0].terminator.return_value;
    const inject_mapping = inject_use.variant_tag_mapping.?;
    try testing.expectEqual(@as(u32, 1), inject_mapping.end - inject_mapping.start);
    const inject_variant = (try db.lookupInterned(queries.Types, inject.return_type.interned().?)).variant;
    const inject_target = inject_variant.members[inject.variant_coercion_tags[inject_mapping.start]];
    const inject_callable = (try db.lookupInterned(queries.Types, inject_target.interned().?)).callable;
    try testing.expect(inject_callable.is_fallible);
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = inject_id })).* != null);

    const produce_id = scope.resolve("produce").?;
    const produce_signature = (try db.get(queries.FunctionSignature, produce_id)).*.?;
    const source_variant = (try db.lookupInterned(queries.Types, produce_signature.return_type.interned().?)).variant;
    const widen_id = scope.resolve("widen").?;
    const widen = (try db.get(queries.AnalyzeFunctionBody, widen_id)).*.?;
    const widen_use = widen.blocks[0].terminator.return_value;
    const widen_mapping = widen_use.variant_tag_mapping.?;
    try testing.expectEqual(@as(u32, @intCast(source_variant.members.len)), widen_mapping.end - widen_mapping.start);
    const target_variant = (try db.lookupInterned(queries.Types, widen.return_type.interned().?)).variant;
    for (source_variant.members, 0..) |source_member, source_tag| {
        const target_tag = widen.variant_coercion_tags[widen_mapping.start + source_tag];
        const target_member = target_variant.members[target_tag];
        if (source_member == .none) {
            try testing.expectEqual(structures.TypeId.none, target_member);
        } else {
            const source_callable = (try db.lookupInterned(queries.Types, source_member.interned().?)).callable;
            const target_callable = (try db.lookupInterned(queries.Types, target_member.interned().?)).callable;
            try testing.expect(!source_callable.is_fallible);
            try testing.expect(target_callable.is_fallible);
        }
    }
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = widen_id })).* != null);
}

test "variant injection prefers an exact callable member over a fallible widening" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Plain: type = func(int) int
        \\static Checked: type = fallible(int) int
        \\func identity(value: int) int -> value
        \\func inject() Checked | Plain | none -> identity
        \\func answer() int
        \\  const selected = inject()
        \\  return if const operation = selected as Plain -> operation(42) else 1
        \\exit(answer())
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "static callable variant annotations preserve the payload representation" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Plain: type = func(int) int
        \\func identity(value: int) int -> value
        \\static selected: Plain | none = identity
        \\if const operation = selected as Plain -> exit(operation(42)) else exit(1)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "fallible callables do not narrow to ordinary parameters" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible checked(value: int) int -> value
        \\func apply(callable: func(int) int) int -> callable(42)
        \\exit(apply(checked))
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.call_argument_type_mismatch, std.meta.activeTag(diagnostics[0].kind));
}

test "fallible calls preserve success payloads across propagation" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible positive(value: int) int
        \\  value > 0
        \\  return value
        \\fallible sum() int -> positive(20) + positive(22)
        \\fallible answer() unit
        \\  sum() == 42
        \\if answer() -> exit(42) else exit(1)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "fallible call failure propagates without later effects" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible negative(value: int) int
        \\  value < 0
        \\  return value
        \\fallible caller() int
        \\  const value = negative(1)
        \\  exit(99)
        \\  return value
        \\if caller() -> exit(1) else exit(42)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "fallible calls preserve zero-sized and memory-returned payloads" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible produce(value: int) int | none
        \\  value > 0
        \\  return value
        \\fallible inspect() unit
        \\  const produced = produce(7)
        \\  produced is int
        \\  return
        \\fallible forward() unit
        \\  inspect()
        \\if forward() -> exit(42) else exit(1)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "unhandled fallible calls are rejected from ordinary functions" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible checked() int -> 42
        \\static bad = func() int -> checked()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const bad = scope.resolve("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.fallible_expression_outside_fallible_function, std.meta.activeTag(diagnostics[0].kind));
}

test "fallibility edits invalidate signatures and callers" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\fallible target() int -> 42
        \\fallible caller() int -> target()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const target = scope.resolve("target").?;
    const caller = scope.resolve("caller").?;
    const fallible_signature = try db.get(queries.FunctionSignature, target);
    const fallible_body = try db.get(queries.AnalyzeFunctionBody, caller);
    try testing.expect(fallible_signature.*.?.is_fallible);
    try testing.expectEqual(.fallible_call, std.meta.activeTag(fallible_body.*.?.blocks[0].terminator));

    try setSource(db, 1,
        \\func target() int -> 42
        \\fallible caller() int -> target()
    );
    const ordinary_signature = try db.get(queries.FunctionSignature, target);
    const ordinary_body = try db.get(queries.AnalyzeFunctionBody, caller);
    try testing.expect(!ordinary_signature.*.?.is_fallible);
    try testing.expect(fallible_signature != ordinary_signature);
    try testing.expect(fallible_body != ordinary_body);
    try testing.expectEqual(.return_value, std.meta.activeTag(ordinary_body.*.?.blocks[0].terminator));

    try setSource(db, 1,
        \\fallible target() int -> 42
        \\func caller() int -> target()
    );
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, caller)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, caller, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.fallible_expression_outside_fallible_function, std.meta.activeTag(diagnostics[0].kind));
}

test "every integer comparison selects the fallible success edge" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  const a = if 1 < 2 -> 1 else 0
        \\  const b = if 2 > 1 -> 2 else 0
        \\  const c = if 1 <= 1 -> 4 else 0
        \\  const d = if 1 >= 1 -> 8 else 0
        \\  const e = if 1 == 1 -> 16 else 0
        \\  const f = if 1 <> 2 -> 11 else 0
        \\  return a + b + c + d + e + f
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "bool equality selects fallible edges without truthiness" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\func answer() int
        \\  const equal = if true == true -> 20 else 0
        \\  const unequal = if true <> false -> 22 else 0
        \\  return equal + unequal
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    const cases = [_]struct { file_id: structures.FileId, source: []const u8, kind: DiagnosticKind }{
        .{ .file_id = 2, .source = "func bad() int -> if true < false -> 1 else 0", .kind = .comparison_operand_not_int },
        .{ .file_id = 3, .source = "func bad() int -> if true == 1 -> 1 else 0", .kind = .equality_operand_type_mismatch },
        .{ .file_id = 4, .source = "func bad() int -> if none == none -> 1 else 0", .kind = .equality_operand_not_supported },
        .{ .file_id = 5, .source = "func bad() int -> if true -> 1 else 0", .kind = .if_condition_not_fallible },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "unit-success logical conditions compose and preserve precedence" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  const a = if 1 < 2 and 2 < 3 -> 1 else 0
        \\  const b = if 2 < 1 and 2 < 3 -> 0 else 2
        \\  const c = if 1 < 2 or 2 < 1 -> 4 else 0
        \\  const d = if 2 < 1 or 1 < 2 -> 8 else 0
        \\  const e = if not 2 < 1 -> 16 else 0
        \\  const f = if not 1 < 2 -> 0 else 11
        \\  return if 2 < 3 and 5 > 4 or 1 < 5 and not 9 < 2 -> a + b + c + d + e + f else 0
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "and and or evaluate their right operand only on the required edge" {
    const cases = [_]struct { body: []const u8, expected: u8 }{
        .{ .body = "if 2 < 1 and stop(61) < 0 -> exit(1) else exit(42)", .expected = 42 },
        .{ .body = "if 1 < 2 or stop(62) < 0 -> exit(42) else exit(1)", .expected = 42 },
        .{ .body = "if 1 < 2 and stop(63) < 0 -> exit(1) else exit(2)", .expected = 63 },
        .{ .body = "if 2 < 1 or stop(64) < 0 -> exit(1) else exit(2)", .expected = 64 },
    };
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for (cases) |case| {
        const db = try testDatabase(1);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator,
            \\static stop = func(code: int) int
            \\  exit(code)
            \\  return 0
            \\{s}
        , .{case.body});
        defer testing.allocator.free(source);
        try addSource(db, 1, source);
        const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "short-circuit condition edges preserve mutable local state" {
    const cases = [_]struct { condition: []const u8, expected: u8 }{
        .{ .condition = "1 < 2 or (if 1 < 2 -> value = 1 else value = 2) < 3", .expected = 5 },
        .{ .condition = "2 < 1 or (if 1 < 2 -> value = 1 else value = 2) < 3", .expected = 1 },
        .{ .condition = "2 < 1 and (if 1 < 2 -> value = 1 else value = 2) < 3", .expected = 5 },
        .{ .condition = "1 < 2 and (if 1 < 2 -> value = 1 else value = 2) < 3", .expected = 1 },
    };
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for (cases) |case| {
        const db = try testDatabase(1);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator,
            \\var value = 5
            \\if {s} -> unit else unit
            \\exit(value)
        , .{case.condition});
        defer testing.allocator.free(source);
        try addSource(db, 1, source);
        const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "logical condition edits retain equal results and recover diagnostics" {
    const db = try testDatabase(1);
    defer db.deinit();

    const original = "static choose = func() int -> return if 1 < 2 or 2 < 1 -> 42 else 24";
    try addSource(db, 1, original);
    const item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("choose").?;
    const instance: structures.InstanceId = .{ .item = item };
    const body = try db.get(queries.AnalyzeFunctionBody, item);
    const artifact = try db.get(queries.CompileFunction, instance);

    try setSource(db, 1, "static choose = func() int -> return if (1 < 2) or (2 < 1) -> 42 else 24");
    try testing.expectEqual(body, try db.get(queries.AnalyzeFunctionBody, item));
    try testing.expectEqual(artifact, try db.get(queries.CompileFunction, instance));

    try setSource(db, 1, "static choose = func() int -> return if 1 < 2 and 2 < 1 -> 42 else 24");
    try expectCompiledFunctionResult(db, 1, "choose", &.{"choose"}, 24);

    try setSource(db, 1, "static choose = func() int -> return if 1 < 2 and 2 -> 42 else 24");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, item)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, item, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.if_condition_not_fallible, std.meta.activeTag(diagnostics[0].kind));

    try setSource(db, 1, original);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, item)).* != null);
    const recovered = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, item, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(recovered);
    try testing.expectEqual(@as(usize, 0), recovered.len);
}

test "fallible if condition binds its successful result" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\fallible give() int -> 42
        \\func answer() int -> if const result = give() -> result else 0
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "give" }, 42);
}

test "if validates conditions and expected result types" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct { file_id: structures.FileId, source: []const u8, kind: DiagnosticKind }{
        .{
            .file_id = 1,
            .source = "static bad = func() int -> return if true -> 1 else 2",
            .kind = .if_condition_not_fallible,
        },
        .{
            .file_id = 2,
            .source = "static noop = func() unit -> return\nstatic bad = func() int -> return if noop() < 1 -> 1 else 2",
            .kind = .comparison_operand_not_int,
        },
        .{
            .file_id = 3,
            .source = "static bad = func() int\n  const left: int | none = 1\n  const right: int | unit = 1\n  return if 1 == 1 -> left else right",
            .kind = .return_type_mismatch,
        },
        .{
            .file_id = 4,
            .source = "func give() int -> 42\nfunc bad() int -> if const result = give() -> result else 0",
            .kind = .if_condition_not_fallible,
        },
        .{
            .file_id = 5,
            .source = "fallible give() int -> 42\nfunc bad() int -> if const result: byte = give() -> result else 0",
            .kind = .local_type_mismatch,
        },
        .{
            .file_id = 6,
            .source = "fallible give() int -> 42\nfunc bad() int -> if const result = give() -> 1 else result",
            .kind = .unknown_value,
        },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const bad_id = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "if conditions separate unimplemented and non-fallible forms" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct { file_id: structures.FileId, source: []const u8, marker: []const u8, kind: structures.Diagnostic.Kind }{
        .{ .file_id = 3, .source = "static bad = func(v: int) int -> return if v? -> 1 else 2", .marker = "?", .kind = .fallible_condition_not_supported },
        .{ .file_id = 4, .source = "static bad = func(v: int) int -> return if v < 1 and v -> 1 else 2", .marker = "v", .kind = .if_condition_not_fallible },
        .{ .file_id = 5, .source = "static bad = func(v: int) int -> return if not v -> 1 else 2", .marker = "v", .kind = .if_condition_not_fallible },
        .{ .file_id = 7, .source = "static bad = func(v: int) int -> return if const x = v? -> x else 2", .marker = "?", .kind = .fallible_condition_not_supported },
        .{ .file_id = 8, .source = "static bad = func(v: int) int -> return if const x = v -> x else 2", .marker = "v", .kind = .if_condition_not_fallible },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const bad_id = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, diagnostics[0].kind);
        const marker_start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try testing.expectEqual(structures.SourceSpan{ .start = marker_start, .end = marker_start + case.marker.len }, diagnostics[0].span.?);
    }
}

test "variant inspection tests active members and permits partially overlapping selectors" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static classify = func(value: int | none) int
        \\  const exact = if value is int -> 20 else 10
        \\  const overlap = if value is int | unit -> 2 else 1
        \\  const disjoint = if value is unit -> 100 else 0
        \\  const composed = if value is int and not value is none -> 4 else 0
        \\  return exact + overlap + disjoint + composed
        \\static answer = func() int -> return classify(1) + classify(none)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "classify" }, 37);
}

test "variant extraction binds the narrowed value only in the success branch" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static extract = func(value: int | none) int
        \\  return if const number = value as int -> number else 0
        \\static answer = func() int -> return extract(42) + extract(none)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "extract" }, 42);
}

test "variant extraction annotations widen successful payloads" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static extract = func(value: int | none) int
        \\  return if const widened: int | unit = value as int
        \\    if const number = widened as int -> number else 1
        \\  else
        \\    0
        \\static answer = func() int -> return extract(42) + extract(none)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "extract" }, 42);
}

test "variant extraction remaps subset tags and bare as discards its payload" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static select = func(value: int | unit | none) int
        \\  return if const narrowed = value as int | none
        \\    if const number = narrowed as int -> number else 2
        \\  else
        \\    0
        \\static accepts_int = func(value: int | none) int -> return if value as int -> 1 else 0
        \\static impossible = func(value: int | none) int -> return if const no: int = value as unit -> no else 42
        \\static answer = func() int -> return select(39) + select(none) + select(unit) + accepts_int(1) + impossible(1)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "select", "accepts_int", "impossible" }, 84);
}

test "variant inspection enforces operand and condition binding rules" {
    const db = try testDatabase(7);
    defer db.deinit();

    const cases = [_]struct { file_id: structures.FileId, source: []const u8, kind: DiagnosticKind }{
        .{
            .file_id = 1,
            .source = "static bad = func(value: int) int -> return if value is int -> 1 else 0",
            .kind = .variant_inspection_operand_not_variant,
        },
        .{
            .file_id = 2,
            .source = "static bad = func(value: int) int -> return if value as int -> 1 else 0",
            .kind = .variant_inspection_operand_not_variant,
        },
        .{
            .file_id = 3,
            .source = "static bad = func(value: int | none) int -> return if var number = value as int -> number else 0",
            .kind = .condition_binding_must_be_immutable,
        },
        .{
            .file_id = 4,
            .source = "static bad = func(value: int | none) int\n  const result = if const number = value as int -> number else 0\n  return number + result",
            .kind = .unknown_value,
        },
        .{
            .file_id = 5,
            .source = "static bad = func(value: int | none) int -> return if value is int -> value else 0",
            .kind = .return_type_mismatch,
        },
        .{
            .file_id = 6,
            .source = "static bad = func(value: int | none) int -> return if const number: none = value as int -> 1 else 0",
            .kind = .local_type_mismatch,
        },
        .{
            .file_id = 7,
            .source = "static bad = func(value: int | none) int\n  const number = 0\n  return if const number = value as int -> number else 0",
            .kind = .duplicate_local_binding,
        },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const bad_id = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "variant inspection edits retain equal artifacts and recover diagnostics" {
    const db = try testDatabase(1);
    defer db.deinit();

    const original = "static inspect = func(value: int | none) int -> return if const selected = value as int -> 42 else 24";
    try addSource(db, 1, original);
    const item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("inspect").?;
    const instance: structures.InstanceId = .{ .item = item };
    const body = try db.get(queries.AnalyzeFunctionBody, item);
    const artifact = try db.get(queries.CompileFunction, instance);

    try setSource(db, 1, "static inspect = func(value: int | none) int -> return if const selected = (value) as int -> 42 else 24");
    try testing.expectEqual(body, try db.get(queries.AnalyzeFunctionBody, item));
    try testing.expectEqual(artifact, try db.get(queries.CompileFunction, instance));

    try setSource(db, 1, "static inspect = func(value: int | none) int -> return if const selected = value as none -> 42 else 24");
    try testing.expect(body != try db.get(queries.AnalyzeFunctionBody, item));
    try testing.expect(artifact != try db.get(queries.CompileFunction, instance));

    try setSource(db, 1, "static inspect = func(value: int) int -> return if value is int -> 42 else 24");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, item)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, item, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.variant_inspection_operand_not_variant, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1, original);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, item)).* != null);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, item, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "variant inspection compilation cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariantInspectionAllocations, .{});
}

fn testVariantInspectionAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try addSource(db, 1,
        \\static select = func(value: int | unit | none) int
        \\  return if const narrowed = value as int | none
        \\    if const number = narrowed as int -> number else 2
        \\  else 0
        \\select(40)
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "unit branch results join without a machine value" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static noop = func() unit -> return
        \\static choose = func(value: int) unit -> return if value == 0 -> noop() else noop()
        \\choose(0)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "no-else if joins its body with implicit unit" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = func() int | unit -> return if 1 < 2 -> 42
        \\static skipped = func() int | unit -> return if 2 < 1 -> 42
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const selected = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("selected").?)).*.?;
    try testing.expectEqual(@as(usize, 1), selected.block_argument_types.len);
    const result_type = selected.block_argument_types[0];
    try testing.expectEqual(selected.return_type, result_type);
    const members = (try db.lookupInterned(queries.Types, result_type.interned().?)).variant.members;
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .unit }, members);

    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 0, 0);
    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 4, 42);
    try expectCompiledVariantWord(db, 1, "skipped", &.{"skipped"}, 0, 1);
}

test "multi-statement branches keep locals lexical and skip unselected effects" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  const selected = if 1 < 2
        \\    const local = 20
        \\    local + 1
        \\  else
        \\    const local = exit(99)
        \\    0
        \\  const other = if 2 < 1
        \\    exit(98)
        \\  else
        \\    const local = 20
        \\    local + 1
        \\  return selected + other
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    try addSource(db, 2,
        \\static bad = func() int
        \\  const value = if 1 < 2
        \\    const hidden = 42
        \\    hidden
        \\  else 0
        \\  return hidden + value
    );
    const bad_id = (try db.get(queries.BuildModuleScope, 2)).*.?.resolve("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_id)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.unknown_value, diagnostics[0].kind);
}

test "top-level conditionals support general scoped statements" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\if 1 < 2
        \\  const code = 40 + 2
        \\  exit(code)
        \\else
        \\  exit(99)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "early returns terminate only their reachable paths" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static choose = func(value: int) int
        \\  if value < 0
        \\    return 20
        \\  const result = 22
        \\  return result
        \\static nested = func(value: int) int
        \\  return if value < 0
        \\    return 20
        \\  else
        \\    22
        \\static answer = func() int -> choose(-1) + nested(1)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "choose", "nested" }, 42);
}

test "return completeness accepts divergence and rejects reachable fallthrough" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static complete = func(value: int) int
        \\  if value < 0 -> return 20 else return 22
        \\static stop = func() never -> exit(42)
        \\static unit_fallthrough = func()
        \\  const ignored = 1 + 2
        \\stop()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const complete = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("complete").?)).*.?;
    try testing.expectEqual(structures.TypeId.int, complete.return_type);
    const stop = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("stop").?)).*.?;
    try testing.expectEqual(structures.TypeId.never, stop.return_type);
    try testing.expectEqual(structures.FunctionBodyAnalysis.Terminator.diverge, stop.blocks[0].terminator);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, scope.resolve("unit_fallthrough").?)).* != null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);

    const incomplete_source =
        \\static incomplete = func(value: int) int
        \\  if value < 0 -> return 1
    ;
    try addSource(db, 2, incomplete_source);
    const incomplete_id = (try db.get(queries.BuildModuleScope, 2)).*.?.resolve("incomplete").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, incomplete_id)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, incomplete_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind{ .missing_return_value = .int }, diagnostics[0].kind);
    const incomplete_name = std.mem.indexOf(u8, incomplete_source, "incomplete").?;
    try testing.expectEqual(structures.SourceSpan{ .start = incomplete_name, .end = incomplete_name + "incomplete".len }, diagnostics[0].span.?);

    try addSource(db, 3,
        \\static incomplete = func() int | unit
        \\  const value = 1
    );
    const variant_id = (try db.get(queries.BuildModuleScope, 3)).*.?.resolve("incomplete").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, variant_id)).* == null);
    const variant_diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, variant_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(variant_diagnostics);
    try testing.expectEqual(@as(usize, 1), variant_diagnostics.len);
    const variant_signature = (try db.get(queries.FunctionSignature, variant_id)).*.?;
    try testing.expectEqual(structures.Diagnostic.Kind{ .missing_return_value = variant_signature.return_type }, variant_diagnostics[0].kind);
}

test "edits that change return reachability update only reachable calls" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static leaf = func() int -> 42
        \\static answer = func(value: int) int
        \\  if value < 0 -> return 1
        \\  return leaf()
        \\answer(1)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const answer_id = scope.resolve("answer").?;
    const leaf_id = scope.resolve("leaf").?;
    const reachable = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(@as(usize, 3), reachable.instances.len);
    try testing.expectEqual(leaf_id, reachable.instances[2].item);

    try setSource(db, 1,
        \\static leaf = func() int -> 42
        \\static answer = func(value: int) int
        \\  if value < 0 -> return 1 else return 2
        \\  return leaf()
        \\answer(1)
    );
    const updated = (try db.get(queries.AnalyzeFunctionBody, answer_id)).*.?;
    try testing.expectEqual(@as(usize, 0), updated.call_arguments.len);
    const updated_reachable = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(@as(usize, 2), updated_reachable.instances.len);
    try testing.expectEqual(answer_id, updated_reachable.instances[1].item);
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
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const add_id = scope.resolve("add").?;
    const twice_id = scope.resolve("twice").?;

    const add_signature = (try db.get(queries.FunctionSignature, add_id)).*.?;
    try expectImmParameters(&.{ .int, .int }, add_signature.parameters);
    const add = (try db.get(queries.AnalyzeFunctionBody, add_id)).*.?;
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .int }, add.block_argument_types);
    try testing.expectEqual(@as(u32, 0), add.blocks[0].argument_start);
    try testing.expectEqual(@as(u32, 2), add.blocks[0].argument_end);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(add.instructions[0].addi.lhs));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(add.instructions[0].addi.rhs));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(add.blocks[0].terminator.return_value.value));

    const twice = (try db.get(queries.AnalyzeFunctionBody, twice_id)).*.?;
    try expectDirectValueUses(&.{ @enumFromInt(0), @enumFromInt(0) }, twice.call_arguments);
    try testing.expectEqual(add_id, twice.instructions[0].call.target);
    try testing.expectEqual(structures.FunctionValueRange{ .start = 0, .end = 2 }, twice.instructions[0].call.arguments);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(twice.blocks[0].terminator.return_value.value));

    const answer = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try expectDirectValueUses(&.{
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
        kind: DiagnosticKind,
    }{
        .{
            .file_id = 1,
            .source = "static target = func(x: int) int -> return x\nstatic caller = func() int -> return target()",
            .function_name = "caller",
            .kind = .call_argument_count_mismatch,
        },
        .{
            .file_id = 2,
            .source = "static target = func(x: int) int -> return x\nstatic caller = func() int -> return target(1, 2)",
            .function_name = "caller",
            .kind = .call_argument_count_mismatch,
        },
        .{
            .file_id = 3,
            .source = "static caller = func(x: int) int\n  const x = 1\n  return x",
            .function_name = "caller",
            .kind = .duplicate_local_binding,
        },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const function_id = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve(case.function_name).?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
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
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const target_id = scope.resolve("target").?;
    const caller_id = scope.resolve("caller").?;
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, caller_id)).* != null);

    try setSource(db, 1,
        \\static target = func(x: int, y: int) int -> return x + y
        \\static caller = func() int -> return target(7)
    );
    try testing.expectEqual(@as(?usize, 2), (try db.get(SignatureParent, target_id)).*);
    try expectImmParameters(&.{ .int, .int }, (try db.get(queries.FunctionSignature, target_id)).*.?.parameters);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, caller_id)).* == null);

    try setSource(db, 1,
        \\static target = func(renamed: int) int -> return renamed
        \\static caller = func() int -> return target(7)
    );
    try testing.expectEqual(@as(?usize, 1), (try db.get(SignatureParent, target_id)).*);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, caller_id)).* != null);

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
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("locals").?)).*.?;

    try testing.expectEqual(@as(usize, 7), body.instructions.len);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[0].call.target);
    try testing.expectEqual(scope.resolve("leaf").?, body.instructions[1].call.target);
    try testing.expectEqual(@as(i32, 2), body.instructions[2].const_int);
    try testing.expectEqual(@as(i32, 1), body.instructions[3].const_int);
    try testing.expectEqual(@as(u32, 2), @intFromEnum(body.instructions[4].addi.lhs));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(body.instructions[4].addi.rhs));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[5].muli.lhs));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(body.instructions[5].muli.rhs));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(body.instructions[6].addi.lhs));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(body.instructions[6].addi.rhs));
    try testing.expectEqual(@as(u32, 6), @intFromEnum(body.blocks[0].terminator.return_value.value));
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
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

test "mutable locals and compound assignments reuse ordinary SSA values" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  var value = 10
        \\  value = 20
        \\  value += 2
        \\  value *= 2
        \\  value -= 2
        \\  value /= 2
        \\  const assigned = value = value
        \\  return assigned + value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try testing.expectEqual(@as(usize, 11), body.instructions.len);
    try testing.expectEqual(@as(u32, 10), @intFromEnum(body.blocks[0].terminator.return_value.value));
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "top-level mutable locals execute assignment right-hand sides once" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static one = func() int -> 1
        \\var status = 41
        \\status += one()
        \\exit(status)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, entry_id)).*.?;
    try testing.expectEqual(@as(usize, 4), body.instructions.len);
    try testing.expectEqual(scope.resolve("one").?, body.instructions[1].call.target);
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "conditional assignments merge mutable outer locals" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = func() int
        \\  var left = 1
        \\  var right = 0
        \\  if 1 < 2
        \\    left = 40
        \\    right = 2
        \\  else
        \\    left = 0
        \\    right = 1
        \\  return left + right
        \\static skipped = func() int
        \\  var value = 40
        \\  if 2 < 1 -> value = exit(1)
        \\  return value + 2
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const selected = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("selected").?)).*.?;
    try testing.expectEqual(@as(usize, 3), selected.blocks[3].argument_end - selected.blocks[3].argument_start);
    try testing.expectEqual(@as(usize, 6), selected.branch_arguments.len);
    try expectCompiledFunctionResult(db, 1, "selected", &.{"selected"}, 42);
    try expectCompiledFunctionResult(db, 1, "skipped", &.{"skipped"}, 42);
}

test "loops carry mutable state through fallthrough and continue backedges" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  var value = 0
        \\  var total = 0
        \\  const result = loop
        \\    value += 1
        \\    if value < 3 -> continue
        \\    if value < 3 -> exit(99)
        \\    total += value
        \\    if value > 5 -> break total
        \\  return result + 24
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("answer").?)).*.?;
    try testing.expect(body.blocks.len >= 6);
    try testing.expect(body.branch_arguments.len > 0);
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "nested loop control targets the nearest loop" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static answer = func() int
        \\  var outer = 0
        \\  var total = 0
        \\  loop
        \\    outer += 1
        \\    var inner = 0
        \\    loop
        \\      inner += 1
        \\      if inner < 2 -> continue
        \\      break
        \\    total += outer
        \\    if outer < 6 -> continue
        \\    break
        \\  return total + 21
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "loop break values join and bare break contributes unit" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = func() int | none
        \\  return loop
        \\    if 1 < 2 -> break 42
        \\    break none
        \\static skipped = func() int | none
        \\  return loop
        \\    if 2 < 1 -> break 42
        \\    break none
        \\static bare = func() int | unit
        \\  return loop
        \\    if 1 < 2 -> break
        \\    break 42
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const selected = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("selected").?)).*.?;
    var found_return = false;
    for (selected.blocks) |block| switch (block.terminator) {
        .return_value => |returned| {
            try testing.expectEqual(selected.return_type, selected.block_argument_types[@intFromEnum(returned.value)]);
            found_return = true;
        },
        else => {},
    };
    try testing.expect(found_return);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, scope.resolve("bare").?)).* != null);
    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 0, 0);
    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 4, 42);
    try expectCompiledVariantWord(db, 1, "skipped", &.{"skipped"}, 0, 1);
    try expectCompiledVariantWord(db, 1, "bare", &.{"bare"}, 0, 1);
}

test "loop control diagnostics and break reachability update callers" {
    const db = try testDatabase(1);
    defer db.deinit();

    const invalid_cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{ .file_id = 1, .source = "static bad = func() -> break", .kind = .break_outside_loop },
        .{ .file_id = 2, .source = "static bad = func() -> continue", .kind = .continue_outside_loop },
    };
    for (invalid_cases) |case| {
        try addSource(db, case.file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, diagnostics[0].kind);
    }

    try addSource(db, 3,
        \\static leaf = func() int -> 42
        \\static answer = func() int
        \\  loop -> continue
        \\  return leaf()
        \\answer()
    );
    const scope = (try db.get(queries.BuildModuleScope, 3)).*.?;
    const answer = scope.resolve("answer").?;
    const leaf = scope.resolve("leaf").?;
    const without_leaf = (try db.get(queries.CollectReachableInstances, 3)).*.?;
    try testing.expectEqual(@as(usize, 2), without_leaf.instances.len);

    try setSource(db, 3,
        \\static leaf = func() int -> 42
        \\static answer = func() int
        \\  loop -> break
        \\  return leaf()
        \\answer()
    );
    const reachable = (try db.get(queries.CollectReachableInstances, 3)).*.?;
    try testing.expectEqual(@as(usize, 3), reachable.instances.len);
    try testing.expectEqual(answer, reachable.instances[1].item);
    try testing.expectEqual(leaf, reachable.instances[2].item);
    try expectCompiledFunctionResult(db, 3, "answer", &.{ "answer", "leaf" }, 42);
}

test "assignment widening preserves a mutable variable's declared variant type" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static selected = func() int | none
        \\  var value: int | none = none
        \\  value = 42
        \\  return value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, scope.resolve("selected").?)).*.?;
    try testing.expectEqual(body.return_type, body.instructions[3].variant_coerce.target_type);
    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 0, 0);
    try expectCompiledVariantWord(db, 1, "selected", &.{"selected"}, 4, 42);
}

test "assignment diagnostics distinguish targets mutability and type" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        marker: []const u8,
        kind: DiagnosticKind,
    }{
        .{ .file_id = 1, .source = "static bad = func() int\n  const value = 1\n  value = 2\n  return value", .marker = "value = 2", .kind = .assignment_to_immutable },
        .{ .file_id = 2, .source = "static bad = func(value: int) int\n  value = 2\n  return value", .marker = "value = 2", .kind = .assignment_to_immutable },
        .{ .file_id = 3, .source = "static bad = func() int\n  missing = 2\n  return 1", .marker = "missing", .kind = .unknown_value },
        .{ .file_id = 4, .source = "static bad = func() int\n  var value = 1\n  value = none\n  return value", .marker = "none", .kind = .assignment_type_mismatch },
        .{ .file_id = 5, .source = "static bad = func() int\n  var value = 1\n  (if 1 < 2 -> value else 2) = 3\n  return value", .marker = "(if", .kind = .assignment_target_not_local },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const function_id = (try db.get(queries.BuildModuleScope, case.file_id)).*.?.resolve("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
        const start = std.mem.indexOf(u8, case.source, case.marker).?;
        try testing.expectEqual(start, diagnostics[0].span.?.start);
    }
}

test "mutable body edits update analysis and recover from immutable assignment" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static answer = func() int\n  var value = 40\n  value += 2\n  return value");
    const answer_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer_id)).* != null);
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);

    try setSource(db, 1, "static answer = func() int\n  var value = 40\n  value += 3\n  return value");
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 43);

    try setSource(db, 1, "static answer = func() int\n  const value = 40\n  value += 2\n  return value");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer_id)).* == null);

    try setSource(db, 1, "static answer = func() int\n  var value = 40\n  value += 2\n  return value");
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
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
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "sum3", "twice" }, 42);
}

test "local binding diagnostics follow lexical scope and declared type" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        file_id: structures.FileId,
        source: []const u8,
        marker: []const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{ .file_id = 1, .source = "static f = func() int\n  const duplicate = 1\n  const duplicate = 2\n  return 1", .marker = "duplicate", .kind = .duplicate_local_binding },
        .{ .file_id = 2, .source = "static f = func() int\n  const x = missing\n  return x", .marker = "missing", .kind = .unknown_value },
        .{ .file_id = 3, .source = "static f = func() int\n  const x: float = 1\n  return x", .marker = "float", .kind = .float_type_not_supported },
        .{ .file_id = 4, .source = "static f = func() int\n  const leaf = 1\n  return leaf()", .marker = "leaf", .kind = .value_not_callable },
    };
    for (cases) |case| {
        try addSource(db, case.file_id, case.source);
        const function_id = (try db.get(queries.IndexItems, case.file_id)).*.?.ids()[0];
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, diagnostics[0].kind);
        const start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + case.marker.len }, diagnostics[0].span.?);
    }
}

test "declarations cannot shadow visible module names" {
    const db = try testDatabase(1);
    defer db.deinit();

    const local_source =
        \\func visible() int -> 1
        \\func bad() int
        \\  const visible = 2
        \\  return visible
    ;
    try addSource(db, 1, local_source);
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const start = std.mem.indexOf(u8, local_source, "const visible").? + "const ".len;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, bad, true, 1, .{
        .start = start,
        .end = start + "visible".len,
    }, .duplicate_local_binding);

    const parameter_source =
        \\func visible() int -> 1
        \\func bad(visible: int) int -> visible
    ;
    try addSource(db, 2, parameter_source);
    const parameter = (try db.get(queries.BuildModuleScope, 2)).*.?.resolve("bad").?;
    try testing.expect((try db.get(queries.FunctionSignature, parameter)).* == null);
    const parameter_start = std.mem.indexOf(u8, parameter_source, "bad(visible").? + "bad(".len;
    try expectSingleQueryDiagnostic(db, queries.FunctionSignature, parameter, true, 2, .{
        .start = parameter_start,
        .end = parameter_start + "visible".len,
    }, .duplicate_parameter);

    const entry_source =
        \\func visible() int -> 1
        \\const visible = 2
    ;
    try addSource(db, 3, entry_source);
    const entry = (try db.get(queries.SelectEntry, 3)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry)).* == null);
    const entry_start = std.mem.lastIndexOf(u8, entry_source, "visible").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, entry, true, 3, .{
        .start = entry_start,
        .end = entry_start + "visible".len,
    }, .duplicate_local_binding);
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
    const user_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("user").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, user_id)).* == null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.AnalyzeFunctionBody, user_id, structures.Diagnostic)).len);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, user_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.float_type_not_supported, diagnostics[0].kind);
}

test "body edits preserve signature consumers and update body analysis" {
    const db = try testDatabase(1);
    defer db.deinit();

    SignatureParent.executions.reset();
    try addSource(db, 1, "static f = func() int\n  const value = 7\n  return value");
    const function_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    try testing.expect((try db.get(SignatureParent, function_id)).* != null);
    try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, function_id)).*.?, 7);

    try setSource(db, 1, "static f = func() int\n  const value = 8\n  return value");
    try testing.expect((try db.get(SignatureParent, function_id)).* != null);
    try SignatureParent.executions.expect(1);
    try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, function_id)).*.?, 8);

    try setSource(db, 1, "static f = func() foo -> return 8");
    try testing.expect((try db.get(queries.FunctionSignature, function_id)).* == null);
}

test "function signature rejects invalid parameter and return types without duplicate body diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static unknown = func() foo -> return 1");
    try addSource(db, 2, "static missing_param = func(x) int -> return 1");
    try addSource(db, 3, "static bad_param = func(x: float) int -> return 1");
    try addSource(db, 4, "static duplicate = func(x: int, x: int) int -> return 1");

    for ([_]structures.FileId{ 1, 2, 3, 4 }) |file_id| {
        const function_id = (try db.get(queries.IndexItems, file_id)).*.?.ids()[0];
        try testing.expect((try db.get(queries.FunctionSignature, function_id)).* == null);
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const direct = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic);
        try testing.expectEqual(@as(usize, 0), direct.len);
        const transitive = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(transitive);
        try testing.expectEqual(@as(usize, 1), transitive.len);
    }
}

test "function signatures retain mutable borrow parameter modes" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1, "func update(mut value: int) int -> value");

    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("update").?;
    const signature = (try db.get(queries.FunctionSignature, function_id)).*.?;
    try testing.expectEqual(@as(usize, 1), signature.parameters.len);
    try testing.expectEqual(structures.ParameterMode.mut, signature.parameters[0].mode);
    try testing.expectEqual(structures.TypeId.int, signature.parameters[0].type_id);
}

test "mutable borrow parameters publish their final value" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func increment(mut value: int) int
        \\  value += 1
        \\  return value
    );

    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("increment").?;
    const body = (try db.get(queries.AnalyzeFunctionBody, function_id)).*.?;
    var write_count: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .mut_parameter_write) write_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), write_count);
}

test "mutable borrow calls update caller places" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func increment(mut value: int)
        \\  value += 1
        \\func answer() int
        \\  var value = 40
        \\  var pair = Pair{left = 1, right = 1}
        \\  increment(value)
        \\  increment(pair.right)
        \\  return value + pair.left + pair.right - 2
    );

    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "increment" }, 42);
}

test "mutable borrows forward through indirect calls and disjoint fields" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func increment(mut value: int)
        \\  value += 1
        \\func forward(mut value: int)
        \\  const selected = increment
        \\  selected(value)
        \\func update_pair(mut left: int, mut right: int)
        \\  left += 1
        \\  right += 2
        \\func update_whole(mut pair: Pair)
        \\  pair.left += 1
        \\  pair.right += 1
        \\func answer() int
        \\  var value = 39
        \\  var pair = Pair{left = 0, right = 0}
        \\  forward(value)
        \\  update_pair(pair.left, pair.right)
        \\  update_whole(pair)
        \\  return value + pair.left
    );

    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "forward", "increment", "update_pair", "update_whole" }, 42);
}

test "fallible mutable borrows update success and failure paths" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\fallible change(mut value: int, should_succeed: int) unit
        \\  value += 1
        \\  should_succeed > 0
        \\func answer() int
        \\  var succeeded = 20
        \\  if change(succeeded, 1) -> succeeded += 0 else return 0
        \\  var failed = 20
        \\  if change(failed, 0) -> return 0
        \\  return succeeded + failed
    );

    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "change" }, 42);
}

test "mutable borrow copy-back follows memory return storage" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Pair = struct
        \\  left: int
        \\  right: int
        \\func update(mut value: int) Pair
        \\  value += 1
        \\  return Pair{left = 1, right = 1}
        \\func answer() int
        \\  var value = 39
        \\  const pair = update(value)
        \\  return value + pair.left + pair.right
    );

    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "update" }, 42);
}

test "mutable borrow arguments require non-overlapping mutable places" {
    const cases = [_]struct {
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{
            .source = "func update(mut value: int) -> value += 1\nfunc bad()\n  const value = 1\n  update(value)",
            .kind = .mutable_argument_requires_mutable_place,
        },
        .{
            .source = "func update(mut value: int) -> value += 1\nfunc bad() -> update(1)",
            .kind = .mutable_argument_requires_place,
        },
        .{
            .source = "func update(mut changed: int, imm observed: int) -> changed += observed\nfunc bad()\n  var value = 1\n  update(value, value)",
            .kind = .overlapping_mutable_arguments,
        },
        .{
            .source = "static Pair = struct\n  left: int\n  right: int\nfunc update(mut pair: Pair, mut left: int) -> left += pair.right\nfunc bad()\n  var pair = Pair{left = 1, right = 2}\n  update(pair, pair.left)",
            .kind = .overlapping_mutable_arguments,
        },
        .{
            .source = "func bad(mut value: int) int -> value^",
            .kind = .ownership_transfer_requires_owned_place,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "mutable borrow mode edits update callers incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func update(mut value: int)
        \\  value += 1
        \\func answer() int
        \\  var value = 41
        \\  update(value)
        \\  return value
    );

    const answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    const mut_body = try db.get(queries.AnalyzeFunctionBody, answer);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "update" }, 42);

    try setSource(db, 1,
        \\func update(imm value: int) -> return
        \\func answer() int
        \\  var value = 41
        \\  update(value)
        \\  return value
    );
    const imm_body = try db.get(queries.AnalyzeFunctionBody, answer);
    try testing.expect(mut_body != imm_body);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "update" }, 41);
}

test "function body analysis rejects unsupported expressions and literals" {
    const db = try testDatabase(2);
    defer db.deinit();
    try addSource(db, 1, "static unsupported = func() int -> return sizeof(int)");
    try addSource(db, 2, "static bare_return = func() int -> return");
    try addSource(db, 4, "static float = func() int -> return 1.5");
    try addSource(db, 5, "static overflow = func() int -> return 2147483648");

    for ([_]structures.FileId{ 1, 2, 4, 5 }) |file_id| {
        const function_id = (try db.get(queries.IndexItems, file_id)).*.?.ids()[0];
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        if (file_id == 4) try testing.expectEqual(structures.Diagnostic.Kind.float_literal_not_supported, diagnostics[0].kind);
        if (file_id == 5) try testing.expectEqual(structures.Diagnostic.Kind.integer_literal_out_of_range, diagnostics[0].kind);
    }
}

test "unsupported declarations and transfers are rejected at their owning boundary" {
    const cases = [_]struct {
        source: []const u8,
        marker: []const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{
            .source = "func outer() int\n  func inner() int -> 1\n  return 0",
            .marker = "inner",
            .kind = .nested_declaration_not_supported,
        },
        .{
            .source = "func transfer(value: int) int -> value^",
            .marker = "^",
            .kind = .ownership_transfer_requires_owned_place,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const function_id = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolve(if (file_id == 1) "outer" else "transfer").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const start = std.mem.indexOf(u8, case.source, case.marker).?;
        try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function_id, true, file_id, .{
            .start = start,
            .end = start + case.marker.len,
        }, case.kind);
    }
}

test "ownership transfer invalidates const and mutable local roots" {
    const cases = [_][]const u8{
        "static Box = struct\n  value: int\nfunc bad() int\n  const box = Box{value = 42}\n  const moved = box^\n  return box.value",
        "static Box = struct\n  value: int\nfunc bad() int\n  var box = Box{value = 42}\n  const moved = box^\n  return box.value",
    };

    for (cases, 1..) |source, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, source);
        const function_id = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const start = std.mem.lastIndexOf(u8, source, "box.value").?;
        try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function_id, true, file_id, .{
            .start = start,
            .end = start + "box".len,
        }, .use_after_transfer);
    }
}

test "whole assignment restores a transferred mutable root" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func answer() int
        \\  var box = Box{value = 20}
        \\  const moved = box^
        \\  box = Box{value = moved.value + 22}
        \\  return box.value
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "owning destinations require copy or explicit transfer" {
    const cases = [_][]const u8{
        "static Box = struct\n  value: int\nfunc bad() int\n  const box = Box{value = 42}\n  const copied = box\n  return copied.value",
        "static Box = struct\n  value: int\nfunc bad() Box\n  const box = Box{value = 42}\n  return box",
    };

    for (cases, 1..) |source, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, source);
        const function_id = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "ownership availability joins across branches" {
    const db = try testDatabase(1);
    defer db.deinit();
    const source =
        \\static Box = struct
        \\  value: int
        \\func bad(flag: int) int
        \\  const box = Box{value = 42}
        \\  if flag < 1
        \\    const moved = box^
        \\  return box.value
    ;
    try addSource(db, 1, source);
    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
    const start = std.mem.lastIndexOf(u8, source, "box.value").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function_id, true, 1, .{
        .start = start,
        .end = start + "box".len,
    }, .possibly_transferred);
}

test "ownership transfer must be restored before a loop backedge" {
    const db = try testDatabase(1);
    defer db.deinit();
    const source =
        \\static Box = struct
        \\  value: int
        \\func bad()
        \\  var box = Box{value = 42}
        \\  loop
        \\    const moved = box^
        \\    continue
    ;
    try addSource(db, 1, source);
    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
    const start = std.mem.indexOf(u8, source, "continue").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function_id, true, 1, .{
        .start = start,
        .end = start + "continue".len,
    }, .transferred_value_not_restored_before_loop_backedge);
}

test "imm arguments borrow non-copyable values and reject transfers" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func read_box(box: Box) int -> box.value
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return read_box(box)
        \\func bad() int
        \\  const box = Box{value = 42}
        \\  return read_box(box^)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "read_box" }, 42);

    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.ownership_transfer_requires_owning_context, std.meta.activeTag(diagnostics[0].kind));
}

test "explicit transfers satisfy return and assignment ownership" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func make() Box
        \\  const box = Box{value = 20}
        \\  return box^
        \\func answer() int
        \\  var target = Box{value = 0}
        \\  const source = make()
        \\  target = source^
        \\  return target.value + 22
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "make" }, 42);
}

test "restored ownership remains available through branches and loop backedges" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func branch(flag: int) int
        \\  var box = Box{value = 42}
        \\  if flag < 1
        \\    const moved = box^
        \\    box = Box{value = moved.value}
        \\  return box.value
        \\func answer() int
        \\  var box = Box{value = 40}
        \\  var count = 0
        \\  const result = loop
        \\    const moved = box^
        \\    box = Box{value = moved.value + 1}
        \\    count += 1
        \\    if count < 2 -> continue
        \\    break box.value
        \\  return result
    );
    const branch = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("branch").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, branch)).* != null);
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
}

test "ownership diagnostics recover incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();
    const invalid =
        \\static Box = struct
        \\  value: int
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  const moved = box^
        \\  return box.value
    ;
    try addSource(db, 1, invalid);
    var answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);

    try setSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  const moved = box^
        \\  return moved.value
    );
    answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try expectCompiledFunctionResult(db, 1, "answer", &.{"answer"}, 42);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "ownership transfers are rejected in borrowing contexts" {
    const cases = [_][]const u8{
        "func bad() int\n  const value = 20\n  return value^ + 22",
        "static Box = struct\n  value: int\nfunc read_box(box: Box) int -> box.value\nfunc bad() int\n  const box = Box{value = 42}\n  return read_box(box^)",
    };

    for (cases, 1..) |source, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, source);
        const function_id = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.ownership_transfer_requires_owning_context, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "discard assignment borrows once without copy or move" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  copy = func(imm self: Box) Box -> self
        \\  move = func(var self: Box) Box -> self^
        \\  value: int
        \\func increment(mut value: int) Box
        \\  value += 1
        \\  return Box{value = value}
        \\func answer() int
        \\  var calls = 0
        \\  const box = Box{value = 41}
        \\  _ = increment(calls)
        \\  _ = box
        \\  return box.value + calls
    );

    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const answer = scope.resolveFunction("answer").?;
    const body = (try db.get(queries.AnalyzeFunctionBody, answer)).*.?;
    const increment = scope.resolveFunction("increment").?;
    var increment_calls: usize = 0;
    var direct_calls: usize = 0;
    for (body.instructions) |instruction| switch (instruction) {
        .call => |call| {
            direct_calls += 1;
            if (call.target == increment) increment_calls += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), increment_calls);
    try testing.expectEqual(@as(usize, 1), direct_calls);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "increment" }, 42);
}

test "discard assignment rejects explicit transfer" {
    const db = try testDatabase(1);
    defer db.deinit();
    const source =
        \\static Box = struct
        \\  value: int
        \\func bad()
        \\  const box = Box{value = 42}
        \\  _ = box^
    ;
    try addSource(db, 1, source);
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const start = std.mem.indexOf(u8, source, "^").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, bad, true, 1, .{
        .start = start,
        .end = start + 1,
    }, .ownership_transfer_requires_owning_context);
}

test "trivial copy keeps distinct ownership generations for one SSA value" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Resource
        \\  copy = trivial
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
        \\func answer() int
        \\  const source = Resource{value = 42}
        \\  const copied = source
        \\  return copied.value + source.value - 42
        \\exit(answer())
    );

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "mutable copy-back preserves its ownership generation" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Resource
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
        \\func increment(mut resource: Resource)
        \\  resource.value += 1
        \\func answer() int
        \\  var resource = Resource{value = 41}
        \\  increment(resource)
        \\  return resource.value
        \\exit(answer())
    );

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "conditional and loop joins reconcile ownership generations" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Resource
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
        \\func branch(flag: int) int
        \\  var resource = Resource{value = 1}
        \\  if flag < 1
        \\    resource = Resource{value = 2}
        \\  return resource.value
        \\func looped() int
        \\  var resource = Resource{value = 40}
        \\  var count = 0
        \\  loop
        \\    const moved = resource^
        \\    resource = Resource{value = moved.value + 1}
        \\    count += 1
        \\    if count < 2 -> continue
        \\    break
        \\  return resource.value
        \\func answer() int -> branch(0) + branch(1) + looped() - 3
        \\exit(answer())
    );

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "fallible owned results originate only on success edges" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Resource
        \\  drop = func(deinit self: Resource) -> return
        \\  value: int
        \\fallible make(value: int) Resource
        \\  value > 0
        \\  return Resource{value = value}
        \\fallible answer() int
        \\  const resource = make(42)
        \\  return resource.value
        \\if answer() -> exit(42) else exit(1)
    );

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "underscore remains ordinary outside discard assignment statements" {
    const cases = [_][]const u8{
        "func bad()\n  _ += 1",
        "func bad() int\n  const value = _ = 1\n  return value",
    };
    for (cases, 1..) |source, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const start = std.mem.indexOf(u8, source, "_").?;
        try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, bad, true, file_id, .{
            .start = start,
            .end = start + 1,
        }, .unknown_value);
    }
}

test "field assignment cannot rebuild from a root transferred by its right hand side" {
    const db = try testDatabase(1);
    defer db.deinit();
    const source =
        \\static Box = struct
        \\  value: int
        \\func bad() int
        \\  var box = Box{value = 42}
        \\  box.value = box^
        \\  return box.value
    ;
    try addSource(db, 1, source);
    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.use_after_transfer, std.meta.activeTag(diagnostics[0].kind));
}

test "condition bindings require copying the extracted value" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func bad(value: Box | none) int
        \\  if const box = value as Box -> return box.value
        \\  return 0
    );
    const function_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
}

test "conditional ownership checks only place-backed result paths" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func valid(flag: int)
        \\  const scalar = 42
        \\  const box = Box{value = 42}
        \\  const selected = if flag < 1 -> scalar else box^
        \\func bad(flag: int)
        \\  const box = Box{value = 42}
        \\  const selected = if flag < 1 -> box else Box{value = 0}
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, scope.resolveFunction("valid").?)).* != null);
    const bad = scope.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
}

test "var parameters own mutable values" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func increment(var box: Box) Box
        \\  box.value += 1
        \\  return box^
        \\func answer() int
        \\  const source = Box{value = 41}
        \\  const result = increment(source^)
        \\  return result.value
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const signature = (try db.get(queries.FunctionSignature, scope.resolveFunction("increment").?)).*.?;
    try testing.expectEqual(structures.ParameterMode.@"var", signature.parameters[0].mode);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "increment" }, 42);
}

test "interleaved var parameters precede body locals" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func combine(imm first: int, var left: Box, imm second: int, var right: Box) int
        \\  const moved = left^
        \\  left = Box{value = moved.value + first}
        \\  var result = left.value + right.value
        \\  result += second
        \\  return result
        \\func answer() int -> combine(1, Box{value = 10}, 2, Box{value = 29})
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "combine" }, 42);
}

test "var parameter availability flows through branches and loops" {
    const cases = [_]struct {
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{
            .source = "static Box = struct\n  value: int\nfunc bad(imm flag: int, var box: Box) int\n  if flag < 1\n    const moved = box^\n  return box.value",
            .kind = .possibly_transferred,
        },
        .{
            .source = "static Box = struct\n  value: int\nfunc bad(var box: Box)\n  loop\n    const moved = box^\n    continue",
            .kind = .transferred_value_not_restored_before_loop_backedge,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "bare var arguments copy without invalidating their source" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func increment(var value: int) int
        \\  value += 1
        \\  return value^
        \\func answer() int
        \\  const source = 41
        \\  const changed = increment(source)
        \\  return changed + source - 41
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "increment" }, 42);
}

test "var arguments require copy or explicit transfer" {
    const cases = [_]struct {
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{
            .source = "static Box = struct\n  value: int\nfunc take(var box: Box) int -> box.value\nfunc bad() int\n  const box = Box{value = 42}\n  return take(box)",
            .kind = .type_not_copyable,
        },
        .{
            .source = "static Box = struct\n  value: int\nfunc take(var box: Box) int -> box.value\nfunc bad() int\n  const box = Box{value = 42}\n  const result = take(box^)\n  return box.value",
            .kind = .use_after_transfer,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "var parameters accept owned temporaries and inferred indirect calls" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func read_box(var box: Box) int -> box.value
        \\func direct() int -> read_box(Box{value = 42})
        \\func answer() int
        \\  const selected = read_box
        \\  const box = Box{value = 42}
        \\  return selected(box^)
    );
    try expectCompiledFunctionResult(db, 1, "direct", &.{ "direct", "read_box" }, 42);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "read_box" }, 42);
}

test "non-copyable var parameters must transfer when returned" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func bad(var box: Box) Box -> box
    );
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
}

test "var parameter mode edits invalidate and recover callers" {
    const db = try testDatabase(1);
    defer db.deinit();
    const imm_source =
        \\static Box = struct
        \\  value: int
        \\func take(imm box: Box) int -> box.value
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return take(box^)
    ;
    try addSource(db, 1, imm_source);
    var answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.ownership_transfer_requires_owning_context, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func take(var box: Box) int -> box.value
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return take(box^)
    );
    answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "take" }, 42);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "struct copy and move properties control ownership uses" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Copyable = struct
        \\  copy = trivial
        \\  value: int
        \\static Immovable = struct
        \\  move = none
        \\  value: int
        \\func take(var value: Copyable) int -> value.value
        \\func take_immovable(var value: Immovable) int -> value.value
        \\func answer() int
        \\  const source = Copyable{value = 42}
        \\  const result = take(source)
        \\  return result + source.value - 42
        \\func bad() int
        \\  const source = Immovable{value = 42}
        \\  const moved = source^
        \\  return moved.value
        \\func bad_copy() int
        \\  const source = Immovable{value = 42}
        \\  return take_immovable(source)
    );
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "take" }, 42);

    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_movable, std.meta.activeTag(diagnostics[0].kind));

    const bad_copy = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad_copy").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad_copy)).* == null);
    const copy_diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad_copy, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(copy_diagnostics);
    try testing.expectEqual(@as(usize, 1), copy_diagnostics.len);
    const details = copy_diagnostics[0].kind.type_not_copyable;
    try testing.expectEqual(diagnostics[0].kind.type_not_movable, details.type_id);
    try testing.expect(!details.is_movable);
}

test "copy diagnostic names a parameterized struct" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Ref(T: type)
        \\  value: T
        \\func bad() unit
        \\  const owner = Ref{value = 42}
        \\  const copied = owner
        \\  _ = copied
    );
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
    const types: queries.TypeInterner(*Database) = .{ .ctx = db };
    try testing.expectEqualStrings("Ref", (try types.structName(diagnostics[0].kind.type_not_copyable.type_id)).?);
}

test "copy diagnostic names the function producing a struct" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static makeBox = func() type
        \\  return struct
        \\    value: int
        \\static Box: type = makeBox()
        \\func bad() unit
        \\  const owner = Box{value = 42}
        \\  const copied = owner
        \\  _ = copied
    );
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
    const types: queries.TypeInterner(*Database) = .{ .ctx = db };
    try testing.expectEqualStrings("makeBox", (try types.structName(diagnostics[0].kind.type_not_copyable.type_id)).?);
}

test "copy diagnostic leaves a non-function-produced struct anonymous" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = comptime -> struct
        \\  value: int
        \\func bad() unit
        \\  const owner = Box{value = 42}
        \\  const copied = owner
        \\  _ = copied
    );
    const bad = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("bad").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
    const types: queries.TypeInterner(*Database) = .{ .ctx = db };
    try testing.expectEqualStrings("anonymous struct", (try types.structName(diagnostics[0].kind.type_not_copyable.type_id)).?);
}

test "struct copy property edits invalidate and recover owning callers" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Box = struct
        \\  value: int
        \\func take(var box: Box) int -> box.value
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return take(box)
    );
    var answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, answer)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expect(diagnostics[0].kind.type_not_copyable.is_movable);
    freeDiagnostics(diagnostics);

    try setSource(db, 1,
        \\static Box = struct
        \\  copy = trivial
        \\  value: int
        \\func take(var box: Box) int -> box.value
        \\func answer() int
        \\  const box = Box{value = 42}
        \\  return take(box)
    );
    answer = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("answer").?;
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "take" }, 42);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, answer, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "explicit-drop struct obligations are checked at every lifetime end" {
    const resource = "static Resource = struct\n  drop = explicit\n  value: int\n";
    const cases = [_][]const u8{
        "func bad()\n  const resource = Resource{value = 42}",
        "func bad()\n  Resource{value = 42}",
        "func bad()\n  _ = Resource{value = 42}",
        "func bad()\n  var resource = Resource{value = 41}\n  resource = Resource{value = 42}",
        "func inspect(imm resource: Resource) int -> resource.value\nfunc bad() int -> inspect(Resource{value = 42})",
        "func bad() int -> Resource{value = 42}.value",
        "func bad(imm flag: int)\n  const resource = Resource{value = 42}\n  if flag < 1\n    const moved = resource^",
        "func bad()\n  loop\n    const resource = Resource{value = 42}\n    break",
        "static Outer = struct\n  resource: Resource\nfunc bad()\n  const outer = Outer{resource = Resource{value = 42}}",
        "static Outer = struct\n  resource: Resource\nfunc bad()\n  var outer = Outer{resource = Resource{value = 41}}\n  outer.resource = Resource{value = 42}",
    };

    for (cases, 1..) |body, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        const source = try std.mem.concat(testing.allocator, u8, &.{ resource, body });
        defer testing.allocator.free(source);
        try addSource(db, file_id, source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.value_requires_explicit_drop, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "unconsumed var parameter diagnostic points to the parameter name" {
    const db = try testDatabase(1);
    defer db.deinit();
    const source =
        \\static S = struct
        \\  drop = explicit
        \\func foo(var s: S)
        \\  return
    ;
    try addSource(db, 1, source);
    const foo = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("foo").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, foo)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, foo, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.value_requires_explicit_drop, std.meta.activeTag(diagnostics[0].kind));
    const start = std.mem.indexOf(u8, source, "s: S").?;
    try testing.expectEqual(structures.SourceSpan{ .start = start, .end = start + 1 }, diagnostics[0].span.?);
}

test "explicit-drop obligations move with transferred values" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = explicit
        \\  value: int
        \\func forward(var resource: Resource) Resource -> resource^
    );
    const forward = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("forward").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, forward)).* != null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, forward, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "explicit-drop abandonment diagnostics update and recover incrementally" {
    const db = try testDatabase(1);
    defer db.deinit();
    const valid =
        \\static Resource = struct
        \\  drop = explicit
        \\func dispose(deinit resource: Resource) -> return
        \\func use()
        \\  const resource = Resource{}
        \\  dispose(resource^)
    ;
    try addSource(db, 1, valid);
    const use = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("use").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* != null);

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = explicit
        \\func dispose(deinit resource: Resource) -> return
        \\func use()
        \\  const resource = Resource{}
        \\  _ = resource
    );
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, use, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.value_requires_explicit_drop, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1, valid);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* != null);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, use, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "deinit parameters satisfy explicit-drop obligations" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = explicit
        \\  value: int
        \\func dispose(deinit resource: Resource) int
        \\  resource = Resource{value = resource.value + 1}
        \\  return resource.value
        \\func direct() int -> dispose(Resource{value = 41})
        \\func answer() int
        \\  const selected = dispose
        \\  const resource = Resource{value = 41}
        \\  return selected(resource^)
    );
    try expectCompiledFunctionResult(db, 1, "direct", &.{ "direct", "dispose" }, 42);
    try expectCompiledFunctionResult(db, 1, "answer", &.{ "answer", "dispose" }, 42);
}

test "deinit arguments require ownership and invalidate transferred roots" {
    const cases = [_]struct {
        source: []const u8,
        kind: DiagnosticKind,
    }{
        .{
            .source = "static Resource = struct\n  drop = explicit\n  value: int\nfunc dispose(deinit resource: Resource) -> return\nfunc bad()\n  const resource = Resource{value = 42}\n  dispose(resource)",
            .kind = .type_not_copyable,
        },
        .{
            .source = "static Resource = struct\n  drop = explicit\n  value: int\nfunc dispose(deinit resource: Resource) -> return\nfunc bad() int\n  const resource = Resource{value = 42}\n  dispose(resource^)\n  return resource.value",
            .kind = .use_after_transfer,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        const bad = (try db.get(queries.BuildModuleScope, file_id)).*.?.resolveFunction("bad").?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, bad)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, bad, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.kind, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "deinit parameters can forward explicit-drop obligations" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\static Resource = struct
        \\  drop = explicit
        \\  value: int
        \\func forward(deinit resource: Resource) Resource -> resource^
    );
    const forward = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("forward").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, forward)).* != null);
}

test "drop property edits invalidate and recover function lifetimes" {
    const db = try testDatabase(1);
    defer db.deinit();
    const trivial_source =
        \\static Resource = struct
        \\  drop = trivial
        \\  value: int
        \\func use()
        \\  const resource = Resource{value = 42}
    ;
    try addSource(db, 1, trivial_source);
    var use = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("use").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* != null);

    try setSource(db, 1,
        \\static Resource = struct
        \\  drop = explicit
        \\  value: int
        \\func use()
        \\  const resource = Resource{value = 42}
    );
    use = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("use").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, use, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.value_requires_explicit_drop, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    try setSource(db, 1, trivial_source);
    use = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveFunction("use").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, use)).* != null);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, use, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "function analysis distinguishes entry stale restored and invalid identities" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 7";
    try addSource(db, 1, valid);
    const index = (try db.get(queries.IndexItems, 1)).*.?;
    const function_id = index.ids()[0];
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.FunctionSignature, entry_id)).* == null);
    try expectUnitBody((try db.get(queries.AnalyzeFunctionBody, entry_id)).*.?);

    try setSource(db, 1, "");
    try testing.expect((try db.get(queries.FunctionSignature, function_id)).* == null);
    try setSource(db, 1, valid);
    try testing.expect((try db.get(queries.FunctionSignature, function_id)).* != null);
    try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, function_id)).*.?, 7);

    const invalid: structures.ItemId = @enumFromInt(std.math.maxInt(u32));
    try testing.expectError(error.InvalidInternId, db.get(queries.FunctionSignature, invalid));
    try testing.expectError(error.InvalidInternId, db.get(queries.AnalyzeFunctionBody, invalid));
}

test "duplicate names block module analysis until deduplicated" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
    );
    try testing.expect((try db.get(queries.IndexItems, 1)).* == null);
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const blocked_diagnostics = try db.transitiveAccumulatorValues(queries.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(blocked_diagnostics);
    try testing.expectEqual(@as(usize, 1), blocked_diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, blocked_diagnostics[0].kind);

    try setSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static renamed = func() int -> return 2
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const first_id = scope.resolve("duplicate").?;
    const second_id = scope.resolve("renamed").?;
    try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, first_id)).*.?, 1);
    try expectIntegerReturnBody((try db.get(queries.AnalyzeFunctionBody, second_id)).*.?, 2);
}

test "duplicate top-level names fail executable construction without any call" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
        \\exit(0)
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, diagnostics[0].kind);
}

test "malformed function diagnostics remain parse-only and top-level return stays rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static f = func() int -> return 1");
    const function_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    try setSource(db, 1, "static f = func() int");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function_id)).* == null);
    const direct = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), direct.len);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, function_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expect(diagnostics.len > 0);

    try addSource(db, 2, "return 7");
    const entry_id = (try db.get(queries.SelectEntry, 2)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_instance.item)).* == null);
    try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 2)).* == null);
    const return_span: structures.SourceSpan = .{ .start = 0, .end = "return".len };
    const entry_kind: structures.Diagnostic.Kind = .top_level_return;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, entry_id, true, 2, return_span, entry_kind);
    try expectSingleQueryDiagnostic(db, queries.CompileFunction, entry_instance, false, 2, return_span, entry_kind);
    const entry_diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 2, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(entry_diagnostics);
    try testing.expectEqual(@as(usize, 1), entry_diagnostics.len);
    try testing.expectEqual(entry_kind, entry_diagnostics[0].kind);
}

test "entry analysis rejects top-level returns" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        source: []const u8,
        marker: []const u8,
    }{
        .{ .source = "return", .marker = "return" },
        .{ .source = "static ok = 1\nreturn 7\nprint(1)", .marker = "return" },
        .{ .source = "if 1 < 2 -> return", .marker = "return" },
        .{ .source = "loop\n  return", .marker = "return" },
    };
    const entry_kind: structures.Diagnostic.Kind = .top_level_return;

    for (cases, 10..) |case, file_id| {
        try addSource(db, file_id, case.source);
        const entry_id = (try db.get(queries.SelectEntry, file_id)).*.?;
        const entry_instance: structures.InstanceId = .{ .item = entry_id };
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_instance.item)).* == null);
        try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* == null);
        try testing.expect((try db.get(queries.BuildExecutable, file_id)).* == null);
        const start = std.mem.indexOf(u8, case.source, case.marker).?;
        const span: structures.SourceSpan = .{ .start = start, .end = start + case.marker.len };
        try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, entry_id, true, file_id, span, entry_kind);
        try expectSingleQueryDiagnostic(db, queries.CompileFunction, entry_instance, false, file_id, span, entry_kind);
        try expectSingleQueryDiagnostic(db, queries.BuildExecutable, file_id, false, file_id, span, entry_kind);
    }
}

test "entry const bindings name typed values and execute" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static status = func(value: int) int -> return value * 2
        \\const a = status(21)
        \\exit(a)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const status_id = scope.resolve("status").?;
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const body = (try db.get(queries.AnalyzeFunctionBody, entry_id)).*.?;

    try testing.expectEqual(@as(usize, 3), body.instructions.len);
    try testing.expectEqual(@as(i32, 21), body.instructions[0].const_int);
    try testing.expectEqual(status_id, body.instructions[1].call.target);
    try testing.expectEqual(structures.TypeId.never, body.instructions[2].resultType());

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "entry const binding edits retain equal analysis and recover" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "const value = 21\nexit(value)");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const initial = try db.get(queries.AnalyzeFunctionBody, entry_id);
    try testing.expect(initial.* != null);

    try setSource(db, 1, "const renamed = 21\nexit(renamed)");
    try testing.expectEqual(initial, try db.get(queries.AnalyzeFunctionBody, entry_id));

    try setSource(db, 1, "exit(renamed)");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.unknown_value, diagnostics[0].kind);

    try setSource(db, 1, "const restored = 21\nexit(restored)");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
}

test "entry analysis resolves one direct call without analyzing its callee body" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\broken()
    );
    const index = (try db.get(queries.IndexItems, 1)).*.?;
    const callee_id = index.ids()[0];
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;

    const entry_body = (try db.get(queries.AnalyzeFunctionBody, entry_id)).*.?;
    try testing.expectEqual(@as(usize, 1), entry_body.instructions.len);
    try testing.expectEqual(callee_id, entry_body.instructions[0].call.target);
    try testing.expect((try db.get(queries.FunctionSignature, callee_id)).* != null);
    try testing.expectEqual(@as(usize, 0), (try db.directAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic)).len);

    // The invalid body is diagnosed only when it is independently demanded.
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, callee_id)).* == null);
}

test "entry analysis validates all root syntax before resolving a call" {
    const db = try testDatabase(2);
    defer db.deinit();

    const cases = [_]struct {
        source: []const u8,
        marker: []const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{ .source = "static bad = func() foo -> return 1\nbad()\nreturn", .marker = "return", .kind = .top_level_return },
        .{ .source = "static f = func() int -> return 1\nsizeof(int)\nf()", .marker = "sizeof", .kind = .expression_not_supported },
    };

    for (cases, 10..) |case, file_id| {
        try addSource(db, file_id, case.source);
        const entry_id = (try db.get(queries.SelectEntry, file_id)).*.?;
        try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
        const start = std.mem.lastIndexOf(u8, case.source, case.marker).?;
        try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, entry_id, true, file_id, .{
            .start = start,
            .end = start + case.marker.len,
        }, case.kind);
    }
}

test "top-level imports and public markers leave entry analysis unchanged" {
    const db = try testDatabase(1);
    defer db.deinit();

    const physics_module = try db.intern(queries.ModulePaths, .{ .path = "physics" });
    const math_module = try db.intern(queries.ModulePaths, .{ .path = "math" });
    _ = try addModuleFile(db, 2, "physics", "pub struct Body\n  x: int");
    _ = try addModuleFile(db, 3, "math", "pub struct Vec3\n  x: int");
    try addModuleMembers(db, physics_module, &.{2});
    try addModuleMembers(db, math_module, &.{3});
    try addSource(db, 1,
        \\import physics
        \\import physics.{Body}
        \\pub import math.{Vec3}
        \\pub static doubled = func(value: int) int -> return value * 2
        \\const a = doubled(21)
        \\exit(a)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try testing.expect(scope.resolve("doubled") != null);
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "imports outside the top level are rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static f = func() int
        \\  import physics
        \\  return 1
    ;
    try addSource(db, 1, source);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const function = scope.resolveFunction("f").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function)).* == null);
    const start = std.mem.indexOf(u8, source, "import").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function, true, 1, .{
        .start = start,
        .end = start + "import".len,
    }, .import_outside_top_level);
}

test "nested public markers are rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    const source =
        \\static f = func() int
        \\  pub static x = 1
        \\  return x
    ;
    try addSource(db, 1, source);
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const function = scope.resolveFunction("f").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, function)).* == null);
    const start = std.mem.indexOf(u8, source, "pub").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, function, true, 1, .{
        .start = start,
        .end = start + "pub".len,
    }, .misplaced_pub);
}

test "public runtime bindings are rejected" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "pub const x = 1\nexit(0)");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, entry_id, true, 1, .{
        .start = 0,
        .end = "pub".len,
    }, .misplaced_pub);
}

test "qualified types require a visible namespace" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static f = func(body: physics.Body) int -> return 1");
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const function = scope.resolveFunction("f").?;
    try testing.expect((try db.get(queries.FunctionSignature, function)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, function, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.unknown_type, std.meta.activeTag(diagnostics[0].kind));
}

test "entry call lookup reports only the demanded resolution failure" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "missing()");
    const missing_entry = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, missing_entry)).* == null);
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, missing_entry, true, 1, .{
        .start = 0,
        .end = "missing".len,
    }, .unknown_function);

    const unsupported = "static bad = func() foo -> return 1\nbad()";
    try addSource(db, 2, unsupported);
    const unsupported_entry = (try db.get(queries.SelectEntry, 2)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, unsupported_entry)).* == null);
    const unsupported_diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, unsupported_entry, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(unsupported_diagnostics);
    try testing.expectEqual(@as(usize, 1), unsupported_diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.unknown_type, unsupported_diagnostics[0].kind);

    // A call to a duplicated name adds no "unknown function" diagnostic; the
    // discovery rejection is the only failure the file reports.
    try addSource(db, 3,
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
        \\duplicate()
    );
    try testing.expect((try db.get(queries.SelectEntry, 3)).* == null);
    try testing.expect((try db.get(queries.BuildExecutable, 3)).* == null);
    const duplicate_diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 3, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(duplicate_diagnostics);
    try testing.expectEqual(@as(usize, 1), duplicate_diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, duplicate_diagnostics[0].kind);

    const value_source = "static value = 1\nvalue()";
    try addSource(db, 4, value_source);
    const value_entry = (try db.get(queries.SelectEntry, 4)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, value_entry)).* == null);
    const value_start = std.mem.lastIndexOf(u8, value_source, "value").?;
    try expectSingleQueryDiagnostic(db, queries.AnalyzeFunctionBody, value_entry, true, 4, .{
        .start = value_start,
        .end = value_start + "value".len,
    }, .value_not_callable);
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
    const initial_parse = try db.get(queries.ParseFile, 1);
    const initial_scope = try db.get(queries.BuildModuleScope, 1);
    const alpha_id = initial_scope.*.?.resolve("alpha").?;
    const bravo_id = initial_scope.*.?.resolve("bravo").?;
    try testing.expectEqual(alpha_id, (try db.get(EntryCallParent, 1)).*.?);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try testing.expectEqual(initial_parse, try db.get(queries.ParseFile, 1));
    try testing.expectEqual(initial_scope, try db.get(queries.BuildModuleScope, 1));
    try testing.expectEqual(bravo_id, (try db.get(EntryCallParent, 1)).*.?);

    try setSource(db, 1,
        \\static bravo = func() int -> return 20
        \\static alpha = func() int -> return 10
        \\bravo()
    );
    try testing.expectEqual(bravo_id, (try db.get(EntryCallParent, 1)).*.?);
    try EntryCallParent.executions.expect(2);

    // Removing the runtime call removes the scope dependency as well, but the
    // duplicate-name error is owned by discovery, so it stays diagnosed even
    // though no body requests the module scope.
    try setSource(db, 1,
        \\static duplicate = func() int -> return 20
        \\static duplicate = func() int -> return 10
    );
    try testing.expect((try db.get(EntryCallParent, 1)).* == null);
    try testing.expect((try db.get(queries.SelectEntry, 1)).* == null);
    const blocked_diagnostics = try db.transitiveAccumulatorValues(queries.SelectEntry, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(blocked_diagnostics);
    try testing.expectEqual(@as(usize, 1), blocked_diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.duplicate_top_level_declaration, blocked_diagnostics[0].kind);

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
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const initial_body = try db.get(queries.AnalyzeFunctionBody, entry_id);
    const initial_artifact = try db.get(queries.CompileFunction, instance);
    try testing.expectEqual(structures.TypeId.unit, initial_body.*.?.instructions[0].call.return_type);

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const updated_body = try db.get(queries.AnalyzeFunctionBody, entry_id);
    try testing.expect(initial_body != updated_body);
    try testing.expectEqual(structures.TypeId.int, updated_body.*.?.instructions[0].call.return_type);
    try testing.expectEqual(initial_artifact, try db.get(queries.CompileFunction, instance));
}

test "entry call diagnostics and downstream refusal update and recover" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static value = 1\nmissing()");
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    const initial = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), initial.len);
    const initial_span = initial[0].span.?;

    try setSource(db, 1, "static longer = 1\nmissing()");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);
    const moved = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, entry_id, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 1), moved.len);
    try testing.expect(initial_span.start != moved[0].span.?.start);

    const unsupported_signature =
        \\static target = func() foo -> return 1
        \\target()
    ;
    try setSource(db, 1, unsupported_signature);
    const unsupported_parse = try db.get(queries.ParseFile, 1);
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* == null);

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    try testing.expectEqual(unsupported_parse, try db.get(queries.ParseFile, 1));
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry_id)).* != null);
    const body = (try db.get(queries.AnalyzeFunctionBody, instance.item)).*.?;
    const target_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("target").?;
    try expectDirectCallBody(body, target_id);
    const body_diagnostics = try db.directAccumulatorValues(queries.AnalyzeFunctionBody, instance.item, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), body_diagnostics.len);
    try expectDirectCallArtifact((try db.get(queries.CompileFunction, instance)).*.?, target_id);
    const compile_diagnostics = try db.directAccumulatorValues(queries.CompileFunction, instance, structures.Diagnostic);
    try testing.expectEqual(@as(usize, 0), compile_diagnostics.len);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);

    try setSource(db, 1, "");
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, instance.item)).* != null);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "BuildExecutable links a direct call while keeping the entry artifact independent of the callee's value" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const entry_instance: structures.InstanceId = .{ .item = entry_id };

    const entry_artifact = try db.get(queries.CompileFunction, entry_instance);
    try testing.expect(entry_artifact.* != null);
    const initial_executable = try db.get(queries.BuildExecutable, 1);
    try testing.expect(initial_executable.* != null);
    const initial_bytes = try testing.allocator.dupe(u8, initial_executable.*.?.bytes);
    defer testing.allocator.free(initial_bytes);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, initial_executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));

    // Editing only the callee's return value changes the callee's compiled
    // artifact and the linked executable, but not the caller's own artifact:
    // direct-call compilation stays independent of the callee body.
    try setSource(db, 1,
        \\static target = func() int -> return 99
        \\target()
    );
    try testing.expectEqual(entry_id, (try db.get(queries.SelectEntry, 1)).*.?);
    try testing.expectEqual(entry_artifact, try db.get(queries.CompileFunction, entry_instance));

    const updated_executable = try db.get(queries.BuildExecutable, 1);
    try testing.expect(updated_executable.* != null);
    try testing.expect(!std.mem.eql(u8, initial_bytes, updated_executable.*.?.bytes));

    try runtime.writeProgram(io, updated_executable.*.?.bytes);
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
    const executable = try db.get(queries.BuildExecutable, 1);
    try testing.expect(executable.* != null);

    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.*.?.bytes);
    try testing.expectEqual(@as(u8, 0), runtime.runProg(io, testing.allocator, &.{}));
}

test "CollectReachableInstances publishes stable breadth-first order" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static shared = func() int -> return 1
        \\static left = func() int -> return shared()
        \\static right = func() int -> return shared()
        \\left()
        \\right()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const entry: structures.InstanceId = .{ .item = (try db.get(queries.SelectEntry, 1)).*.? };
    const left: structures.InstanceId = .{ .item = scope.resolve("left").? };
    const right: structures.InstanceId = .{ .item = scope.resolve("right").? };
    const shared: structures.InstanceId = .{ .item = scope.resolve("shared").? };

    const initial = try db.get(queries.CollectReachableInstances, 1);
    try testing.expectEqualSlices(
        structures.InstanceId,
        &.{ entry, left, right, shared },
        initial.*.?.instances,
    );

    try setSource(db, 1,
        \\static shared = func() int -> return 2
        \\static left = func() int -> return shared()
        \\static right = func() int -> return shared()
        \\left()
        \\right()
    );
    try testing.expectEqual(initial, try db.get(queries.CollectReachableInstances, 1));
}

test "static type and value parameters produce canonical reachable instances" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static Whole: type = int
        \\func identity(static T: type, static N: int, value: T) T
        \\  _ = N
        \\  return value
        \\exit(identity(int, 1, 40) + identity(Whole, 1, 1) + identity(int, 2, 1))
    );

    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const identity = scope.resolveFunction("identity").?;
    const reachable = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(@as(usize, 4), reachable.instances.len);
    try testing.expect(reachable.instances[0].specialization == null);
    try testing.expectEqual(identity, reachable.instances[1].item);
    try testing.expectEqual(identity, reachable.instances[2].item);
    try testing.expect(reachable.instances[1].specialization != null);
    try testing.expect(reachable.instances[2].specialization != null);
    try testing.expect(reachable.instances[1].specialization != reachable.instances[2].specialization);

    const first_arguments = try db.lookupInterned(queries.CompileTimeValueTuples, reachable.instances[1].specialization.?);
    const second_arguments = try db.lookupInterned(queries.CompileTimeValueTuples, reachable.instances[2].specialization.?);
    try testing.expectEqual(structures.CompileTimeValue{ .type = .int }, try lookupCompileTimeValue(db, first_arguments.values[0]));
    try testing.expectEqual(structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 1 } } }, try lookupCompileTimeValue(db, first_arguments.values[1]));
    try testing.expectEqual(structures.CompileTimeValue{ .runtime = .{ .type_id = .int, .value = .{ .int = 2 } } }, try lookupCompileTimeValue(db, second_arguments.values[1]));

    const first_signature = (try db.get(queries.FunctionInstanceSignature, reachable.instances[1])).*.?;
    try expectImmParameters(&.{.int}, first_signature.parameters);
    try testing.expectEqual(structures.TypeId.int, first_signature.return_type);
    const retained_instance = reachable.instances[1];
    const replaced_specialization = reachable.instances[2].specialization;
    const retained_artifact = try db.get(queries.CompileFunction, retained_instance);

    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));

    try setSource(db, 1,
        \\static Whole: type = int
        \\func identity(static T: type, static N: int, value: T) T
        \\  _ = N
        \\  return value
        \\exit(identity(int, 1, 40) + identity(Whole, 1, 1) + identity(int, 3, 1))
    );
    const updated = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(@as(usize, 4), updated.instances.len);
    try testing.expectEqual(retained_instance, updated.instances[1]);
    try testing.expect(updated.instances[2].specialization != replaced_specialization);
    try testing.expectEqual(retained_artifact, try db.get(queries.CompileFunction, retained_instance));
}

test "type-valued signatures use canonical specialization values and stay compile-time-only" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\func choose(static T: type) type -> T
        \\func invalid(value: type) -> ()
        \\choose(int)
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const choose = scope.resolveFunction("choose").?;
    const type_int = try db.intern(queries.CompileTimeValues, structures.CompileTimeValue{ .type = .int });
    const arguments = [_]structures.CompileTimeValueId{type_int};
    const specialization = try db.intern(queries.CompileTimeValueTuples, .{ .values = &arguments });
    const signature = (try db.get(queries.FunctionInstanceSignature, .{
        .item = choose,
        .specialization = specialization,
    })).*.?;
    try testing.expectEqual(@as(usize, 0), signature.parameters.len);
    try testing.expectEqual(structures.TypeId.type, signature.return_type);

    const invalid = scope.resolveFunction("invalid").?;
    try testing.expect((try db.get(queries.FunctionSignature, invalid)).* == null);
    var diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, invalid, structures.Diagnostic, testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.parameter_type_not_supported, std.meta.activeTag(diagnostics[0].kind));
    freeDiagnostics(diagnostics);

    const entry = (try db.get(queries.SelectEntry, 1)).*.?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, entry)).* == null);
    diagnostics = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionBody, entry, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.type_value_used_as_runtime_value, std.meta.activeTag(diagnostics[0].kind));
}

test "static specialization validates compile-time and dependent runtime arguments" {
    const cases = [_]struct {
        source: []const u8,
        expected: DiagnosticKind,
    }{
        .{
            .source =
            \\func identity(static T: type, value: T) T -> value
            \\exit(identity(bool, 42))
            ,
            .expected = .call_argument_type_mismatch,
        },
        .{
            .source =
            \\func identity(static T: type, value: T) T -> value
            \\exit(identity(1, 42))
            ,
            .expected = .static_argument_not_supported,
        },
        .{
            .source =
            \\func identity(static N: int, value: int) int -> value
            \\exit(identity(true, 42))
            ,
            .expected = .static_argument_type_mismatch,
        },
        .{
            .source =
            \\func identity(static T: type, value: T) T -> value
            \\const unspecialized = identity
            ,
            .expected = .static_parameter_requires_specialization,
        },
    };

    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        try testing.expect((try db.get(queries.BuildExecutable, file_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(
            queries.BuildExecutable,
            file_id,
            structures.Diagnostic,
            testing.allocator,
        );
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.expected, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "direct and instance calls infer static parameters from runtime types" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1, "func identity(static T: type, value: T) T -> value\nexit(identity(42))");
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    try setSource(db, 1,
        \\struct Box(T: type, N: int)
        \\  value: T
        \\func identity(static T: type, value: T) T -> value
        \\func middle(first: int, static T: type, value: T, last: int) int -> first + value + last
        \\func read(static T: type, static N: int, boxed: Box(T, N)) int -> boxed.value + N
        \\struct S
        \\  value: int
        \\  func pick(imm self: S, static T: type, value: T) T -> value
        \\static Alias: type = Box(int, 3)
        \\const boxed = Alias{value = 10}
        \\const item = S{value = 1}
        \\exit(identity(10) + middle(1, 2, 3) + read(boxed) + item.pick(13))
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "static inference honors independent expected types and existing explicit calls" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Box(N: int)
        \\  value: int
        \\func read(value: byte, static N: int, boxed: Box(N)) int -> boxed.value + N
        \\const boxed = Box(3){value = 7}
        \\exit(read(4, boxed) + read(4, 3, boxed) + 22)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "inferred static calls reuse specialization identities across source edits" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Box(N: int)
        \\  value: int
        \\func read(static N: int, boxed: Box(N)) int -> boxed.value + N
        \\exit(read(Box(3){value = 39}))
    );
    const before = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    const old_instance = before.instances[1];
    const old_artifact = try db.get(queries.CompileFunction, old_instance);
    try setSource(db, 1,
        \\struct Box(N: int)
        \\  value: int
        \\func read(static N: int, boxed: Box(N)) int -> boxed.value + N
        \\exit(read(Box(4){value = 38}))
    );
    const after = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expect(after.instances[1].specialization != old_instance.specialization);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    try setSource(db, 1,
        \\struct Box(N: int)
        \\  value: int
        \\func read(static N: int, boxed: Box(N)) int -> boxed.value + N
        \\exit(read(Box(3){value = 39}))
    );
    const restored = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(old_instance, restored.instances[1]);
    try testing.expectEqual(old_artifact, try db.get(queries.CompileFunction, old_instance));
}

test "inferred static instance calls retain inherited factory specialization" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Box(T: type)
        \\  value: T
        \\  func pick(imm self: Box(T), static U: type, value: U) U -> value
        \\const boxed = Box(int){value = 1}
        \\exit(boxed.pick(42))
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
}

test "inferred calls preserve runtime argument order and parameter modes" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func stop(code: int) int
        \\  exit(code)
        \\  return 0
        \\func pair(static T: type, first: T, second: T) T -> first + second
        \\func increment(static T: type, mut value: T)
        \\  value += 1
        \\func take(static T: type, var value: T) T -> value
        \\var answer = 41
        \\increment(answer)
        \\_ = take(answer)
        \\exit(answer)
    );
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    const first = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, first.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(io, testing.allocator, &.{}));
    try setSource(db, 1,
        \\func stop(code: int) int
        \\  exit(code)
        \\  return 0
        \\func pair(static T: type, first: T, second: T) T -> first + second
        \\exit(pair(stop(11), stop(12)))
    );
    const ordered = (try db.get(queries.BuildExecutable, 1)).*.?;
    try runtime.writeProgram(io, ordered.bytes);
    try testing.expectEqual(@as(u8, 11), try runtime.runProg(io, testing.allocator, &.{}));
}

test "static inference rejects missing conflicting and non-invertible evidence" {
    const cases = [_]struct { source: []const u8, expected: DiagnosticKind }{
        .{
            .source = "func read(static N: int, value: int) int -> value\nexit(read(42))",
            .expected = .static_argument_cannot_be_inferred,
        },
        .{
            .source = "func equal(static T: type, left: T, right: T) T -> left\nexit(equal(1, true))",
            .expected = .static_argument_inference_conflict,
        },
        .{
            .source =
            \\func constant(static N: int) type -> int
            \\func read(static N: int, value: constant(N)) int -> value
            \\exit(read(42))
            ,
            .expected = .static_argument_cannot_be_inferred,
        },
        .{
            .source =
            \\struct Box(N: int)
            \\  value: int
            \\func constant(static N: int) type -> Box(1)
            \\func read(static N: int, value: constant(N)) int -> value.value
            \\exit(read(Box(1){value = 42}))
            ,
            .expected = .static_argument_cannot_be_inferred,
        },
        .{
            .source =
            \\struct Box(N: int)
            \\  value: int
            \\func equal(static N: int, left: Box(N), right: Box(N)) int -> left.value
            \\exit(equal(Box(1){value = 1}, Box(2){value = 2}))
            ,
            .expected = .static_argument_inference_conflict,
        },
    };
    for (cases, 1..) |case, file_id| {
        const db = try testDatabase(1);
        defer db.deinit();
        try addSource(db, file_id, case.source);
        try testing.expect((try db.get(queries.BuildExecutable, file_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, file_id, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(case.expected, std.meta.activeTag(diagnostics[0].kind));
    }
}

test "static primitive values dominate every specialized control-flow path" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func choose(static N: int, value: int) int
        \\  if value < 1
        \\    return N
        \\  return N + value
        \\exit(choose(42, 0))
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "static type positions disambiguate unit and none type values" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func identity(static T: type, value: T) T -> value
        \\_ = identity(unit, unit)
        \\_ = identity(none, none)
        \\exit(42)
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), runtime.runProg(io, testing.allocator, &.{}));
}

test "stale specialization arity is unavailable across edits and recovers" {
    const db = try testDatabase(1);
    defer db.deinit();
    const original =
        \\func identity(static T: type, value: T) T -> value
        \\exit(identity(int, 42))
    ;
    try addSource(db, 1, original);
    const initial_reachable = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    const old_instance = initial_reachable.instances[1];
    try testing.expect((try db.get(queries.CompileFunction, old_instance)).* != null);

    try setSource(db, 1,
        \\func identity(static T: type, static N: int, value: T) T -> value
        \\exit(identity(int, 1, 42))
    );
    try testing.expect((try db.get(queries.CompileFunction, old_instance)).* == null);
    const stale_diagnostics = try db.transitiveAccumulatorValues(
        queries.CompileFunction,
        old_instance,
        structures.Diagnostic,
        testing.allocator,
    );
    defer freeDiagnostics(stale_diagnostics);
    try testing.expectEqual(@as(usize, 0), stale_diagnostics.len);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);

    try setSource(db, 1, original);
    const restored = (try db.get(queries.CollectReachableInstances, 1)).*.?;
    try testing.expectEqual(old_instance, restored.instances[1]);
    try testing.expect((try db.get(queries.CompileFunction, old_instance)).* != null);
}

test "BuildExecutable collects cyclic reachability without recursive compilation" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1,
        \\static first = func() int -> return second()
        \\static second = func() int -> return first()
        \\first()
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
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
    const executable = try db.get(queries.BuildExecutable, 1);
    try testing.expect(executable.* != null);

    const shared_code = [_]u8{ 0xB8, 0x78, 0x56, 0x34, 0x12, 0xBA, 1, 0, 0, 0, 0xC3 };
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
    const with_leaf = try db.get(queries.BuildExecutable, 1);
    try testing.expect(with_leaf.* != null);
    const initial_bytes = try testing.allocator.dupe(u8, with_leaf.*.?.bytes);
    defer testing.allocator.free(initial_bytes);

    try setSource(db, 1,
        \\static leaf = func() int -> return 1
        \\static middle = func() int -> return 9
        \\middle()
    );
    const without_leaf = try db.get(queries.BuildExecutable, 1);
    try testing.expect(without_leaf.* != null);
    try testing.expect(!std.mem.eql(u8, initial_bytes, without_leaf.*.?.bytes));

    try setSource(db, 1,
        \\static leaf = func() int -> return true
        \\static middle = func() int -> return 9
        \\middle()
    );
    try testing.expectEqual(without_leaf, try db.get(queries.BuildExecutable, 1));
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
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
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(
        structures.Diagnostic.Kind{ .return_type_mismatch = .{ .expected = .int, .found = .bool } },
        diagnostics[0].kind,
    );

    try setSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "concurrent entry call analysis shares one stable result" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1,
        \\static target = func() int -> return 1
        \\target()
    );
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    var handles: [16]Handle(queries.AnalyzeFunctionBody) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(queries.AnalyzeFunctionBody, entry_id);
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
    kind: structures.Diagnostic.Kind,
) !void {
    const direct = try db.directAccumulatorValues(Q, input, structures.Diagnostic);
    try testing.expectEqual(@as(usize, if (owns_direct_diagnostic) 1 else 0), direct.len);

    const transitive = try db.transitiveAccumulatorValues(Q, input, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(transitive);
    try testing.expectEqual(@as(usize, 1), transitive.len);
    try testing.expectEqual(file_id, transitive[0].file_id);
    try testing.expectEqual(span, transitive[0].span.?);
    try testing.expectEqual(kind, transitive[0].kind);
}

test "direct entry call SSA remains demand driven across callee edits and reorder" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\static other = func() int -> return 2
        \\broken()
    );
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const broken_id = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("broken").?;
    const initial = try db.get(queries.AnalyzeFunctionBody, instance.item);
    try expectDirectCallBody(initial.*.?, broken_id);

    // Independently demanding the invalid callee body must not create a caller
    // analysis dependency on it.
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, broken_id)).* == null);
    try setSource(db, 1,
        \\static broken = func() int -> return false
        \\static other = func() int -> return 20
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(queries.AnalyzeFunctionBody, instance.item));

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(queries.AnalyzeFunctionBody, instance.item));
}

test "direct entry call SSA tracks target changes removal and restoration" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\alpha()
    );
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const alpha_id = scope.resolve("alpha").?;
    const bravo_id = scope.resolve("bravo").?;
    try expectDirectCallBody((try db.get(queries.AnalyzeFunctionBody, instance.item)).*.?, alpha_id);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try expectDirectCallBody((try db.get(queries.AnalyzeFunctionBody, instance.item)).*.?, bravo_id);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
    );
    const unit = (try db.get(queries.AnalyzeFunctionBody, instance.item)).*.?;
    try expectUnitBody(unit);

    try setSource(db, 1,
        \\static alpha = func() int -> return 1
        \\static bravo = func() int -> return 2
        \\bravo()
    );
    try expectDirectCallBody((try db.get(queries.AnalyzeFunctionBody, instance.item)).*.?, bravo_id);
}

test "CompileFunction produces owned value-equal artifacts for distinct instances" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static first = func() int -> return 7");
    try addSource(db, 2, "static second = func() int -> return 7");
    const first_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    const second_id = (try db.get(queries.IndexItems, 2)).*.?.ids()[0];
    const first = try db.get(queries.CompileFunction, .{ .item = first_id });
    const second = try db.get(queries.CompileFunction, .{ .item = second_id });

    try testing.expect(first != second);
    try testing.expect(first.*.?.code.ptr != second.*.?.code.ptr);
    try testing.expect(structures.CompiledFunction.eql(first.*.?, second.*.?));
    try testing.expectEqualSlices(u8, &.{ 0xB8, 7, 0, 0, 0, 0xBA, 1, 0, 0, 0, 0xC3 }, first.*.?.code);
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
    const target_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    const instance: structures.InstanceId = .{ .item = target_id };
    const initial = try db.get(queries.CompileFunction, instance);

    try setSource(db, 1,
        \\static target = func() int -> return 8
        \\static unrelated = func() int -> return 1
    );
    const changed = try db.get(queries.CompileFunction, instance);
    try testing.expect(initial != changed);
    try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, changed.*.?.code[1..5], .little));

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 1
    );
    const equal_shape = try db.get(queries.CompileFunction, instance);
    try testing.expectEqual(changed, equal_shape);

    try setSource(db, 1,
        \\static target = func() int
        \\  return 8
        \\static unrelated = func() int -> return 2
    );
    try testing.expectEqual(equal_shape, try db.get(queries.CompileFunction, instance));
}

test "direct call artifacts follow target identity without demanding the callee" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\static broken = func() int -> return true
        \\static other = func() int -> return 2
        \\broken()
    );
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const instance: structures.InstanceId = .{ .item = entry_id };
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const broken_id = scope.resolve("broken").?;
    const other_id = scope.resolve("other").?;
    const initial = try db.get(queries.CompileFunction, instance);
    try expectDirectCallArtifact(initial.*.?, broken_id);
    try testing.expect((try db.get(queries.CompileFunction, .{ .item = broken_id })).* == null);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\broken()
    );
    try testing.expectEqual(initial, try db.get(queries.CompileFunction, instance));

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\other()
    );
    const changed = (try db.get(queries.CompileFunction, instance)).*.?;
    try expectDirectCallArtifact(changed, other_id);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
    );
    const unit = (try db.get(queries.CompileFunction, instance)).*.?;
    try testing.expectEqualSlices(u8, &.{ 0xBA, 1, 0, 0, 0, 0xC3 }, unit.code);
    try testing.expectEqual(@as(usize, 0), unit.relocations.len);
    try testing.expectEqual(@as(usize, 0), unit.referenced_instances.len);

    try setSource(db, 1,
        \\static other = func() int -> return 20
        \\static broken = func() int -> return false
        \\other()
    );
    try expectDirectCallArtifact((try db.get(queries.CompileFunction, instance)).*.?, other_id);
}

test "CompileFunction exposes semantic diagnostics without duplicating them" {
    const db = try testDatabase(2);
    defer db.deinit();

    try addSource(db, 1, "static header = func() foo -> return 1");
    try addSource(db, 2, "static body = func() int -> return true");
    for ([_]structures.FileId{ 1, 2 }) |file_id| {
        const item_id = (try db.get(queries.IndexItems, file_id)).*.?.ids()[0];
        const instance: structures.InstanceId = .{ .item = item_id };
        try testing.expect((try db.get(queries.CompileFunction, instance)).* == null);
        const direct = try db.directAccumulatorValues(queries.CompileFunction, instance, structures.Diagnostic);
        try testing.expectEqual(@as(usize, 0), direct.len);
        const transitive = try db.transitiveAccumulatorValues(queries.CompileFunction, instance, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(transitive);
        try testing.expectEqual(@as(usize, 1), transitive.len);
    }
}

test "CompileFunction supports entry retention stale restoration and invalid instances" {
    const db = try testDatabase(1);
    defer db.deinit();

    const valid = "static f = func() int -> return 7";
    try addSource(db, 1, valid);
    const function_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    const function_instance: structures.InstanceId = .{ .item = function_id };
    const entry_instance: structures.InstanceId = .{ .item = entry_id };
    const initial_entry = try db.get(queries.CompileFunction, entry_instance);
    try testing.expectEqualSlices(u8, &.{ 0xBA, 1, 0, 0, 0, 0xC3 }, initial_entry.*.?.code);

    try setSource(db, 1, "static f = func() foo -> return true");
    try testing.expectEqual(initial_entry, try db.get(queries.CompileFunction, entry_instance));
    try testing.expect((try db.get(queries.CompileFunction, function_instance)).* == null);

    try setSource(db, 1, "");
    try testing.expectEqual(initial_entry, try db.get(queries.CompileFunction, entry_instance));
    try testing.expect((try db.get(queries.CompileFunction, function_instance)).* == null);
    try setSource(db, 1, valid);
    try testing.expect((try db.get(queries.CompileFunction, entry_instance)).* != null);
    try testing.expect((try db.get(queries.CompileFunction, function_instance)).* != null);

    const invalid: structures.InstanceId = .{ .item = @enumFromInt(std.math.maxInt(u32)) };
    try testing.expectError(error.InvalidInternId, db.get(queries.CompileFunction, invalid));
}

test "concurrent CompileFunction requests share function and entry results" {
    const db = try testDatabase(4);
    defer db.deinit();

    try addSource(db, 1, "static f = func() int -> return 7\nf()");
    const function_id = (try db.get(queries.IndexItems, 1)).*.?.ids()[0];
    const entry_id = (try db.get(queries.SelectEntry, 1)).*.?;
    for ([_]structures.InstanceId{ .{ .item = function_id }, .{ .item = entry_id } }) |instance| {
        var handles: [16]Handle(queries.CompileFunction) = undefined;
        for (&handles) |*handle| handle.* = try db.spawn(queries.CompileFunction, instance);
        const first = try handles[0].wait();
        for (handles[1..]) |handle| try testing.expectEqual(first, try handle.wait());
        if (instance.item == entry_id) try expectDirectCallArtifact(first.*.?, function_id);
    }
}

test "item locations survive body and unrelated-index edits but not renames" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1, "static target = func() int -> return 1");
    const initial_result = try db.get(queries.DiscoverItems, 1);
    const initial_tree = initial_result.*.?;
    const initial_name = try testing.allocator.dupe(u8, initial_tree.items[0].loc.name);
    defer testing.allocator.free(initial_name);
    const initial_loc: structures.ItemLoc = .{
        .origin = initial_tree.items[0].loc.origin,
        .kind = initial_tree.items[0].loc.kind,
        .name = initial_name,
    };
    const initial_declaration = initial_tree.items[0].declaration;

    const updated_source =
        \\static unrelated = func() int -> return 0
        \\static target = func() int
        \\  const x = 1
        \\  return x + 1
    ;
    try setSource(db, 1, updated_source);
    const updated_result = try db.get(queries.DiscoverItems, 1);
    const updated_tree = updated_result.*.?;
    const target = findItemByName(updated_tree.items, "target").?;
    try testing.expect(structures.ItemLoc.eql(initial_loc, target.loc));
    try testing.expect(initial_declaration != target.declaration);

    try setSource(db, 1, "static renamed = func() int -> return 2");
    const renamed_result = try db.get(queries.DiscoverItems, 1);
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

    _ = try db.get(queries.ParseFile, 1);
    const unchanged_before = try db.get(queries.ParseFile, 2);

    const updated_source = "const new_name = 1";
    try setSource(db, 1, updated_source);

    const updated = try db.get(queries.ParseFile, 1);
    const unchanged_after = try db.get(queries.ParseFile, 2);

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
    const diagnostics_before = try db.directAccumulatorValues(Parity, 1, OwnedDiagnostic);

    try db.setInput(NumberInput, 1, 2);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    try Parity.executions.expect(1);
    try ParityParent.executions.expect(1);

    try db.setInput(NumberInput, 1, 4);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    const diagnostics_after = try db.directAccumulatorValues(Parity, 1, OwnedDiagnostic);

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

    const diagnostics = try db.transitiveAccumulatorValues(DiagnosticParent, 1, OwnedDiagnostic, testing.allocator);
    defer freeOwnedDiagnostics(diagnostics);
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

    const diagnostics = try db.directAccumulatorValues(RetryableFailure, 1, OwnedDiagnostic);
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

    const module: structures.ModuleId = @enumFromInt(0);
    failing.fail_index = failing.alloc_index + 3;
    const loc: structures.ItemLoc = .{ .origin = .{ .module = module }, .kind = .function, .name = "owned" };
    try testing.expectError(error.OutOfMemory, db.intern(queries.ItemLocations, loc));
    try testing.expect(failing.has_induced_failure);
    try testing.expectError(error.InvalidInternId, db.lookupInterned(queries.ItemLocations, @enumFromInt(0)));

    failing.fail_index = std.math.maxInt(usize);
    const id = try db.intern(queries.ItemLocations, loc);
    try testing.expectEqualStrings("owned", (try db.lookupInterned(queries.ItemLocations, id)).name);

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

test "cycles introduced during dependency verification reject retry and recover" {
    for ([_]usize{ 1, 4 }) |worker_count| {
        const db = try testDatabase(worker_count);
        defer db.deinit();

        try db.addInput(NumberInput, 10, 0);
        try db.addInput(NumberInput, 11, 0);
        const initial = try db.get(DynamicCycleA, 1);
        try testing.expectEqual(@as(u32, 0), initial.*);

        try db.setInput(NumberInput, 11, 1);
        try testing.expectError(error.QueryCycle, db.get(DynamicCycleA, 1));
        try testing.expectError(error.QueryCycle, db.get(DynamicCycleA, 1));

        try db.setInput(NumberInput, 11, 0);
        try testing.expectEqual(initial, try db.get(DynamicCycleA, 1));
        try db.setInput(NumberInput, 10, 1);
        try db.setInput(NumberInput, 11, 1);
        try testing.expectEqual(@as(u32, 1), (try db.get(DynamicCycleB, 1)).*);
    }
}

test "database initialization frees state when worker allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, Database.init(failing.allocator(), .{ .worker_count = 1 }));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "function declaration annotations validate when demanded and recover" {
    const db = try testDatabase(1);
    defer db.deinit();
    const valid = "static f = func() int -> return 7\nexit(f())";
    try addSource(db, 1, valid);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    try setSource(db, 1, "static f: func() int = func() int -> return 7\nexit(f())");
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    for ([_][]const u8{ "int", "func(int) unit" }) |annotation| {
        const source = try std.fmt.allocPrint(testing.allocator, "static f: {s} = func() int -> return 7\nexit(f())", .{annotation});
        defer testing.allocator.free(source);
        try setSource(db, 1, source);
        try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
        defer freeDiagnostics(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(DiagnosticKind.static_initializer_type_mismatch, std.meta.activeTag(diagnostics[0].kind));
    }
    try setSource(db, 1, valid);
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
    try setSource(db, 1, "static f: int = func() int -> return 7\nexit(0)");
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* != null);
}

test "expression graph preserves effects across statements arguments and selected branches" {
    const cases = [_]struct { body: []const u8, expected: u8 }{
        .{ .body = "pair(stop(11), stop(12))", .expected = 11 },
        .{ .body = "const unused = stop(21)\nstop(22)", .expected = 21 },
        .{ .body = "const selected = if 1 < 2 -> pair(1, 2) else stop(31)\nexit(selected)", .expected = 3 },
        .{ .body = "const selected = if 2 < 1 -> stop(41) else if 1 < 2 -> 42 else stop(43)\nexit(selected)", .expected = 42 },
        .{ .body = "const selected = if stop(51) < stop(52) -> stop(53) else stop(54)\nexit(selected)", .expected = 51 },
    };
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    for (cases) |case| {
        const db = try testDatabase(1);
        defer db.deinit();
        const source = try std.fmt.allocPrint(testing.allocator, "static stop = func(code: int) int\n  exit(code)\n  return 0\n" ++
            "static pair = func(a: int, b: int) int -> return a + b\n{s}", .{case.body});
        defer testing.allocator.free(source);
        try addSource(db, 1, source);
        const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
        try runtime.writeProgram(io, executable.bytes);
        try testing.expectEqual(case.expected, try runtime.runProg(io, testing.allocator, &.{}));
    }
}

test "indirect calls evaluate the callee before their arguments" {
    const db = try testDatabase(1);
    defer db.deinit();

    try addSource(db, 1,
        \\func first(value: int) int -> 1
        \\func second(value: int) int -> 2
        \\func answer() int
        \\  var operation = first
        \\  return operation(if 1 < 2
        \\    operation = second
        \\    0
        \\  else
        \\    0
        \\  )
        \\exit(answer())
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    const io = testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try runtime.writeProgram(io, executable.bytes);
    try testing.expectEqual(@as(u8, 1), try runtime.runProg(io, testing.allocator, &.{}));
}

test "redundant variant binding annotations retain typed and compiled results" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1, "static f = func(value: int | none) int | none\n  const bound = value\n  return bound");
    const item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("f").?;
    const body = try db.get(queries.AnalyzeFunctionBody, item);
    const artifact = try db.get(queries.CompileFunction, .{ .item = item });
    try setSource(db, 1, "static f = func(value: int | none) int | none\n  const bound: int | none = value\n  return bound");
    try testing.expectEqual(body, try db.get(queries.AnalyzeFunctionBody, item));
    try testing.expectEqual(artifact, try db.get(queries.CompileFunction, .{ .item = item }));
}

test "typed expression graph construction cleans up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testTypedExpressionAllocations, .{});
}

fn testTypedExpressionAllocations(gpa: std.mem.Allocator) !void {
    const db = try Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try addSource(db, 1,
        \\struct Box
        \\  copy = func(imm self: Box) Box -> Box{value = self.value}
        \\  drop = func(deinit self: Box) -> return
        \\  value: int
        \\static identity = func(value: int) int -> return value
        \\func specialize(static N: int, value: int) int
        \\  _ = N
        \\  return value
        \\static choose = func(flag: int) int | none
        \\  const box = Box{value = flag}
        \\  const copied = box
        \\  copied.value
        \\  const saved = identity(flag)
        \\  const alias: int = saved
        \\  identity(alias)
        \\  specialize(1, alias)
        \\  const selected: int | none = if saved < 0 -> if saved < -1 -> none else identity(alias) else identity(saved)
        \\  var mutable: int | none = selected
        \\  var count = 0
        \\  if saved < 0 or (if saved < -1 -> count += 1 else count += 2) < 3 -> mutable = none else mutable = identity(saved)
        \\  return loop
        \\    count += 1
        \\    if count < 2 -> continue
        \\    break mutable
    );
    const item = (try db.get(queries.BuildModuleScope, 1)).*.?.resolve("choose").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionBody, item)).* != null);
}

test "discarded spawn handles settle scalar accumulators before parent publication" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, value: Input) !Output {
            try ctx.emit(u32, value);
            return value;
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        var started: std.atomic.Value(bool) = .init(false);

        pub fn run(ctx: *Context, value: Input) !Output {
            started.store(true, .release);
            _ = try ctx.spawn(Child, value);
            return value;
        }
    };
    const db = try testDatabase(1);
    defer db.deinit();
    Parent.started.store(false, .monotonic);
    const parent = try db.spawn(Parent, 42);
    while (!Parent.started.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(u32, 42), (try parent.wait()).*);
    const emitted = try db.transitiveAccumulatorValues(Parent, 42, u32, testing.allocator);
    defer testing.allocator.free(emitted);
    try testing.expectEqualSlices(u32, &.{42}, emitted);
    try db.addInput(NumberInput, 0, 1);
}

test "failed dependency registration leaves stale queries idle and retryable" {
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        var failing: *testing.FailingAllocator = undefined;

        pub fn run(ctx: *Context, value: Input) !Output {
            failing.fail_index = failing.alloc_index;
            return (try ctx.get(CountedQuery, value)).*;
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(failing.allocator(), .{ .worker_count = 1 });
    defer db.deinit();
    Parent.failing = &failing;
    try db.addInput(NumberInput, 0, 1);
    _ = try db.get(CountedQuery, 42);
    try db.setInput(NumberInput, 0, 2);
    try testing.expectError(error.OutOfMemory, db.get(Parent, 42));
    failing.fail_index = std.math.maxInt(usize);
    try db.setInput(NumberInput, 0, 3);
    try testing.expectEqual(@as(u32, 42), (try db.get(CountedQuery, 42)).*);
}

test "static variant widening uses canonical active members and payloads" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func identity(value: int) int -> value
        \\static Plain: type = func(int) int
        \\static Checked: type = fallible(int) int
        \\static narrow: int | none = 42
        \\static wide: int | none | unit = narrow
        \\func widen() int | none | unit -> narrow
        \\static computed = widen()
        \\static callback: Checked | none = identity
        \\func inject() Checked | none -> identity
        \\static injected = inject()
        \\static original: Plain | none = identity
        \\static adapted: Checked | none | unit = original
        \\func adapt() Checked | none | unit -> original
        \\static adapted_computed = adapt()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    for ([_][2][]const u8{ .{ "wide", "computed" }, .{ "callback", "injected" }, .{ "adapted", "adapted_computed" } }) |names| {
        try testing.expectEqual(
            (try db.get(queries.ResolveStatic, scope.resolveStatic(names[0]).?)).*.?,
            (try db.get(queries.ResolveStatic, scope.resolveStatic(names[1]).?)).*.?,
        );
    }
}

test "generated namespace queries reject stale source positions" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func factory() type -> struct
        \\  value: int
        \\  func read(value: int) int -> value
        \\static S = factory()
    );
    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const ty = try resolvedStaticType(db, scope.resolveStatic("S").?);
    const identity = (try db.lookupInterned(queries.Types, ty.interned().?)).structure;
    try testing.expect((try db.get(queries.StructNamespace, identity)).* != null);
    try setSource(db, 1, "func factory() type -> int");
    try testing.expect((try db.get(queries.StructNamespace, identity)).* == null);
    try testing.expect((try db.get(queries.GeneratedStructDefinition, identity.generated)).* == null);
}

test "aggregate explicit drop retains automatic field cleanup" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Automatic
        \\  drop = func(deinit self: Automatic) -> exit(42)
        \\struct Explicit
        \\  drop = explicit
        \\struct Combined
        \\  automatic: Automatic
        \\  explicit: Explicit
        \\func consume(deinit value: Combined) -> return
        \\consume(Combined{automatic = Automatic{}, explicit = Explicit{}})
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
    try runtime.writeProgram(testing.io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(testing.io, testing.allocator, &.{}));
}

test "whole replacement does not extend the old generation past its last use" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Resource
        \\  drop = func(deinit self: Resource) -> exit(42)
        \\func intervening() -> exit(1)
        \\func answer()
        \\  var resource = Resource{}
        \\  _ = resource
        \\  intervening()
        \\  resource = Resource{}
        \\answer()
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
    try runtime.writeProgram(testing.io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(testing.io, testing.allocator, &.{}));
}

test "ownership strategies require bare strategy names" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct S
        \\  copy = missing.trivial
        \\const value = S{}
    );
    try testing.expect((try db.get(queries.BuildExecutable, 1)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 1, structures.Diagnostic, testing.allocator);
    defer freeDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(DiagnosticKind.invalid_struct_property_value, std.meta.activeTag(diagnostics[0].kind));
}

test "adding a previously missing input invalidates cached fallback results" {
    try testing.checkAllAllocationFailures(testing.allocator, testMissingInputRegistration, .{});
}

fn testMissingInputRegistration(gpa: std.mem.Allocator) !void {
    const OptionalInput = struct {
        pub const Key = u32;
        pub const Value = u32;
    };
    const ReadOptional = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = ctx.input(OptionalInput, key) catch |err| switch (err) {
                error.InputNotFound => return 0,
                else => return err,
            };
            return value.*;
        }
    };
    const db = try Database.init(gpa, .{ .worker_count = 0 });
    defer db.deinit();
    try testing.expectEqual(@as(u32, 0), (try db.get(ReadOptional, 1)).*);
    try testing.expectError(error.InputNotFound, db.setInput(OptionalInput, 1, 42));
    try db.addInput(OptionalInput, 1, 42);
    try testing.expectEqual(@as(u32, 42), (try db.get(ReadOptional, 1)).*);
    try testing.expectError(error.DuplicateInput, db.addInput(OptionalInput, 1, 5));
    try db.setInput(OptionalInput, 1, 24);
    try testing.expectEqual(@as(u32, 24), (try db.get(ReadOptional, 1)).*);
}

test "static aggregate parameters dominate every specialized branch" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\struct Pair
        \\  copy = trivial
        \\  left: int
        \\  right: int
        \\func choose(static pair: Pair, flag: int) int
        \\  if flag > 0
        \\    return pair.left
        \\  return pair.right
        \\static result = choose(Pair{left = 1, right = 21}, 0)
        \\exit(result + choose(Pair{left = 1, right = 21}, 0))
    );
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
    try runtime.writeProgram(testing.io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(testing.io, testing.allocator, &.{}));
}

test "nested generated structs discover each declaration under its own owner" {
    const db = try testDatabase(1);
    defer db.deinit();
    try addSource(db, 1,
        \\func outer(static T: type) type -> struct
        \\  func inner(static U: type) type -> struct
        \\    value: U
        \\    func answer() int -> 42
        \\  value: T
        \\static Outer = outer(int)
        \\static Inner = Outer.inner(bool)
        \\exit(Inner.answer())
    );
    const discovered = (try db.get(queries.DiscoverItems, 1)).*.?;
    try testing.expectEqual(@as(usize, 6), discovered.items.len);
    try testing.expectEqualStrings("outer", discovered.items[0].loc.name);
    try testing.expectEqualStrings("inner", discovered.items[1].loc.name);
    try testing.expectEqualStrings("answer", discovered.items[2].loc.name);
    try testing.expectEqual(@as(?u32, 0), discovered.items[1].parent);
    try testing.expectEqual(@as(?u32, 1), discovered.items[2].parent);
    const executable = (try db.get(queries.BuildExecutable, 1)).*.?;
    defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
    try runtime.writeProgram(testing.io, executable.bytes);
    try testing.expectEqual(@as(u8, 42), try runtime.runProg(testing.io, testing.allocator, &.{}));
}

test "handled child failures recompute without publishing stale accumulators" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = (try ctx.input(NumberInput, key)).*;
            if (value == 0) return error.NotAvailable;
            try ctx.emit(u32, value);
            return value;
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = ctx.get(Child, key) catch |err| switch (err) {
                error.NotAvailable => return 0,
                else => return err,
            };
            return value.*;
        }
    };
    const db = try testDatabase(1);
    defer db.deinit();
    try db.addInput(NumberInput, 0, 42);
    try db.addInput(NumberInput, 1, 0);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    try db.setInput(NumberInput, 0, 0);
    try testing.expectEqual(@as(u32, 0), (try db.get(Parent, 0)).*);
    const accumulated = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
    defer testing.allocator.free(accumulated);
    try testing.expectEqual(@as(usize, 0), accumulated.len);
    try db.setInput(NumberInput, 1, 1);
    try testing.expectEqual(@as(u32, 0), (try db.get(Parent, 0)).*);
    try db.setInput(NumberInput, 0, 42);
    try testing.expectEqual(@as(u32, 42), (try db.get(Child, 0)).*);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    const recovered = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
    defer testing.allocator.free(recovered);
    try testing.expectEqualSlices(u32, &.{42}, recovered);
}
