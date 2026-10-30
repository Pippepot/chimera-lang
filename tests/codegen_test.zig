const std = @import("std");
const test_sources = @import("test_sources");
const codegen = test_sources.codegen;
const runtime = test_sources.runtime;
const structures = test_sources.structures;
const allocation_failure_allocator = test_sources.allocation_failure_allocator;

test "machine encoding is available before native allocation" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    try function.emit(.ret);
    var encoded = try function.encode(&.{}, &.{}, &.{});
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{0xc3}, encoded.code.items);
}

test "machine pointer operands preserve register and spill width" {
    for (0..3) |mode| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.store_rax, @fromBackingInt(0), 0);
        try function.register(.load_rax, @fromBackingInt(0), 0);
        var encoded = try function.encode(&.{switch (mode) {
            0 => .rbx,
            1 => .r12,
            else => null,
        }}, &.{256}, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = switch (mode) {
            0 => &.{ 0x48, 0x89, 0xc3, 0x48, 0x89, 0xd8 },
            1 => &.{ 0x49, 0x89, 0xc4, 0x4c, 0x89, 0xe0 },
            else => &.{ 0x48, 0x89, 0x84, 0x24, 0, 1, 0, 0, 0x48, 0x8b, 0x84, 0x24, 0, 1, 0, 0 },
        };
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    }
}

test "machine parameter loads disappear when the ABI home is retained" {
    for (0..3) |mode| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.instructions.append(std.testing.allocator, .{ .parameter = .{ .value = @fromBackingInt(0), .offset = 128 } });
        try function.emit(.ret);
        function.verify(1);
        var encoded = try function.encode(&.{switch (mode) {
            0 => .r8,
            1 => .r11,
            else => null,
        }}, &.{128}, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = switch (mode) {
            0 => &.{ 0x44, 0x8B, 0x84, 0x24, 128, 0, 0, 0, 0xC3 },
            1 => &.{ 0x44, 0x8B, 0x9C, 0x24, 128, 0, 0, 0, 0xC3 },
            else => &.{0xC3},
        };
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    }
}

test "machine parameter caching does not displace local values" {
    for ([_]usize{ 4, 10 }) |local_count| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.instructions.append(std.testing.allocator, .{ .parameter = .{ .value = @fromBackingInt(0), .offset = 0 } });
        for (1..local_count + 1) |index| try function.register(.store_eax, @fromBackingInt(@intCast(index)), 0);
        for (0..20) |_| try function.register(.load_eax, @fromBackingInt(0), 0);
        for (1..local_count + 1) |index| try function.register(.load_eax, @fromBackingInt(@intCast(index)), 0);
        var allocation = try test_sources.registers.allocate(std.testing.allocator, &function, local_count + 1);
        defer allocation.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?test_sources.x86_encoding.Register, null), allocation.registers[0]);
        try std.testing.expectEqual(local_count, allocation.used.len);
        for (allocation.registers[1..]) |register| try std.testing.expect(register != null);
    }
}

test "machine preservation excludes caller-saved registers" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    try function.preserve(false, 0);
    try function.preserve(true, 0);
    var encoded = try function.encode(&.{}, &.{}, &.{ .r8, .rbx, .r11 });
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x1C, 0x24, 0x48, 0x8B, 0x1C, 0x24 }, encoded.code.items);
}

test "machine indexed constant stores preserve base encoding and spill fallback" {
    for (0..3) |mode| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_rax, @fromBackingInt(0), 0);
        try function.emit(.lea_rax_rax_rcx_4);
        try function.immediate(.mov_rax_i32, 1);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{switch (mode) {
            0 => .rbx,
            1 => .r13,
            else => null,
        }}, &.{256}, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = switch (mode) {
            0 => &.{ 0xc7, 0x04, 0x8b, 1, 0, 0, 0 },
            1 => &.{ 0x41, 0xc7, 0x44, 0x8d, 0, 1, 0, 0, 0 },
            else => &.{ 0x48, 0x8b, 0x84, 0x24, 0, 1, 0, 0, 0x48, 0x8d, 0x04, 0x88, 0xc7, 0, 1, 0, 0, 0 },
        };
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    }
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    try function.register(.load_rax, @fromBackingInt(0), 0);
    try function.emit(.lea_rax_rax_rcx_4);
    try function.immediate(.mov_rax_i32, 1);
    try function.emit(.mov_rdi_rax);
    var encoded = try function.encode(&.{.rbx}, &.{0}, &.{});
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xd8, 0x48, 0x8d, 0x04, 0x88, 0xc7, 0, 1, 0, 0, 0, 0x48, 0x89, 0xc7 }, encoded.code.items);
}

