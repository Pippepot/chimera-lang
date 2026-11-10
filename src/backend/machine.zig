const std = @import("std");
const x86 = @import("x86_encoding.zig");

pub const ValueId = enum(u32) { _ };

pub const Instruction = union(enum) {
    label,
    scratch_dead,
    fixed: struct { bits: u64 = 0, target: u32 = 0, operation: x86.Operation },
    register: struct { operation: x86.RegisterOperation, value: ValueId },
    parameter: struct { value: ValueId, offset: u32, width: enum { byte, dword, qword } = .dword },
    preserve: struct { restore: bool, offset: u32 },

    pub fn registerAccess(self: Instruction) ?struct { value: ValueId, write: bool } {
        return switch (self) {
            .register => |operation| .{ .value = operation.value, .write = operation.operation == .store_byte or operation.operation == .store_eax or operation.operation == .store_rax },
            .parameter => |parameter| .{ .value = parameter.value, .write = true },
            .label, .scratch_dead, .fixed, .preserve => null,
        };
    }
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

/// The instructions a peephole examines, starting at the current one; positions past the end match nothing.
const Window = struct {
    instructions: []const Instruction,

    fn register(window: Window, offset: usize, operation: x86.RegisterOperation) ?ValueId {
        if (offset >= window.instructions.len) return null;
        const instruction = window.instructions[offset];
        if (instruction != .register or instruction.register.operation != operation) return null;
        return instruction.register.value;
    }

    /// The operand bits of a fixed instruction with this operation.
    fn fixed(window: Window, offset: usize, operation: x86.Operation) ?u64 {
        if (offset >= window.instructions.len) return null;
        const instruction = window.instructions[offset];
        if (instruction != .fixed or instruction.fixed.operation != operation) return null;
        return instruction.fixed.bits;
    }

    fn scratchDead(window: Window, offset: usize) bool {
        return offset < window.instructions.len and window.instructions[offset] == .scratch_dead;
    }
};

pub const Function = struct {
    const PeepholeContext = struct { registers: []const ?x86.Register, spills: []const u32, widths: []const WriteWidth };
    /// Combined encodings tried in order; each returns how many instructions it consumed.
    const peepholes = .{ encodeDirectIndexedLoad, encodeIndex, encodeCopy, encodeComparison, encodeIndexedLoad, encodeIndexedStore, encodeInPlace };

    const WriteWidth = enum { unwritten, narrow, wide };
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

    pub fn appendFixed(self: *Function, operation: x86.Operation, operand: x86.Operand, bits: u64) !void {
        std.debug.assert(x86.encoding(operation).operand == operand);
        try self.instructions.append(self.gpa, .{ .fixed = .{ .operation = operation, .bits = bits } });
    }

    pub fn emit(self: *Function, operation: x86.Operation) !void {
        try self.appendFixed(operation, .none, 0);
    }

    pub fn immediate(self: *Function, operation: x86.Operation, value: i32) !void {
        try self.appendFixed(operation, .i32, @as(u32, @bitCast(value)));
    }

    pub fn offset(self: *Function, operation: x86.Operation, value: u32) !void {
        try self.appendFixed(operation, .u32, value);
    }

    pub fn absolute(self: *Function, operation: x86.Operation, value: u64) !void {
        try self.appendFixed(operation, .u64, value);
    }

    pub fn register(self: *Function, operation: x86.RegisterOperation, value: ValueId, bits: u32) !void {
        std.debug.assert(bits == 0);
        switch (operation) {
            .load_byte, .store_byte, .load_eax, .store_eax, .load_rax, .store_rax, .add_eax, .sub_eax, .imul_eax, .cmp_eax, .add_rax, .sub_rax, .imul_rax, .cmp_rax, .and_eax, .or_eax, .xor_eax, .and_rax, .or_rax, .xor_rax, .load_ecx => {},
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
                .parameter => |parameter| std.debug.assert(@backingInt(parameter.value) < value_count),
                .label, .scratch_dead, .preserve => {},
            }
        }
    }

    pub fn patchHere(self: *Function, field: usize) !void {
        try self.patch(field, try self.position());
    }

    pub fn coalesceAccumulatorCopies(self: *Function, value_count: usize) !void {
        for (0..self.instructions.items.len) |index| {
            if (self.accumulatorReload(index) != null) break;
        } else return;
        const accesses = try self.gpa.alloc(struct { reads: usize = 0, writes: usize = 0 }, value_count);
        defer self.gpa.free(accesses);
        @memset(accesses, .{});
        for (self.instructions.items) |instruction| {
            const access = instruction.registerAccess() orelse continue;
            const counts = &accesses[@backingInt(access.value)];
            if (access.write) counts.writes += 1 else counts.reads += 1;
        }
        for (0..self.instructions.items.len) |index| {
            const reload = self.accumulatorReload(index) orelse continue;
            const stored = self.instructions.items[index].register;
            const counts = accesses[@backingInt(stored.value)];
            if (counts.reads != 1 or counts.writes != 1) continue;
            self.instructions.items[index] = .scratch_dead;
            self.instructions.items[reload] = if (stored.operation == .store_rax or self.upperAccumulatorDead(reload + 1))
                .scratch_dead
            else
                .{ .fixed = .{ .operation = .mov_eax_eax } };
        }
    }

    fn accumulatorReload(self: *const Function, index: usize) ?usize {
        const instruction = self.instructions.items[index];
        if (instruction != .register) return null;
        const stored = instruction.register;
        if (stored.operation != .store_eax and stored.operation != .store_rax) return null;
        var reload = index + 1;
        while (reload < self.instructions.items.len and self.instructions.items[reload] == .scratch_dead) reload += 1;
        if (reload == self.instructions.items.len) return null;
        const loaded = self.instructions.items[reload];
        if (loaded != .register or loaded.register.value != stored.value) return null;
        const expected: x86.RegisterOperation = if (stored.operation == .store_eax) .load_eax else .load_rax;
        return if (loaded.register.operation == expected) reload else null;
    }

    fn upperAccumulatorDead(self: *const Function, start: usize) bool {
        for (self.instructions.items[start..]) |instruction| {
            switch (instruction) {
                .scratch_dead => return true,
                .register => |operation| switch (operation.operation) {
                    .load_eax, .load_rax, .add_eax, .sub_eax, .imul_eax => return true,
                    .store_eax, .cmp_eax, .load_ecx => {},
                    else => return false,
                },
                .fixed => |fixed| switch (fixed.operation) {
                    // These overwrite the whole accumulator and read at most its low half.
                    .mov_eax, .mov_eax_rsp, .mov_rax, .mov_rax_rsp, .lea_rax_rsp, .mov_eax_eax, .call_relative => return true,
                    .add_eax, .sub_eax, .imul_eax, .add_eax_rsp, .sub_eax_rsp, .imul_eax_rsp, .add_eax_ecx, .sub_eax_ecx, .imul_eax_ecx => return true,
                    .add_eax_mem_rcx, .sub_eax_mem_rcx, .imul_eax_mem_rcx, .shl_eax, .sar_eax, .shl_eax_cl, .sar_eax_cl, .neg_eax => return true,
                    .movzx_eax_al, .movzx_eax_ax, .movzx_eax_rsp, .movzx_eax_word_rsp, .mov_eax_rsi_offset, .movzx_eax_rsi_offset, .cmove_eax_ecx => return true,
                    // These read at most the low half and leave the accumulator intact.
                    .mov_rsp_eax, .mov_ecx_eax, .mov_edi_eax, .mov_edx_eax, .mov_esi_eax, .mov_rdi_eax, .mov_rsp_al, .mov_rdi_al, .mov_rsp_ax, .mov_rdi_ax => {},
                    .cmp_eax, .cmp_eax_rsp, .cmp_eax_mem_rcx, .test_eax, .movsxd_rcx_eax, .cdq => {},
                    .sete_al, .setne_al, .setl_al, .setg_al, .setle_al, .setge_al => {},
                    else => return false,
                },
                .label, .parameter, .preserve => return false,
            }
        }
        return false;
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
        const widths = try self.gpa.alloc(WriteWidth, registers.len);
        defer self.gpa.free(widths);
        @memset(widths, .unwritten);
        for (self.instructions.items) |instruction| {
            const access = instruction.registerAccess() orelse continue;
            if (!access.write) continue;
            const width = &widths[@backingInt(access.value)];
            if ((instruction == .register and instruction.register.operation == .store_rax) or (instruction == .parameter and instruction.parameter.width == .qword)) {
                width.* = .wide;
            } else if (width.* == .unwritten) width.* = .narrow;
        }
        const context: PeepholeContext = .{ .registers = registers, .spills = spills, .widths = widths };
        var patches: std.ArrayList(struct { field: u32, target: u32 }) = .empty;
        defer patches.deinit(self.gpa);
        var skip_until: usize = 0;
        var last_store: ?struct { operation: x86.Operation, offset: u64, end: usize } = null;
        for (self.instructions.items, fields, 0..) |instruction, *field, index| {
            positions[index] = std.math.cast(u32, encoded.code.items.len) orelse return error.FunctionTooLarge;
            field.* = positions[index];
            if (index < skip_until) continue;
            const consumed = inline for (peepholes) |peephole| {
                const consumed = try peephole(self, &encoded.code, index, context);
                if (consumed != 0) break consumed;
            } else 0;
            skip_until = index + consumed;
            if (consumed != 0) continue;
            switch (instruction) {
                .label => last_store = null,
                .scratch_dead => {},
                .fixed => |fixed| {
                    if (last_store) |store| {
                        const reload: x86.Operation = switch (store.operation) {
                            .mov_rsp_eax => .mov_eax_rsp,
                            .movsd_rsp_xmm0 => .movsd_xmm0_rsp,
                            .movss_rsp_xmm0 => .movss_xmm0_rsp,
                            else => .mov_rax_rsp,
                        };
                        if (store.end == encoded.code.items.len and store.offset == fixed.bits and fixed.operation == reload) continue;
                    }
                    const encoding = x86.selectedEncoding(fixed.operation, fixed.bits);
                    field.* = std.math.add(u32, positions[index], @intCast(encoding.prefix.len)) catch return error.FunctionTooLarge;
                    try x86.appendPattern(&encoded.code, self.gpa, encoding, fixed.bits);
                    if (fixed.target != 0) try patches.append(self.gpa, .{ .field = field.*, .target = fixed.target });
                    if (fixed.operation == .mov_rsp_eax or fixed.operation == .mov_rsp_rax or fixed.operation == .movsd_rsp_xmm0 or fixed.operation == .movss_rsp_xmm0) {
                        last_store = .{ .operation = fixed.operation, .offset = fixed.bits, .end = encoded.code.items.len };
                    }
                },
                .register => |operation| try self.encodeRegister(&encoded.code, operation, registers, spills),
                .parameter => |parameter| if (registers[@backingInt(parameter.value)]) |selected| {
                    try x86.appendRegister(&encoded.code, self.gpa, switch (parameter.width) {
                        .byte => .load_stack_byte,
                        .dword => .load_stack,
                        .qword => .load_stack_64,
                    }, selected, parameter.offset);
                },
                .preserve => |operation| {
                    var offset_value = operation.offset;
                    for (used) |selected| {
                        if (!selected.calleeSaved()) continue;
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
            const target = self.branchTarget(pending.target, positions);
            const displacement = @as(i64, positions[target]) - (@as(i64, pending.field) + @sizeOf(i32));
            const relative = std.math.cast(i32, displacement) orelse return error.RelocationOverflow;
            std.mem.writeInt(i32, encoded.code.items[pending.field..][0..4], relative, .little);
        }
        return encoded;
    }

    fn branchTarget(self: *const Function, initial: u32, positions: []const u32) u32 {
        var target = initial;
        for (0..self.instructions.items.len) |_| {
            if (target == self.instructions.items.len) return target;
            // Coalescing can make all of an outlined edge's copies empty.
            // Resolve its jump directly, but retain every actual encoded write.
            if (positions[target] == positions[target + 1]) {
                target += 1;
                continue;
            }
            const instruction = self.instructions.items[target];
            if (instruction == .fixed and instruction.fixed.operation == .jmp and instruction.fixed.target != 0) {
                target = instruction.fixed.target;
                continue;
            }
            return target;
        }
        return initial; // A jump cycle remains a cycle.
    }

    fn windowAt(self: *const Function, index: usize) Window {
        return .{ .instructions = self.instructions.items[index..] };
    }

    fn encodeIndex(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        const copied = window.register(0, .load_eax) orelse return 0;
        const sign_extend = window.fixed(1, .movsxd_rcx_eax) != null;
        if (!sign_extend and window.fixed(1, .mov_ecx_eax) == null) return 0;
        // The original eax copy is dead only when the base load overwrites rax
        // immediately, without a label or a read of the old accumulator.
        if (window.register(2, .load_rax) == null and window.fixed(2, .lea_rax_rsp) == null and window.fixed(2, .mov_rax_rsp) == null) return 0;
        const source = context.registers[@backingInt(copied)] orelse return 0;
        try x86.appendRegister(code, self.gpa, if (sign_extend) .sign_extend_rcx else .load_ecx, source, 0);
        return 2;
    }

    fn encodeCopy(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        const wide = window.register(0, .load_rax) != null;
        const source_value = window.register(0, if (wide) .load_rax else .load_eax) orelse return 0;
        const destination_value = window.register(1, if (wide) .store_rax else .store_eax) orelse return 0;
        if (!window.scratchDead(2)) return 0;
        const source = context.registers[@backingInt(source_value)] orelse return 0;
        const destination = context.registers[@backingInt(destination_value)] orelse return 0;
        // A coalesced 32-bit copy must still clear unknown upper bits before
        // its result can supply a zero-extended address index.
        if (destination != source or (!wide and context.widths[@backingInt(source_value)] != .narrow)) try x86.appendRegisterBinary(code, self.gpa, if (wide) .store_rax else .store_eax, destination, source);
        return 2;
    }

    fn encodeComparison(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        const lhs_value = window.register(0, .load_eax) orelse return 0;
        if (!window.scratchDead(2)) return 0;
        const lhs = context.registers[@backingInt(lhs_value)] orelse return 0;
        if (window.fixed(1, .cmp_eax)) |bits| {
            try x86.appendRegister(code, self.gpa, .cmp_immediate, lhs, bits);
        } else if (window.fixed(1, .cmp_eax_rsp)) |bits| {
            try x86.appendRegister(code, self.gpa, .cmp_stack, lhs, bits);
        } else if (window.register(1, .cmp_eax)) |rhs_value| {
            const value = @backingInt(rhs_value);
            if (context.registers[value]) |rhs| {
                try x86.appendRegisterBinary(code, self.gpa, .cmp_eax, lhs, rhs);
            } else try x86.appendRegister(code, self.gpa, .cmp_stack, lhs, context.spills[value]);
        } else return 0;
        return 2;
    }

    fn encodeDirectIndexedLoad(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        const value = @backingInt(window.register(0, .load_eax) orelse return 0);
        if (window.fixed(1, .mov_ecx_eax) == null or context.widths[value] != .narrow) return 0;
        const selected = context.registers[value] orelse return 0;
        const consumed = try self.encodeIndexedLoadFrom(code, index + 2, context.registers, selected);
        return if (consumed == 0) 0 else consumed + 2;
    }

    fn encodeIndexedLoad(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        return self.encodeIndexedLoadFrom(code, index, context.registers, null);
    }

    fn encodeIndexedLoadFrom(self: *const Function, code: *std.ArrayList(u8), index: usize, registers: []const ?x86.Register, selected_index: ?x86.Register) !usize {
        const window = self.windowAt(index);
        if (!window.scratchDead(4)) return 0;
        var destination_register: ?x86.Register = null;
        if (window.register(3, .store_eax)) |destination| {
            destination_register = registers[@backingInt(destination)];
        } else if (window.fixed(3, .mov_rsp_eax) == null and window.fixed(3, .mov_rsp_al) == null) return 0;
        const byte = window.fixed(2, .movzx_eax_rax) != null;
        if ((window.fixed(2, if (byte) .movzx_eax_rax else .mov_eax_rax) orelse return 0) != 0) return 0;
        if (window.fixed(1, if (byte) .add_rax_rcx else .lea_rax_rax_rcx_4) == null) return 0;
        if (window.register(0, .load_rax)) |source| {
            const base = registers[@backingInt(source)] orelse return 0;
            try x86.appendIndexedLoad(code, self.gpa, byte, base, destination_register, selected_index, 0);
        } else if (window.fixed(0, .lea_rax_rsp)) |stack_offset| {
            try x86.appendIndexedLoad(code, self.gpa, byte, null, destination_register, selected_index, stack_offset);
        } else return 0;
        return if (destination_register != null) 4 else 3;
    }

    fn encodeIndexedStore(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        var base: ?x86.Register = null;
        var base_offset: u64 = 0;
        if (window.register(0, .load_rax)) |value| {
            base = context.registers[@backingInt(value)] orelse return 0;
        } else if (window.fixed(0, .lea_rax_rsp)) |stack_offset| {
            base_offset = stack_offset;
        } else return 0;
        if (window.fixed(1, .lea_rax_rax_rcx_4) == null) return 0;
        if (window.fixed(2, .mov_rax_i32)) |value| {
            if (base == null or !window.scratchDead(3)) return 0;
            try x86.appendRegister(code, self.gpa, .store_indexed_i32, base.?, value);
            return 3;
        }
        if (window.fixed(2, .mov_rdi_rax) == null or window.fixed(4, .mov_rdi_eax) != 0 or !window.scratchDead(5)) return 0;
        var source: ?x86.Register = null;
        if (window.register(3, .load_eax)) |value| {
            source = context.registers[@backingInt(value)];
            if (source == null) try self.encodeRegister(code, window.instructions[3].register, context.registers, context.spills);
        } else if (window.fixed(3, .mov_eax)) |bits| {
            try x86.append(code, self.gpa, .mov_eax, bits);
        } else if (window.fixed(3, .mov_eax_rsp)) |bits| {
            try x86.append(code, self.gpa, .mov_eax_rsp, bits);
        } else return 0;
        try x86.appendIndexedStore(code, self.gpa, base, source, base_offset);
        return 5;
    }

    fn encodeInPlace(self: *const Function, code: *std.ArrayList(u8), index: usize, context: PeepholeContext) !usize {
        const window = self.windowAt(index);
        const lhs = window.register(0, .load_eax) orelse return 0;
        const result = window.register(2, .store_eax) orelse return 0;
        if (!window.scratchDead(3)) return 0;
        const destination = context.registers[@backingInt(result)] orelse return 0;
        const reuse_lhs = context.registers[@backingInt(lhs)] == destination;
        if (reuse_lhs) inline for (.{
            .{ .add_eax, .add_immediate },
            .{ .sub_eax, .sub_immediate },
            .{ .imul_eax, .imul_immediate },
            .{ .add_eax_rsp, .add_stack },
            .{ .sub_eax_rsp, .sub_stack },
            .{ .imul_eax_rsp, .imul_stack },
        }) |update| if (window.fixed(1, update[0])) |bits| {
            try x86.appendRegister(code, self.gpa, update[1], destination, bits);
            return 3;
        };
        inline for (.{ .{ .add_eax, .add_stack }, .{ .sub_eax, .sub_stack }, .{ .imul_eax, .imul_stack } }) |update| if (window.register(1, update[0])) |rhs| {
            if (!reuse_lhs and (update[0] == .sub_eax or context.registers[@backingInt(rhs)] != destination)) return 0;
            const source = @backingInt(if (reuse_lhs) rhs else lhs);
            if (context.registers[source]) |selected| {
                try x86.appendRegisterBinary(code, self.gpa, update[0], destination, selected);
            } else try x86.appendRegister(code, self.gpa, update[1], destination, context.spills[source]);
            return 3;
        };
        return 0;
    }

    fn encodeRegister(self: *const Function, code: *std.ArrayList(u8), operation: @FieldType(Instruction, "register"), registers: []const ?x86.Register, spills: []const u32) !void {
        const value = @backingInt(operation.value);
        if (registers[value]) |selected| return x86.appendRegister(code, self.gpa, operation.operation, selected, 0);
        const spilled: x86.Operation = switch (operation.operation) {
            .load_byte => .movzx_eax_rsp,
            .store_byte => .mov_rsp_al,
            .load_eax => .mov_eax_rsp,
            .store_eax => .mov_rsp_eax,
            .load_rax => .mov_rax_rsp,
            .store_rax => .mov_rsp_rax,
            .load_ecx => .mov_ecx_rsp,
            inline .add_eax, .sub_eax, .imul_eax, .cmp_eax, .and_eax, .or_eax, .xor_eax, .add_rax, .sub_rax, .imul_rax, .cmp_rax, .and_rax, .or_rax, .xor_rax => |alu| @field(x86.Operation, @tagName(alu) ++ "_rsp"),
            else => unreachable,
        };
        try x86.append(code, self.gpa, spilled, spills[value]);
    }
};
