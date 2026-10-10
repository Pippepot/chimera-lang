const std = @import("std");
const test_sources = @import("test_sources");
const structures = test_sources.structures;
const interpreter = test_sources.comptime_interpreter;
const modules = test_sources.modules;
const query = test_sources.query;
const queries = test_sources.queries;
const Value = interpreter.Value;
const Cell = interpreter.Cell;
const Result = interpreter.Result;
const ExecutionErrorReason = interpreter.ExecutionErrorReason;
const execute = interpreter.execute;
const executeInStorage = interpreter.executeInStorage;
const assignCell = interpreter.assignCell;
const referenceValue = interpreter.referenceValue;
const referenceTarget = interpreter.referenceTarget;
const ValueSnapshot = interpreter.ValueSnapshot;

const ArrayTestExecutor = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(structures.CompileTimeValue.Runtime) = .empty,
    tuples: std.ArrayList([]const structures.CompileTimeValueId) = .empty,
    callee: ?*const structures.FunctionBodyAnalysis = null,

    fn deinit(self: *@This()) void {
        for (self.tuples.items) |tuple| self.allocator.free(tuple);
        self.tuples.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn arrayType(_: *@This(), type_id: structures.TypeId) !?structures.ArrayType {
        return switch (@backingInt(type_id)) {
            100 => .{ .element_type = .int, .length = 3 },
            101 => .{ .element_type = @fromBackingInt(@intCast(100)), .length = 2 },
            102 => .{ .element_type = .int, .length = 0 },
            else => null,
        };
    }

    pub fn call(_: *@This(), _: structures.InstanceId, _: []Value, _: ?structures.SourceSpan) !Result {
        unreachable;
    }

    pub fn convertStaticValue(_: *@This(), _: structures.TypeId, _: structures.CompileTimeValue.RuntimeValue, _: structures.TypeId, _: ?structures.SourceSpan, _: std.mem.Allocator) !Result {
        unreachable;
    }

    pub fn callInStorage(self: *@This(), _: structures.InstanceId, arguments: []Value, _: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!Result {
        std.debug.assert(arguments[0] == .place);
        return executeInStorage(self.callee.?, arguments, self, self.allocator, storage);
    }

    pub fn structFieldCount(_: *@This(), _: structures.TypeId) !?usize {
        return null;
    }

    pub fn structFieldType(_: *@This(), _: structures.TypeId, _: usize) !?structures.TypeId {
        return null;
    }

    pub fn argumentPassing(_: *@This(), type_id: structures.TypeId) !structures.ArgumentPassing {
        return if (@backingInt(type_id) >= 100 and @backingInt(type_id) <= 102) .indirect else .direct;
    }

    pub fn variantMembers(_: *@This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }

    pub fn internRuntime(self: *@This(), type_id: structures.TypeId, value: structures.CompileTimeValue.RuntimeValue) !structures.CompileTimeValueId {
        const value_id: structures.CompileTimeValueId = @fromBackingInt(@intCast(self.values.items.len));
        try self.values.append(self.allocator, .{ .type_id = type_id, .value = value });
        return value_id;
    }

    pub fn lookupRuntime(self: *@This(), value_id: structures.CompileTimeValueId) !?structures.CompileTimeValue.Runtime {
        return self.values.items[@backingInt(value_id)];
    }

    pub fn internTuple(self: *@This(), values: []const structures.CompileTimeValueId) !structures.CompileTimeValueTupleId {
        const tuple_id: structures.CompileTimeValueTupleId = @fromBackingInt(@intCast(self.tuples.items.len));
        const tuple = try self.allocator.dupe(structures.CompileTimeValueId, values);
        errdefer self.allocator.free(tuple);
        try self.tuples.append(self.allocator, tuple);
        return tuple_id;
    }

    pub fn lookupTuple(self: *@This(), tuple_id: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
        return self.tuples.items[@backingInt(tuple_id)];
    }
};

test "interpreter value snapshots compare reference identity and frozen contents" {
    var session_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer session_arena.deinit();
    const storage = session_arena.allocator();
    var snapshot_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer snapshot_arena.deinit();
    const snapshot_storage = snapshot_arena.allocator();
    var executor: ArrayTestExecutor = .{ .allocator = std.testing.allocator };
    defer executor.deinit();
    var target: Cell = .{ .type_id = .int, .storage = storage, .contents = .{ .value = .{ .int = 17 } } };
    var other: Cell = target;
    var arguments = [_]Value{try referenceValue(@fromBackingInt(@intCast(103)), &target, storage)};
    const original_reference = arguments[0];
    const original = try ValueSnapshot.init(&arguments, snapshot_storage);
    arguments[0] = try referenceValue(@fromBackingInt(@intCast(103)), &target, storage);
    const repeated = try ValueSnapshot.init(&arguments, snapshot_storage);
    try std.testing.expect(try original.eql(repeated, std.testing.allocator));
    try std.testing.expectEqual(@as(i32, 17), original.values[0].place.contents.reference.contents.value.int);

    try assignCell(&target, .{ .runtime = .{ .int = 42 } }, &executor);
    const changed = try ValueSnapshot.init(&arguments, snapshot_storage);
    try std.testing.expect(!try original.eql(changed, std.testing.allocator));
    try std.testing.expectEqual(@as(i32, 17), original.values[0].place.contents.reference.contents.value.int);
    try std.testing.expect(referenceTarget(original_reference).? == &target);
    try std.testing.expectEqual(@as(i32, 42), referenceTarget(original_reference).?.contents.value.int);

    try assignCell(&target, .{ .runtime = .{ .int = 17 } }, &executor);
    const restored = try ValueSnapshot.init(&arguments, snapshot_storage);
    try std.testing.expect(try original.eql(restored, std.testing.allocator));
    arguments[0] = try referenceValue(@fromBackingInt(@intCast(103)), &other, storage);
    const retargeted = try ValueSnapshot.init(&arguments, snapshot_storage);
    try std.testing.expect(!try original.eql(retargeted, std.testing.allocator));

    const scalar_place = try ValueSnapshot.init(&.{.{ .place = &target }}, snapshot_storage);
    const scalar_value = try ValueSnapshot.init(&.{.{ .runtime = .{ .int = 17 } }}, snapshot_storage);
    try std.testing.expect(try scalar_place.eql(scalar_value, std.testing.allocator));
}

test "interpreter value snapshots preserve unfinished cyclic fields variants and initializer captures" {
    try expectCyclicSnapshots(std.testing.allocator);
}

test "interpreter snapshot allocation failures release cloning and comparison storage" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(test_sources.allocation_failure_allocator, expectCyclicSnapshots, .{});
}

