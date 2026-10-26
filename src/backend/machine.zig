const std = @import("std");
const x86 = @import("x86_encoding.zig");

pub const ValueId = enum(u32) { _ };

pub const Instruction = union(enum) {
    label,
    scratch_dead,
    fixed: struct { bits: u64 = 0, target: u32 = 0, operation: x86.Operation },
    register: struct { operation: x86.RegisterOperation, value: ValueId },
    preserve: struct { restore: bool, offset: u32 },
};

pub const Encoded = struct {
    code: std.ArrayList(u8) = .empty,
    positions: []u32,
    fields: []u32,

    pub fn deinit(self: *Encoded, gpa: std.mem.Allocator) void {
        self.code.deinit(gpa);
        gpa.free(self.positions);
        gpa.free(self.fields);
        self.* = undefined;
    }
};

pub const Function = struct {
    gpa: std.mem.Allocator,
    instructions: std.ArrayList(Instruction) = .empty,

    pub fn deinit(self: *Function) void {
        self.instructions.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn position(self: *Function) !u32 {
        if (self.instructions.items.len == 0 or self.instructions.items[self.instructions.items.len - 1] != .label) {
            try self.instructions.append(self.gpa, .label);
        }
        return std.math.cast(u32, self.instructions.items.len) orelse error.FunctionTooLarge;
    }

    pub fn emit(self: *Function, operation: x86.Operation) !void {
        std.debug.assert(x86.encoding(operation).operand == .none);
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation } });
    }

    pub fn immediate(self: *Function, operation: x86.Operation, value: i32) !void {
        std.debug.assert(x86.encoding(operation).operand == .i32);
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation, .bits = @as(u32, @bitCast(value)) } });
    }

    pub fn offset(self: *Function, operation: x86.Operation, value: u32) !void {
        std.debug.assert(x86.encoding(operation).operand == .u32);
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation, .bits = value } });
    }

    pub fn absolute(self: *Function, operation: x86.Operation, value: u64) !void {
        std.debug.assert(x86.encoding(operation).operand == .u64);
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation, .bits = value } });
    }

    pub fn register(self: *Function, operation: x86.RegisterOperation, value: ValueId, bits: u32) !void {
        std.debug.assert(bits == 0);
        switch (operation) {
            .load_eax, .store_eax, .load_rax, .store_rax, .add_eax, .sub_eax, .imul_eax, .cmp_eax, .load_ecx => {},
            else => unreachable,
        }
        try self.instructions.append(self.gpa, .{ .register = .{ .operation = operation, .value = value } });
    }

    pub fn preserve(self: *Function, restore: bool, offset_value: u32) !void {
        try self.instructions.append(self.gpa, .{ .preserve = .{ .restore = restore, .offset = offset_value } });
    }

    pub fn patchable(self: *Function, operation: x86.Operation) !u32 {
        const encoding = x86.encoding(operation);
        std.debug.assert(encoding.compact == .none);
        std.debug.assert(encoding.operand == .rel or encoding.operand == .u64);
        const field = std.math.cast(u32, self.instructions.items.len) orelse return error.FunctionTooLarge;
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation } });
        return field;
    }

    pub fn patch(self: *Function, field: usize, target: usize) !void {
        const instruction = &self.instructions.items[field].fixed;
        std.debug.assert(x86.encoding(instruction.operation).operand == .rel);
        std.debug.assert(target != 0);
        instruction.target = std.math.cast(u32, target) orelse return error.FunctionTooLarge;
    }

    pub fn verify(self: *const Function, value_count: usize) void {
        for (self.instructions.items) |instruction| {
            switch (instruction) {
                .fixed => |fixed| if (fixed.target != 0) {
                    const target = fixed.target;
                    std.debug.assert(x86.encoding(fixed.operation).operand == .rel);
                    std.debug.assert(target <= self.instructions.items.len);
                    std.debug.assert(self.instructions.items[target - 1] == .label);
                },
                .register => |operation| std.debug.assert(@backingInt(operation.value) < value_count),
                .label, .scratch_dead, .preserve => {},
            }
        }
    }

    pub fn patchHere(self: *Function, field: usize) !void {
        try self.patch(field, try self.position());
    }

    pub fn addRax(self: *Function, value: u32) !void {
        if (value == 0) return;
        try self.immediate(.add_rax, std.math.cast(i32, value) orelse return error.FunctionTooLarge);
    }

    pub fn encode(self: *const Function, registers: []const ?x86.Register, spills: []const u32, used: []const x86.Register) !Encoded {
        std.debug.assert(registers.len == spills.len);
        const positions = try self.gpa.alloc(u32, self.instructions.items.len + 1);
        const fields = self.gpa.alloc(u32, self.instructions.items.len) catch |err| {
            self.gpa.free(positions);
            return err;
        };
        var encoded: Encoded = .{ .positions = positions, .fields = fields };
        errdefer encoded.deinit(self.gpa);
        var patches: std.ArrayList(struct { field: u32, target: u32 }) = .empty;
        defer patches.deinit(self.gpa);
        var skip_until: usize = 0;
        var last_store: ?struct { operation: x86.Operation, offset: u64, end: usize } = null;
        for (self.instructions.items, fields, 0..) |instruction, *field, index| {
            positions[index] = std.math.cast(u32, encoded.code.items.len) orelse return error.FunctionTooLarge;
            field.* = positions[index];
            if (index < skip_until) continue;
            if (self.redundantCopy(index, registers)) {
                skip_until = index + 2;
                continue;
            }
            if (try self.encodeIndexedStore(&encoded.code, index, registers)) {
                skip_until = index + 3;
                continue;
            }
            if (try self.encodeInPlace(&encoded.code, index, registers, spills)) {
                skip_until = index + 3;
                continue;
            }
            switch (instruction) {
                .label => last_store = null,
                .scratch_dead => {},
                .fixed => |fixed| {
                    if (last_store) |store| {
                        const reload: x86.Operation = if (store.operation == .mov_rsp_eax) .mov_eax_rsp else .mov_rax_rsp;
                        if (store.end == encoded.code.items.len and store.offset == fixed.bits and fixed.operation == reload) continue;
                    }
                    const encoding = x86.selectedEncoding(fixed.operation, fixed.bits);
                    field.* = std.math.add(u32, positions[index], @intCast(encoding.prefix.len)) catch return error.FunctionTooLarge;
                    try x86.appendPattern(&encoded.code, self.gpa, encoding, fixed.bits);
                    if (fixed.target != 0) try patches.append(self.gpa, .{ .field = field.*, .target = fixed.target });
                    if (fixed.operation == .mov_rsp_eax or fixed.operation == .mov_rsp_rax) {
                        last_store = .{ .operation = fixed.operation, .offset = fixed.bits, .end = encoded.code.items.len };
                    }
                },
                .register => |operation| try self.encodeRegister(&encoded.code, operation, registers, spills),
                .preserve => |operation| {
                    var offset_value = operation.offset;
                    for (used) |selected| {
                        offset_value = std.mem.alignForward(u32, offset_value, @alignOf(u64));
                        try x86.appendRegister(&encoded.code, self.gpa, if (operation.restore) .restore else .save, selected, offset_value);
                        offset_value += @sizeOf(u64);
                    }
                },
            }
        }
        positions[self.instructions.items.len] = std.math.cast(u32, encoded.code.items.len) orelse return error.FunctionTooLarge;
        for (patches.items) |pending| {
            std.debug.assert(pending.target < positions.len);
            const displacement = @as(i64, positions[pending.target]) - (@as(i64, pending.field) + @sizeOf(i32));
            const relative = std.math.cast(i32, displacement) orelse return error.RelocationOverflow;
            std.mem.writeInt(i32, encoded.code.items[pending.field..][0..4], relative, .little);
        }
        return encoded;
    }

    fn redundantCopy(self: *const Function, index: usize, registers: []const ?x86.Register) bool {
        const instructions = self.instructions.items[index..];
        if (instructions.len < 3) return false;
        if (instructions[0] != .register or instructions[0].register.operation != .load_eax) return false;
        if (instructions[1] != .register or instructions[1].register.operation != .store_eax) return false;
        if (instructions[2] != .scratch_dead) return false;
        const source = registers[@backingInt(instructions[0].register.value)] orelse return false;
        return registers[@backingInt(instructions[1].register.value)] == source;
    }

    fn encodeIndexedStore(self: *const Function, code: *std.ArrayList(u8), index: usize, registers: []const ?x86.Register) !bool {
        const instructions = self.instructions.items[index..];
        if (instructions.len < 4 or instructions[0] != .register or instructions[0].register.operation != .load_rax) return false;
        if (instructions[1] != .fixed or instructions[1].fixed.operation != .lea_rax_rax_rcx_4) return false;
        if (instructions[2] != .fixed or instructions[2].fixed.operation != .mov_rax_i32) return false;
        if (instructions[3] != .scratch_dead) return false;
        const base = registers[@backingInt(instructions[0].register.value)] orelse return false;
        try x86.appendRegister(code, self.gpa, .store_indexed_i32, base, instructions[2].fixed.bits);
        return true;
    }

    fn encodeInPlace(self: *const Function, code: *std.ArrayList(u8), index: usize, registers: []const ?x86.Register, spills: []const u32) !bool {
        const instructions = self.instructions.items[index..];
        if (instructions.len < 4) return false;
        if (instructions[0] != .register or instructions[0].register.operation != .load_eax) return false;
        if (instructions[2] != .register or instructions[2].register.operation != .store_eax) return false;
        if (instructions[3] != .scratch_dead) return false;
        const destination = registers[@backingInt(instructions[2].register.value)] orelse return false;
        const reuse_lhs = registers[@backingInt(instructions[0].register.value)] == destination;
        const operation = instructions[1];
        if (operation == .fixed) {
            if (!reuse_lhs) return false;
            const update: x86.RegisterOperation = switch (operation.fixed.operation) {
                .add_eax => .add_immediate,
                .sub_eax => .sub_immediate,
                .imul_eax => .imul_immediate,
                else => return false,
            };
            try x86.appendRegister(code, self.gpa, update, destination, operation.fixed.bits);
            return true;
        }
        if (operation != .register) return false;
        const update: x86.RegisterOperation = switch (operation.register.operation) {
            .add_eax => .add_from_eax,
            .sub_eax => .sub_from_eax,
            .imul_eax => .imul_from_eax,
            else => return false,
        };
        if (reuse_lhs) {
            try self.encodeRegister(code, .{ .operation = .load_eax, .value = operation.register.value }, registers, spills);
        } else {
            if (operation.register.operation == .sub_eax) return false;
            if (registers[@backingInt(operation.register.value)] != destination) return false;
            try self.encodeRegister(code, instructions[0].register, registers, spills);
        }
        try x86.appendRegister(code, self.gpa, update, destination, 0);
        return true;
    }

    fn encodeRegister(self: *const Function, code: *std.ArrayList(u8), operation: @FieldType(Instruction, "register"), registers: []const ?x86.Register, spills: []const u32) !void {
        const value = @backingInt(operation.value);
        if (registers[value]) |selected| return x86.appendRegister(code, self.gpa, operation.operation, selected, 0);
        const spilled: x86.Operation = switch (operation.operation) {
            .load_eax => .mov_eax_rsp,
            .store_eax => .mov_rsp_eax,
            .load_rax => .mov_rax_rsp,
            .store_rax => .mov_rsp_rax,
            .add_eax => .add_eax_rsp,
            .sub_eax => .sub_eax_rsp,
            .imul_eax => .imul_eax_rsp,
            .cmp_eax => .cmp_eax_rsp,
            .load_ecx => .mov_ecx_rsp,
            else => unreachable,
        };
        try x86.append(code, self.gpa, spilled, spills[value]);
    }
};
