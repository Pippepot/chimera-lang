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
        if (instance.specialization) |specialization| try writer.print("[{d}]", .{@backingInt(specialization)});
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
    try renderName(loc.name, writer);
}

fn renderName(name: structures.Name, writer: *std.Io.Writer) !void {
    try writer.writeAll(name.text());
    if (name == .operation) try writer.print("/{d}", .{name.operation.operandCount()});
}

fn renderSsaFunction(
    db: *query.Database,
    instance: structures.InstanceId,
    ssa: *const structures.FunctionBodyAnalysis,
    writer: *std.Io.Writer,
) !void {
    const location = try db.lookupInterned(queries.ItemLocations, instance.item);
    try writer.writeAll("fn ");
    try renderName(location.name, writer);
    if (instance.specialization) |specialization| try writer.print("[{d}]", .{@backingInt(specialization)});
    try writer.writeByte('\n');
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
            try renderType(db, ssa.block_arguments[argument_index].type_id, writer);
        }
        try writer.writeByte(')');
        if (block_index == @backingInt(ssa.entry)) try writer.writeAll(" [entry]");
        try writer.writeAll(":\n");

        for (block.instruction_start..block.instruction_end) |instruction_index| {
            try renderInstruction(db, ssa, instruction_index, writer);
        }
        switch (block.terminator) {
            .branch => |branch| try renderBranch(db, ssa, "br", branch, writer),
            .predicate_branch => |predicate| {
                try writer.print("    pbr {s} %{d}, %{d}, ", .{
                    @tagName(predicate.operation),
                    @backingInt(predicate.operands.lhs),
                    @backingInt(predicate.operands.rhs),
                });
                try renderBranchTarget(db, ssa, predicate.then_branch, writer);
                try writer.writeAll(", ");
                try renderBranchTarget(db, ssa, predicate.else_branch, writer);
                try writer.writeByte('\n');
            },
            .fallible_call => |fallible| {
                try writer.writeAll("    fcall ");
                try renderCallTarget(db, fallible.call.target, writer);
                if (fallible.call.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
                try writer.print(" -> b{d}", .{@backingInt(fallible.success)});
                if (fallible.failure) |failure| try writer.print(", failure b{d}", .{@backingInt(failure)});
                try writer.writeByte('\n');
            },
            .return_unit => try writer.writeAll("    ret\n"),
            .return_value => |value| {
                try writer.writeAll("    ret ");
                try renderValueUse(db, value, writer);
                try writer.writeByte('\n');
            },
            .return_failure => try writer.writeAll("    fail\n"),
            .diverge => try writer.writeAll("    diverge\n"),
        }
    }
    try writer.writeByte('\n');
}

fn renderBranch(db: *query.Database, ssa: *const structures.FunctionBodyAnalysis, name: []const u8, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("    {s} ", .{name});
    try renderBranchTarget(db, ssa, branch, writer);
    try writer.writeByte('\n');
}

fn renderBranchTarget(db: *query.Database, ssa: *const structures.FunctionBodyAnalysis, branch: structures.FunctionBranch, writer: *std.Io.Writer) !void {
    try writer.print("b{d}(", .{@backingInt(branch.target)});
    for (ssa.branch_arguments[branch.arguments.start..branch.arguments.end], 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try renderValueUse(db, argument, writer);
    }
    try writer.writeByte(')');
}

