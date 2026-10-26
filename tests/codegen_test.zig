const std = @import("std");
const test_sources = @import("test_sources");
const codegen = test_sources.codegen;
const runtime = test_sources.runtime;
const structures = test_sources.structures;
const allocation_failure_allocator = test_sources.allocation_failure_allocator;

test "in-place loop arithmetic preserves wrapping and operand order" {
    try test_sources.SourceFixture.expectParity(
        \\func calculate(seed: int) int
        \\    var value = seed
        \\    var index = 0
        \\    loop
        \\        if index == 3 -> break
        \\        value *= 3
        \\        value += 1000
        \\        value -= 1000
        \\        value = index + value
        \\        value -= index
        \\        index += 1
        \\    return value
        \\func run() int -> calculate(1) + calculate(2147483647) - calculate(2147483647) + 15
    , 42);
}

test "loop registers preserve parallel copies spills and values across calls" {
    const source =
        \\func called(number: int) int
        \\    var value = number
        \\    var index = 0
        \\    loop
        \\        if index == 3 -> break
        \\        value += 1
        \\        index += 1
        \\    return value
        \\func run() int
        \\    var a = 1
        \\    var b = 2
        \\    var c = 3
        \\    var d = 4
        \\    var e = 5
        \\    var f = 6
        \\    var g = 7
        \\    var h = 8
        \\    var index = 0
        \\    var sum = 0
        \\    loop
        \\        if index == 6 -> break
        \\        const previous = a
        \\        a = b
        \\        b = c
        \\        c = d
        \\        d = e
        \\        e = f
        \\        f = g
        \\        g = h
        \\        h = previous
        \\        sum += called(index)
        \\        index += 1
        \\    return sum + a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h - 147
    ;
    try test_sources.SourceFixture.expectParity(source, 42);
    const fixture = try test_sources.SourceFixture.init(source ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
}

const small_variant = structures.TypeId.fromInterned(@fromBackingInt(@intCast(0)));
const wide_variant = structures.TypeId.fromInterned(@fromBackingInt(@intCast(1)));
const seven_byte_payload = structures.TypeId.fromInterned(@fromBackingInt(@intCast(2)));
const payload_variant = structures.TypeId.fromInterned(@fromBackingInt(@intCast(3)));
const callable_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(4)));
const byte_reference_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(5)));

const TestTypes = struct {
    data: []const u8 = "a*",
    pub fn byteString(self: @This(), _: structures.ByteStringId) ![]const u8 {
        return self.data;
    }
    pub fn storageCursorAccess(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn staticStringBytes(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn layout(_: @This(), type_id: structures.TypeId) !structures.TypeLayout {
        if (type_id == .byte) return .{ .byte_size = 1, .byte_alignment = 1 };
        if (type_id == byte_reference_type) return .{ .byte_size = 8, .byte_alignment = 8 };
        if (type_id == .int or type_id == .bool) return .{ .byte_size = 4, .byte_alignment = 4 };
        if (type_id == .unit or type_id == .none or type_id == .never) return .{ .byte_size = 0, .byte_alignment = 1 };
        if (type_id == small_variant or type_id == wide_variant) return .{ .byte_size = 8, .byte_alignment = 4 };
        if (type_id == seven_byte_payload) return .{ .byte_size = 7, .byte_alignment = 1 };
        if (type_id == payload_variant) return .{ .byte_size = 12, .byte_alignment = 4 };
        if (type_id == callable_type) return .{ .byte_size = 8, .byte_alignment = 8 };
        unreachable;
    }

    pub fn variantLayout(self: @This(), type_id: structures.TypeId) !structures.VariantLayout {
        std.debug.assert(try self.variantMembers(type_id) != null);
        return .{ .layout = try self.layout(type_id), .payload_offset = 4 };
    }

    pub fn structLayout(_: @This(), _: structures.TypeId) !?structures.StructLayout {
        return null;
    }

    pub fn structDefinition(_: @This(), _: structures.TypeId) !?structures.StructDefinition {
        return null;
    }

    pub fn arrayType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
        return null;
    }

    pub fn borrowElement(_: @This(), type_id: structures.TypeId) !?structures.TypeId {
        return if (type_id == byte_reference_type) structures.TypeId.byte else null;
    }

    pub fn storageAccess(_: @This(), type_id: structures.TypeId) !?structures.TypeId {
        return if (type_id == byte_reference_type) .byte else null;
    }

    pub fn argumentPassing(_: @This(), _: structures.TypeId) !structures.ArgumentPassing {
        return .direct;
    }

    pub fn variantMembers(_: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
        if (type_id == small_variant) return &.{ .int, .none };
        if (type_id == wide_variant) return &.{ .int, .unit, .none };
        if (type_id == payload_variant) return &.{ .none, seven_byte_payload };
        return null;
    }

    pub fn callable(_: @This(), type_id: structures.TypeId) !?structures.CallableType {
        return if (type_id == callable_type)
            .{ .parameters = &.{}, .return_type = .int }
        else
            null;
    }
};

fn integerConstant(value: i32) structures.FunctionBodyAnalysis.Instruction {
    return .{ .const_int = value };
}

fn directCall(target: structures.InstanceId) structures.FunctionBodyAnalysis.Instruction {
    return .{ .call = .{
        .target = .{ .direct = target },
        .arguments = .{ .start = 0, .end = 0 },
        .return_type = .int,
    } };
}

fn integerNegate(operand: u32) structures.FunctionBodyAnalysis.Instruction {
    return .{ .negi = @fromBackingInt(@intCast(operand)) };
}

const IntegerBinaryOperation = enum { add, subtract, multiply, divide_signed };

fn integerBinary(operation: IntegerBinaryOperation, lhs: u32, rhs: u32) structures.FunctionBodyAnalysis.Instruction {
    const operands: structures.BinaryOperands = .{
        .lhs = @fromBackingInt(@intCast(lhs)),
        .rhs = @fromBackingInt(@intCast(rhs)),
    };
    return switch (operation) {
        .add => .{ .addi = operands },
        .subtract => .{ .subi = operands },
        .multiply => .{ .muli = operands },
        .divide_signed => .{ .divsi = operands },
    };
}

fn functionSsa(
    instructions: []structures.FunctionBodyAnalysis.Instruction,
    blocks: []structures.FunctionBodyAnalysis.Block,
) structures.FunctionBodyAnalysis {
    var return_type: structures.TypeId = .unit;
    for (blocks) |block| switch (block.terminator) {
        .return_value => return_type = .int,
        else => {},
    };
    return .{
        .return_type = return_type,
        .instructions = instructions,
        .blocks = blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };
}

const array_copy_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(5)));
const array_wrapper_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(6)));
const array_reference_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(7)));
const reference_reference_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(8)));