fn expectCyclicSnapshots(allocator: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    const body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .parameter_modes = &.{},
        .block_arguments = &.{},
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &.{},
        .blocks = &.{},
        .entry = @fromBackingInt(@intCast(0)),
    };
    var other_body = body;
    other_body.return_type = .int;
    var captured: Cell = .{ .type_id = .int, .storage = storage, .contents = .{ .value = .{ .int = 31 } } };
    var fields: [3]Cell = undefined;
    var aggregate: Cell = .{ .type_id = @fromBackingInt(@intCast(100)), .storage = storage, .contents = .{ .fields = &fields } };
    var variant: Cell = .{ .type_id = @fromBackingInt(@intCast(102)), .storage = storage, .contents = .{ .variant_payload = &aggregate } };
    fields = .{
        .{ .type_id = .int, .storage = storage, .contents = .uninitialized },
        .{ .type_id = @fromBackingInt(@intCast(103)), .storage = storage, .contents = .{ .reference = &variant } },
        .{ .type_id = .int, .storage = storage, .contents = .{ .value = .{ .int = 17 } } },
    };
    var inner_captures = [_]Value{ .{ .place = &captured }, .{ .type = .int } };
    var captures = [_]Value{
        .{ .place = &variant },
        .{ .initializer = .{ .body = &body, .captures = &inner_captures } },
    };
    var arguments = [_]Value{
        .{ .place = &fields[1] },
        .{ .place = &variant },
        .{ .initializer = .{ .body = &body, .captures = &captures } },
    };
    const original = try ValueSnapshot.init(&arguments, storage);
    const repeated = try ValueSnapshot.init(&arguments, storage);
    const original_capture = try ValueSnapshot.init(arguments[2..], storage);
    try std.testing.expect(try original.eql(repeated, allocator));
    const saved_fields = original.values[1].place.contents.variant_payload.contents.fields;
    try std.testing.expect(saved_fields[0].contents == .uninitialized);
    try std.testing.expect(saved_fields[1].contents == .reference);
    try std.testing.expectEqual(@as(i32, 17), saved_fields[2].contents.value.int);
    try std.testing.expect(original.values[0].place.contents.reference == original.values[1].place);

    fields[0].contents = .{ .value = .{ .int = 23 } };
    const finished = try ValueSnapshot.init(&arguments, storage);
    try std.testing.expect(!try original.eql(finished, allocator));
    try std.testing.expect(saved_fields[0].contents == .uninitialized);
    fields[0].contents = .uninitialized;
    captured.contents.value = .{ .int = 42 };
    const changed_capture = try ValueSnapshot.init(arguments[2..], storage);
    try std.testing.expect(!try original_capture.eql(changed_capture, allocator));
    try std.testing.expectEqual(@as(i32, 31), original_capture.values[0].initializer.captures[1].initializer.captures[0].place.contents.value.int);
    captured.contents.value = .{ .int = 31 };
    captures[1].initializer.body = &other_body;
    const changed_body = try ValueSnapshot.init(&arguments, storage);
    try std.testing.expect(!try original.eql(changed_body, allocator));
}

