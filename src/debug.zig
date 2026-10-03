const std = @import("std");
const ast = @import("frontend/parser.zig");
const codegen = @import("backend/codegen.zig");
const disasm = @import("backend/disasm.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const structures = @import("structures.zig");
const diagnostics = @import("diagnostics.zig");

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
    sources: []const diagnostics.DiagnosticSource,
    writer: *std.Io.Writer,
) !void {
    const reachable = (try db.get(queries.CollectReachableInstances, file_id)).* orelse unreachable;

    try writer.writeAll("SSA\n");
    for (reachable.instances) |instance| {
        const body = (try db.get(queries.AnalyzeFunctionInstance, instance)).*;
        if (body == null) continue;
        try renderFunctionSource(db, instance, sources, writer);
        try renderSsaFunction(db, instance, &body.?, writer);
    }
}

fn renderFunctionSource(db: *query.Database, instance: structures.InstanceId, sources: []const diagnostics.DiagnosticSource, writer: *std.Io.Writer) !void {
    const resolved = (try db.get(queries.ResolveItem, instance.item)).* orelse unreachable;
    for (sources) |source| {
        if (source.file_id != resolved.file_id) continue;
        try writer.print("source {s} :: ", .{source.path});
        try renderItemName(db, instance.item, writer);
        if (instance.specialization) |specialization| try writer.print("[{d}]", .{@intFromEnum(specialization)});
        try writer.writeByte('\n');
        return;
    }
    unreachable; // The driver supplies every registered source.
}

fn renderItemName(db: *query.Database, item: structures.ItemId, writer: *std.Io.Writer) anyerror!void {
    const loc = try db.lookupInterned(queries.ItemLocations, item);
    if (loc.owner) |owner| {
        try renderItemName(db, owner, writer);
        try writer.writeByte('.');
    } else if (loc.origin == .module) {
        const module = try db.lookupInterned(queries.ModulePaths, loc.origin.module);
        try writer.print("{s}.", .{if (module.path.len == 0) "$entry" else module.path});
    }
    try writer.writeAll(loc.name);
}