const ArrayCopyTypes = struct {
    pub fn byteString(_: *@This(), id: structures.ByteStringId) ![]const u8 {
        return (TestTypes{}).byteString(id);
    }
    array_length: u32 = 1024,
    field_offsets: [2]u32 = .{ 0, 4 },

    pub fn staticStringBytes(_: *@This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn storageCursorAccess(_: *@This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn facts(self: *@This()) *@This() {
        return self;
    }

    pub fn layout(self: *@This(), type_id: structures.TypeId) !structures.TypeLayout {
        if (type_id == array_copy_type) return .{ .byte_size = self.array_length * 4, .byte_alignment = 4 };
        if (type_id == array_wrapper_type) return .{ .byte_size = self.array_length * 4 + 4, .byte_alignment = 4 };
        if (type_id == array_reference_type or type_id == reference_reference_type) return .{ .byte_size = 8, .byte_alignment = 8 };
        return (TestTypes{}).layout(type_id);
    }

    pub fn structLayout(self: *@This(), type_id: structures.TypeId) !?structures.StructLayout {
        return if (type_id == array_wrapper_type)
            .{ .layout = try self.layout(type_id), .field_offsets = &self.field_offsets }
        else
            null;
    }

    pub fn structDefinition(_: *@This(), _: structures.TypeId) !?structures.StructDefinition {
        return null;
    }

    pub fn arrayType(self: *@This(), type_id: structures.TypeId) !?structures.ArrayType {
        return if (type_id == array_copy_type) .{ .element_type = .int, .length = self.array_length } else null;
    }

    pub fn borrowElement(_: *@This(), type_id: structures.TypeId) !?structures.TypeId {
        if (type_id == array_reference_type) return array_copy_type;
        if (type_id == reference_reference_type) return array_reference_type;
        return null;
    }

    pub fn storageAccess(self: *@This(), type_id: structures.TypeId) !?structures.TypeId {
        return self.borrowElement(type_id);
    }

    pub fn argumentPassing(_: *@This(), type_id: structures.TypeId) !structures.ArgumentPassing {
        return if (type_id == array_copy_type or type_id == array_wrapper_type) .indirect else .direct;
    }

    pub fn variantMembers(_: *@This(), type_id: structures.TypeId) !?[]const structures.TypeId {
        return (TestTypes{}).variantMembers(type_id);
    }

    pub fn variantLayout(_: *@This(), type_id: structures.TypeId) !structures.VariantLayout {
        return (TestTypes{}).variantLayout(type_id);
    }

    pub fn callable(_: *@This(), type_id: structures.TypeId) !?structures.CallableType {
        return (TestTypes{}).callable(type_id);
    }
};

fn expectArtifactExitCode(artifact: structures.CompiledFunction, expected: u8) !void {
    const allocator = std.testing.allocator;
    const entry: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const exit_function: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    var exit_artifact = try codegen.compileExternalExit(allocator);
    defer exit_artifact.deinit(allocator);
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry, .artifact = artifact },
        .{ .instance = exit_function, .artifact = exit_artifact },
    };
    var executable = executable: {
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        break :executable try codegen.buildExecutableWithResultAllocator(entry, &functions, scratch.allocator(), allocator);
    };
    defer executable.deinit(allocator);
    try test_sources.expectProgramExit(executable.bytes, expected);
}

test "native comparisons and selections preserve signed and boolean predicates" {
    for ([_]structures.PredicateOperation{ .lti, .gti, .lei, .gei, .eqi, .nei, .eqb, .neb }) |predicate| {
        for ([_]i32{ -1, 0, 1 }) |left| {
            if ((predicate == .eqb or predicate == .neb) and left < 0) continue;
            const expected = switch (predicate) {
                .lti => left < 0,
                .gti => left > 0,
                .lei => left <= 0,
                .gei => left >= 0,
                .eqi, .eqb => left == 0,
                .nei, .neb => left != 0,
                .eqt, .net => unreachable,
            };
            const boolean = predicate == .eqb or predicate == .neb;
            var instructions = [_]structures.FunctionInstruction{
                if (boolean) .{ .const_bool = left != 0 } else .{ .const_int = left },
                if (boolean) .{ .const_bool = false } else .{ .const_int = 0 },
                .{ .compare = .{ .operation = predicate, .operands = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(1) } } },
                .{ .const_bool = true },
                .{ .const_bool = false },
                .{ .select = .{ .condition = @fromBackingInt(2), .then_value = @fromBackingInt(3), .else_value = @fromBackingInt(4), .type_id = .bool } },
                .{ .compare = .{ .operation = .eqb, .operands = .{ .lhs = @fromBackingInt(5), .rhs = @fromBackingInt(3) } } },
                .{ .const_int = 42 },
                .{ .const_int = 91 },
                .{ .select = .{ .condition = @fromBackingInt(6), .then_value = @fromBackingInt(7), .else_value = @fromBackingInt(8), .type_id = .int } },
                directCall(.{ .item = @fromBackingInt(1) }),
            };
            instructions[10].call.arguments = .{ .start = 0, .end = 1 };
            instructions[10].call.return_type = .never;
            var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }};
            var body = functionSsa(&instructions, &blocks);
            body.call_arguments = &.{.{ .prepared = .{ .value = @fromBackingInt(9) } }};
            var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            try expectArtifactExitCode(artifact, if (expected) 42 else 91);
        }
    }
}

test "native bulk operations preserve overlapping move direction and clear the direction flag" {
    for ([_]bool{ false, true }) |backward| {
        for ([_]bool{ false, true }) |empty| {
            var types: ArrayCopyTypes = .{ .array_length = 6 };
            var instructions = [_]structures.FunctionInstruction{
                .{ .local_storage = array_copy_type },
                .{ .const_int = 0 },
                .{ .const_int = 1 },
                .{ .const_int = 2 },
                .{ .const_int = 3 },
                .{ .const_int = 4 },
                .{ .const_int = 6 },
                .{ .const_int = 10 },
                .{ .const_int = 20 },
                .{ .const_int = 30 },
                .{ .array_element = .{ .array = @fromBackingInt(0), .index = @fromBackingInt(1), .type_id = .int } },
                .{ .array_element = .{ .array = @fromBackingInt(0), .index = @fromBackingInt(2), .type_id = .int } },
                .{ .array_element = .{ .array = @fromBackingInt(0), .index = @fromBackingInt(3), .type_id = .int } },
                .{ .array_element = .{ .array = @fromBackingInt(0), .index = @fromBackingInt(5), .type_id = .int } },
                .{ .fill = .{ .first = @fromBackingInt(10), .count = @fromBackingInt(6), .value = @fromBackingInt(3), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(7), .destination = @fromBackingInt(10), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(8), .destination = @fromBackingInt(11), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(9), .destination = @fromBackingInt(12), .type_id = .int } },
                .{ .move = .{ .destination = @fromBackingInt(if (backward) 11 else 10), .source = @fromBackingInt(if (backward) 10 else 11), .count = @fromBackingInt(if (empty) 1 else 4), .type_id = .int, .backward = backward } },
                .{ .fill = .{ .first = @fromBackingInt(13), .count = @fromBackingInt(3), .value = @fromBackingInt(3), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(11), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(12), .type_id = .int } },
                .{ .value_copy = .{ .source = @fromBackingInt(13), .type_id = .int } },
                .{ .addi = .{ .lhs = @fromBackingInt(20), .rhs = @fromBackingInt(21) } },
                .{ .addi = .{ .lhs = @fromBackingInt(23), .rhs = @fromBackingInt(22) } },
                .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
            };
            var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }};
            var body = functionSsa(&instructions, &blocks);
            body.call_arguments = &.{.{ .prepared = .{ .value = @fromBackingInt(24) } }};
            var artifact = try codegen.compileFunction(&body, &types, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            try expectArtifactExitCode(artifact, if (empty) 52 else if (backward) 32 else 34);
        }
    }
}