test "interpreter snapshots preserve aliases and detect changes across large cyclic arrays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    const fields = try storage.alloc(Cell, 4096);
    for (fields) |*field| field.* = .{ .type_id = .int, .storage = storage, .contents = .{ .value = .{ .int = 17 } } };
    var array: Cell = .{ .type_id = @fromBackingInt(@intCast(100)), .storage = storage, .contents = .{ .fields = fields } };
    fields[0] = .{ .type_id = @fromBackingInt(@intCast(103)), .storage = storage, .contents = .{ .reference = &array } };
    fields[1] = .{ .type_id = @fromBackingInt(@intCast(103)), .storage = storage, .contents = .{ .reference = &fields[fields.len - 1] } };
    const arguments = [_]Value{ .{ .place = &fields[0] }, .{ .place = &array } };
    const original = try ValueSnapshot.init(&arguments, storage);
    const repeated = try ValueSnapshot.init(&arguments, storage);
    try std.testing.expect(try original.eql(repeated, std.testing.allocator));
    const saved_fields = original.values[1].place.contents.fields;
    try std.testing.expect(saved_fields[0].contents.reference == original.values[1].place);
    try std.testing.expect(saved_fields[1].contents.reference == &saved_fields[saved_fields.len - 1]);

    fields[fields.len - 1].contents.value.int = 42;
    const changed = try ValueSnapshot.init(&arguments, storage);
    try std.testing.expect(!try original.eql(changed, std.testing.allocator));
    try std.testing.expectEqual(@as(i32, 17), saved_fields[saved_fields.len - 1].contents.value.int);
    fields[fields.len - 1].contents.value.int = 17;
    fields[1].contents.reference = &fields[fields.len - 2];
    const retargeted = try ValueSnapshot.init(&arguments, storage);
    try std.testing.expect(!try original.eql(retargeted, std.testing.allocator));
}

