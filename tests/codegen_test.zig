const std = @import("std");
const test_sources = @import("test_sources");
const codegen = test_sources.codegen;
const runtime = test_sources.runtime;
const structures = test_sources.structures;

const small_variant = structures.TypeId.fromInterned(@enumFromInt(0));
const wide_variant = structures.TypeId.fromInterned(@enumFromInt(1));
const seven_byte_payload = structures.TypeId.fromInterned(@enumFromInt(2));
const payload_variant = structures.TypeId.fromInterned(@enumFromInt(3));
const callable_type = structures.TypeId.fromInterned(@enumFromInt(4));

const TestTypes = struct {
    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn layout(_: @This(), type_id: structures.TypeId) !structures.TypeLayout {
        if (type_id == .int) return .{ .byte_size = 4, .byte_alignment = 4 };
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

    pub fn borrowElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
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
            .{ .parameters = &.{}, .return_type = .int, .is_fallible = false }
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
    return .{ .negi = @enumFromInt(operand) };
}

const IntegerBinaryOperation = enum { add, subtract, multiply, divide_signed };

fn integerBinary(operation: IntegerBinaryOperation, lhs: u32, rhs: u32) structures.FunctionBodyAnalysis.Instruction {
    const operands: structures.BinaryOperands = .{
        .lhs = @enumFromInt(lhs),
        .rhs = @enumFromInt(rhs),
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
        .block_argument_types = &.{},
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = instructions,
        .blocks = blocks,
        .entry = @enumFromInt(0),
    };
}

test "single aligned function artifact builds and runs without borrowing code" {
    const io = std.testing.io;
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
        const entry: structures.InstanceId = .{ .item = @enumFromInt(0) };
        const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = artifact }};
        break :blk try codegen.buildExecutable(entry, &functions, std.testing.allocator);
    };
    defer executable.deinit(std.testing.allocator);

    const artifact_code = [_]u8{ 0xBA, 1, 0, 0, 0, 0xC3 };
    const artifact_file_offset = std.mem.indexOf(u8, executable.bytes, &artifact_code).?;
    try std.testing.expectEqual(@as(u64, 0), (0x400000 + artifact_file_offset) % 16);

    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 0), runtime.runProg(io, std.testing.allocator, &.{}));
}

test "ordinary function artifacts encode signed 32-bit literal returns" {
    for ([_]i32{ std.math.minInt(i32), 7, std.math.maxInt(i32) }) |return_value| {
        var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
            integerConstant(return_value),
        };
        var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
            .instruction_start = 0,
            .instruction_end = 1,
            .terminator = .{ .return_value = .{ .value = @enumFromInt(0) } },
        }};
        const ssa = functionSsa(&instructions, &blocks);
        var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 11), artifact.code.len);
        try std.testing.expectEqual(@as(u8, 0xB8), artifact.code[0]);
        try std.testing.expectEqual(return_value, std.mem.readInt(i32, artifact.code[1..5], .little));
        try std.testing.expectEqualSlices(u8, &.{ 0xBA, 1, 0, 0, 0, 0xC3 }, artifact.code[5..]);
        try std.testing.expectEqual(@as(u32, 1), artifact.required_alignment);
        try std.testing.expectEqual(@as(usize, 0), artifact.relocations.len);
        try std.testing.expectEqual(@as(usize, 0), artifact.referenced_instances.len);
    }
}

test "external exit artifact reads its argument from the call stack" {
    var artifact = try codegen.compileExternalExit(std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{
        0x8B, 0x84, 0x24, 8,  0, 0, 0,
        0x89, 0xC7, 0xB8, 60, 0, 0, 0,
        0x0F, 0x05,
    }, artifact.code);
    try std.testing.expectEqual(@as(usize, 0), artifact.relocations.len);
    try std.testing.expectEqual(@as(usize, 0), artifact.referenced_instances.len);
}

test "direct call artifacts own exact relocation metadata" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0xdeadbeef) };
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

    instructions[0] = directCall(.{ .item = @enumFromInt(1) });
    var different_target = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer different_target.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.code, different_target.code);
    try std.testing.expectEqualSlices(structures.CompiledFunction.Relocation, first.relocations, different_target.relocations);
    try std.testing.expect(!structures.CompiledFunction.eql(first, different_target));
}