test "native byte fills and directed moves preserve exact byte storage" {
    for ([_]bool{ false, true }) |backward| {
        for ([_]bool{ false, true }) |empty| {
            var instructions = [_]structures.FunctionInstruction{
                .{ .local_storage = .byte },
                .{ .local_storage = .byte },
                .{ .const_byte = 42 },
                .{ .const_byte = 13 },
                .{ .const_int = 1 },
                .{ .const_int = 0 },
                .{ .fill = .{ .first = @fromBackingInt(0), .count = @fromBackingInt(4), .value = @fromBackingInt(2), .type_id = .byte } },
                .{ .fill = .{ .first = @fromBackingInt(1), .count = @fromBackingInt(4), .value = @fromBackingInt(3), .type_id = .byte } },
                .{ .move = .{ .destination = @fromBackingInt(1), .source = @fromBackingInt(0), .count = @fromBackingInt(if (empty) 5 else 4), .type_id = .byte, .backward = backward } },
                .{ .byte_to_int = @fromBackingInt(1) },
                .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
            };
            var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }};
            var body = functionSsa(&instructions, &blocks);
            body.call_arguments = &.{.{ .prepared = .{ .value = @fromBackingInt(9) } }};
            var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            try expectArtifactExitCode(artifact, if (empty) 13 else 42);
        }
    }
}

test "native array projections scale runtime indices and large copies remain bounded" {
    for ([_]u32{ 65, 1024 }) |array_length| {
        var types: ArrayCopyTypes = .{ .array_length = array_length };
        var modes = [_]structures.ParameterMode{.imm};
        var arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int }};
        var instructions = [_]structures.FunctionInstruction{
            .{ .local_storage = array_copy_type },
            .{ .local_storage = array_copy_type },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(1)), .destination = @fromBackingInt(@intCast(2)), .type_id = array_copy_type } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(2)), .index = @fromBackingInt(@intCast(0)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(4)), .type_id = .int } },
        };
        var blocks = [_]structures.FunctionBlock{.{
            .argument_end = 1,
            .instruction_start = 0,
            .instruction_end = instructions.len,
            .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(5)) } },
        }};
        var body = functionSsa(&instructions, &blocks);
        body.parameter_modes = &modes;
        body.block_arguments = &arguments;
        var artifact = try codegen.compileFunction(&body, &types, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        try std.testing.expect(artifact.code.len < 256);
        try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0xf3, 0xa4 }) != null);
        try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0x48, 0x8d, 0x04, 0x88 }) != null);
    }
}

test "large struct wrapping array copies remain bounded and preserve field offsets" {
    const exit_function: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    var previous_code_size: ?usize = null;
    for ([_]u32{ 65, 1024 }) |array_length| {
        var types: ArrayCopyTypes = .{ .array_length = array_length };
        var instructions = [_]structures.FunctionInstruction{
            .{ .local_storage = array_copy_type },
            integerConstant(11),
            integerConstant(31),
            integerConstant(7),
            integerConstant(0),
            integerConstant(@intCast(array_length - 1)),
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(4)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(1)), .destination = @fromBackingInt(@intCast(6)), .type_id = .int } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(5)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(2)), .destination = @fromBackingInt(@intCast(8)), .type_id = .int } },
            .{ .local_storage = array_wrapper_type },
            .{ .storage_projection = .{ .owner = @fromBackingInt(@intCast(10)), .type_id = .int, .projection = .{ .field = 0 } } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(3)), .destination = @fromBackingInt(@intCast(11)), .type_id = .int } },
            .{ .storage_projection = .{ .owner = @fromBackingInt(@intCast(10)), .type_id = array_copy_type, .projection = .{ .field = 1 } } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(0)), .destination = @fromBackingInt(@intCast(13)), .type_id = array_copy_type } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(10)), .type_id = array_wrapper_type } },
            .{ .field_access = .{ .operand = @fromBackingInt(@intCast(15)), .field_index = 1, .field_type = array_copy_type } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(16)), .index = @fromBackingInt(@intCast(4)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(17)), .type_id = .int } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(16)), .index = @fromBackingInt(@intCast(5)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(19)), .type_id = .int } },
            .{ .field_access = .{ .operand = @fromBackingInt(@intCast(15)), .field_index = 0, .field_type = .int } },
            integerBinary(.add, 18, 20),
            integerBinary(.add, 22, 21),
            .{ .call = .{ .target = .{ .direct = exit_function }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
        };
        var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(@intCast(23)) } }};
        var blocks = [_]structures.FunctionBlock{.{
            .instruction_start = 0,
            .instruction_end = instructions.len,
            .terminator = .diverge,
        }};
        var body = functionSsa(&instructions, &blocks);
        body.call_arguments = &call_arguments;
        var artifact = try codegen.compileFunction(&body, &types, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        try std.testing.expect(artifact.code.len < 1024);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, artifact.code, &.{ 0xf3, 0xa4 }));
        if (previous_code_size) |expected_size| try std.testing.expectEqual(expected_size, artifact.code.len);
        previous_code_size = artifact.code.len;
        try expectArtifactExitCode(artifact, 49);
    }
}