test "interpreter call cycles reject unchanged references and allow changed referents" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, allocator,
        \\import std.memory.{borrow_local}
        \\import std.array.{Array}
        \\func repeat(imm reference: Ref(int, false)) int -> repeat(reference)
        \\func unchanged() int
        \\    const value = 17
        \\    return repeat(borrow_local(int, value))
        \\func advance(imm reference: Ref(int, true)) int
        \\    if reference[] == 0 -> return 42
        \\    reference.replace(reference[] - 1)
        \\    return advance(reference)
        \\func changing() int
        \\    var values = Array(int, 1).filled(3)
        \\    if const reference = values.get_mut(0) -> return advance(reference)
        \\    return 90
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const arguments = try db.intern(queries.CompileTimeValueTuples, .{ .values = &.{} });
    const repeated_call: queries.ExecuteComptimeCall.Input = .{
        .instance = .{ .item = scope.resolveFunction("unchanged").? },
        .arguments = arguments,
    };
    const repeated = (try db.get(queries.ExecuteComptimeCall, repeated_call)).*.?;
    try std.testing.expect(repeated == .execution_error);
    const diagnostics = try db.transitiveAccumulatorValues(queries.ExecuteComptimeCall, repeated_call, structures.Diagnostic, allocator);
    defer allocator.free(diagnostics);
    var has_cycle = false;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .compile_time_call_cycle) has_cycle = true;
    }
    try std.testing.expect(has_cycle);
    const changed = (try db.get(queries.ExecuteComptimeCall, .{
        .instance = .{ .item = scope.resolveFunction("changing").? },
        .arguments = arguments,
    })).*.?;
    try std.testing.expect(changed == .completed);
    try std.testing.expect(changed.completed.outcome == .returned);
    const value = (try db.lookupInterned(queries.CompileTimeValues, changed.completed.outcome.returned)).*;
    try std.testing.expectEqual(@as(i32, 42), value.runtime.value.int);
}

test "interpreter arrays fill through counted CFG and publish aggregate tuples" {
    var executor: ArrayTestExecutor = .{ .allocator = std.testing.allocator };
    defer executor.deinit();
    for ([_]structures.TypeId{ @fromBackingInt(@intCast(100)), @fromBackingInt(@intCast(102)) }) |type_id| {
        const array = (try executor.arrayType(type_id)).?;
        var instructions = [_]structures.FunctionInstruction{
            .{ .local_storage = type_id },
            .{ .const_int = 0 },
            .{ .const_int = @intCast(array.length) },
            .{ .const_int = 1 },
            .{ .const_int = 17 },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(1)), .index = @fromBackingInt(@intCast(0)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(5)), .destination = @fromBackingInt(@intCast(6)), .type_id = .int } },
            .{ .addi = .{ .lhs = @fromBackingInt(@intCast(0)), .rhs = @fromBackingInt(@intCast(4)) } },
        };
        var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int }};
        var branch_arguments = [_]structures.FunctionValueUse{ .{ .value = @fromBackingInt(@intCast(2)) }, .{ .value = @fromBackingInt(@intCast(8)) } };
        var blocks = [_]structures.FunctionBlock{
            .{ .instruction_start = 0, .instruction_end = 5, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 1 } } } },
            .{ .argument_end = 1, .instruction_start = 5, .instruction_end = 5, .terminator = .{ .predicate_branch = .{
                .operation = .lti,
                .operands = .{ .lhs = @fromBackingInt(@intCast(0)), .rhs = @fromBackingInt(@intCast(3)) },
                .then_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } },
                .else_branch = .{ .target = @fromBackingInt(@intCast(3)), .arguments = .{ .start = 0, .end = 0 } },
            } } },
            .{ .instruction_start = 5, .instruction_end = 8, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 1, .end = 2 } } } },
            .{ .instruction_start = 8, .instruction_end = 8, .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(1)) } } },
        };
        const body: structures.FunctionBodyAnalysis = .{ .return_type = type_id, .parameter_modes = &.{}, .block_arguments = &block_arguments, .branch_arguments = &branch_arguments, .call_arguments = &.{}, .instructions = &instructions, .blocks = &blocks, .entry = @fromBackingInt(@intCast(0)) };
        var arguments: [0]Value = .{};
        const result = try execute(&body, &arguments, &executor, std.testing.allocator);
        try std.testing.expect(result == .returned);
        const elements = try executor.lookupTuple(result.returned.runtime.structure);
        try std.testing.expectEqual(@as(usize, array.length), elements.len);
        for (elements) |element| {
            const value = (try executor.lookupRuntime(element)).?;
            try std.testing.expectEqual(structures.TypeId.int, value.type_id);
            try std.testing.expectEqual(@as(i32, 17), value.value.int);
        }
    }
}