test "function references relocate absolute addresses for indirect calls" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0xabcdef01) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        .{ .function_ref = .{ .target = target.item, .type_id = callable_type } },
        .{ .call = .{
            .target = .{ .indirect = @enumFromInt(0) },
            .arguments = .{ .start = 0, .end = 0 },
            .return_type = .int,
        } },
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @enumFromInt(1) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .block_argument_types = &.{},
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0xFF, 0xD0 }) != null);
    try std.testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    try std.testing.expectEqual(@as(u32, 9), artifact.relocations[0].offset);
    try std.testing.expectEqual(structures.CompiledFunction.RelocationKind.address_absolute_64, artifact.relocations[0].kind);
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

fn expectDirectCallArtifact(artifact: structures.CompiledFunction, target: structures.InstanceId) !void {
    try std.testing.expectEqualSlices(u8, &.{ 0xE8, 0, 0, 0, 0, 0xBA, 1, 0, 0, 0, 0xC3 }, artifact.code);
    try std.testing.expectEqual(@as(u32, 1), artifact.required_alignment);
    try std.testing.expectEqual(@as(usize, 1), artifact.relocations.len);
    try std.testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try std.testing.expectEqual(structures.CompiledFunction.RelocationKind.call_relative_32, artifact.relocations[0].kind);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(artifact.relocations[0].reference));
    try std.testing.expectEqual(@as(i64, 0), artifact.relocations[0].addend);
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

test "multiple calls produce ordered relocations and deduplicate references" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(7) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(target),
        directCall(target),
        integerConstant(42),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @enumFromInt(2) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{
        0xE8, 0,  0, 0, 0,
        0xE8, 0,  0, 0, 0,
        0xB8, 42, 0, 0, 0,
        0xBA, 1,  0, 0, 0,
        0xC3,
    }, artifact.code);
    try std.testing.expectEqual(@as(usize, 2), artifact.relocations.len);
    try std.testing.expectEqual(@as(u32, 1), artifact.relocations[0].offset);
    try std.testing.expectEqual(@as(u32, 6), artifact.relocations[1].offset);
    try std.testing.expectEqual(@intFromEnum(artifact.relocations[0].reference), @intFromEnum(artifact.relocations[1].reference));
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

test "typed expression values survive calls and execute every integer arithmetic operator" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(3) };
    const expression_id: structures.InstanceId = .{ .item = @enumFromInt(2) };
    const left_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const right_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
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
        .terminator = .{ .return_value = .{ .value = @enumFromInt(10) } },
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
        .reference = @enumFromInt(0),
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
            .relocations = &.{},
            .referenced_instances = &.{},
        } },
        .{ .instance = right_id, .artifact = .{
            .code = &right_code,
            .required_alignment = 1,
            .relocations = &.{},
            .referenced_instances = &.{},
        } },
    };
    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);

    const io = std.testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 42), runtime.runProg(io, std.testing.allocator, &.{}));
}

test "cyclic CFG accepts multi-value parallel backedge copies" {
    var block_argument_types = [_]structures.TypeId{ .int, .int, .int, .int, .int };
    var branch_arguments = [_]structures.FunctionValueUse{
        .{ .value = @enumFromInt(0) },
        .{ .value = @enumFromInt(1) },
        .{ .value = @enumFromInt(3) },
        .{ .value = @enumFromInt(2) },
        .{ .value = @enumFromInt(2) },
    };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{integerConstant(0)};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{
        .{
            .argument_start = 0,
            .argument_end = 2,
            .instruction_start = 0,
            .instruction_end = 0,
            .terminator = .{ .branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 2 } } },
        },
        .{
            .argument_start = 2,
            .argument_end = 4,
            .instruction_start = 0,
            .instruction_end = 1,
            .terminator = .{ .predicate_branch = .{
                .operation = .gti,
                .operands = .{ .lhs = @enumFromInt(2), .rhs = @enumFromInt(5) },
                .then_branch = .{ .target = @enumFromInt(2), .arguments = .{ .start = 4, .end = 5 } },
                .else_branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 2, .end = 4 } },
            } },
        },
        .{
            .argument_start = 4,
            .argument_end = 5,
            .instruction_start = 1,
            .instruction_end = 1,
            .terminator = .{ .return_value = .{ .value = @enumFromInt(4) } },
        },
    };
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .block_argument_types = &block_argument_types,
        .branch_arguments = &branch_arguments,
        .call_arguments = &.{},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };

    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.code.len != 0);
}