test "borrowed writes preserve indirect storage and pointer-valued addresses" {
    const exit_function: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    for ([_]u32{ 2, 3, 4, 16, 32, 64, 65, 1024 }) |array_length| {
        var types: ArrayCopyTypes = .{ .array_length = array_length };
        var instructions = [_]structures.FunctionInstruction{
            .{ .local_storage = array_copy_type },
            .{ .local_storage = array_copy_type },
            integerConstant(11),
            integerConstant(31),
            integerConstant(0),
            integerConstant(@intCast(array_length - 1)),
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(4)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(2)), .destination = @fromBackingInt(@intCast(6)), .type_id = .int } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(5)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(3)), .destination = @fromBackingInt(@intCast(8)), .type_id = .int } },
            .{ .borrow_address = .{ .source = @fromBackingInt(@intCast(0)), .type_id = array_reference_type } },
            .{ .borrow_read = .{ .source = @fromBackingInt(@intCast(10)), .type_id = array_copy_type } },
            .{ .borrow_address = .{ .source = @fromBackingInt(@intCast(1)), .type_id = array_reference_type } },
            .{ .borrow_write = .{ .reference = @fromBackingInt(@intCast(12)), .value = @fromBackingInt(@intCast(11)), .type_id = array_copy_type } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(1)), .index = @fromBackingInt(@intCast(4)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(14)), .type_id = .int } },
            .{ .borrow_address = .{ .source = @fromBackingInt(@intCast(12)), .type_id = reference_reference_type } },
            .{ .borrow_read = .{ .source = @fromBackingInt(@intCast(16)), .type_id = array_reference_type } },
            integerConstant(17),
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(18)), .destination = @fromBackingInt(@intCast(6)), .type_id = .int } },
            .{ .borrow_write = .{ .reference = @fromBackingInt(@intCast(17)), .value = @fromBackingInt(@intCast(11)), .type_id = array_copy_type } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(1)), .index = @fromBackingInt(@intCast(4)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(21)), .type_id = .int } },
            .{ .array_element = .{ .array = @fromBackingInt(@intCast(1)), .index = @fromBackingInt(@intCast(5)), .type_id = .int } },
            .{ .value_copy = .{ .source = @fromBackingInt(@intCast(23)), .type_id = .int } },
            integerBinary(.add, 15, 22),
            integerBinary(.add, 25, 24),
            .{ .call = .{ .target = .{ .direct = exit_function }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
        };
        var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(@intCast(26)) } }};
        var blocks = [_]structures.FunctionBlock{.{
            .instruction_start = 0,
            .instruction_end = instructions.len,
            .terminator = .diverge,
        }};
        var body = functionSsa(&instructions, &blocks);
        body.call_arguments = &call_arguments;
        var artifact = try codegen.compileFunction(&body, &types, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        const large_copy = array_length > 64;
        try std.testing.expectEqual(@as(usize, if (large_copy) 2 else 0), std.mem.count(u8, artifact.code, &.{ 0xf3, 0xa4 }));
        if (large_copy) try std.testing.expect(artifact.code.len < 1024);
        try expectArtifactExitCode(artifact, 59);
    }
}

test "divergence traps before a following block can execute" {
    var instructions: [0]structures.FunctionInstruction = .{};
    var blocks = [_]structures.FunctionBlock{
        .{ .instruction_start = 0, .instruction_end = 0, .terminator = .diverge },
        .{ .instruction_start = 0, .instruction_end = 0, .terminator = .return_unit },
    };
    const body = functionSsa(&instructions, &blocks);
    var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, artifact.code, &.{ 0x0F, 0x0B }));
}

test "single aligned function artifact builds and runs without borrowing code" {
    var executable = blk: {
        var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
            .instruction_start = 0,
            .instruction_end = 0,
            .terminator = .return_unit,
        }};
        const ssa = functionSsa(&.{}, &blocks);
        var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        artifact.required_alignment = 16;
        const entry: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
        const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = artifact }};
        break :blk try codegen.buildExecutable(entry, &functions, std.testing.allocator);
    };
    defer executable.deinit(std.testing.allocator);

    const artifact_code = [_]u8{0xC3};
    const artifact_file_offset = std.mem.indexOf(u8, executable.bytes, &artifact_code).?;
    try std.testing.expectEqual(@as(u64, 0), (0x400000 + artifact_file_offset) % 16);

    try test_sources.expectProgramExit(executable.bytes, @as(u8, 0));
}

test "storage joins keep the source address for directly movable values" {
    const allocator = std.testing.allocator;
    const exit_function: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    var arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int, .representation = .storage }};
    var uses = [_]structures.FunctionValueUse{.{ .value = @fromBackingInt(@intCast(1)) }};
    var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(@intCast(1)) } }};
    var instructions = [_]structures.FunctionInstruction{
        integerConstant(10),
        integerConstant(42),
        .{ .value_copy = .{ .source = @fromBackingInt(@intCast(2)), .type_id = .int, .destination = @fromBackingInt(@intCast(0)) } },
        .{ .call = .{ .target = .{ .direct = exit_function }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
    };
    var blocks = [_]structures.FunctionBlock{
        .{ .instruction_start = 0, .instruction_end = 1, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 1 } } } },
        .{ .argument_start = 0, .argument_end = 1, .instruction_start = 1, .instruction_end = 4, .terminator = .diverge },
    };
    var body = functionSsa(&instructions, &blocks);
    body.block_arguments = &arguments;
    body.branch_arguments = &uses;
    body.call_arguments = &call_arguments;
    var artifact = try codegen.compileFunction(&body, TestTypes{}, allocator);
    defer artifact.deinit(allocator);
    var exit_artifact = try codegen.compileExternalExit(allocator);
    defer exit_artifact.deinit(allocator);
    const entry: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry, .artifact = artifact },
        .{ .instance = exit_function, .artifact = exit_artifact },
    };
    var executable = try codegen.buildExecutable(entry, &functions, allocator);
    defer executable.deinit(allocator);
    try test_sources.expectProgramExit(executable.bytes, @as(u8, 42));
}

test "ordinary function artifacts encode signed 32-bit literal returns" {
    for ([_]i32{ std.math.minInt(i32), 7, std.math.maxInt(i32) }) |return_value| {
        var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
            integerConstant(return_value),
        };
        var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
            .instruction_start = 0,
            .instruction_end = 1,
            .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(0)) } },
        }};
        const ssa = functionSsa(&instructions, &blocks);
        var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 6), artifact.code.len);
        try std.testing.expectEqual(@as(u8, 0xB8), artifact.code[0]);
        try std.testing.expectEqual(return_value, std.mem.readInt(i32, artifact.code[1..5], .little));
        try std.testing.expectEqualSlices(u8, &.{0xC3}, artifact.code[5..]);
        try std.testing.expectEqual(@as(u32, 1), artifact.required_alignment);
        try std.testing.expectEqual(@as(usize, 0), artifact.relocations.len);
        try std.testing.expectEqual(@as(usize, 0), artifact.referenced_instances.len);
    }
}

test "external exit artifact reads its argument from the call stack" {
    var artifact = try codegen.compileExternalExit(std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{
        0x8B, 0x44, 0x24, 8,
        0x89, 0xC7, 0xB8, 60,
        0,    0,    0,    0x0F,
        0x05,
    }, artifact.code);
    try std.testing.expectEqual(@as(usize, 0), artifact.relocations.len);
    try std.testing.expectEqual(@as(usize, 0), artifact.referenced_instances.len);
}

test "direct call artifacts own exact relocation metadata" {
    const target: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0xdeadbeef)) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(target),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const ssa = functionSsa(&instructions, &blocks);

    var first = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try expectDirectCallArtifact(first, target);
    try expectDirectCallArtifact(second, target);
    try std.testing.expect(first.code.ptr != second.code.ptr);
    try std.testing.expect(first.relocations.ptr != second.relocations.ptr);
    try std.testing.expect(first.referenced_instances.ptr != second.referenced_instances.ptr);
    try std.testing.expect(structures.CompiledFunction.eql(first, second));

    instructions[0] = directCall(.{ .item = @fromBackingInt(@intCast(1)) });
    var different_target = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer different_target.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.code, different_target.code);
    try std.testing.expectEqualSlices(structures.CompiledFunction.Relocation, first.relocations, different_target.relocations);
    try std.testing.expect(!structures.CompiledFunction.eql(first, different_target));
}