test "interpreter array references survive nested calls and cannot be published" {
    const array_type: structures.TypeId = @fromBackingInt(@intCast(100));
    const reference_type: structures.TypeId = @fromBackingInt(@intCast(103));
    var callee_instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 0 },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(1)), .type_id = .int } },
        .{ .borrow_address = .{ .source = @fromBackingInt(@intCast(2)), .type_id = reference_type } },
    };
    var modes = [_]structures.ParameterMode{.imm};
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = array_type, .representation = .storage }};
    var callee_blocks = [_]structures.FunctionBlock{.{ .argument_end = 1, .instruction_start = 0, .instruction_end = 3, .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(3)) } } }};
    const callee: structures.FunctionBodyAnalysis = .{ .return_type = reference_type, .parameter_modes = &modes, .block_arguments = &block_arguments, .branch_arguments = &.{}, .call_arguments = &.{}, .instructions = &callee_instructions, .blocks = &callee_blocks, .entry = @fromBackingInt(@intCast(0)) };
    var instructions = [_]structures.FunctionInstruction{
        .{ .local_storage = array_type },
        .{ .const_int = 0 },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(1)), .type_id = .int } },
        .{ .const_int = 17 },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(3)), .destination = @fromBackingInt(@intCast(2)), .type_id = .int } },
        .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(@intCast(0)) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = reference_type } },
        .{ .const_int = 42 },
        .{ .borrow_write = .{ .reference = @fromBackingInt(@intCast(5)), .value = @fromBackingInt(@intCast(6)), .type_id = .int } },
        .{ .borrow_read = .{ .source = @fromBackingInt(@intCast(5)), .type_id = .int } },
    };
    var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(@intCast(0)) } }};
    var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(8)) } } }};
    var body: structures.FunctionBodyAnalysis = .{ .return_type = .int, .parameter_modes = &.{}, .block_arguments = &.{}, .branch_arguments = &.{}, .call_arguments = &call_arguments, .instructions = &instructions, .blocks = &blocks, .entry = @fromBackingInt(@intCast(0)) };
    var executor: ArrayTestExecutor = .{ .allocator = std.testing.allocator, .callee = &callee };
    defer executor.deinit();
    var arguments: [0]Value = .{};
    const result = try execute(&body, &arguments, &executor, std.testing.allocator);
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(i32, 42), result.returned.runtime.int);
    body.return_type = reference_type;
    blocks[0].terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(5)) } };
    const escaping = try execute(&body, &arguments, &executor, std.testing.allocator);
    try std.testing.expect(escaping == .execution_error);
    try std.testing.expectEqual(ExecutionErrorReason.unsupported_operation, escaping.execution_error.reason);
}