test "loop allocation bases preserve checked element reads and writes" {
    try test_sources.SourceFixture.expectParity(
        \\func run() int
        \\    var values = List(int).filled(0, 16)
        \\    if not (values is List(int)) -> return 0
        \\    var index = 0
        \\    loop
        \\        if index == values.len() -> break
        \\        values[index] = index + 1
        \\        index += 1
        \\    var count = 0
        \\    for number in 0..values.len()
        \\        if values[number] > 0 -> count += 1
        \\    return count + values[15] + 10
    , 42);
}

test "loop allocation snapshots follow descriptor replacement through variant aliases" {
    try test_sources.SourceFixture.expectParity(
        \\func run() int
        \\    var values = List(int).new(1)
        \\    if not (values is List(int)) -> return 90
        \\    ref selected = values
        \\    var index = 0
        \\    loop
        \\        if index == 8 -> break
        \\        const appended = selected.append(index + 1)
        \\        if not (appended is unit) -> return 91
        \\        selected[0] += 1
        \\        index += 1
        \\    var total = 0
        \\    for position in 0..8
        \\        total += selected[position]
        \\    return total - 2
    , 42);
}

test "conditional counting preserves wrapping and both predicate outcomes" {
    try test_sources.SourceFixture.expectParity(
        \\func run() int
        \\    var values: List(int) = [0, 1, -1]
        \\    var wrapping = 2147483647
        \\    var count = 40
        \\    for number in 0..values.len()
        \\        if values[number] == 0 -> wrapping += 1
        \\        if values[number] <> 0 -> count += 1
        \\    if wrapping <> -2147483648 -> return 0
        \\    return count
    , 42);
}

test "conditional increments preserve both instruction orders and comparison dependencies" {
    for (0..3) |order| for ([_]bool{ false, true }) |matched| {
        const comparison_index: u32 = if (order == 0) 4 else 5;
        const addition_index: u32 = if (order == 0) 5 else 4;
        var instructions = [_]structures.FunctionInstruction{
            .{ .const_int = if (matched) 41 else 42 },
            .{ .const_int = 1 },
            .{ .const_int = 7 },
            .{ .const_int = if (order == 2) 42 else if (matched) 7 else 9 },
            .const_unit,
            .const_unit,
            .{ .select = .{ .condition = @fromBackingInt(comparison_index), .then_value = @fromBackingInt(addition_index), .else_value = @fromBackingInt(0), .type_id = .int } },
            .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
        };
        instructions[addition_index] = .{ .addi = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(1) } };
        instructions[comparison_index] = .{ .compare = .{ .operation = .eqi, .operands = .{ .lhs = @fromBackingInt(if (order == 2) addition_index else 2), .rhs = @fromBackingInt(3) } } };
        const body: structures.FunctionBodyAnalysis = .{
            .return_type = .unit,
            .call_arguments = &.{.{ .prepared = .{ .value = @fromBackingInt(6) } }},
            .instructions = &instructions,
            .blocks = &.{.{ .argument_start = 0, .argument_end = 0, .instruction_start = 0, .instruction_end = instructions.len, .terminator = .diverge }},
            .entry = @fromBackingInt(0),
        };
        var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
        defer artifact.deinit(std.testing.allocator);
        try expectArtifactExitCode(artifact, 42);
    };
}

test "machine symbolic positions resolve after register and spill encoding" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    const value: test_sources.machine.ValueId = @fromBackingInt(0);
    try function.immediate(.mov_eax, 42);
    try function.register(.store_eax, value, 0);
    const jump = try function.patchable(.jmp);
    try function.register(.load_eax, value, 0);
    try function.patchHere(jump);
    const returned = try function.position();
    try function.emit(.ret);
    for (0..2) |index| {
        var encoded = try function.encode(&.{if (index == 0) .rbx else null}, &.{256}, &.{});
        defer encoded.deinit(std.testing.allocator);
        const field = encoded.fields[jump];
        const displacement = std.mem.readInt(i32, encoded.code.items[field..][0..4], .little);
        try std.testing.expectEqual(@as(i64, encoded.positions[returned]), @as(i64, field) + 4 + displacement);
        try std.testing.expectEqual(@as(u8, 0xc3), encoded.code.items[encoded.positions[returned]]);
    }
}