test "function references relocate absolute addresses for indirect calls" {
    const target: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0xabcdef01)) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        .{ .function_ref = .{ .target = target.item, .type_id = callable_type } },
        .{ .call = .{
            .target = .{ .indirect = @fromBackingInt(@intCast(0)) },
            .arguments = .{ .start = 0, .end = 0 },
            .return_type = .int,
        } },
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(1)) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0xFF, 0xD0 }) != null);
    try std.testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    const address_offset = artifact.relocations[0].offset;
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0xb8 }, artifact.code[address_offset - 2 .. address_offset]);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, artifact.code[address_offset..][0..8], .little));
    try std.testing.expectEqual(structures.CompiledFunction.RelocationKind.address_absolute_64, artifact.relocations[0].kind);
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

fn expectDirectCallArtifact(artifact: structures.CompiledFunction, target: structures.InstanceId) !void {
    try std.testing.expectEqualSlices(u8, &.{ 0xE8, 0, 0, 0, 0, 0xC3 }, artifact.code);
    try std.testing.expectEqual(@as(u32, 1), artifact.required_alignment);
    try std.testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    try std.testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try std.testing.expectEqual(structures.CompiledFunction.RelocationKind.call_relative_32, artifact.relocations[0].kind);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(artifact.relocations[0].reference.function));
    try std.testing.expectEqual(@as(i64, 0), artifact.relocations[0].addend);
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

test "multiple calls produce ordered relocations and deduplicate references" {
    const target: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(7)) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(target),
        directCall(target),
        integerConstant(42),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(2)) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{
        0xE8, 0,  0, 0, 0,
        0xE8, 0,  0, 0, 0,
        0xB8, 42, 0, 0, 0,
        0xC3,
    }, artifact.code);
    try std.testing.expectEqual(@as(usize, 2), artifact.relocations.len);
    try std.testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try std.testing.expectEqual(@as(u32, 6), artifact.relocations[1].offset);
    try std.testing.expectEqual(@backingInt(artifact.relocations[0].reference.function), @backingInt(artifact.relocations[1].reference.function));
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

test "typed expression values survive calls and execute every integer arithmetic operator" {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(3)) };
    const expression_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(2)) };
    const left_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const right_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(left_id),
        directCall(right_id),
        integerBinary(.divide_signed, 0, 1),
        integerConstant(5),
        integerConstant(3),
        integerBinary(.multiply, 3, 4),
        integerBinary(.add, 2, 5),
        integerConstant(15),
        integerBinary(.subtract, 6, 7),
        integerNegate(8),
        integerNegate(9),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(10)) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var expression = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer expression.deinit(std.testing.allocator);

    const entry_code = [_]u8{
        0xE8, 0,    0,    0,    0,
        0x89, 0xC7, 0xB8, 60,   0,
        0,    0,    0x0F, 0x05,
    };
    const entry_relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = .{ .function = @fromBackingInt(@intCast(0)) },
        .addend = 0,
    }};
    const entry_references = [_]structures.InstanceId{expression_id};
    const entry: structures.CompiledFunction = .{
        .code = &entry_code,
        .required_alignment = 1,
        .relocations = &entry_relocations,
        .referenced_instances = &entry_references,
    };
    const left_code = [_]u8{ 0xB8, 84, 0, 0, 0, 0xC3 };
    const right_code = [_]u8{ 0xB8, 2, 0, 0, 0, 0xC3 };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = expression_id, .artifact = expression },
        .{ .instance = left_id, .artifact = .{
            .code = &left_code,
            .required_alignment = 1,
        } },
        .{ .instance = right_id, .artifact = .{
            .code = &right_code,
            .required_alignment = 1,
        } },
    };
    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);

    try test_sources.expectProgramExit(executable.bytes, @as(u8, 42));
}

test "native predicate edges preserve copies across physical block orders" {
    const cases = [_]struct { operation: structures.PredicateOperation, lhs: i32, rhs: i32, taken: bool }{
        .{ .operation = .lti, .lhs = -3, .rhs = 1, .taken = true },
        .{ .operation = .lti, .lhs = 1, .rhs = -3, .taken = false },
        .{ .operation = .gti, .lhs = 1, .rhs = -3, .taken = true },
        .{ .operation = .gti, .lhs = -3, .rhs = 1, .taken = false },
        .{ .operation = .lei, .lhs = -3, .rhs = -3, .taken = true },
        .{ .operation = .lei, .lhs = 1, .rhs = -3, .taken = false },
        .{ .operation = .gei, .lhs = -3, .rhs = -3, .taken = true },
        .{ .operation = .gei, .lhs = -3, .rhs = 1, .taken = false },
        .{ .operation = .eqi, .lhs = -3, .rhs = -3, .taken = true },
        .{ .operation = .eqi, .lhs = -3, .rhs = 1, .taken = false },
        .{ .operation = .nei, .lhs = -3, .rhs = 1, .taken = true },
        .{ .operation = .nei, .lhs = -3, .rhs = -3, .taken = false },
        .{ .operation = .eqb, .lhs = 1, .rhs = 1, .taken = true },
        .{ .operation = .eqb, .lhs = 1, .rhs = 0, .taken = false },
        .{ .operation = .neb, .lhs = 1, .rhs = 0, .taken = true },
        .{ .operation = .neb, .lhs = 1, .rhs = 1, .taken = false },
    };
    for (cases) |case| {
        for ([_][4]usize{ .{ 0, 1, 2, 3 }, .{ 0, 2, 1, 3 }, .{ 2, 0, 1, 3 }, .{ 2, 1, 0, 3 }, .{ 1, 2, 3, 0 } }) |order| {
            var arguments = [_]structures.FunctionBlockArgument{ .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int } };
            var uses = [_]structures.FunctionValueUse{
                .{ .value = @fromBackingInt(8) },  .{ .value = @fromBackingInt(9) },
                .{ .value = @fromBackingInt(10) }, .{ .value = @fromBackingInt(11) },
                .{ .value = @fromBackingInt(1) },  .{ .value = @fromBackingInt(0) },
                .{ .value = @fromBackingInt(3) },  .{ .value = @fromBackingInt(2) },
            };
            const boolean = case.operation == .eqb or case.operation == .neb;
            var instructions = [_]structures.FunctionInstruction{
                if (boolean) .{ .const_bool = case.lhs != 0 } else integerConstant(case.lhs),
                if (boolean) .{ .const_bool = case.rhs != 0 } else integerConstant(case.rhs),
                integerConstant(11),
                integerConstant(31),
                integerConstant(7),
                integerConstant(3),
                integerBinary(.subtract, 4, 5),
                .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
            };
            var calls = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(12) } }};
            var blocks: [4]structures.FunctionBlock = undefined;
            blocks[order[0]] = .{ .instruction_start = 0, .instruction_end = 6, .terminator = .{ .predicate_branch = .{
                .operation = case.operation,
                .operands = .{ .lhs = @fromBackingInt(6), .rhs = @fromBackingInt(7) },
                .then_branch = .{ .target = @fromBackingInt(@intCast(order[1])), .arguments = .{ .start = 0, .end = 2 } },
                .else_branch = .{ .target = @fromBackingInt(@intCast(order[2])), .arguments = .{ .start = 2, .end = 4 } },
            } } };
            blocks[order[1]] = .{ .argument_end = 2, .instruction_start = 6, .instruction_end = 6, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(order[3])), .arguments = .{ .start = 4, .end = 6 } } } };
            blocks[order[2]] = .{ .argument_start = 2, .argument_end = 4, .instruction_start = 6, .instruction_end = 6, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(order[3])), .arguments = .{ .start = 6, .end = 8 } } } };
            blocks[order[3]] = .{ .argument_start = 4, .argument_end = 6, .instruction_start = 6, .instruction_end = 8, .terminator = .diverge };
            var body = functionSsa(&instructions, &blocks);
            body.entry = @fromBackingInt(@intCast(order[0]));
            body.block_arguments = &arguments;
            body.branch_arguments = &uses;
            body.call_arguments = &calls;
            var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            try expectArtifactExitCode(artifact, if (case.taken) 20 else 252);
        }
    }
}