test "interpreter nested array copies retain destination cells and rehydrate tuples" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    var executor: ArrayTestExecutor = .{ .allocator = std.testing.allocator };
    defer executor.deinit();
    var source: Cell = .{ .type_id = @fromBackingInt(@intCast(101)), .storage = storage, .contents = .uninitialized };
    var arguments = [_]Value{.{ .place = &source }};
    var modes = [_]structures.ParameterMode{.imm};
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = source.type_id, .representation = .storage }};
    var instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .{ .const_int = 2 },
        .{ .const_int = 17 },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(1)), .type_id = @fromBackingInt(@intCast(100)) } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(2)), .type_id = @fromBackingInt(@intCast(100)) } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(5)), .index = @fromBackingInt(@intCast(1)), .type_id = .int } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(5)), .index = @fromBackingInt(@intCast(2)), .type_id = .int } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(5)), .index = @fromBackingInt(@intCast(3)), .type_id = .int } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(6)), .index = @fromBackingInt(@intCast(1)), .type_id = .int } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(6)), .index = @fromBackingInt(@intCast(2)), .type_id = .int } },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(6)), .index = @fromBackingInt(@intCast(3)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(7)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(8)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(9)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(10)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(11)), .type_id = .int } },
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .destination = @fromBackingInt(@intCast(12)), .type_id = .int } },
    };
    var blocks = [_]structures.FunctionBlock{.{ .argument_end = 1, .instruction_start = 0, .instruction_end = instructions.len, .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(0)) } } }};
    var body: structures.FunctionBodyAnalysis = .{ .return_type = source.type_id, .parameter_modes = &modes, .block_arguments = &block_arguments, .branch_arguments = &.{}, .call_arguments = &.{}, .instructions = &instructions, .blocks = &blocks, .entry = @fromBackingInt(@intCast(0)) };
    const result = try executeInStorage(&body, &arguments, &executor, std.testing.allocator, storage);
    try std.testing.expect(result == .returned);
    const runtime = result.returned.runtime;
    var destination: Cell = .{ .type_id = source.type_id, .storage = storage, .contents = .uninitialized };
    try assignCell(&destination, .{ .place = &source }, &executor);
    const target = &destination.contents.fields[0].contents.fields[1];
    const reference = try referenceValue(@fromBackingInt(@intCast(103)), target, storage);
    try assignCell(target, .{ .runtime = .{ .int = 42 } }, &executor);
    try std.testing.expectEqual(@as(i32, 17), source.contents.fields[0].contents.fields[1].contents.value.int);
    try assignCell(&destination, .{ .runtime = runtime }, &executor);
    try std.testing.expect(referenceTarget(reference).? == target);
    try std.testing.expectEqual(@as(i32, 17), target.contents.value.int);
    var hydrated: Cell = .{ .type_id = source.type_id, .storage = storage, .contents = .{ .value = runtime } };
    arguments[0] = .{ .place = &hydrated };
    body.return_type = .unit;
    body.instructions = instructions[0..12];
    blocks[0].instruction_end = @intCast(body.instructions.len);
    blocks[0].terminator = .return_unit;
    const hydration = try executeInStorage(&body, &arguments, &executor, std.testing.allocator, storage);
    try std.testing.expect(hydration == .returned);
    try std.testing.expectEqual(@as(usize, 2), hydrated.contents.fields.len);
    for (hydrated.contents.fields) |array| {
        try std.testing.expectEqual(@as(structures.TypeId, @fromBackingInt(@intCast(100))), array.type_id);
        try std.testing.expectEqual(@as(usize, 3), array.contents.fields.len);
        for (array.contents.fields) |element| try std.testing.expectEqual(@as(i32, 17), element.contents.value.int);
    }
    arguments[0] = reference;
    block_arguments[0].type_id = @fromBackingInt(@intCast(103));
    body.return_type = block_arguments[0].type_id;
    body.instructions = &.{};
    blocks[0].instruction_end = 0;
    blocks[0].terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(0)) } };
    const escaping = try execute(&body, &arguments, &executor, std.testing.allocator);
    try std.testing.expect(escaping == .execution_error);
    try std.testing.expectEqual(ExecutionErrorReason.unsupported_operation, escaping.execution_error.reason);
}