test "machine register copies forward only when scratch is dead" {
    for (0..5) |mode| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        if (mode == 3) _ = try function.position();
        try function.register(.store_eax, @fromBackingInt(1), 0);
        if (mode != 2) try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{ if (mode == 4) null else .r12, if (mode == 1) .r12 else .rbx }, &.{ 0, 4 }, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = switch (mode) {
            0 => &.{ 0x41, 0x8B, 0xDC },
            1 => &.{},
            2, 3 => &.{ 0x44, 0x89, 0xE0, 0x89, 0xC3 },
            else => &.{ 0x8B, 0x04, 0x24, 0x89, 0xC3 },
        };
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    }
}

test "machine comparisons avoid scratch copies for register and immediate operands" {
    const cases = [_]struct { lhs: test_sources.x86_encoding.Register, rhs: test_sources.x86_encoding.Register, expected: []const u8 }{
        .{ .lhs = .rbx, .rhs = .rbp, .expected = &.{ 0x3B, 0xDD } },
        .{ .lhs = .rbx, .rhs = .r12, .expected = &.{ 0x41, 0x3B, 0xDC } },
        .{ .lhs = .r12, .rhs = .rbx, .expected = &.{ 0x44, 0x3B, 0xE3 } },
        .{ .lhs = .r12, .rhs = .r13, .expected = &.{ 0x45, 0x3B, 0xE5 } },
    };
    for (cases) |case| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        try function.register(.cmp_eax, @fromBackingInt(1), 0);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{ case.lhs, case.rhs }, &.{ 0, 4 }, &.{});
        defer encoded.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, case.expected, encoded.code.items);
    }
    for ([_]i32{ -129, -128, 0, 127, 128 }) |immediate| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        try function.immediate(.cmp_eax, immediate);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{.r12}, &.{0}, &.{});
        defer encoded.deinit(std.testing.allocator);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(std.testing.allocator);
        try expected.appendSlice(std.testing.allocator, if (std.math.cast(i8, immediate) != null) &.{ 0x41, 0x83, 0xFC } else &.{ 0x41, 0x81, 0xFC });
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(immediate)));
        try expected.appendSlice(std.testing.allocator, bytes[0..if (std.math.cast(i8, immediate) != null) @as(usize, 1) else 4]);
        try std.testing.expectEqualSlices(u8, expected.items, encoded.code.items);
    }
}

test "machine comparisons preserve compact spill operands and scratch boundaries" {
    for ([_]u32{ 0, 127, 128 }) |offset| for ([_]bool{ false, true }) |spilled_operand| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        if (spilled_operand) {
            try function.register(.cmp_eax, @fromBackingInt(1), 0);
        } else try function.offset(.cmp_eax_rsp, offset);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{ .r12, null }, &.{ 0, offset }, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = switch (offset) {
            0 => &.{ 0x44, 0x3B, 0x24, 0x24 },
            127 => &.{ 0x44, 0x3B, 0x64, 0x24, 127 },
            else => &.{ 0x44, 0x3B, 0xA4, 0x24, 128, 0, 0, 0 },
        };
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    };
    for (0..3) |mode| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        if (mode == 1) _ = try function.position();
        try function.immediate(.cmp_eax, 7);
        if (mode != 0) try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{if (mode == 2) null else .rbx}, &.{0}, &.{});
        defer encoded.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, if (mode == 2) &.{ 0x8B, 0x04, 0x24, 0x83, 0xF8, 7 } else &.{ 0x89, 0xD8, 0x83, 0xF8, 7 }, encoded.code.items);
    }
}

test "machine in-place arithmetic requires dead scratch and respects labels" {
    for (0..3) |mode| for ([_]bool{ false, true }) |register_operand| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        if (mode == 2) _ = try function.position();
        if (register_operand)
            try function.register(.sub_eax, @fromBackingInt(1), 0)
        else
            try function.immediate(.sub_eax, 7);
        try function.register(.store_eax, @fromBackingInt(2), 0);
        if (mode != 1) try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{ .rbx, .r12, .rbx }, &.{ 0, 4, 8 }, &.{});
        defer encoded.deinit(std.testing.allocator);
        const expected: []const u8 = if (register_operand)
            (if (mode == 0) &.{ 0x41, 0x2B, 0xDC } else &.{ 0x89, 0xD8, 0x44, 0x29, 0xE0, 0x89, 0xC3 })
        else
            (if (mode == 0) &.{ 0x83, 0xeb, 7 } else &.{ 0x89, 0xd8, 0x83, 0xe8, 7, 0x89, 0xc3 });
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    };
}