test "direct call artifact construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompileDirectCallAllocations, .{});
}

test "expression artifact construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompileExpressionAllocations, .{});
}

test "variant subset call construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompileVariantSubsetCallAllocations, .{});
}

test "variant injection copies an arbitrary-size non-variant interned payload" {
    var block_argument_types = [_]structures.TypeId{seven_byte_payload};
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .variant_coerce = .{
        .operand = @enumFromInt(0),
        .target_type = payload_variant,
        .tag_mapping = .{ .start = 0, .end = 1 },
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .argument_end = 1,
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = .{ .value = @enumFromInt(1) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = payload_variant,
        .block_argument_types = &block_argument_types,
        .variant_coercion_tags = &.{1},
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, std.testing.allocator);
    defer artifact.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0x0F, 0xB6, 0x84, 0x24 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.code, &.{ 0x88, 0x84, 0x24 }) != null);
}

fn testCompileVariantSubsetCallAllocations(gpa: std.mem.Allocator) !void {
    var block_argument_types = [_]structures.TypeId{small_variant};
    var call_arguments = [_]structures.FunctionValueUse{.{
        .value = @enumFromInt(0),
        .coerce_to = wide_variant,
        .variant_tag_mapping = .{ .start = 0, .end = 2 },
    }};
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = .{
        .target = .{ .direct = .{ .item = @enumFromInt(0) } },
        .arguments = .{ .start = 0, .end = 1 },
        .return_type = wide_variant,
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .argument_end = 1,
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = .{ .value = @enumFromInt(1) } },
    }};
    const ssa: structures.FunctionBodyAnalysis = .{
        .return_type = wide_variant,
        .block_argument_types = &block_argument_types,
        .variant_coercion_tags = &.{ 0, 2 },
        .branch_arguments = &.{},
        .call_arguments = &call_arguments,
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, gpa);
    defer artifact.deinit(gpa);
}

fn testCompileExpressionAllocations(gpa: std.mem.Allocator) !void {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(.{ .item = @enumFromInt(0) }),
        integerConstant(2),
        integerBinary(.multiply, 0, 1),
        integerConstant(1),
        integerBinary(.add, 2, 3),
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = .{ .value = @enumFromInt(4) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var artifact = try codegen.compileFunction(&ssa, TestTypes{}, gpa);
    defer artifact.deinit(gpa);
}

fn testCompileDirectCallAllocations(gpa: std.mem.Allocator) !void {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        directCall(.{ .item = @enumFromInt(0) }),
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
        .terminator = .{ .return_value = .{ .value = @enumFromInt(0) } },
    }};
    const ssa = functionSsa(&instructions, &blocks);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codegen.compileFunction(&ssa, TestTypes{}, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "executable builder rejects artifact metadata independently" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const entry: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const code = [_]u8{0xC3};
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 0,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};

    const with_relocation: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &.{},
    };
    const invalid_functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = with_relocation }};
    try std.testing.expectError(error.RelocationOutOfBounds, codegen.buildExecutable(entry, &invalid_functions, failing.allocator()));
    try std.testing.expect(!failing.has_induced_failure);

    const with_reference: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &references,
    };
    const missing_functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = with_reference }};
    try std.testing.expectError(error.MissingReferencedArtifact, codegen.buildExecutable(entry, &missing_functions, std.testing.allocator));
}