test "initializer capture cell subtrees survive the constructing region storage" {
    const outer_type: structures.TypeId = @fromBackingInt(@intCast(100));
    const nested_type: structures.TypeId = @fromBackingInt(@intCast(101));
    const variant_type: structures.TypeId = @fromBackingInt(@intCast(102));
    const Executor = struct {
        pub fn convertStaticValue(_: *@This(), _: structures.TypeId, _: structures.CompileTimeValue.RuntimeValue, _: structures.TypeId, _: ?structures.SourceSpan, _: std.mem.Allocator) !Result {
            unreachable;
        }
        pub fn call(_: *@This(), _: structures.InstanceId, _: []Value, _: ?structures.SourceSpan) !Result {
            unreachable;
        }
        pub fn callInStorage(self: *@This(), instance: structures.InstanceId, arguments: []Value, span: ?structures.SourceSpan, _: std.mem.Allocator) !Result {
            return self.call(instance, arguments, span);
        }
        pub fn arrayType(_: *@This(), _: structures.TypeId) !?structures.ArrayType {
            return null;
        }
        pub fn structFieldCount(_: *@This(), type_id: structures.TypeId) !?usize {
            return if (type_id == outer_type or type_id == nested_type) 1 else null;
        }
        pub fn structFieldType(_: *@This(), type_id: structures.TypeId, index: usize) !?structures.TypeId {
            if (index != 0) return null;
            return if (type_id == outer_type) nested_type else if (type_id == nested_type) .int else null;
        }
        pub fn lookupTuple(_: *@This(), tuple: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
            return if (@backingInt(tuple) == 0) &.{@fromBackingInt(@intCast(0))} else &.{@fromBackingInt(@intCast(1))};
        }
        pub fn lookupRuntime(_: *@This(), value: structures.CompileTimeValueId) !?structures.CompileTimeValue.Runtime {
            return if (@backingInt(value) == 0)
                .{ .type_id = nested_type, .value = .{ .structure = @fromBackingInt(@intCast(1)) } }
            else
                .{ .type_id = .int, .value = .{ .int = 17 } };
        }
        pub fn internRuntime(_: *@This(), _: structures.TypeId, _: structures.CompileTimeValue.RuntimeValue) !structures.CompileTimeValueId {
            unreachable;
        }
        pub fn internTuple(_: *@This(), _: []const structures.CompileTimeValueId) !structures.CompileTimeValueTupleId {
            unreachable;
        }
        pub fn variantMembers(_: *@This(), _: structures.TypeId) !?[]const structures.TypeId {
            return null;
        }
        pub fn argumentPassing(_: *@This(), _: structures.TypeId) !structures.ArgumentPassing {
            unreachable;
        }
    };
    var owner_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer owner_arena.deinit();
    const owner_storage = owner_arena.allocator();
    var executor: Executor = .{};
    for ([_]bool{ false, true }) |variant| for ([_]bool{ false, true }) |initialized| {
        const cell = try owner_storage.create(Cell);
        cell.* = .{ .type_id = if (variant) variant_type else outer_type, .storage = owner_storage, .contents = .uninitialized };
        if (initialized) cell.contents = .{ .value = if (variant)
            .{ .variant = .{ .member_type = nested_type, .payload = @fromBackingInt(@intCast(0)) } }
        else
            .{ .structure = @fromBackingInt(@intCast(0)) } };
        var arguments = [_]Value{.{ .place = cell }};
        var parameters = [_]structures.ParameterMode{.imm};
        var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = cell.type_id, .representation = .storage }};
        var instructions = [_]structures.FunctionInstruction{
            .{ .storage_projection = .{ .owner = @fromBackingInt(@intCast(0)), .type_id = nested_type, .projection = if (variant) .variant else .{ .field = 0 } } },
            .{ .storage_projection = .{ .owner = @fromBackingInt(@intCast(1)), .type_id = .int, .projection = .{ .field = 0 } } },
            .{ .const_int = 42 },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(3)), .destination = @fromBackingInt(@intCast(2)), .type_id = .int } },
        };
        var blocks = [_]structures.FunctionBlock{.{ .argument_start = 0, .argument_end = 1, .instruction_start = 0, .instruction_end = instructions.len, .terminator = .return_unit }};
        const body: structures.FunctionBodyAnalysis = .{ .return_type = .unit, .is_initializer_region = true, .parameter_modes = &parameters, .block_arguments = &block_arguments, .branch_arguments = &.{}, .call_arguments = &.{}, .instructions = &instructions, .blocks = &blocks, .entry = @fromBackingInt(@intCast(0)) };
        var region_bytes: [8192]u8 = undefined;
        var region_storage: std.heap.FixedBufferAllocator = .init(&region_bytes);
        const result = try execute(&body, &arguments, &executor, region_storage.allocator());
        try std.testing.expect(result == .returned);
        try std.testing.expect(result.returned.runtime == .unit);
        @memset(&region_bytes, 0);
        const nested = if (variant) cell.contents.variant_payload else &cell.contents.fields[0];
        try std.testing.expect(nested.contents == .fields);
        try std.testing.expectEqual(@as(i32, 42), nested.contents.fields[0].contents.value.int);
    };
}