test "native predicate branches without edge copies use one conditional jump" {
    for ([_]bool{ false, true }) |taken| {
        for ([_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } }) |order| {
            var instructions = [_]structures.FunctionInstruction{
                integerConstant(if (taken) -1 else 1),                                                                                                     integerConstant(0),                                                                                                                        integerConstant(42), integerConstant(7),
                .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } }, .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 1, .end = 2 }, .return_type = .never } },
            };
            var calls = [_]structures.FunctionCallArgument{ .{ .prepared = .{ .value = @fromBackingInt(2) } }, .{ .prepared = .{ .value = @fromBackingInt(3) } } };
            var blocks: [3]structures.FunctionBlock = undefined;
            blocks[order[0]] = .{ .instruction_start = 0, .instruction_end = 4, .terminator = .{ .predicate_branch = .{
                .operation = .lti,
                .operands = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(1) },
                .then_branch = .{ .target = @fromBackingInt(@intCast(order[1])), .arguments = .{ .start = 0, .end = 0 } },
                .else_branch = .{ .target = @fromBackingInt(@intCast(order[2])), .arguments = .{ .start = 0, .end = 0 } },
            } } };
            blocks[order[1]] = .{ .instruction_start = 4, .instruction_end = 5, .terminator = .diverge };
            blocks[order[2]] = .{ .instruction_start = 5, .instruction_end = 6, .terminator = .diverge };
            var body = functionSsa(&instructions, &blocks);
            body.entry = @fromBackingInt(@intCast(order[0]));
            body.call_arguments = &calls;
            var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            const listing = try test_sources.disasm.disassemble(artifact.code, std.testing.allocator);
            defer std.testing.allocator.free(listing);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, listing, "  j"));
            try std.testing.expect(std.mem.indexOf(u8, listing, "  jmp ") == null);
            try expectArtifactExitCode(artifact, if (taken) 42 else 7);
        }
    }
}

test "native parallel backedge copies preserve cycles while falling through to exit" {
    for ([_]i32{ 0, 1, 2, 3 }) |count| {
        var arguments = [_]structures.FunctionBlockArgument{ .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int } };
        var uses = [_]structures.FunctionValueUse{
            .{ .value = @fromBackingInt(5) },  .{ .value = @fromBackingInt(6) }, .{ .value = @fromBackingInt(7) },
            .{ .value = @fromBackingInt(10) }, .{ .value = @fromBackingInt(2) }, .{ .value = @fromBackingInt(1) },
            .{ .value = @fromBackingInt(1) },  .{ .value = @fromBackingInt(2) },
        };
        var instructions = [_]structures.FunctionInstruction{
            integerConstant(count),         integerConstant(11),            integerConstant(31),                                                                                                                       integerConstant(0), integerConstant(1),
            integerBinary(.subtract, 0, 9), integerBinary(.subtract, 4, 3), .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
        };
        var calls = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(11) } }};
        var blocks = [_]structures.FunctionBlock{
            .{ .instruction_start = 0, .instruction_end = 5, .terminator = .{ .branch = .{ .target = @fromBackingInt(1), .arguments = .{ .start = 0, .end = 3 } } } },
            .{ .argument_end = 3, .instruction_start = 5, .instruction_end = 6, .terminator = .{ .predicate_branch = .{
                .operation = .gti,
                .operands = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(8) },
                .then_branch = .{ .target = @fromBackingInt(1), .arguments = .{ .start = 3, .end = 6 } },
                .else_branch = .{ .target = @fromBackingInt(2), .arguments = .{ .start = 6, .end = 8 } },
            } } },
            .{ .argument_start = 3, .argument_end = 5, .instruction_start = 6, .instruction_end = 8, .terminator = .diverge },
        };
        var body = functionSsa(&instructions, &blocks);
        body.block_arguments = &arguments;
        body.branch_arguments = &uses;
        body.call_arguments = &calls;
        var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        try expectArtifactExitCode(artifact, if (@mod(count, 2) == 0) 20 else 236);
    }
}

test "native copies preserve byte tails and adjacent guards across the bulk threshold" {
    const allocator = std.testing.allocator;
    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 255, 256, 257 }) |count| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.append(allocator, '[');
        for (0..count) |index| try bytes.print(allocator, "{s}{d}", .{ if (index == 0) "" else ", ", index % 251 });
        try bytes.append(allocator, ']');
        const count_text = try allocator.print("{d}", .{count});
        defer allocator.free(count_text);
        const source = try test_sources.renderTemplate(allocator,
            \\struct Guard
            \\    pub before: byte
            \\    pub payload: Array(byte, $count)
            \\    pub after: byte
            \\func roundtrip(value: Array(byte, $count)) Array(byte, $count)
            \\    return value
            \\func replace(mut target: Array(byte, $count), value: Array(byte, $count))
            \\    target = value
            \\func calculate() int
            \\    const original: Array(byte, $count) = $bytes
            \\    var guarded = Guard{before = 7, payload = original, after = 9}
            \\    replace(guarded.payload, roundtrip(original))
            \\    if byte_int(guarded.before) <> 7 -> return 91
            \\    if byte_int(guarded.after) <> 9 -> return 92
            \\    var index = 0
            \\    loop
            \\        if index >= $count -> break
            \\        if byte_int(guarded.payload[index]) <> index % 251 -> return 93
            \\        index += 1
            \\    return 42
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 94
            \\exit(run())
        , .{ .count = count_text, .bytes = bytes.items });
        defer allocator.free(source);
        try test_sources.SourceFixture.expectSourceExit(source, 42);
    }
}

