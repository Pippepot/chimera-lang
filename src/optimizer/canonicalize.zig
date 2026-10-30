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
        for (function.blocks.items) |*block| {
            rules.source = block.instructions.items;
            rules.rewritten = .empty;
            for (rules.source, 0..) |index, position| {
                rules.position = position;
                if (!function.removed.items[index]) {
                    // Rules may append instructions and relocate the function's arrays.
                    function_ir.allOperands(function, &function.instructions.items[index], function, Function.resolveOperand);
                    const result = function.results.items[index];
                    const original = function.instructions.items[index];
                    var instruction = original;
                    if (try rules.simplify(&instruction, result)) {
                        function.instructions.items[index] = instruction;
                        changed = true;
                        changes.storage = changes.storage or switch (original) {
                            .borrow_read, .borrow_write, .borrow_address => true,
                            else => function_ir.usesStorage(function, &original) or function_ir.usesStorage(function, &instruction),
                        };
                    }
                }
                if (rules.rewritten.capacity != 0) try rules.rewritten.append(function.scratch, index);
            }
            if (rules.rewritten.capacity != 0) block.instructions = rules.rewritten;
        }
        for (function.blocks.items) |*block| {
            function_ir.terminatorAllOperands(function, &block.terminator, function, Function.resolveOperand);
            if (rules.simplifyTerminator(&block.terminator)) changed = true;
        }
        changes.changed = changes.changed or changed;
        if (changed) function.invalidateOperands();
    }
    function.operands_dirty = false;
    changes.control_flow = rules.graph_changed;
    return changes;
}

