const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const compaction = @import("compaction.zig");
const effects = @import("effects.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const Function = function_ir.Function;

pub fn canonicalize(function: *Function) !function_ir.Changes {
    function.resolveReferences();
    var rules: Rules = .{ .function = function, .address_taken = try addressTaken(function) };
    var changed = true;
    var changes: function_ir.Changes = .{};
    while (changed) {
        changed = false;
        for (function.blocks.items) |block| for (block.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            const result = function.results.items[index];
            const original = instruction.*;
            if (try rules.simplify(instruction, result)) {
                changed = true;
                changes.storage = changes.storage or switch (original) {
                    .borrow_read, .borrow_write, .borrow_address => true,
                    else => function_ir.usesStorage(function, &original) or function_ir.usesStorage(function, instruction),
                };
            }
        };
        for (function.blocks.items) |*block| {
            if (rules.simplifyTerminator(&block.terminator)) changed = true;
        }
        changes.changed = changes.changed or changed;
        if (changed) {
            function.invalidateOperands();
            function.resolveReferences();
        }
    }
    changes.control_flow = rules.graph_changed;
    return changes;
}

const Rules = struct {
    function: *Function,
    address_taken: []const bool,
    stable_values: ?[]const bool = null,
    graph_changed: bool = false,

    fn simplify(self: *Rules, instruction: *Instruction, result: ValueId) !bool {
        if (self.function.find(result) != result) return false;
        switch (instruction.*) {
            .addi, .subi, .muli, .divsi => return self.simplifyBinary(instruction, result),
            .negi => |operand| return self.simplifyNegation(instruction, result, operand),
            .byte_to_int => |operand| {
                const folded = self.constant(operand) orelse return false;
                instruction.* = .{ .const_int = folded };
                return true;
            },
            .value_copy => |copy| return self.simplifyCopy(copy, result),
            .borrow_read => |operation| return self.simplifyBorrowRead(instruction, operation, result),
            .borrow_address => |operation| return self.simplifyBorrowAddress(operation, result),
            .field_access => |operation| return self.simplifyFieldAccess(instruction, operation, result),
            .aggregate => |operation| return self.simplifyAggregate(operation, result),
            .variant_tag => |operand| return self.simplifyVariantTag(instruction, operand),
            .variant_extract => |operation| return self.simplifyVariantExtract(operation, result),
            .compare => |operation| return self.simplifyCompare(instruction, operation, result),
            .borrow_write => |operation| return self.simplifyBorrowWrite(instruction, operation),
            .select => |operation| return self.simplifySelect(operation, result),
            else => return false,
        }
    }

    fn simplifyBinary(self: *Rules, instruction: *Instruction, result: ValueId) bool {
        const operands = binaryOperands(instruction);
        const original = operands.*;
        const lhs = self.constant(original.lhs);
        const rhs = self.constant(original.rhs);
        if (lhs != null and rhs != null) {
            const folded = instruction.integerResult(lhs.?, rhs.?) orelse return false;
            instruction.* = .{ .const_int = folded };
            return true;
        }
        const laws = algebra(instruction.*);
        if (laws.commutative and lhs != null) {
            operands.* = .{ .lhs = original.rhs, .rhs = original.lhs };
            return true;
        }
        if (rhs) |constant_rhs| {
            if (laws.identity == constant_rhs) return self.alias(result, original.lhs);
            if (laws.absorbing == constant_rhs) {
                instruction.* = .{ .const_int = constant_rhs };
                return true;
            }
            if (laws.negating == constant_rhs) {
                instruction.* = .{ .negi = original.lhs };
                return true;
            }
        }
        if (laws.self_result) |self_result| if (original.lhs == original.rhs) {
            instruction.* = .{ .const_int = self_result };
            return true;
        };
        return false;
    }

    fn simplifyNegation(self: *Rules, instruction: *Instruction, result: ValueId, operand: ValueId) bool {
        if (self.constant(operand)) |value| {
            instruction.* = .{ .const_int = -%value };
            return true;
        }
        const negated = self.function.definition(operand) orelse return false;
        if (negated != .negi) return false;
        return self.alias(result, negated.negi);
    }

    fn simplifyCopy(self: *Rules, copy: structures.ValueCopy, result: ValueId) bool {
        if (copy.destination != null) return false;
        if (self.function.valueType(copy.source) != copy.type_id or !self.function.plainValue(copy.source)) return false;
        return self.alias(result, copy.source);
    }

    fn simplifyBorrowRead(self: *Rules, instruction: *Instruction, operation: structures.BorrowOperation, result: ValueId) bool {
        const reference = self.function.definition(operation.source) orelse return false;
        if (reference != .borrow_address or reference.borrow_address.base_is_reference) return false;
        const address = reference.borrow_address;
        const fields = self.function.borrow_fields.items[address.fields.start..address.fields.end];
        if (fields.len == 0) {
            if (self.function.valueType(address.source) != operation.type_id) return false;
            self.function.replace(result, address.source);
            return true;
        }
        if (fields.len != 1) return false;
        instruction.* = .{ .storage_projection = .{
            .owner = address.source,
            .type_id = operation.type_id,
            .projection = switch (fields[0]) {
                .field => |index| .{ .field = index },
                .variant => .variant,
            },
        } };
        return true;
    }

    fn simplifyBorrowWrite(self: *Rules, instruction: *Instruction, operation: structures.BorrowWriteOperation) bool {
        const reference = self.function.definition(operation.reference) orelse return false;
        if (reference != .borrow_address or reference.borrow_address.base_is_reference) return false;
        const address = reference.borrow_address;
        if (address.fields.start != address.fields.end or self.function.valueType(address.source) != operation.type_id) return false;
        instruction.* = .{ .value_copy = .{ .source = operation.value, .type_id = operation.type_id, .destination = address.source } };
        return true;
    }

    fn simplifyBorrowAddress(self: *Rules, operation: structures.BorrowAddressOperation, result: ValueId) bool {
        if (!operation.base_is_reference or operation.fields.start != operation.fields.end) return false;
        if (self.function.valueType(operation.source) != operation.type_id) return false;
        return self.alias(result, operation.source);
    }

    fn simplifyFieldAccess(self: *Rules, instruction: *Instruction, operation: structures.FieldAccessOperation, result: ValueId) !bool {
        const function = self.function;
        if (function.definition(operation.operand)) |aggregate| {
            if (aggregate != .aggregate) return false;
            const field = function.aggregate_fields.items[aggregate.aggregate.fields.start + operation.field_index];
            return self.alias(result, field);
        }
        const argument = function.definitions.items[@backingInt(operation.operand)].argument;
        if (argument.block == function.entry or !function.plainValue(operation.operand) or self.address_taken[@backingInt(operation.operand)]) return false;
        const parameters = function.blocks.items[argument.block].parameters.items;
        const position = std.mem.indexOfScalar(ValueId, parameters, operation.operand).?;
        const incoming = (try function.controlFlowEdges()).incoming[argument.block].items;
        var common: ?ValueId = null;
        for (incoming) |edge| {
            const use = function.branchArguments(edge.branch(function).*)[position];
            if (use.coerce_to != null) return false;
            const value = function.find(use.value);
            if (value == operation.operand) continue;
            const aggregate = function.definition(value) orelse return false;
            if (aggregate != .aggregate) return false;
            const field = function.find(function.aggregate_fields.items[aggregate.aggregate.fields.start + operation.field_index]);
            if (function.definition(field)) |definition| if (definition == .field_access and std.meta.eql(definition.field_access, operation)) continue;
            if (common) |previous| {
                if (previous == field) continue;
                const first = function.definition(previous) orelse return false;
                switch (first) {
                    .const_int, .const_bool, .const_byte => if (!std.meta.eql(first, function.definition(field) orelse return false)) return false,
                    else => return false,
                }
            } else common = field;
        }
        const field = common orelse return false;
        if (function.definition(field)) |definition| switch (definition) {
            .const_int, .const_bool, .const_byte => {
                instruction.* = definition;
                return true;
            },
            else => {},
        };
        return self.alias(result, field);
    }

    fn simplifyAggregate(self: *Rules, operation: structures.AggregateOperation, result: ValueId) !bool {
        const fields = self.function.aggregate_fields.items[operation.fields.start..operation.fields.end];
        var source: ?ValueId = null;
        for (fields, 0..) |field, position| {
            const definition = self.function.definition(field) orelse return false;
            if (definition != .field_access) return false;
            const access = definition.field_access;
            if (access.field_index != position) return false;
            if (source) |previous| {
                if (previous != access.operand) return false;
            } else source = access.operand;
        }
        const value = self.function.find(source orelse return false);
        if (self.function.valueType(value) != operation.type_id) return false;
        if (!self.function.plainValue(value)) return false;
        if (self.address_taken[@backingInt(result)] or self.address_taken[@backingInt(value)]) {
            if (self.stable_values == null) self.stable_values = try effects.stableValues(self.function);
            const stable = self.stable_values.?;
            if (!stable[@backingInt(result)] or !stable[@backingInt(value)]) return false;
            self.function.replace(result, value);
            return true;
        }
        return self.alias(result, value);
    }

    fn simplifyVariantTag(self: *Rules, instruction: *Instruction, operand: ValueId) bool {
        const coercion = self.function.definition(operand) orelse return false;
        if (coercion != .variant_coerce or coercion.variant_coerce.destination != null) return false;
        const mapping = coercion.variant_coerce.tag_mapping orelse return false;
        if (mapping.end - mapping.start != 1) return false;
        instruction.* = .{ .const_int = @intCast(self.function.variant_coercion_tags.items[mapping.start]) };
        return true;
    }

    fn simplifyVariantExtract(self: *Rules, operation: structures.VariantOperation, result: ValueId) bool {
        if (operation.destination != null) return false;
        const coercion = self.function.definition(operation.operand) orelse return false;
        if (coercion != .variant_coerce or coercion.variant_coerce.destination != null) return false;
        const source = coercion.variant_coerce.operand;
        if (self.function.valueType(source) != operation.target_type) return false;
        return self.alias(result, source);
    }

    fn simplifyTerminator(self: *Rules, terminator: *Terminator) bool {
        if (terminator.* != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        if (predicate.operation == .eqb or predicate.operation == .neb) if (self.function.definition(predicate.operands.lhs)) |definition| if (definition == .compare) if (self.constantBool(predicate.operands.rhs)) |expected| {
            const holds = (predicate.operation == .eqb) == expected;
            const compare = definition.compare;
            terminator.predicate_branch.operation = if (holds) compare.operation else compare.operation.negated();
            terminator.predicate_branch.operands = compare.operands;
            return true;
        };
        const order = self.operandOrder(predicate.operands) orelse return false;
        terminator.* = .{ .branch = if (predicate.operation.holds(order)) predicate.then_branch else predicate.else_branch };
        self.graph_changed = true;
        self.function.invalidateControlFlow();
        return true;
    }

    fn operandOrder(self: *const Rules, operands: structures.BinaryOperands) ?std.math.Order {
        if (operands.lhs == operands.rhs) return .eq;
        return std.math.order(self.constant(operands.lhs) orelse return null, self.constant(operands.rhs) orelse return null);
    }

    fn constantBool(self: *const Rules, value: ValueId) ?bool {
        const definition = self.function.definition(value) orelse return null;
        return if (definition == .const_bool) definition.const_bool else null;
    }

    fn simplifyCompare(self: *Rules, instruction: *Instruction, operation: structures.CompareOperation, result: ValueId) bool {
        if (operation.operation == .eqb or operation.operation == .neb) if (self.constantBool(operation.operands.rhs)) |expected| {
            const holds = (operation.operation == .eqb) == expected;
            if (holds) return self.alias(result, operation.operands.lhs);
            if (self.function.definition(operation.operands.lhs)) |definition| if (definition == .compare) {
                instruction.* = .{ .compare = .{ .operation = definition.compare.operation.negated(), .operands = definition.compare.operands } };
                return true;
            };
        };
        const order = self.operandOrder(operation.operands) orelse return false;
        instruction.* = .{ .const_bool = operation.operation.holds(order) };
        return true;
    }

    fn simplifySelect(self: *Rules, operation: structures.SelectOperation, result: ValueId) bool {
        if (operation.then_value == operation.else_value) return self.alias(result, operation.then_value);
        const condition = self.constantBool(operation.condition) orelse return false;
        return self.alias(result, if (condition) operation.then_value else operation.else_value);
    }

    fn alias(self: *Rules, result: ValueId, target: ValueId) bool {
        if (self.address_taken[@backingInt(result)] or self.address_taken[@backingInt(target)] or !self.function.plainValue(target)) return false;
        self.function.replace(result, target);
        return true;
    }

    fn constant(self: *const Rules, value: ValueId) ?i32 {
        return switch (self.function.definition(value) orelse return null) {
            .const_int => |integer| integer,
            .const_bool => |boolean| @intFromBool(boolean),
            .const_byte => |byte| byte,
            else => null,
        };
    }
};

const Algebra = struct {
    commutative: bool = false,
    identity: ?i32 = null,
    absorbing: ?i32 = null,
    negating: ?i32 = null,
    self_result: ?i32 = null,
};

fn algebra(instruction: Instruction) Algebra {
    return switch (instruction) {
        .addi => .{ .commutative = true, .identity = 0 },
        .subi => .{ .identity = 0, .self_result = 0 },
        .muli => .{ .commutative = true, .identity = 1, .absorbing = 0, .negating = -1 },
        .divsi => .{ .identity = 1, .negating = -1 },
        else => unreachable,
    };
}

fn binaryOperands(instruction: *Instruction) *structures.BinaryOperands {
    return switch (instruction.*) {
        inline .addi, .subi, .muli, .divsi => |*operands| operands,
        else => unreachable,
    };
}

pub fn addressTaken(function: *Function) ![]const bool {
    if (function.address_taken) |taken| return taken;
    const taken = try function.scratch.alloc(bool, function.valueCount());
    @memset(taken, false);
    for (function.blocks.items) |block| for (block.instructions.items) |index| {
        if (function.removed.items[index]) continue;
        const instruction = &function.instructions.items[index];
        switch (instruction.*) {
            inline .value_copy, .variant_coerce, .variant_extract => |operation| {
                if (operation.destination) |destination| taken[@backingInt(destination)] = true;
            },
            .static_conversion => |operation| {
                taken[@backingInt(operation.operand)] = true;
                if (operation.destination) |destination| taken[@backingInt(destination)] = true;
            },
            .storage_projection => |projection| taken[@backingInt(projection.owner)] = true,
            .array_element => |element| taken[@backingInt(element.array)] = true,
            .storage_cursor => |cursor| taken[@backingInt(cursor.source)] = true,
            .borrow_address => |address| if (!address.base_is_reference) {
                taken[@backingInt(address.source)] = true;
            },
            .initializer_ref => |reference| {
                for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |capture| taken[@backingInt(capture)] = true;
            },
            .call => |call| markCallAddresses(function, call, taken),
            .fill => |operation| taken[@backingInt(operation.first)] = true,
            .move => |operation| {
                taken[@backingInt(operation.destination)] = true;
                taken[@backingInt(operation.source)] = true;
            },
            else => {},
        }
    };
    for (function.blocks.items) |*block| {
        for (block.terminator.branches()) |maybe_branch| if (maybe_branch) |branch| markBranchAddresses(function, branch.*, taken);
    }
    function.address_taken = taken;
    return taken;
}

fn markCallAddresses(function: *const Function, call: structures.FunctionCall, taken: []bool) void {
    if (call.destination) |destination| taken[@backingInt(destination)] = true;
    for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
        if (argument != .prepared) taken[@backingInt(argument.valueId())] = true;
    }
}

fn markBranchAddresses(function: *const Function, branch: structures.FunctionBranch, taken: []bool) void {
    const arguments = function.branch_arguments.items[branch.arguments.start..branch.arguments.end];
    const parameters = function.blocks.items[@backingInt(branch.target)].parameters.items;
    const count = @min(arguments.len, parameters.len);
    for (arguments[0..count], parameters[0..count]) |argument, parameter| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        if (data.representation != .value or !function.direct(data.type_id)) taken[@backingInt(argument.value)] = true;
    }
    for (arguments[count..]) |argument| taken[@backingInt(argument.value)] = true;
}