test "executable builder requires the entry and every referenced artifact" {
    const entry: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const leaf_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const leaf_code = [_]u8{0xC3};
    const leaf: structures.CompiledFunction = .{
        .code = &leaf_code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const only_leaf = [_]codegen.ReachableFunction{.{ .instance = leaf_id, .artifact = leaf }};
    try std.testing.expectError(error.MissingEntryArtifact, codegen.buildExecutable(entry, &only_leaf, std.testing.allocator));

    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{leaf_id};
    const with_call: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const only_entry = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = with_call }};
    try std.testing.expectError(error.MissingReferencedArtifact, codegen.buildExecutable(entry, &only_entry, std.testing.allocator));
}

test "executable builder resolves a direct call to its callee's file offset" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const callee_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{callee_id};
    const entry: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    const callee_code = [_]u8{ 0xB8, 42, 0, 0, 0, 0xC3 };
    const callee: structures.CompiledFunction = .{
        .code = &callee_code,
        .required_alignment = 16,
        .relocations = &.{},
        .referenced_instances = &.{},
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

    const io = std.testing.io;
    try runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 0), runtime.runProg(io, std.testing.allocator, &.{}));
}

test "executable builder patches multiple relocations to one shared artifact" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const shared_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const entry_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{
        .{ .offset = 1, .kind = .call_relative_32, .reference = @enumFromInt(0), .addend = 0 },
        .{ .offset = 6, .kind = .call_relative_32, .reference = @enumFromInt(0), .addend = 0 },
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
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = shared_id, .artifact = shared },
    };

    var executable = try codegen.buildExecutable(entry_id, &functions, std.testing.allocator);
    defer executable.deinit(std.testing.allocator);

    const startup_suffix = [_]u8{ 0x31, 0xFF, 0xB8, 60, 0, 0, 0, 0x0F, 0x05 };
    const entry_offset = std.mem.indexOf(u8, executable.bytes, &startup_suffix).? + startup_suffix.len;
    const shared_offset = std.mem.indexOf(u8, executable.bytes, &shared_code).?;
    for ([_]usize{ entry_offset + 1, entry_offset + 6 }) |field_offset| {
        const displacement = std.mem.readInt(i32, executable.bytes[field_offset..][0..4], .little);
        const expected: i64 = @as(i64, @intCast(shared_offset)) - @as(i64, @intCast(field_offset)) - 4;
        try std.testing.expectEqual(expected, displacement);
    }
    try std.testing.expect(std.mem.indexOfPos(u8, executable.bytes, shared_offset + 1, &shared_code) == null);
}

test "executable builder resolves cyclic artifact graphs" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(2) };
    const first_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const second_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocation = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
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

test "executable builder rejects a relocation outside entry code bounds" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const callee_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 3,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
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
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    try std.testing.expectError(error.RelocationOutOfBounds, codegen.buildExecutable(entry_id, &functions, std.testing.allocator));
}

test "executable builder rejects a reference index outside referenced_instances" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const callee_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(1),
        .addend = 0,
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
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    try std.testing.expectError(error.RelocationOutOfBounds, codegen.buildExecutable(entry_id, &functions, std.testing.allocator));
}

test "executable builder rejects a displacement outside the signed 32-bit range" {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const callee_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
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
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    try std.testing.expectError(error.RelocationOverflow, codegen.buildExecutable(entry_id, &functions, std.testing.allocator));
}

test "executable construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBuildExecutableAllocations, .{});
}

test "linked executable construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBuildExecutableWithCalleeAllocations, .{});
}

fn testBuildExecutableWithCalleeAllocations(gpa: std.mem.Allocator) !void {
    const entry_id: structures.InstanceId = .{ .item = @enumFromInt(1) };
    const callee_id: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
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
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{
        .{ .instance = entry_id, .artifact = entry },
        .{ .instance = callee_id, .artifact = callee },
    };
    var executable = try codegen.buildExecutable(entry_id, &functions, gpa);
    defer executable.deinit(gpa);
}

fn testBuildExecutableAllocations(gpa: std.mem.Allocator) !void {
    const entry: structures.InstanceId = .{ .item = @enumFromInt(0) };
    const code = [_]u8{0xC3};
    const artifact: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = artifact }};
    var executable = try codegen.buildExecutable(entry, &functions, gpa);
    defer executable.deinit(gpa);
}