fn renderInstruction(
    db: *query.Database,
    ssa: *const structures.FunctionBodyAnalysis,
    instruction_index: usize,
    writer: *std.Io.Writer,
) !void {
    const result = @backingInt(ssa.instructionValue(instruction_index));
    switch (ssa.instructions[instruction_index]) {
        .const_int => |value| try writer.print("    %{d} = const_int {d}\n", .{ result, value }),
        .const_byte => |value| try writer.print("    %{d} = const_byte {d}\n", .{ result, value }),
        .const_string_literal => |value| try writer.print("    %{d} = const_string_literal @{d}\n", .{ result, @backingInt(value) }),
        .const_data => |value| try writer.print("    %{d} = const_data @{d}\n", .{ result, @backingInt(value) }),
        .const_byte_pointer => |value| try writer.print("    %{d} = const_byte_pointer @{d}+{d}\n", .{ result, @backingInt(value.data), value.offset }),
        .byte_pointer, .byte_to_int => |value| try writer.print("    %{d} = {s} %{d}\n", .{ result, @tagName(ssa.instructions[instruction_index]), @backingInt(value) }),
        .byte_offset, .byte_read => |value| try writer.print("    %{d} = {s} %{d}, %{d}\n", .{ result, @tagName(ssa.instructions[instruction_index]), @backingInt(value.lhs), @backingInt(value.rhs) }),
        .const_int_literal => |value| try writer.print("    %{d} = const_int_literal {d}\n", .{ result, value }),
        .static_conversion => |conversion| {
            try writer.print("    %{d} = static_conversion %{d} to ", .{ result, @backingInt(conversion.operand) });
            try renderType(db, conversion.type_id, writer);
            try writer.writeByte('\n');
        },
        .const_bool => |value| try writer.print("    %{d} = const_bool {s}\n", .{ result, if (value) "true" else "false" }),
        .const_type => |type_id| {
            try writer.print("    %{d} = const_type ", .{result});
            try renderType(db, type_id, writer);
            try writer.writeByte('\n');
        },
        .const_unit => try writer.print("    %{d} = const_unit\n", .{result}),
        .const_none => try writer.print("    %{d} = const_none\n", .{result}),
        .initializer_ref => |reference| try writer.print("    %{d} = initializer_ref region {d}, captures {d}..{d}\n", .{ result, reference.region, reference.captures.start, reference.captures.end }),
        .function_ref => |reference| {
            const target = try db.lookupInterned(queries.ItemLocations, reference.target);
            try writer.print("    %{d} = function_ref @", .{result});
            try renderName(target.name, writer);
            try writer.writeByte('\n');
        },
        .variant_tag => |operand| try writer.print("    %{d} = variant_tag %{d}\n", .{ result, @backingInt(operand) }),
        .variant_coerce => |coercion| {
            try writer.print("    %{d} = variant_coerce %{d} to ", .{ result, @backingInt(coercion.operand) });
            try renderType(db, coercion.target_type, writer);
            if (coercion.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
            try writer.writeByte('\n');
        },
        .variant_extract => |extraction| {
            try writer.print("    %{d} = variant_extract %{d} as ", .{ result, @backingInt(extraction.operand) });
            try renderType(db, extraction.target_type, writer);
            try writer.writeByte('\n');
        },
        .callable_coerce => |coercion| {
            try writer.print("    %{d} = callable_coerce %{d}", .{ result, @backingInt(coercion.operand) });
            if (coercion.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
            try writer.writeByte('\n');
        },
        .local_storage => |type_id| {
            try writer.print("    %{d} = local_storage ", .{result});
            try renderType(db, type_id, writer);
            try writer.writeByte('\n');
        },
        .result_storage => |type_id| {
            try writer.print("    %{d} = result_storage ", .{result});
            try renderType(db, type_id, writer);
            try writer.writeByte('\n');
        },
        .storage_projection => |operation| {
            try writer.print("    %{d} = storage_projection %{d}", .{ result, @backingInt(operation.owner) });
            switch (operation.projection) {
                .box_element => try writer.writeAll(".element"),
                .field => |index| try writer.print(".{d}", .{index}),
                .variant => try writer.writeAll(".payload"),
                .allocation_array => try writer.writeAll(".elements"),
            }
            try writer.writeByte('\n');
        },
        .allocation_element => |operation| try writer.print("    %{d} = allocation_element %{d}[%{d}]\n", .{
            result,
            @backingInt(operation.allocation),
            @backingInt(operation.index),
        }),
        .array_element => |operation| try writer.print("    %{d} = array_element %{d}[%{d}]\n", .{
            result,
            @backingInt(operation.array),
            @backingInt(operation.index),
        }),
        .borrow_box => |operation| try writer.print("    %{d} = borrow_box %{d}\n", .{ result, @backingInt(operation.source) }),
        .borrow_address => |operation| {
            try writer.print("    %{d} = borrow_address %{d}", .{ result, @backingInt(operation.source) });
            if (operation.base_is_reference) try writer.writeAll("[]");
            for (ssa.borrow_fields[operation.fields.start..operation.fields.end]) |projection| switch (projection) {
                .field => |field| try writer.print(".{d}", .{field}),
                .variant => |member| {
                    try writer.writeAll(" as ");
                    try renderType(db, member, writer);
                },
            };
            try writer.writeByte('\n');
        },
        .borrow_read => |operation| try writer.print("    %{d} = borrow_read %{d}\n", .{ result, @backingInt(operation.source) }),
        .borrow_write => |operation| try writer.print("    %{d} = borrow_write %{d}, %{d}\n", .{
            result,
            @backingInt(operation.reference),
            @backingInt(operation.value),
        }),
        .value_copy => |operation| {
            try writer.print("    %{d} = value_copy %{d}", .{ result, @backingInt(operation.source) });
            if (operation.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
            try writer.writeByte('\n');
        },
        .field_access => |operation| try writer.print("    %{d} = field_access %{d}, {d}\n", .{
            result,
            @backingInt(operation.operand),
            operation.field_index,
        }),
        .mut_parameter_write => |operation| try writer.print("    mut_parameter_write {d}, %{d}\n", .{
            operation.parameter_index,
            @backingInt(operation.value),
        }),
        .call_mut_argument => |operation| {
            try writer.print("    %{d} = call_mut_argument {d}", .{ result, operation.argument_index });
            if (operation.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
            try writer.writeByte('\n');
        },
        .call => |call| {
            try writer.print("    %{d} = call ", .{result});
            try renderCallTarget(db, call.target, writer);
            try writer.writeByte('(');
            for (ssa.call_arguments[call.arguments.start..call.arguments.end], 0..) |argument, index| {
                if (index != 0) try writer.writeAll(", ");
                if (argument == .deinit) try writer.writeAll("deinit ");
                try renderValueUse(db, argument.valueUse(), writer);
            }
            try writer.writeAll(") : ");
            try renderType(db, call.return_type, writer);
            if (call.destination) |storage| try writer.print(" into %{d}", .{@backingInt(storage)});
            try writer.writeByte('\n');
        },
        .negi => |operand| try writer.print("    %{d} = negi %{d}\n", .{ result, @backingInt(operand) }),
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
            try writer.writeByte('@');
            try renderName(location.name, writer);
        },
        .indirect => |value| try writer.print("%{d}", .{@backingInt(value)}),
        .initializer => |value| try writer.print("init %{d}", .{@backingInt(value)}),
    }
}

fn renderValueUse(db: *query.Database, value_use: structures.FunctionValueUse, writer: *std.Io.Writer) !void {
    try writer.print("%{d}", .{@backingInt(value_use.value)});
    if (value_use.coerce_to) |target_type| {
        try writer.writeAll(" as ");
        try renderType(db, target_type, writer);
    }
}

fn renderType(db: *query.Database, type_id: structures.TypeId, writer: *std.Io.Writer) anyerror!void {
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    if (try types.arrayType(type_id)) |array| {
        try writer.writeAll("Array(");
        try renderType(db, array.element_type, writer);
        return writer.print(", {d})", .{array.length});
    }
    if (type_id.interned()) |interned_id| {
        try writer.print("type#{d}", .{@backingInt(interned_id)});
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
        @backingInt(operands.lhs),
        @backingInt(operands.rhs),
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

test "SSA debug renders nested array types and indexed array projections" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    const row: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = .int, .length = 3 } }));
    const matrix: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = row, .length = 0 } }));
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try renderType(db, matrix, &output.writer);
    try output.writer.writeByte('\n');
    var arguments = [_]structures.FunctionBlockArgument{.{ .type_id = row, .representation = .storage }};
    var instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 1 },
        .{ .array_element = .{ .array = @fromBackingInt(@intCast(0)), .index = @fromBackingInt(@intCast(1)), .type_id = .int } },
    };
    const body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .parameter_modes = &.{},
        .block_arguments = &arguments,
        .instructions = &instructions,
        .call_arguments = &.{},
        .branch_arguments = &.{},
        .blocks = &.{},
        .entry = @fromBackingInt(@intCast(0)),
    };
    try renderInstruction(db, &body, 1, &output.writer);
    try std.testing.expectEqualStrings("Array(Array(int, 3), 0)\n    %2 = array_element %0[%1]\n", output.writer.buffered());
}
