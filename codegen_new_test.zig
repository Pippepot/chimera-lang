const std = @import("std");
const codegen = @import("codegen_new.zig");
const runtime = @import("runtime.zig");
const structures = @import("structures.zig");

test "single aligned function artifact builds and runs without borrowing code" {
    const io = std.testing.io;
    var executable = blk: {
        var blocks = [_]structures.SsaFunction.Block{.{
            .instruction_start = 0,
            .instruction_end = 0,
            .terminator = .return_unit,
        }};
        const ssa: structures.SsaFunction = .{
            .instructions = &.{},
            .blocks = &blocks,
            .entry = @enumFromInt(0),
        };
        var artifact = try codegen.compileFunction(&ssa, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        artifact.required_alignment = 16;
        const entry: structures.InstanceId = .{ .item = @enumFromInt(0) };
        const functions = [_]codegen.ReachableFunction{.{ .instance = entry, .artifact = artifact }};
        break :blk try codegen.buildExecutable(entry, &functions, std.testing.allocator);
    };
    defer executable.deinit(std.testing.allocator);

    const artifact_code = [_]u8{0xC3};
    const artifact_file_offset = std.mem.indexOf(u8, executable.bytes, &artifact_code).?;
    try std.testing.expectEqual(@as(u64, 0), (0x400000 + artifact_file_offset) % 16);

    runtime.writeProgram(io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 0), runtime.runProg(io, std.testing.allocator, &.{}));
}

test "ordinary function artifacts encode signed 32-bit literal returns" {
    for ([_]i32{ std.math.minInt(i32), 7, std.math.maxInt(i32) }) |return_value| {
        var instructions = [_]structures.SsaFunction.Instruction{
            .{ .integer_constant = return_value },
        };
        var blocks = [_]structures.SsaFunction.Block{.{
            .instruction_start = 0,
            .instruction_end = 1,
            .terminator = .{ .return_value = @enumFromInt(0) },
        }};
        const ssa: structures.SsaFunction = .{
            .instructions = &instructions,
            .blocks = &blocks,
            .entry = @enumFromInt(0),
        };
        var artifact = try codegen.compileFunction(&ssa, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 6), artifact.code.len);
        try std.testing.expectEqual(@as(u8, 0xB8), artifact.code[0]);
        try std.testing.expectEqual(return_value, std.mem.readInt(i32, artifact.code[1..5], .little));
        try std.testing.expectEqual(@as(u8, 0xC3), artifact.code[5]);
        try std.testing.expectEqual(@as(u32, 1), artifact.required_alignment);
        try std.testing.expectEqual(@as(usize, 0), artifact.relocations.len);
        try std.testing.expectEqual(@as(usize, 0), artifact.referenced_instances.len);
    }
}

test "ordinary function compilation rejects an invalid return value" {
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .integer_constant = 7 },
    };
    var blocks = [_]structures.SsaFunction.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(1) },
    }};
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expectError(error.InvalidSsa, codegen.compileFunction(&ssa, std.testing.allocator));
}

test "direct call artifacts own exact relocation metadata" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0xdeadbeef) };
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .direct_call = target },
    };
    var blocks = [_]structures.SsaFunction.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };

    var first = try codegen.compileFunction(&ssa, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try codegen.compileFunction(&ssa, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try expectDirectCallArtifact(first, target);
    try expectDirectCallArtifact(second, target);
    try std.testing.expect(first.code.ptr != second.code.ptr);
    try std.testing.expect(first.relocations.ptr != second.relocations.ptr);
    try std.testing.expect(first.referenced_instances.ptr != second.referenced_instances.ptr);
    try std.testing.expect(structures.CompiledFunction.eql(first, second));

    instructions[0] = .{ .direct_call = .{ .item = @enumFromInt(1) } };
    var different_target = try codegen.compileFunction(&ssa, std.testing.allocator);
    defer different_target.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.code, different_target.code);
    try std.testing.expectEqualSlices(structures.CompiledFunction.Relocation, first.relocations, different_target.relocations);
    try std.testing.expect(!structures.CompiledFunction.eql(first, different_target));
}

fn expectDirectCallArtifact(artifact: structures.CompiledFunction, target: structures.InstanceId) !void {
    try std.testing.expectEqualSlices(u8, &.{ 0xE8, 0, 0, 0, 0, 0xC3 }, artifact.code);
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
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .direct_call = target },
        .{ .direct_call = target },
        .{ .integer_constant = 42 },
    };
    var blocks = [_]structures.SsaFunction.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = @enumFromInt(2) },
    }};
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };

    var artifact = try codegen.compileFunction(&ssa, std.testing.allocator);
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
    try std.testing.expectEqual(@intFromEnum(artifact.relocations[0].reference), @intFromEnum(artifact.relocations[1].reference));
    try std.testing.expectEqualSlices(structures.InstanceId, &.{target}, artifact.referenced_instances);
}

test "structurally invalid SSA is rejected without allocating" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0) };
    var one_call = [_]structures.SsaFunction.Instruction{.{ .direct_call = target }};
    var bad_start = [_]structures.SsaFunction.Block{.{ .instruction_start = 1, .instruction_end = 1, .terminator = .return_unit }};
    var bad_end = [_]structures.SsaFunction.Block{.{ .instruction_start = 0, .instruction_end = 0, .terminator = .return_unit }};
    var two_blocks = [_]structures.SsaFunction.Block{
        .{ .instruction_start = 0, .instruction_end = 1, .terminator = .return_unit },
        .{ .instruction_start = 1, .instruction_end = 1, .terminator = .return_unit },
    };
    const cases = [_]structures.SsaFunction{
        .{ .instructions = &one_call, .blocks = &bad_start, .entry = @enumFromInt(0) },
        .{ .instructions = &one_call, .blocks = &bad_end, .entry = @enumFromInt(0) },
        .{ .instructions = &one_call, .blocks = &two_blocks, .entry = @enumFromInt(0) },
    };

    for (cases) |ssa| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.InvalidSsa, codegen.compileFunction(&ssa, failing.allocator()));
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "direct call artifact construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompileDirectCallAllocations, .{});
}

fn testCompileDirectCallAllocations(gpa: std.mem.Allocator) !void {
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .direct_call = .{ .item = @enumFromInt(0) } },
    };
    var blocks = [_]structures.SsaFunction.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var artifact = try codegen.compileFunction(&ssa, gpa);
    defer artifact.deinit(gpa);
}

test "ordinary function compilation cleans up allocation failure" {
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .integer_constant = 7 },
    };
    var blocks = [_]structures.SsaFunction.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(0) },
    }};
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codegen.compileFunction(&ssa, failing.allocator()));
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
    runtime.writeProgram(io, executable.bytes);
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