const Rules = struct {
    function: *Function,
    address_taken: []const bool,
    stable_values: ?[]const bool = null,
    graph_changed: bool = false,
    source: []const u32 = &.{},
    position: usize = 0,
    rewritten: std.ArrayList(u32) = .empty,

    /// Pure scalar expansion cannot expose storage or change existing memory facts.
    fn emitScalar(self: *Rules, instruction: Instruction) !ValueId {
        const function = self.function;
        std.debug.assert(compaction.isScalar(instruction.resultType()));
        std.debug.assert(compaction.removableWhenUnused(function, instruction));
        if (self.rewritten.capacity == 0) try self.rewritten.appendSlice(function.scratch, self.source[0..self.position]);
        const origin = self.source[self.position];
        const index = try function.newInstruction(instruction, function.instructionSpan(origin), function.instructionFrame(origin));
        const value = function.results.items[index];
        std.debug.assert(function.plainValue(value));
        try self.rewritten.append(function.scratch, index);
        return value;
    }

    fn isAddressTaken(self: *const Rules, value: ValueId) bool {
        // Newly emitted scalars are private; original facts remain conservative.
        std.debug.assert(@backingInt(value) < self.function.valueCount());
        return @backingInt(value) < self.address_taken.len and self.address_taken[@backingInt(value)];
    }

    fn simplify(self: *Rules, instruction: *Instruction, result: ValueId) !bool {
        if (self.function.find(result) != result) return false;
        switch (instruction.*) {
            .addi, .subi, .muli, .shli, .shrsi => return self.simplifyBinary(instruction, result),
            .divsi => return self.simplifyDivision(instruction, result),
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

    fn simplifyDivision(self: *Rules, instruction: *Instruction, result: ValueId) !bool {
        if (self.simplifyBinary(instruction, result)) return true;
        const operands = instruction.divsi;
        const divisor = self.constant(operands.rhs) orelse return false;
        if (self.isAddressTaken(result) or self.isAddressTaken(operands.lhs) or self.isAddressTaken(operands.rhs)) return false;
        if (!self.function.plainValue(operands.lhs)) return false;
        const magnitude: u32 = @intCast(if (divisor < 0) -@as(i64, divisor) else divisor);
        if (magnitude <= 1 or !std.math.isPowerOfTwo(magnitude)) return false;
        const zero = try self.emitScalar(.{ .const_int = 0 });
        const count = try self.emitScalar(.{ .const_int = @intCast(@ctz(magnitude)) });
        const mask = try self.emitScalar(.{ .const_int = @intCast(magnitude - 1) });
        const negative = try self.emitScalar(.{ .compare = .{ .operation = .lti, .operands = .{ .lhs = operands.lhs, .rhs = zero } } });
        const bias = try self.emitScalar(.{ .select = .{ .condition = negative, .then_value = mask, .else_value = zero, .type_id = .int } });
        const rounded = try self.emitScalar(.{ .addi = .{ .lhs = operands.lhs, .rhs = bias } });
        const quotient: Instruction = .{ .shrsi = .{ .lhs = rounded, .rhs = count } };
        instruction.* = if (divisor > 0) quotient else .{ .negi = try self.emitScalar(quotient) };
        return true;
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
        if (argument.block == function.entry or !function.plainValue(operation.operand) or self.isAddressTaken(operation.operand)) return false;
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
        if (self.isAddressTaken(result) or self.isAddressTaken(value)) {
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
        if (self.isAddressTaken(result) or self.isAddressTaken(target) or !self.function.plainValue(target)) return false;
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
        .shli, .shrsi => .{ .identity = 0 },
        else => unreachable,
    };
}

fn binaryOperands(instruction: *Instruction) *structures.BinaryOperands {
    return switch (instruction.*) {
        inline .addi, .subi, .muli, .divsi, .shli, .shrsi => |*operands| operands,
        else => unreachable,
    };
}

const AddressSet = struct {
    taken: []bool,

    fn mark(self: @This(), value: ValueId) void {
        self.taken[@backingInt(value)] = true;
    }
};

pub fn addressTaken(function: *Function) ![]const bool {
    if (function.address_taken) |taken| return taken;
    const taken = try function.scratch.alloc(bool, function.valueCount());
    @memset(taken, false);
    const addresses: AddressSet = .{ .taken = taken };
    for (function.blocks.items) |block| for (block.instructions.items) |index| {
        if (!function.removed.items[index]) visitInstructionAddresses(function, function.instructions.items[index], addresses, AddressSet.mark);
    };
    for (function.blocks.items) |*block| {
        for (block.terminator.branches()) |maybe_branch| if (maybe_branch) |branch| visitBranchAddresses(function, branch.*, addresses, AddressSet.mark);
    }
    function.address_taken = taken;
    return taken;
}

pub fn visitInstructionAddresses(function: *const Function, instruction: Instruction, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    switch (instruction) {
        inline .value_copy, .variant_coerce, .variant_extract => |operation| {
            if (operation.destination) |destination| visit(context, destination);
        },
        .static_conversion => |operation| {
            visit(context, operation.operand);
            if (operation.destination) |destination| visit(context, destination);
        },
        .storage_projection => |projection| visit(context, projection.owner),
        .array_element => |element| visit(context, element.array),
        .storage_cursor => |cursor| visit(context, cursor.source),
        .borrow_address => |address| if (!address.base_is_reference) {
            visit(context, address.source);
        },
        .initializer_ref => |reference| {
            for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |capture| visit(context, capture);
        },
        .call => |call| visitCallAddresses(function, call, context, visit),
        .fill => |operation| visit(context, operation.first),
        .move => |operation| {
            visit(context, operation.destination);
            visit(context, operation.source);
        },
        else => {},
    }
}

fn visitCallAddresses(function: *const Function, call: structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    if (call.destination) |destination| visit(context, destination);
    for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
        if (argument != .prepared) visit(context, argument.valueId());
    }
}

pub fn visitBranchAddresses(function: *const Function, branch: structures.FunctionBranch, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    const arguments = function.branch_arguments.items[branch.arguments.start..branch.arguments.end];
    const parameters = function.blocks.items[@backingInt(branch.target)].parameters.items;
    const count = @min(arguments.len, parameters.len);
    for (arguments[0..count], parameters[0..count]) |argument, parameter| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        if (data.representation != .value or !function.direct(data.type_id)) visit(context, argument.value);
    }
    for (arguments[count..]) |argument| visit(context, argument.value);
}