fn renderSsaFunction(
    db: *query.Database,
    instance: structures.InstanceId,
    ssa: *const structures.FunctionBodyAnalysis,
    writer: *std.Io.Writer,
) !void {
    const location = try db.lookupInterned(queries.ItemLocations, instance.item);
    if (instance.specialization) |specialization| {
        try writer.print("fn {s}[{d}]\n", .{ location.name, @intFromEnum(specialization) });
    } else {
        try writer.print("fn {s}\n", .{location.name});
    }
    for (ssa.blocks, 0..) |block, block_index| {
        try writer.print("  b{d}(", .{block_index});
        for (block.argument_start..block.argument_end) |argument_index| {
            if (argument_index != block.argument_start) try writer.writeAll(", ");
            try writer.print("%{d}: ", .{argument_index});
            switch (ssa.block_arguments[argument_index].representation) {
                .value => {},
                .storage => try writer.writeAll("storage "),
                .initializer => try writer.writeAll("init "),
            }
            try renderType(ssa.block_arguments[argument_index].type_id, writer);
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
            .fallible_call => |fallible| {
                try writer.writeAll("    fcall ");
                try renderCallTarget(db, fallible.call.target, writer);
                if (fallible.call.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
                try writer.print(" -> b{d}", .{@intFromEnum(fallible.success)});
                if (fallible.failure) |failure| try writer.print(", failure b{d}", .{@intFromEnum(failure)});
                try writer.writeByte('\n');
            },
            .return_unit => try writer.writeAll("    ret\n"),
            .return_value => |value| {
                try writer.writeAll("    ret ");
                try renderValueUse(value, writer);
                try writer.writeByte('\n');
            },
            .return_failure => try writer.writeAll("    fail\n"),
            .diverge => try writer.writeAll("    diverge\n"),
        }
    }
    try writer.writeByte('\n');
}

fn renderBranch(ssa: *const structures.FunctionBodyAnalysis, name: []const u8, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("    {s} ", .{name});
    try renderBranchTarget(ssa, branch, writer);
    try writer.writeByte('\n');
}

fn renderBranchTarget(ssa: *const structures.FunctionBodyAnalysis, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("b{d}(", .{@intFromEnum(branch.target)});
    for (ssa.branch_arguments[branch.arguments.start..branch.arguments.end], 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try renderValueUse(argument, writer);
    }
    try writer.writeByte(')');
}

fn renderInstruction(
    db: *query.Database,
    ssa: *const structures.FunctionBodyAnalysis,
    instruction_index: usize,
    writer: *std.Io.Writer,
) !void {
    const result = @intFromEnum(ssa.instructionValue(instruction_index));
    switch (ssa.instructions[instruction_index]) {
        .const_int => |value| try writer.print("    %{d} = const_int {d}\n", .{ result, value }),
        .const_byte => |value| try writer.print("    %{d} = const_byte {d}\n", .{ result, value }),
        .const_bool => |value| try writer.print("    %{d} = const_bool {s}\n", .{ result, if (value) "true" else "false" }),
        .const_type => |type_id| {
            try writer.print("    %{d} = const_type ", .{result});
            try renderType(type_id, writer);
            try writer.writeByte('\n');
        },
        .const_unit => try writer.print("    %{d} = const_unit\n", .{result}),
        .const_none => try writer.print("    %{d} = const_none\n", .{result}),
        .initializer_ref => |reference| try writer.print("    %{d} = initializer_ref region {d}, captures {d}..{d}\n", .{ result, reference.region, reference.captures.start, reference.captures.end }),
        .function_ref => |reference| {
            const target = try db.lookupInterned(queries.ItemLocations, reference.target);
            try writer.print("    %{d} = function_ref @{s}\n", .{ result, target.name });
        },
        .variant_tag => |operand| try writer.print("    %{d} = variant_tag %{d}\n", .{ result, @intFromEnum(operand) }),
        .variant_coerce => |coercion| {
            try writer.print("    %{d} = variant_coerce %{d} to ", .{ result, @intFromEnum(coercion.operand) });
            try renderType(coercion.target_type, writer);
            if (coercion.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
            try writer.writeByte('\n');
        },
        .variant_extract => |extraction| {
            try writer.print("    %{d} = variant_extract %{d} as ", .{ result, @intFromEnum(extraction.operand) });
            try renderType(extraction.target_type, writer);
            try writer.writeByte('\n');
        },
        .callable_coerce => |coercion| {
            try writer.print("    %{d} = callable_coerce %{d}", .{ result, @intFromEnum(coercion.operand) });
            if (coercion.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
            try writer.writeByte('\n');
        },
        .struct_init => |operation| {
            try writer.print("    %{d} = struct_init ", .{result});
            try renderType(operation.type_id, writer);
            try writer.writeByte('(');
            for (ssa.struct_field_values[operation.fields.start..operation.fields.end], 0..) |field, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("{d} = %{d}", .{ field.field_index, @intFromEnum(field.value) });
            }
            try writer.writeAll(")\n");
        },
        .local_storage => |type_id| {
            try writer.print("    %{d} = local_storage ", .{result});
            try renderType(type_id, writer);
            try writer.writeByte('\n');
        },
        .result_storage => |type_id| {
            try writer.print("    %{d} = result_storage ", .{result});
            try renderType(type_id, writer);
            try writer.writeByte('\n');
        },
        .storage_projection => |operation| {
            try writer.print("    %{d} = storage_projection %{d}", .{ result, @intFromEnum(operation.owner) });
            switch (operation.projection) {
                .box_element => try writer.writeAll(".element"),
                .field => |index| try writer.print(".{d}", .{index}),
                .variant => try writer.writeAll(".payload"),
            }
            try writer.writeByte('\n');
        },
        .allocation_element => |operation| try writer.print("    %{d} = allocation_element %{d}[%{d}]\n", .{
            result,
            @intFromEnum(operation.allocation),
            @intFromEnum(operation.index),
        }),
        .borrow_box => |operation| try writer.print("    %{d} = borrow_box %{d}\n", .{ result, @intFromEnum(operation.source) }),
        .borrow_address => |operation| {
            try writer.print("    %{d} = borrow_address %{d}", .{ result, @intFromEnum(operation.source) });
            if (operation.base_is_reference) try writer.writeAll("[]");
            for (ssa.borrow_fields[operation.fields.start..operation.fields.end]) |field| try writer.print(".{d}", .{field});
            try writer.writeByte('\n');
        },
        .borrow_read => |operation| try writer.print("    %{d} = borrow_read %{d}\n", .{ result, @intFromEnum(operation.source) }),
        .borrow_write => |operation| try writer.print("    %{d} = borrow_write %{d}, %{d}\n", .{
            result,
            @intFromEnum(operation.reference),
            @intFromEnum(operation.value),
        }),
        .value_copy => |operation| {
            try writer.print("    %{d} = value_copy %{d}", .{ result, @intFromEnum(operation.source) });
            if (operation.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
            try writer.writeByte('\n');
        },
        .field_access => |operation| try writer.print("    %{d} = field_access %{d}, {d}\n", .{
            result,
            @intFromEnum(operation.operand),
            operation.field_index,
        }),
        .field_update => |operation| try writer.print("    %{d} = field_update %{d}, {d} = %{d}\n", .{
            result,
            @intFromEnum(operation.operand),
            operation.field_index,
            @intFromEnum(operation.value),
        }),
        .mut_parameter_write => |operation| try writer.print("    mut_parameter_write {d}, %{d}\n", .{
            operation.parameter_index,
            @intFromEnum(operation.value),
        }),
        .call_mut_argument => |operation| {
            try writer.print("    %{d} = call_mut_argument {d}", .{ result, operation.argument_index });
            if (operation.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
            try writer.writeByte('\n');
        },
        .call => |call| {
            try writer.print("    %{d} = call ", .{result});
            try renderCallTarget(db, call.target, writer);
            try writer.writeByte('(');
            for (ssa.call_arguments[call.arguments.start..call.arguments.end], 0..) |argument, index| {
                if (index != 0) try writer.writeAll(", ");
                if (argument == .deinit) try writer.writeAll("deinit ");
                try renderValueUse(argument.valueUse(), writer);
            }
            try writer.writeAll(") : ");
            try renderType(call.return_type, writer);
            if (call.destination) |storage| try writer.print(" into %{d}", .{@intFromEnum(storage)});
            try writer.writeByte('\n');
        },
        .negi => |operand| try writer.print("    %{d} = negi %{d}\n", .{ result, @intFromEnum(operand) }),
        .addi => |operands| try renderBinary(writer, result, "addi", operands),
        .subi => |operands| try renderBinary(writer, result, "subi", operands),
        .muli => |operands| try renderBinary(writer, result, "muli", operands),
        .divsi => |operands| try renderBinary(writer, result, "divsi", operands),
    }
}

fn renderCallTarget(db: *query.Database, target: @FieldType(structures.FunctionCall, "target"), writer: *std.Io.Writer) !void {
    switch (target) {
        .direct => |instance| {
            const location = try db.lookupInterned(queries.ItemLocations, instance.item);
            try writer.print("@{s}", .{location.name});
        },
        .indirect => |value| try writer.print("%{d}", .{@intFromEnum(value)}),
        .initializer => |value| try writer.print("init %{d}", .{@intFromEnum(value)}),
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
    db: *query.Database,
    file_id: structures.FileId,
    sources: []const diagnostics.DiagnosticSource,
    executable: structures.Executable,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const assembly = try disasm.disassemble(codegen.executableCode(executable), gpa);
    defer gpa.free(assembly);
    try writer.writeAll("ASM\n");
    const reachable = (try db.get(queries.CollectReachableInstances, file_id)).* orelse unreachable;
    for (reachable.instances) |instance| try renderFunctionSource(db, instance, sources, writer);
    try writer.writeAll(assembly);
    try writer.writeByte('\n');
}
