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
    writer: *std.Io.Writer,
) !void {
    const reachable = (try db.get(queries.CollectReachableInstances, file_id)).* orelse unreachable;

    try writer.writeAll("SSA\n");
    for (reachable.instances) |instance| {
        const lowered = (try db.get(queries.LowerToSSA, instance)).* orelse unreachable;
        try renderSsaFunction(db, instance, &lowered, writer);
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
            try writer.print("%{d}: ", .{argument_index});
            try renderType(ssa.block_argument_types[argument_index], writer);
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
            .return_value => |value| {
                try writer.writeAll("    ret ");
                try renderValueUse(value, writer);
                try writer.writeByte('\n');
            },
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
        try renderValueUse(argument, writer);
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
        .const_unit => try writer.print("    %{d} = const_unit\n", .{result}),
        .const_none => try writer.print("    %{d} = const_none\n", .{result}),
        .variant_coerce => |coercion| {
            try writer.print("    %{d} = variant_coerce %{d} to ", .{ result, @intFromEnum(coercion.operand) });
            try renderType(coercion.target_type, writer);
            try writer.writeByte('\n');
        },
        .call => |call| {
            const target = try db.lookupInterned(queries.ItemLocations, call.target.item);
            try writer.print("    %{d} = call @{s}(", .{ result, target.name });
            for (ssa.call_arguments[call.arguments.start..call.arguments.end], 0..) |argument, index| {
                if (index != 0) try writer.writeAll(", ");
                try renderValueUse(argument, writer);
            }
            try writer.writeAll(") : ");
            try renderType(call.return_type, writer);
            try writer.writeByte('\n');
        },
        .exit => |operand| try writer.print("    %{d} = exit %{d}\n", .{ result, @intFromEnum(operand) }),
        .negi => |operand| try writer.print("    %{d} = negi %{d}\n", .{ result, @intFromEnum(operand) }),
        .addi => |operands| try renderBinary(writer, result, "addi", operands),
        .subi => |operands| try renderBinary(writer, result, "subi", operands),
        .muli => |operands| try renderBinary(writer, result, "muli", operands),
        .divsi => |operands| try renderBinary(writer, result, "divsi", operands),
    }
}

fn renderValueUse(value_use: structures.FunctionValueUse, writer: *std.Io.Writer) !void {
    try writer.print("%{d}", .{@intFromEnum(value_use.value)});
    if (value_use.coerce_to) |target_type| {
        try writer.writeAll(" as ");
        try renderType(target_type, writer);
    }
}

fn renderType(type_id: structures.TypeId, writer: *std.Io.Writer) !void {
    if (type_id.interned()) |interned_id| {
        try writer.print("type#{d}", .{@intFromEnum(interned_id)});
    } else {
        try writer.writeAll(@tagName(type_id));
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
