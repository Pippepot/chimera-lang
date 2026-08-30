const std = @import("std");
const ast = @import("ast_new.zig");
const codegen = @import("codegen_new.zig");
const disasm = @import("legacy/disasm.zig");
const query = @import("query_new.zig");
const queries = @import("query_structures.zig");
const structures = @import("structures.zig");

pub fn renderAst(
    gpa: std.mem.Allocator,
    parsed: *const structures.Ast,
    source: []const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("AST\n");
    try ast.renderAst(gpa, parsed, source, writer);
    try writer.writeByte('\n');
}

pub fn renderReachableSsa(
    db: *query.Database,
    file_id: structures.FileId,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const entry_id = (try db.get(queries.SelectEntry, file_id)).* orelse unreachable;
    const entry: structures.InstanceId = .{ .item = entry_id };

    var instances: std.ArrayList(structures.InstanceId) = .empty;
    defer instances.deinit(gpa);
    var seen = std.AutoHashMap(structures.InstanceId, void).init(gpa);
    defer seen.deinit();

    try writer.writeAll("SSA\n");
    try instances.append(gpa, entry);
    try seen.put(entry, {});
    var next: usize = 0;
    while (next < instances.items.len) : (next += 1) {
        const instance = instances.items[next];
        const lowered = (try db.get(queries.LowerToSSA, instance)).* orelse unreachable;
        try renderSsaFunction(db, instance, &lowered, writer);

        const artifact = (try db.get(queries.CompileFunction, instance)).* orelse unreachable;
        for (artifact.referenced_instances) |referenced| {
            const result = try seen.getOrPut(referenced);
            if (!result.found_existing) try instances.append(gpa, referenced);
        }
    }
}

fn renderSsaFunction(
    db: *query.Database,
    instance: structures.InstanceId,
    ssa: *const structures.SsaFunction,
    writer: *std.Io.Writer,
) !void {
    const location = try db.lookupInterned(queries.ItemLocations, instance.item);
    try writer.print("fn {s}\n", .{location.name});
    for (ssa.blocks, 0..) |block, block_index| {
        try writer.print("  b{d}(", .{block_index});
        for (block.argument_start..block.argument_end) |argument_index| {
            if (argument_index != block.argument_start) try writer.writeAll(", ");
            try writer.print("%{d}: {s}", .{ argument_index, @tagName(ssa.block_argument_types[argument_index]) });
        }
        try writer.writeByte(')');
        if (block_index == @intFromEnum(ssa.entry)) try writer.writeAll(" [entry]");
        try writer.writeAll(":\n");

        for (block.instruction_start..block.instruction_end) |instruction_index| {
            try renderInstruction(db, ssa, instruction_index, writer);
        }
        switch (block.terminator) {
            .branch => |branch| try renderBranch(ssa, "br", branch, writer),
            .predicate_branch => |predicate| {
                try writer.print("    pbr {s} %{d}, %{d}, ", .{
                    @tagName(predicate.operation),
                    @intFromEnum(predicate.operands.lhs),
                    @intFromEnum(predicate.operands.rhs),
                });
                try renderBranchTarget(ssa, predicate.then_branch, writer);
                try writer.writeAll(", ");
                try renderBranchTarget(ssa, predicate.else_branch, writer);
                try writer.writeByte('\n');
            },
            .return_unit => try writer.writeAll("    ret\n"),
            .return_value => |value| try writer.print("    ret %{d}\n", .{@intFromEnum(value)}),
        }
    }
    try writer.writeByte('\n');
}

fn renderBranch(ssa: *const structures.SsaFunction, name: []const u8, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("    {s} ", .{name});
    try renderBranchTarget(ssa, branch, writer);
    try writer.writeByte('\n');
}

fn renderBranchTarget(ssa: *const structures.SsaFunction, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("b{d}(", .{@intFromEnum(branch.target)});
    for (ssa.branch_arguments[branch.arguments.start..branch.arguments.end], 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("%{d}", .{@intFromEnum(argument)});
    }
    try writer.writeByte(')');
}

fn renderInstruction(
    db: *query.Database,
    ssa: *const structures.SsaFunction,
    instruction_index: usize,
    writer: *std.Io.Writer,
) !void {
    const result = @intFromEnum(ssa.instructionValue(instruction_index));
    switch (ssa.instructions[instruction_index]) {
        .consti => |value| try writer.print("    %{d} = consti {d}\n", .{ result, value }),
        .call => |call| {
            const target = try db.lookupInterned(queries.ItemLocations, call.target.item);
            try writer.print("    %{d} = call @{s}(", .{ result, target.name });
            for (ssa.call_arguments[call.arguments.start..call.arguments.end], 0..) |argument, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("%{d}", .{@intFromEnum(argument)});
            }
            try writer.print(") : {s}\n", .{@tagName(call.return_type)});
        },
        .exit => |operand| try writer.print("    %{d} = exit %{d}\n", .{ result, @intFromEnum(operand) }),
        .negi => |operand| try writer.print("    %{d} = negi %{d}\n", .{ result, @intFromEnum(operand) }),
        .addi => |operands| try renderBinary(writer, result, "addi", operands),
        .subi => |operands| try renderBinary(writer, result, "subi", operands),
        .muli => |operands| try renderBinary(writer, result, "muli", operands),
        .divsi => |operands| try renderBinary(writer, result, "divsi", operands),
    }
}

fn renderBinary(
    writer: *std.Io.Writer,
    result: usize,
    name: []const u8,
    operands: structures.BinaryOperands,
) !void {
    try writer.print("    %{d} = {s} %{d}, %{d}\n", .{
        result,
        name,
        @intFromEnum(operands.lhs),
        @intFromEnum(operands.rhs),
    });
}

pub fn renderAssembly(
    executable: structures.Executable,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const assembly = try disasm.disassemble(codegen.executableCode(executable), gpa);
    defer gpa.free(assembly);
    try writer.writeAll("ASM\n");
    try writer.writeAll(assembly);
    try writer.writeByte('\n');
}