test "machine in-place register arithmetic avoids scratch copies" {
    const cases = [_]struct { destination: test_sources.x86_encoding.Register, source: test_sources.x86_encoding.Register, expected: [3][]const u8 }{
        .{ .destination = .rbx, .source = .rbp, .expected = .{ &.{ 0x03, 0xDD }, &.{ 0x2B, 0xDD }, &.{ 0x0F, 0xAF, 0xDD } } },
        .{ .destination = .rbx, .source = .r12, .expected = .{ &.{ 0x41, 0x03, 0xDC }, &.{ 0x41, 0x2B, 0xDC }, &.{ 0x41, 0x0F, 0xAF, 0xDC } } },
        .{ .destination = .r12, .source = .rbx, .expected = .{ &.{ 0x44, 0x03, 0xE3 }, &.{ 0x44, 0x2B, 0xE3 }, &.{ 0x44, 0x0F, 0xAF, 0xE3 } } },
        .{ .destination = .r12, .source = .r13, .expected = .{ &.{ 0x45, 0x03, 0xE5 }, &.{ 0x45, 0x2B, 0xE5 }, &.{ 0x45, 0x0F, 0xAF, 0xE5 } } },
        .{ .destination = .r13, .source = .r13, .expected = .{ &.{ 0x45, 0x03, 0xED }, &.{ 0x45, 0x2B, 0xED }, &.{ 0x45, 0x0F, 0xAF, 0xED } } },
    };
    for (cases) |case| for ([_]test_sources.x86_encoding.RegisterOperation{ .add_eax, .sub_eax, .imul_eax }, case.expected) |operation, expected| for ([_]bool{ false, true }) |reuse_rhs| {
        if (reuse_rhs and operation == .sub_eax) continue;
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        try function.register(operation, @fromBackingInt(1), 0);
        try function.register(.store_eax, @fromBackingInt(2), 0);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        const registers = if (reuse_rhs)
            [_]?test_sources.x86_encoding.Register{ case.source, case.destination, case.destination }
        else
            [_]?test_sources.x86_encoding.Register{ case.destination, case.source, case.destination };
        var encoded = try function.encode(&registers, &.{ 0, 4, 8 }, &.{});
        defer encoded.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    };
}

test "machine in-place stack arithmetic preserves compact offsets" {
    const cases = [_]struct { destination: test_sources.x86_encoding.Register, offset: u32, expected: [3][]const u8 }{
        .{ .destination = .rbx, .offset = 0, .expected = .{ &.{ 0x03, 0x1C, 0x24 }, &.{ 0x2B, 0x1C, 0x24 }, &.{ 0x0F, 0xAF, 0x1C, 0x24 } } },
        .{ .destination = .r12, .offset = 127, .expected = .{ &.{ 0x44, 0x03, 0x64, 0x24, 127 }, &.{ 0x44, 0x2B, 0x64, 0x24, 127 }, &.{ 0x44, 0x0F, 0xAF, 0x64, 0x24, 127 } } },
        .{ .destination = .r13, .offset = 128, .expected = .{ &.{ 0x44, 0x03, 0xAC, 0x24, 128, 0, 0, 0 }, &.{ 0x44, 0x2B, 0xAC, 0x24, 128, 0, 0, 0 }, &.{ 0x44, 0x0F, 0xAF, 0xAC, 0x24, 128, 0, 0, 0 } } },
    };
    for (cases) |case| for ([_]test_sources.x86_encoding.Operation{ .add_eax_rsp, .sub_eax_rsp, .imul_eax_rsp }, case.expected) |operation, expected| for ([_]bool{ false, true }) |spilled_operand| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        try function.register(.load_eax, @fromBackingInt(0), 0);
        if (spilled_operand) {
            try function.register(switch (operation) {
                .add_eax_rsp => .add_eax,
                .sub_eax_rsp => .sub_eax,
                .imul_eax_rsp => .imul_eax,
                else => unreachable,
            }, @fromBackingInt(1), 0);
        } else try function.offset(operation, case.offset);
        try function.register(.store_eax, @fromBackingInt(2), 0);
        try function.instructions.append(std.testing.allocator, .scratch_dead);
        var encoded = try function.encode(&.{ case.destination, null, case.destination }, &.{ 0, case.offset, 4 }, &.{});
        defer encoded.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, expected, encoded.code.items);
    };
}

