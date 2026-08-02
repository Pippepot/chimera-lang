const std = @import("std");
const codegen = @import("codegen_new.zig");
const runtime = @import("runtime.zig");
const structures = @import("structures.zig");

test "single aligned function artifact builds and runs without borrowing code" {
    const io = std.testing.io;
    var executable = blk: {
        const ssa: structures.SsaFunction = .{
            .instructions = &.{},
            .terminator = .return_unit,
        };
        var artifact = try codegen.compileFunction(&ssa, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        artifact.required_alignment = 16;
        break :blk try codegen.buildExecutable(&artifact, null, std.testing.allocator);
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
        const ssa: structures.SsaFunction = .{
            .instructions = &instructions,
            .terminator = .{ .return_value = @enumFromInt(0) },
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
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .terminator = .{ .return_value = @enumFromInt(1) },
    };
    try std.testing.expectError(error.InvalidSsa, codegen.compileFunction(&ssa, std.testing.allocator));
}

test "direct call artifacts own exact relocation metadata" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0xdeadbeef) };
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .direct_call = target },
    };
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .terminator = .return_unit,
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

test "invalid direct call SSA is rejected without allocating" {
    const target: structures.InstanceId = .{ .item = @enumFromInt(0) };
    var one_call = [_]structures.SsaFunction.Instruction{.{ .direct_call = target }};
    var two_calls = [_]structures.SsaFunction.Instruction{ .{ .direct_call = target }, .{ .direct_call = target } };
    var mixed = [_]structures.SsaFunction.Instruction{ .{ .direct_call = target }, .{ .integer_constant = 1 } };
    const cases = [_]structures.SsaFunction{
        .{ .instructions = &one_call, .terminator = .{ .return_value = @enumFromInt(0) } },
        .{ .instructions = &two_calls, .terminator = .return_unit },
        .{ .instructions = &mixed, .terminator = .return_unit },
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
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .terminator = .return_unit,
    };
    var artifact = try codegen.compileFunction(&ssa, gpa);
    defer artifact.deinit(gpa);
}

test "ordinary function compilation cleans up allocation failure" {
    var instructions = [_]structures.SsaFunction.Instruction{
        .{ .integer_constant = 7 },
    };
    const ssa: structures.SsaFunction = .{
        .instructions = &instructions,
        .terminator = .{ .return_value = @enumFromInt(0) },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, codegen.compileFunction(&ssa, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "executable builder rejects artifact metadata independently" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
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
    try std.testing.expectError(error.UnsupportedArtifactMetadata, codegen.buildExecutable(&with_relocation, null, failing.allocator()));

    const with_reference: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &references,
    };
    try std.testing.expectError(error.UnsupportedArtifactMetadata, codegen.buildExecutable(&with_reference, null, failing.allocator()));
    try std.testing.expect(!failing.has_induced_failure);
}

test "executable builder rejects a callee mismatched with entry metadata" {
    const code = [_]u8{0xC3};
    const no_call: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    const leaf_code = [_]u8{0xC3};
    const leaf: structures.CompiledFunction = .{
        .code = &leaf_code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    try std.testing.expectError(error.UnsupportedArtifactMetadata, codegen.buildExecutable(&no_call, &leaf, std.testing.allocator));

    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
    const with_call: structures.CompiledFunction = .{
        .code = &call_code,
        .required_alignment = 1,
        .relocations = &relocations,
        .referenced_instances = &references,
    };
    try std.testing.expectError(error.UnsupportedArtifactMetadata, codegen.buildExecutable(&with_call, null, std.testing.allocator));
}

test "executable builder resolves a direct call to its callee's file offset" {
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
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

    var executable = try codegen.buildExecutable(&entry, &callee, std.testing.allocator);
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

test "executable builder rejects a relocation outside entry code bounds" {
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 3,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
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
    try std.testing.expectError(error.RelocationOutOfBounds, codegen.buildExecutable(&entry, &callee, std.testing.allocator));
}

test "executable builder rejects a reference index outside referenced_instances" {
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(1),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
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
    try std.testing.expectError(error.RelocationOutOfBounds, codegen.buildExecutable(&entry, &callee, std.testing.allocator));
}

test "executable builder rejects a displacement outside the signed 32-bit range" {
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        // Forces the patched displacement past the signed 32-bit range
        // directly, without requiring a huge (real) address layout.
        .addend = std.math.maxInt(i64),
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
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
    try std.testing.expectError(error.RelocationOverflow, codegen.buildExecutable(&entry, &callee, std.testing.allocator));
}

test "executable construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBuildExecutableAllocations, .{});
}

test "linked executable construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBuildExecutableWithCalleeAllocations, .{});
}

fn testBuildExecutableWithCalleeAllocations(gpa: std.mem.Allocator) !void {
    const call_code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
    const relocations = [_]structures.CompiledFunction.Relocation{.{
        .offset = 1,
        .kind = .call_relative_32,
        .reference = @enumFromInt(0),
        .addend = 0,
    }};
    const references = [_]structures.InstanceId{.{ .item = @enumFromInt(0) }};
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
    var executable = try codegen.buildExecutable(&entry, &callee, gpa);
    defer executable.deinit(gpa);
}

fn testBuildExecutableAllocations(gpa: std.mem.Allocator) !void {
    const code = [_]u8{0xC3};
    const artifact: structures.CompiledFunction = .{
        .code = &code,
        .required_alignment = 1,
        .relocations = &.{},
        .referenced_instances = &.{},
    };
    var executable = try codegen.buildExecutable(&artifact, null, gpa);
    defer executable.deinit(gpa);
}