test "native nested array addressing handles native scales zero sizes and multiplication fallback" {
    const allocator = std.testing.allocator;
    for ([_]u32{ 0, 1, 2, 3, 4, 7, 8, 9 }) |width| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.append(allocator, '[');
        for (0..3) |row| {
            if (row != 0) try bytes.appendSlice(allocator, ", ");
            try bytes.append(allocator, '[');
            for (0..width) |index| try bytes.print(allocator, "{s}{d}", .{ if (index == 0) "" else ", ", row * 16 + index });
            try bytes.append(allocator, ']');
        }
        try bytes.append(allocator, ']');
        const width_text = try allocator.print("{d}", .{width});
        defer allocator.free(width_text);
        const source = try test_sources.renderTemplate(allocator,
            \\func index(value: int) int
            \\    return value
            \\func calculate() int
            \\    var grid: Array(Array(byte, $width), 3) = $bytes
            \\    if ref invalid: Array(byte, $width) = grid.get(-1) -> return 91
            \\    var outer = 0
            \\    loop
            \\        if outer >= 3 -> break
            \\        const selected = grid[index(outer)]
            \\        var inner = 0
            \\        loop
            \\            if inner >= $width -> break
            \\            if byte_int(selected[index(inner)]) <> outer * 16 + inner -> return 92
            \\            inner += 1
            \\        outer += 1
            \\    return 42
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 93
            \\exit(run())
        , .{ .width = width_text, .bytes = bytes.items });
        defer allocator.free(source);
        try test_sources.SourceFixture.expectSourceExit(source, 42);
    }
}

test "cyclic CFG accepts multi-value parallel backedge copies" {
    var block_arguments = [_]structures.FunctionBlockArgument{ .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int } };
    var parameter_modes = [_]structures.ParameterMode{ .imm, .imm };
    var branch_arguments = [_]structures.FunctionValueUse{
        .{ .value = @fromBackingInt(@intCast(0)) },
        .{ .value = @fromBackingInt(@intCast(1)) },
        .{ .value = @fromBackingInt(@intCast(3)) },
        .{ .value = @fromBackingInt(@intCast(2)) },
        .{ .value = @fromBackingInt(@intCast(2)) },
    };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{integerConstant(0)};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{
        .{
            .argument_start = 0,
            .argument_end = 2,
            .instruction_start = 0,
            .instruction_end = 0,
            .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 2 } } },
        },
        .{
            .argument_start = 2,
            .argument_end = 4,
            .instruction_start = 0,
            .instruction_end = 1,
            .terminator = .{ .predicate_branch = .{
                .operation = .gti,
                .operands = .{ .lhs = @fromBackingInt(@intCast(2)), .rhs = @fromBackingInt(@intCast(5)) },
                .then_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 4, .end = 5 } },
                .else_branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 2, .end = 4 } },
            } },
        },
        .{
            .argument_start = 4,
            .argument_end = 5,
            .instruction_start = 1,
            .instruction_end = 1,
            .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(4)) } },
        },
    };
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .parameter_modes = &parameter_modes,
        .block_arguments = &block_arguments,
        .branch_arguments = &branch_arguments,
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.code.len != 0);
}

test "direct call artifact construction cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(allocation_failure_allocator, testCompileDirectCallAllocations, .{});
}

test "expression artifact construction cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(allocation_failure_allocator, testCompileExpressionAllocations, .{});
}

test "variant subset call construction cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(allocation_failure_allocator, testCompileVariantSubsetCallAllocations, .{});
}

test "variant injection copies an arbitrary-size non-variant interned payload" {
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = seven_byte_payload }};
    var parameter_modes = [_]structures.ParameterMode{.imm};
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .variant_coerce = .{
        .operand = @fromBackingInt(@intCast(0)),
        .target_type = payload_variant,
        .tag_mapping = .{ .start = 0, .end = 1 },
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .argument_end = 1,
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(1)) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = payload_variant,
        .parameter_modes = &parameter_modes,
        .block_arguments = &block_arguments,
        .variant_coercion_tags = &.{1},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0x0F, 0xB6, 0x44, 0x24 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0x88, 0x44, 0x24 }) != null);
}

fn testCompileVariantSubsetCallAllocations(gpa: std.mem.Allocator) !void {
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = small_variant }};
    var parameter_modes = [_]structures.ParameterMode{.imm};
    var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{
        .value = @fromBackingInt(@intCast(0)),
        .coerce_to = wide_variant,
        .variant_tag_mapping = .{ .start = 0, .end = 2 },
    } }};
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = .{
        .target = .{ .direct = .{ .item = @fromBackingInt(@intCast(0)) } },
        .arguments = .{ .start = 0, .end = 1 },
        .return_type = wide_variant,
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .argument_end = 1,
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(1)) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = wide_variant,
        .parameter_modes = &parameter_modes,
        .block_arguments = &block_arguments,
        .variant_coercion_tags = &.{ 0, 2 },
        .call_arguments = &call_arguments,
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @fromBackingInt(@intCast(0)),
    };
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, gpa);
    defer artifact.deinit(gpa);
}

fn testCompileExpressionAllocations(gpa: std.mem.Allocator) !void {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(.{ .item = @fromBackingInt(@intCast(0)) }),
        integerConstant(2),
        integerBinary(.multiply, 0, 1),
        integerConstant(1),
        integerBinary(.add, 2, 3),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(4)) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, gpa);
    defer artifact.deinit(gpa);
}

fn testCompileDirectCallAllocations(gpa: std.mem.Allocator) !void {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(.{ .item = @fromBackingInt(@intCast(0)) }),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, gpa);
    defer artifact.deinit(gpa);
}