test "machine liveness retains expanded branch uses under register pressure" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    for (0..12) |index| {
        try function.immediate(.mov_eax, @intCast(index));
        try function.register(.store_eax, @fromBackingInt(@intCast(index)), 0);
    }
    try function.emit(.test_eax);
    const skip = try function.patchable(.je);
    try function.register(.load_eax, @fromBackingInt(7), 0);
    try function.patchHere(skip);
    for (0..12) |index| try function.register(.load_eax, @fromBackingInt(@intCast(index)), 0);
    try function.emit(.ret);
    function.verify(12);
    var allocation = try test_sources.registers.allocate(std.testing.allocator, &function, 12);
    defer allocation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), allocation.used.len);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(@TypeOf(allocation.registers[0]), allocation.registers, &.{null}));
    for (allocation.registers, 0..) |selected, index| {
        if (selected == null) continue;
        for (allocation.registers[index + 1 ..]) |other| if (other) |register| {
            try std.testing.expect(selected.? != register);
        };
    }
}

test "machine call clobbers exclude caller-saved live ranges" {
    for ([_]bool{ false, true }) |indirect| {
        var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
        defer function.deinit();
        for (0..8) |index| {
            try function.immediate(.mov_eax, @intCast(index));
            try function.register(.store_eax, @fromBackingInt(@intCast(index)), 0);
        }
        if (indirect) {
            try function.emit(.call_rax);
        } else _ = try function.patchable(.call_relative);
        for (0..8) |index| try function.register(.load_eax, @fromBackingInt(@intCast(index)), 0);
        try function.emit(.ret);
        var allocation = try test_sources.registers.allocate(std.testing.allocator, &function, 8);
        defer allocation.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 6), allocation.used.len);
        for (allocation.registers) |selected| if (selected) |register| {
            try std.testing.expect(register.calleeSaved());
        };
    }
}

test "machine fixed register operands remain reserved" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    try function.immediate(.mov_r8d, 7);
    try function.emit(.zero_r9d);
    for (0..10) |index| {
        try function.immediate(.mov_eax, @intCast(index));
        try function.register(.store_eax, @fromBackingInt(@intCast(index)), 0);
    }
    for (0..10) |index| try function.register(.load_eax, @fromBackingInt(@intCast(index)), 0);
    try function.emit(.ret);
    var allocation = try test_sources.registers.allocate(std.testing.allocator, &function, 10);
    defer allocation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), allocation.used.len);
    for (allocation.registers) |selected| if (selected) |register| {
        try std.testing.expect(register != .r8);
        try std.testing.expect(register != .r9);
    };
}

test "machine live ranges reuse registers between separate definitions" {
    var function: test_sources.machine.Function = .{ .gpa = std.testing.allocator };
    defer function.deinit();
    try function.register(.store_eax, @fromBackingInt(0), 0);
    try function.register(.load_eax, @fromBackingInt(0), 0);
    try function.emit(.call_rax);
    try function.register(.store_eax, @fromBackingInt(1), 0);
    try function.register(.load_eax, @fromBackingInt(1), 0);
    try function.register(.store_eax, @fromBackingInt(0), 0);
    try function.register(.load_eax, @fromBackingInt(0), 0);
    try function.emit(.ret);
    var allocation = try test_sources.registers.allocate(std.testing.allocator, &function, 2);
    defer allocation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), allocation.used.len);
    try std.testing.expectEqual(allocation.registers[0], allocation.registers[1]);
    try std.testing.expect(!allocation.registers[0].?.calleeSaved());
}

test "machine division branches preserve live loop values and signed overflow" {
    try test_sources.SourceFixture.expectParity(
        \\func calculate(divisor: int) int
        \\    var value = -2147483648
        \\    var index = 0
        \\    loop
        \\        if index == 3 -> break
        \\        value /= divisor
        \\        index += 1
        \\    return value
        \\func run() int -> calculate(-1) - calculate(1) + 42
    , 42);
}

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