test "fallible initializer calls route ordinary failure without a value" {
    const Executor = struct {
        pub fn convertStaticValue(_: *@This(), _: structures.TypeId, _: structures.CompileTimeValue.RuntimeValue, _: structures.TypeId, _: ?structures.SourceSpan, _: std.mem.Allocator) !Result {
            unreachable;
        }
        pub fn call(_: *@This(), _: structures.InstanceId, _: []Value, _: ?structures.SourceSpan) !Result {
            unreachable;
        }
        pub fn callInStorage(self: *@This(), instance: structures.InstanceId, arguments: []Value, span: ?structures.SourceSpan, _: std.mem.Allocator) !Result {
            return self.call(instance, arguments, span);
        }
        pub fn arrayType(_: *@This(), _: structures.TypeId) !?structures.ArrayType {
            return null;
        }
        pub fn structFieldType(_: *@This(), _: structures.TypeId, _: usize) !?structures.TypeId {
            return null;
        }
        pub fn structFieldCount(_: *@This(), _: structures.TypeId) !?usize {
            unreachable;
        }
        pub fn lookupTuple(_: *@This(), _: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
            unreachable;
        }
        pub fn lookupRuntime(_: *@This(), _: structures.CompileTimeValueId) !?structures.CompileTimeValue.Runtime {
            unreachable;
        }
        pub fn internRuntime(_: *@This(), _: structures.TypeId, _: structures.CompileTimeValue.RuntimeValue) !structures.CompileTimeValueId {
            unreachable;
        }
        pub fn internTuple(_: *@This(), _: []const structures.CompileTimeValueId) !structures.CompileTimeValueTupleId {
            unreachable;
        }
        pub fn variantMembers(_: *@This(), _: structures.TypeId) !?[]const structures.TypeId {
            unreachable;
        }
        pub fn argumentPassing(_: *@This(), _: structures.TypeId) !structures.ArgumentPassing {
            unreachable;
        }
    };
    var executor: Executor = .{};
    var region_blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = 0, .terminator = .return_failure }};
    const region: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .is_fallible = true,
        .is_initializer_region = true,
        .parameter_modes = &.{},
        .block_arguments = &.{},
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &.{},
        .blocks = &region_blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };
    var arguments = [_]Value{.{ .initializer = .{ .body = &region, .captures = &.{} } }};
    var modes = [_]structures.ParameterMode{.init};
    var block_arguments = [_]structures.FunctionBlockArgument{
        .{ .type_id = .int, .representation = .initializer },
        .{ .type_id = .int },
    };
    var blocks = [_]structures.FunctionBlock{
        .{ .argument_end = 1, .instruction_start = 0, .instruction_end = 0, .terminator = .{ .fallible_call = .{
            .call = .{ .target = .{ .initializer = @fromBackingInt(@intCast(0)) }, .arguments = .{ .start = 0, .end = 0 }, .return_type = .int },
            .success = @fromBackingInt(@intCast(1)),
            .failure = @fromBackingInt(@intCast(2)),
        } } },
        .{ .argument_start = 1, .argument_end = 2, .instruction_start = 0, .instruction_end = 0, .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(1)) } } },
        .{ .argument_start = 2, .argument_end = 2, .instruction_start = 0, .instruction_end = 0, .terminator = .return_failure },
    };
    const body: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .is_fallible = true,
        .parameter_modes = &modes,
        .block_arguments = &block_arguments,
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &.{},
        .blocks = &blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };
    const result = try execute(&body, &arguments, &executor, std.testing.allocator);
    try std.testing.expect(result == .failure);
}

test "explicit fail evaluates in direct nested and initializer calls" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, allocator,
        \\fallible fail_value() int -> fail
        \\fallible nested() int -> fail_value?()
        \\fallible materialize(init item: int) int -> return item
        \\fallible initialized() int -> materialize?(if true == true -> fail else 0)
        \\func handled() int -> if const value = initialized() -> value else 42
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const arguments = try db.intern(queries.CompileTimeValueTuples, .{ .values = &.{} });
    for ([_][]const u8{ "fail_value", "nested", "initialized", "handled" }) |name| {
        const result = (try db.get(queries.ExecuteComptimeCall, .{
            .instance = .{ .item = scope.resolveFunction(name).? },
            .arguments = arguments,
        })).*.?;
        try std.testing.expect(result == .completed);
        if (std.mem.eql(u8, name, "handled")) {
            try std.testing.expect(result.completed.outcome == .returned);
            const value = (try db.lookupInterned(queries.CompileTimeValues, result.completed.outcome.returned)).*;
            try std.testing.expectEqual(@as(i32, 42), value.runtime.value.int);
        } else try std.testing.expect(result.completed.outcome == .failure);
    }
}