test "ordinary function compilation cleans up allocation failure" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        integerConstant(7),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = .{ .value = @fromBackingInt(@intCast(0)) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codegen.compileFunction(&ssa, TestTypes{}, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "executable bulk reservation cleans up allocation failure" {
    const entry: structures.InstanceId = .{ .item = @fromBackingInt(0) };
    const code: [4096]u8 = @splat(0xC3);
    const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = .{
        .code = &code,
        .required_alignment = 1,
    } }};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, codegen.buildExecutable(entry, &functions, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "executable builder resolves a direct call to its callee's file offset" {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const callee_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = .{ .function = @fromBackingInt(@intCast(0)) },
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{callee_id};
    const entry: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const callee_code = [_]u8{ 0xB8, 42, 0, 0, 0, 0xBA, 1, 0, 0, 0, 0xC3 };
    const callee: structures.CompiledFunction = .{
        .code = &callee_code,
        .required_alignment = 16,
    };

    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);

    const callee_file_offset = std.mem.indexOf(u8, executable.bytes, &callee_code).?;
    try std.testing.expectEqual(@as(u64, 0), (0x400000 + callee_file_offset) % 16);

    // Locate the entry's call site by walking back from the callee over its
    // alignment padding, rather than scanning for a second 0xE8 byte: the
    // entry's own displacement bytes are patched (not zero), so a byte scan
    // could collide with a stray 0xE8 in an unrelated field.
    var entry_end_offset = callee_file_offset;
    while (entry_end_offset > 0 and executable.bytes[entry_end_offset - 1] == 0x90) : (entry_end_offset -= 1) {}
    const call_site_offset = entry_end_offset - call_code.len;
    try std.testing.expectEqual(@as(u8, 0xE8), executable.bytes[call_site_offset]);
    try std.testing.expectEqual(@as(u8, 0xC3), executable.bytes[call_site_offset + 5]);

    const displacement = std.mem.readInt(i32, executable.bytes[call_site_offset + 1 ..][0..4], .little);
    const expected: i64 = @as(i64, @intCast(callee_file_offset)) - @as(i64, @intCast(call_site_offset)) - 5;
    try std.testing.expectEqual(expected, displacement);

    try test_sources.expectProgramExit(executable.bytes, @as(u8, 0));
}

test "executable builder patches multiple relocations to one shared artifact" {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const shared_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const entry_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{
        .{ .offset = 1, .kind = .call_relative_32, .reference = .{ .function = @fromBackingInt(@intCast(0)) }, .addend = 0 },
        .{ .offset = 6, .kind = .call_relative_32, .reference = .{ .function = @fromBackingInt(@intCast(0)) }, .addend = 0 },
    };
    const references = [_]structures.InstanceId{shared_id};
    const entry: structures.CompiledFunction = .{
        .code = &entry_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const shared_code = [_]u8{ 0xB8, 0x78, 0x56, 0x34, 0x12, 0xC3 };
    const shared: structures.CompiledFunction = .{
        .code = &shared_code,
        .required_alignment = 1,
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = shared_id, .artifact = shared },
    };

    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);

    const shared_offset = std.mem.indexOf(u8, executable.bytes, &shared_code).?;
    const entry_offset = shared_offset - entry_code.len;
    for ([_]usize{ entry_offset + 1, entry_offset + 6 }) |field_offset| {
        const displacement = std.mem.readInt(i32, executable.bytes[field_offset..][0..4], .little);
        const expected: i64 = @as(i64, @intCast(shared_offset)) - @as(i64, @intCast(field_offset)) - 4;
        try std.testing.expectEqual(expected, displacement);
    }
    try std.testing.expect(std.mem.indexOfPos(u8, executable.bytes, shared_offset + 1, &shared_code) == null);
}

test "executable builder resolves cyclic artifact graphs" {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(2)) };
    const first_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const second_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocation = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = .{ .function = @fromBackingInt(@intCast(0)) },
        .addend = 0,
    }};
    const entry_references = [_]structures.InstanceId{first_id};
    const first_references = [_]structures.InstanceId{second_id};
    const second_references = [_]structures.InstanceId{first_id};
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = .{ .code = &call_code, .required_alignment = 1, .relocations = &relocation, .referenced_instances = &entry_references } },
        .{ .instance = first_id, .artifact = .{ .code = &call_code, .required_alignment = 1, .relocations = &relocation, .referenced_instances = &first_references } },
        .{ .instance = second_id, .artifact = .{ .code = &call_code, .required_alignment = 1, .relocations = &relocation, .referenced_instances = &second_references } },
    };

    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);
    try std.testing.expect(executable.bytes.len > 0);
}

test "executable builder rejects a displacement outside the signed 32-bit range" {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const callee_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = .{ .function = @fromBackingInt(@intCast(0)) },
        // Forces the patched displacement past the signed 32-bit range
        // directly, without requiring a huge (real) address layout.
        .addend = std.math.maxInt(i64),
    }};
    const references = [_]structures.InstanceId{callee_id};
    const entry: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const callee_code = [_]u8{0xC3};
    const callee: structures.CompiledFunction = .{
        .code = &callee_code,
        .required_alignment = 1,
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    try std.testing.expectError(error.RelocationOverflow, codegen.buildExecutable(entry_id, &functions, std.testing.allocator));
}

test "executable construction cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(allocation_failure_allocator, testBuildExecutableAllocations, .{});
}

test "linked executable construction cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(allocation_failure_allocator, testBuildExecutableWithCalleeAllocations, .{});
}

fn testBuildExecutableWithCalleeAllocations(gpa: std.mem.Allocator) !void {
    const entry_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(1)) };
    const callee_id: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = .{ .function = @fromBackingInt(@intCast(0)) },
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{callee_id};
    const entry: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const callee_code = [_]u8{ 0xB8, 7, 0, 0, 0, 0xC3 };
    const callee: structures.CompiledFunction = .{
        .code = &callee_code,
        .required_alignment = 1,
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    var executable = try codegen.buildExecutable(entry_id, &functions, gpa);
    defer executable.deinit(gpa);
}

fn testBuildExecutableAllocations(gpa: std.mem.Allocator) !void {
    const entry: structures.InstanceId = .{ .item = @fromBackingInt(@intCast(0)) };
    const code = [_]u8{0xC3};
    const artifact: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
    };
    const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = artifact }};
    var executable = try codegen.buildExecutable(entry, &functions, gpa);
    defer executable.deinit(gpa);
}

test "native cursor addressing sign extends a negative dynamic index" {
    const bytes = [_]u8{ 42, 99 };
    var instructions = [_]structures.FunctionInstruction{
        .{ .const_storage_cursor = .{ .type_id = byte_reference_type, .data = @fromBackingInt(0), .offset = 1 } },
        integerConstant(1),
        integerNegate(1),
        .{ .cursor_element = .{ .cursor = @fromBackingInt(0), .index = @fromBackingInt(2), .type_id = byte_reference_type } },
        .{ .borrow_read = .{ .source = @fromBackingInt(3), .type_id = .byte } },
        .{ .byte_to_int = @fromBackingInt(4) },
        .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
    };
    var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }};
    var arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(5) } }};
    var body = functionSsa(&instructions, &blocks);
    body.call_arguments = &arguments;
    var artifact = try codegen.compileFunction(&body, TestTypes{ .data = &bytes }, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try expectArtifactExitCode(artifact, 42);
}

test "data relocations own deduplicated bytes and preserve cursor offsets" {
    var bytes = [_]u8{ 'a', 42, 0 };
    const cursor = structures.FunctionInstruction{ .const_storage_cursor = .{ .type_id = byte_reference_type, .data = @fromBackingInt(0), .offset = 1 } };
    var instructions = [_]structures.FunctionInstruction{
        cursor,
        .{ .const_storage_cursor = .{ .type_id = byte_reference_type, .data = @fromBackingInt(1), .offset = 1 } },
        .{ .borrow_read = .{ .source = @fromBackingInt(0), .type_id = .byte } },
        .{ .borrow_read = .{ .source = @fromBackingInt(1), .type_id = .byte } },
        .{ .byte_to_int = @fromBackingInt(2) },
        .{ .byte_to_int = @fromBackingInt(3) },
        .{ .addi = .{ .lhs = @fromBackingInt(4), .rhs = @fromBackingInt(5) } },
        .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
    };
    var blocks = [_]structures.FunctionBlock{.{ .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }};
    var ssa = functionSsa(&instructions, &blocks);
    var arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(6) } }};
    ssa.call_arguments = &arguments;
    var artifact = try codegen.compileFunction(&ssa, TestTypes{ .data = &bytes }, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), artifact.constant_data.len);
    try std.testing.expectEqualSlices(u8, &bytes, artifact.constant_data[0].bytes);
    bytes[1] = 99;
    try expectArtifactExitCode(artifact, 84);
}