test "straight-line registers preserve branches spills and values across calls" {
    const source =
        \\func calculate(seed: int) int
        \\    const a = seed + 1
        \\    const b = seed + 2
        \\    const c = seed + 3
        \\    const d = seed + 4
        \\    const e = seed + 5
        \\    const f = seed + 6
        \\    const g = seed + 7
        \\    const h = seed + 8
        \\    var selected = a
        \\    if seed > 0 -> selected = b
        \\    const called = adjust(seed)
        \\    return selected + a + b + c + d + e + f + g + h + called
        \\func adjust(value: int) int -> value * 3
        \\func run() int -> calculate(1) + calculate(-1) - 33
    ;
    try test_sources.SourceFixture.expectParity(source, 42);
    const fixture = try test_sources.SourceFixture.init(source ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
}

test "scalar parameters preserve repeated reads calls and borrowed mutation" {
    const source =
        \\func adjust(mut value: int) unit -> value += 1
        \\func called(value: int) int -> value * 3
        \\func calculate(seed: int, enabled: bool, mut target: int) int
        \\    var total = seed + called(seed)
        \\    adjust(target)
        \\    if enabled -> total += seed
        \\    if not enabled -> total -= seed
        \\    total += seed + target
        \\    return total
        \\func run() int
        \\    var target = 2
        \\    const first = calculate(3, true, target)
        \\    const second = calculate(3, false, target)
        \\    return first + second + target + 1
    ;
    try test_sources.SourceFixture.expectParity(source, 42);
    const fixture = try test_sources.SourceFixture.init(source ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
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

test "native acyclic backedge copies preserve both dependency directions" {
    for ([_]bool{ false, true }) |backward| {
        for ([_]i32{ 0, 1, 2, 3 }) |iterations| {
            var arguments = [_]structures.FunctionBlockArgument{ .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int }, .{ .type_id = .int } };
            var uses = [_]structures.FunctionValueUse{
                .{ .value = @fromBackingInt(5) },  .{ .value = @fromBackingInt(6) },                       .{ .value = @fromBackingInt(7) },
                .{ .value = @fromBackingInt(11) }, .{ .value = @fromBackingInt(if (backward) 2 else 10) }, .{ .value = @fromBackingInt(if (backward) 10 else 1) },
                .{ .value = @fromBackingInt(1) },  .{ .value = @fromBackingInt(2) },
            };
            var instructions = [_]structures.FunctionInstruction{
                integerConstant(iterations),    integerConstant(11),            integerConstant(31),                                                                                                                       integerConstant(0), integerConstant(1), integerConstant(7),
                integerBinary(.subtract, 0, 9), integerBinary(.subtract, 3, 4), .{ .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(1) } }, .arguments = .{ .start = 0, .end = 1 }, .return_type = .never } },
            };
            var calls = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @fromBackingInt(12) } }};
            var blocks = [_]structures.FunctionBlock{
                .{ .instruction_start = 0, .instruction_end = 6, .terminator = .{ .branch = .{ .target = @fromBackingInt(1), .arguments = .{ .start = 0, .end = 3 } } } },
                .{ .argument_end = 3, .instruction_start = 6, .instruction_end = 7, .terminator = .{ .predicate_branch = .{
                    .operation = .gti,
                    .operands = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(8) },
                    .then_branch = .{ .target = @fromBackingInt(1), .arguments = .{ .start = 3, .end = 6 } },
                    .else_branch = .{ .target = @fromBackingInt(2), .arguments = .{ .start = 6, .end = 8 } },
                } } },
                .{ .argument_start = 3, .argument_end = 5, .instruction_start = 7, .instruction_end = 9, .terminator = .diverge },
            };
            var body = functionSsa(&instructions, &blocks);
            body.block_arguments = &arguments;
            body.branch_arguments = &uses;
            body.call_arguments = &calls;
            var artifact = try codegen.compileFunction(&body, TestTypes{}, std.testing.allocator);
            defer artifact.deinit(std.testing.allocator);
            try expectArtifactExitCode(artifact, if (iterations == 0) 236 else if (iterations > 1) 0 else if (backward) 24 else 252);
        }
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
            \\    match calculate()
            \\        result -> return result
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
            \\    match grid.get(-1)
            \\        ref _matched_invalid and _matched_invalid is Array(byte, $width) ->
            \\            ref invalid = _matched_invalid
            \\            return 91
            \\        _ -> ()
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
            \\    match calculate()
            \\        result -> return result
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
