const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const ir_mod = @import("ir.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const analyze = @import("analyze.zig");


const CacheExt = ".qcache";
const Magic: [8]u8 = .{ 'X', '8', '6', 'Q', 'C', 'A', 'C', 'H' };
const SchemaVersion: u32 = 11;
const CompilerAbiVersion: u32 = 8;

pub const CacheOptions = struct {
    cache_dir_override: ?[]const u8 = null,
};

pub const StageSnapshot = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: []const db.Diagnostic,
    bytes: ?[]const u8,
};

pub const SavePayload = struct {
    source_path: []const u8,
    source_text: []const u8,
    parse: StageSnapshot,
    resolve: StageSnapshot,
    typecheck: StageSnapshot,
    lower: StageSnapshot,
    compile: StageSnapshot,
};

pub const LoadedStage = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: std.ArrayList(db.Diagnostic),
    bytes: ?[]const u8,
};

pub const LoadPayload = struct {
    backing: []u8,
    parse: LoadedStage,
    resolve: LoadedStage,
    typecheck: LoadedStage,
    lower: LoadedStage,
    compile: LoadedStage,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.parse.diagnostics.deinit(gpa);
        self.resolve.diagnostics.deinit(gpa);
        self.typecheck.diagnostics.deinit(gpa);
        self.lower.diagnostics.deinit(gpa);
        self.compile.diagnostics.deinit(gpa);
        gpa.free(self.backing);
    }
};

const LoadError = error{
    InvalidMagic,
    InvalidSchema,
    InvalidCompiler,
    Truncated,
    InvalidData,
} || std.mem.Allocator.Error;

fn splitDirAndName(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    const maybe_dir = std.fs.path.dirname(path);
    return .{
        .dir = maybe_dir orelse ".",
        .name = std.fs.path.basename(path),
    };
}

fn hasCacheExtension(name: []const u8) bool {
    return std.mem.endsWith(u8, name, CacheExt);
}

pub fn sourceHash(source_text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, source_text);
}

pub fn compilerFingerprint() u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(builtin.zig_version_string);
    hasher.update("x86-query-cache");
    var abi_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &abi_bytes, CompilerAbiVersion, .little);
    hasher.update(&abi_bytes);
    return hasher.final();
}

fn cachePathForSource(gpa: std.mem.Allocator, source_path: []const u8, options: CacheOptions) ![]u8 {
    if (options.cache_dir_override) |override_dir| {
        const key_hash = std.hash.Wyhash.hash(0, source_path);
        return std.fmt.allocPrint(gpa, "{s}{c}{x}{s}", .{ override_dir, std.fs.path.sep, key_hash, CacheExt });
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ source_path, CacheExt });
}

fn stageTagByte(stage: db.Stage) u8 {
    return @intFromEnum(stage);
}

fn stageFromByte(byte: u8) !db.Stage {
    return switch (byte) {
        stageTagByte(.parse) => .parse,
        stageTagByte(.resolve) => .resolve,
        stageTagByte(.typecheck) => .typecheck,
        stageTagByte(.lower) => .lower,
        stageTagByte(.compile) => .compile,
        else => error.InvalidData,
    };
}

fn appendU8(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u8) !void {
    try buf.append(gpa, value);
}

fn appendU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendBytes(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try appendU32(buf, gpa, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}

fn appendDiagnostic(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, diag: db.Diagnostic) !void {
    try appendU8(buf, gpa, stageTagByte(diag.stage));
    if (diag.span) |span| {
        try appendU8(buf, gpa, 1);
        try appendU64(buf, gpa, @intCast(span.start));
        try appendU64(buf, gpa, @intCast(span.end));
    } else {
        try appendU8(buf, gpa, 0);
    }
    try appendBytes(buf, gpa, diag.message);
}

fn appendStage(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, snapshot: StageSnapshot) !void {
    try appendU64(buf, gpa, snapshot.changed_at);
    try appendU8(buf, gpa, if (snapshot.has_value) 1 else 0);
    try appendU32(buf, gpa, @intCast(snapshot.diagnostics.len));
    for (snapshot.diagnostics) |diag| {
        try appendDiagnostic(buf, gpa, diag);
    }
    if (snapshot.bytes) |bytes| {
        try appendU8(buf, gpa, 1);
        try appendBytes(buf, gpa, bytes);
    } else {
        try appendU8(buf, gpa, 0);
    }
}

fn serialize(gpa: std.mem.Allocator, payload: SavePayload) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, &Magic);
    try appendU32(&buf, gpa, SchemaVersion);
    try appendU64(&buf, gpa, compilerFingerprint());
    try appendU64(&buf, gpa, sourceHash(payload.source_text));
    try appendBytes(&buf, gpa, payload.source_path);

    inline for (.{ payload.parse, payload.resolve, payload.typecheck, payload.lower, payload.compile }) |s| {
        try appendStage(&buf, gpa, s);
    }

    return buf.toOwnedSlice(gpa);
}

const Reader = struct {
    data: []const u8,
    idx: usize = 0,

    fn readU8(self: *@This()) LoadError!u8 {
        if (self.idx + 1 > self.data.len) return error.Truncated;
        const value = self.data[self.idx];
        self.idx += 1;
        return value;
    }

    fn readU32(self: *@This()) LoadError!u32 {
        const bytes = try self.readSlice(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readU64(self: *@This()) LoadError!u64 {
        const bytes = try self.readSlice(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readSlice(self: *@This(), len: usize) LoadError![]const u8 {
        if (self.idx + len > self.data.len) return error.Truncated;
        const out = self.data[self.idx .. self.idx + len];
        self.idx += len;
        return out;
    }

    fn readBytes(self: *@This()) LoadError![]const u8 {
        const len = try self.readU32();
        return self.readSlice(len);
    }
};

fn readDiagnosticsList(r: *Reader, gpa: std.mem.Allocator) LoadError!std.ArrayList(db.Diagnostic) {
    const count = try r.readU32();
    var list = try std.ArrayList(db.Diagnostic).initCapacity(gpa, count);
    errdefer list.deinit(gpa);

    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        const stage = try stageFromByte(try r.readU8());
        const has_span = try r.readU8();
        var span: ?ast.Span = null;
        if (has_span == 1) {
            const start = try r.readU64();
            const end = try r.readU64();
            span = .{ .start = @intCast(start), .end = @intCast(end) };
        } else if (has_span != 0) {
            return error.InvalidData;
        }
        const msg = try r.readBytes();
        try list.append(gpa, .{
            .stage = stage,
            .span = span,
            .message = msg,
        });
    }

    return list;
}

fn readStage(r: *Reader, gpa: std.mem.Allocator) LoadError!LoadedStage {
    const changed = try r.readU64();
    const has_value_byte = try r.readU8();
    if (has_value_byte != 0 and has_value_byte != 1) return error.InvalidData;

    var diags = try readDiagnosticsList(r, gpa);
    errdefer diags.deinit(gpa);

    const has_bytes = try r.readU8();
    if (has_bytes != 0 and has_bytes != 1) return error.InvalidData;

    return .{
        .changed_at = changed,
        .has_value = has_value_byte == 1,
        .diagnostics = diags,
        .bytes = if (has_bytes == 1) try r.readBytes() else null,
    };
}

const InstFields = switch (@typeInfo(ir_mod.Inst)) {
    .@"union" => |u| u.fields,
    else => @compileError("expected union"),
};
const TermFields = switch (@typeInfo(ir_mod.Terminator)) {
    .@"union" => |u| u.fields,
    else => @compileError("expected union"),
};
const TypeFields = switch (@typeInfo(ir_mod.Type)) {
    .@"union" => |u| u.fields,
    else => @compileError("expected union"),
};

const PbrPayload = blk: {
    for (TermFields) |f| {
        if (std.mem.eql(u8, f.name, "pbr")) break :blk f.type;
    }
    @compileError("pbr field not found in Terminator");
};

fn writeIrPayload(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == void) {
    } else if (T == u32) {
        try appendU32(buf, gpa, value);
    } else if (T == i32) {
        try buf.appendSlice(gpa, std.mem.asBytes(&value));
    } else if (T == f32) {
        try buf.appendSlice(gpa, std.mem.asBytes(&value));
    } else if (T == ir_mod.InstPair) {
        try appendU32(buf, gpa, value.l);
        try appendU32(buf, gpa, value.r);
    } else if (T == ir_mod.CallInst or T == ir_mod.DirectCallInst) {
        try appendU32(buf, gpa, value.callee);
        try appendU8(buf, gpa, value.argc);
        try appendU8(buf, gpa, value.ret_slots);
        for (&value.args) |a| try appendU32(buf, gpa, a);
    } else if (T == ir_mod.FieldLoad) {
        try appendU32(buf, gpa, value.base);
        try appendU32(buf, gpa, value.field_index);
    } else if (T == ir_mod.PtrLoad) {
        try appendU32(buf, gpa, value.ptr);
        try appendU32(buf, gpa, value.offset_slots);
    } else if (T == ir_mod.PtrStore) {
        try appendU32(buf, gpa, value.ptr);
        try appendU32(buf, gpa, value.src);
        try appendU32(buf, gpa, value.offset_slots);
    } else if (T == ir_mod.Branch) {
        try appendU32(buf, gpa, value.target);
        try appendU8(buf, gpa, if (value.arg != null) 1 else 0);
        if (value.arg) |a| try appendU32(buf, gpa, a);
    } else if (T == PbrPayload) {
        try appendU8(buf, gpa, @intFromEnum(value.pred.op));
        try appendU32(buf, gpa, value.pred.pair.l);
        try appendU32(buf, gpa, value.pred.pair.r);
        try appendU32(buf, gpa, value.then_branch.target);
        try appendU8(buf, gpa, if (value.then_branch.arg != null) 1 else 0);
        if (value.then_branch.arg) |a| try appendU32(buf, gpa, a);
        try appendU32(buf, gpa, value.else_branch.target);
        try appendU8(buf, gpa, if (value.else_branch.arg != null) 1 else 0);
        if (value.else_branch.arg) |a| try appendU32(buf, gpa, a);
    } else if (T == ir_mod.Type) {
        try writeIrPayload(buf, gpa, @as(u32, @intCast(value.named)));
        // type writing handled by the caller which already wrote the tag
    } else {
        @compileError("writeIrPayload: unsupported type " ++ @typeName(T));
    }
}

fn readIrPayload(r: *Reader, comptime T: type) LoadError!T {
    if (T == void) {
        return {};
    } else if (T == u32) {
        return try r.readU32();
    } else if (T == i32) {
        return @as(i32, @bitCast(try r.readU32()));
    } else if (T == f32) {
        return @as(f32, @bitCast(try r.readU32()));
    } else if (T == ir_mod.InstPair) {
        return .{ .l = try r.readU32(), .r = try r.readU32() };
    } else if (T == ir_mod.CallInst) {
        return .{
            .callee = try r.readU32(),
            .argc = try r.readU8(),
            .ret_slots = try r.readU8(),
            .args = blk: {
                var args: [ir_mod.MaxCallArgs]ir_mod.ValueRef = undefined;
                for (&args) |*a| a.* = try r.readU32();
                break :blk args;
            },
        };
    } else if (T == ir_mod.DirectCallInst) {
        return .{
            .callee = try r.readU32(),
            .argc = try r.readU8(),
            .ret_slots = try r.readU8(),
            .args = blk: {
                var args: [ir_mod.MaxCallArgs]ir_mod.ValueRef = undefined;
                for (&args) |*a| a.* = try r.readU32();
                break :blk args;
            },
        };
    } else if (T == ir_mod.FieldLoad) {
        return .{ .base = try r.readU32(), .field_index = try r.readU32() };
    } else if (T == ir_mod.PtrLoad) {
        return .{ .ptr = try r.readU32(), .offset_slots = try r.readU32() };
    } else if (T == ir_mod.PtrStore) {
        return .{ .ptr = try r.readU32(), .src = try r.readU32(), .offset_slots = try r.readU32() };
    } else if (T == ir_mod.Branch) {
        return .{
            .target = try r.readU32(),
            .arg = if ((try r.readU8()) == 1) try r.readU32() else null,
        };
    } else if (T == PbrPayload) {
        return .{
            .pred = .{
                .op = @enumFromInt(try r.readU8()),
                .pair = .{ .l = try r.readU32(), .r = try r.readU32() },
            },
            .then_branch = .{
                .target = try r.readU32(),
                .arg = if ((try r.readU8()) == 1) try r.readU32() else null,
            },
            .else_branch = .{
                .target = try r.readU32(),
                .arg = if ((try r.readU8()) == 1) try r.readU32() else null,
            },
        };
    } else {
        @compileError("readIrPayload: unsupported type " ++ @typeName(T));
    }
}

fn writeInst(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, inst: ir_mod.Inst) !void {
    const tag = @intFromEnum(std.meta.activeTag(inst));
    try appendU8(buf, gpa, tag);
    inline for (InstFields, 0..) |field, i| {
        if (tag == i) {
            try writeIrPayload(buf, gpa, @field(inst, field.name));
        }
    }
}

fn readInst(r: *Reader) LoadError!ir_mod.Inst {
    const tag = try r.readU8();
    inline for (InstFields, 0..) |field, i| {
        if (tag == i) {
            return @unionInit(ir_mod.Inst, field.name, try readIrPayload(r, field.type));
        }
    }
    return error.InvalidData;
}

fn writeTerminator(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, term: ir_mod.Terminator) !void {
    const tag = @intFromEnum(std.meta.activeTag(term));
    try appendU8(buf, gpa, tag);
    inline for (TermFields, 0..) |field, i| {
        if (tag == i) {
            try writeIrPayload(buf, gpa, @field(term, field.name));
        }
    }
}

fn readTerminator(r: *Reader) LoadError!ir_mod.Terminator {
    const tag = try r.readU8();
    inline for (TermFields, 0..) |field, i| {
        if (tag == i) {
            return @unionInit(ir_mod.Terminator, field.name, try readIrPayload(r, field.type));
        }
    }
    return error.InvalidData;
}

fn writeType(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, ty: ir_mod.Type) !void {
    const tag = @intFromEnum(std.meta.activeTag(ty));
    try appendU8(buf, gpa, tag);
    inline for (TypeFields, 0..) |field, i| {
        if (tag == i) {
            try writeIrPayload(buf, gpa, @field(ty, field.name));
        }
    }
}

fn readType(r: *Reader) LoadError!ir_mod.Type {
    const tag = try r.readU8();
    inline for (TypeFields, 0..) |field, i| {
        if (tag == i) {
            return @unionInit(ir_mod.Type, field.name, try readIrPayload(r, field.type));
        }
    }
    return error.InvalidData;
}

fn writeBlock(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, block: ir_mod.Block) !void {
    try appendU32(buf, gpa, block.id);
    try appendU8(buf, gpa, if (block.param != null) 1 else 0);
    if (block.param) |p| try appendU32(buf, gpa, p);
    try appendU32(buf, gpa, block.param_width);
    try appendU32(buf, gpa, @intCast(block.insts.items.len));
    for (block.insts.items) |vinst| {
        try appendU32(buf, gpa, vinst.id);
        try writeInst(buf, gpa, vinst.op);
    }
    if (block.terminator) |term| {
        try appendU8(buf, gpa, 1);
        try writeTerminator(buf, gpa, term);
    } else {
        try appendU8(buf, gpa, 0);
    }
}

fn readBlock(r: *Reader, gpa: std.mem.Allocator) LoadError!ir_mod.Block {
    const id = try r.readU32();
    const param: ?ir_mod.ValueRef = if ((try r.readU8()) == 1) try r.readU32() else null;
    const param_width = try r.readU32();
    const inst_count = try r.readU32();
    var insts = try std.ArrayList(ir_mod.ValueInst).initCapacity(gpa, inst_count);
    errdefer insts.deinit(gpa);
    var i: u32 = 0;
    while (i < inst_count) : (i += 1) {
        const vinst_id = try r.readU32();
        const op = try readInst(r);
        try insts.append(gpa, .{ .id = vinst_id, .op = op });
    }
    const has_term = try r.readU8();
    return .{
        .id = id,
        .param = param,
        .param_width = param_width,
        .insts = insts,
        .terminator = if (has_term == 1) try readTerminator(r) else null,
    };
}

fn writeFunction(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, func: ir_mod.Function) !void {
    try appendU32(buf, gpa, func.id);
    try appendU32(buf, gpa, func.name);
    try appendU32(buf, gpa, func.entry);
    try writeType(buf, gpa, func.ret_type);
    try appendU32(buf, gpa, func.ret_slots);
    try appendU32(buf, gpa, func.next_value);
    try appendU32(buf, gpa, @intCast(func.param_values.items.len));
    for (func.param_values.items) |pv| try appendU32(buf, gpa, pv);
    try appendU32(buf, gpa, @intCast(func.blocks.items.len));
    for (func.blocks.items) |*blk| try writeBlock(buf, gpa, blk.*);
}

fn readFunction(r: *Reader, gpa: std.mem.Allocator) LoadError!ir_mod.Function {
    const id = try r.readU32();
    const name = try r.readU32();
    const entry = try r.readU32();
    const ret_type = try readType(r);
    const ret_slots = try r.readU32();
    const next_value = try r.readU32();
    const pv_count = try r.readU32();
    var param_values = try std.ArrayList(ir_mod.ValueRef).initCapacity(gpa, pv_count);
    errdefer param_values.deinit(gpa);
    var pvi: u32 = 0;
    while (pvi < pv_count) : (pvi += 1) {
        try param_values.append(gpa, try r.readU32());
    }
    const block_count = try r.readU32();
    var blocks = try std.ArrayList(ir_mod.Block).initCapacity(gpa, block_count);
    errdefer {
        for (blocks.items) |*blk| blk.deinit(gpa);
        blocks.deinit(gpa);
    }
    var bi: u32 = 0;
    while (bi < block_count) : (bi += 1) {
        try blocks.append(gpa, try readBlock(r, gpa));
    }
    return .{
        .id = id,
        .name = name,
        .entry = entry,
        .blocks = blocks,
        .next_value = next_value,
        .param_values = param_values,
        .ret_type = ret_type,
        .ret_slots = ret_slots,
    };
}

pub fn serializeProgram(gpa: std.mem.Allocator, prog: *const ir_mod.Program) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer buf.deinit(gpa);

    try appendU32(&buf, gpa, @intCast(prog.symbols.items.len));
    for (prog.symbols.items) |s| {
        try appendBytes(&buf, gpa, s);
    }

    try appendU32(&buf, gpa, @intCast(prog.func_types.items.len));
    for (prog.func_types.items) |ft| {
        try appendU32(&buf, gpa, @intCast(ft.params.len));
        for (ft.params) |p| try writeType(&buf, gpa, p);
        try writeType(&buf, gpa, ft.ret);
    }

    try appendU32(&buf, gpa, @intCast(prog.functions.items.len));
    for (prog.functions.items) |*func| try writeFunction(&buf, gpa, func.*);

    try appendU32(&buf, gpa, prog.entry);

    return buf.toOwnedSlice(gpa);
}

pub fn deserializeProgram(gpa: std.mem.Allocator, data: []const u8) !ir_mod.Program {
    var r = Reader{ .data = data };

    const string_count = try r.readU32();
    var symbols = try std.ArrayList([]const u8).initCapacity(gpa, string_count);
    errdefer {
        for (symbols.items) |s| gpa.free(s);
        symbols.deinit(gpa);
    }
    var si: u32 = 0;
    while (si < string_count) : (si += 1) {
        const raw = try r.readBytes();
        const owned = try gpa.dupe(u8, raw);
        try symbols.append(gpa, owned);
    }

    const ft_count = try r.readU32();
    var func_types = try std.ArrayList(ir_mod.IrFuncType).initCapacity(gpa, ft_count);
    errdefer {
        for (func_types.items) |ft| gpa.free(ft.params);
        func_types.deinit(gpa);
    }
    var fti: u32 = 0;
    while (fti < ft_count) : (fti += 1) {
        const param_count = try r.readU32();
        const params = try gpa.alloc(ir_mod.Type, param_count);
        errdefer gpa.free(params);
        var pi: u32 = 0;
        while (pi < param_count) : (pi += 1) {
            params[pi] = try readType(&r);
        }
        const ret = try readType(&r);
        try func_types.append(gpa, .{ .params = params, .ret = ret });
    }

    const fn_count = try r.readU32();
    var functions = try std.ArrayList(ir_mod.Function).initCapacity(gpa, fn_count);
    errdefer {
        for (functions.items) |*f| f.deinit(gpa);
        functions.deinit(gpa);
    }
    var fi: u32 = 0;
    while (fi < fn_count) : (fi += 1) {
        try functions.append(gpa, try readFunction(&r, gpa));
    }

    const entry = try r.readU32();

    if (r.idx != r.data.len) return error.InvalidData;

    return .{
        .entry = entry,
        .functions = functions,
        .symbols = symbols,
        .func_types = func_types,
    };
}

// ── Typecheck Type/FuncType serialization ──

fn writeTcType(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, ty: analyze.Type) (error{OutOfMemory}!void) {
    const tag = std.meta.activeTag(ty);
    try appendU8(buf, gpa, @intFromEnum(tag));
    switch (ty) {
        .unit, .bool, .int, .float, .type_type, .none => {},
        .named => |s| try appendBytes(buf, gpa, s),
        .func => |ft| try writeTcFuncType(buf, gpa, ft.*),
        .variant => |variant_ty| {
            try appendU32(buf, gpa, @intCast(variant_ty.members.len));
            for (variant_ty.members) |member_ty| try writeTcType(buf, gpa, member_ty);
        },
    }
}

fn readTcType(r: *Reader, allocator: std.mem.Allocator) LoadError!analyze.Type {
    const tag = try r.readU8();
    return switch (tag) {
        0 => .unit,
        1 => .bool,
        2 => .int,
        3 => .float,
        4 => .type_type,
        5 => .none,
        6 => .{ .named = try allocator.dupe(u8, try r.readBytes()) },
        7 => blk: {
            const ft = try allocator.create(analyze.FuncType);
            ft.* = try readTcFuncType(r, allocator);
            break :blk .{ .func = ft };
        },
        8 => blk: {
            const member_count = try r.readU32();
            const members = try allocator.alloc(analyze.Type, member_count);
            var member_index: u32 = 0;
            while (member_index < member_count) : (member_index += 1) {
                members[member_index] = try readTcType(r, allocator);
            }
            const variant_ptr = try allocator.create(analyze.VariantType);
            variant_ptr.* = .{ .members = members };
            break :blk .{ .variant = variant_ptr };
        },
        else => error.InvalidData,
    };
}

fn writeTcFuncType(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, ft: analyze.FuncType) (error{OutOfMemory}!void) {
    try appendU32(buf, gpa, @intCast(ft.params.len));
    for (ft.params) |p| try writeTcType(buf, gpa, p);
    try writeTcType(buf, gpa, ft.ret);
}

fn readTcFuncType(r: *Reader, allocator: std.mem.Allocator) LoadError!analyze.FuncType {
    const param_count = try r.readU32();
    var params = try std.ArrayList(analyze.Type).initCapacity(allocator, param_count);
    errdefer params.deinit(allocator);
    var i: u32 = 0;
    while (i < param_count) : (i += 1) {
        try params.append(allocator, try readTcType(r, allocator));
    }
    const ret = try readTcType(r, allocator);
    return .{
        .params = try params.toOwnedSlice(allocator),
        .ret = ret,
    };
}

fn writeStrU32Map(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, map: anytype) !void {
    try appendU32(buf, gpa, @intCast(map.count()));
    var iter = map.iterator();
    while (iter.next()) |entry| {
        try appendBytes(buf, gpa, entry.key_ptr.*);
        try appendU32(buf, gpa, entry.value_ptr.*);
    }
}

fn readStrU32Map(r: *Reader, gpa: std.mem.Allocator, map_ptr: anytype) !void {
    const count = try r.readU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const raw_key = try r.readBytes();
        const owned_key = try gpa.dupe(u8, raw_key);
        try map_ptr.put(owned_key, try r.readU32());
    }
}

fn readStrVoidMap(r: *Reader, gpa: std.mem.Allocator, map_ptr: anytype) !void {
    const count = try r.readU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const raw_key = try r.readBytes();
        const owned_key = try gpa.dupe(u8, raw_key);
        try map_ptr.put(owned_key, {});
    }
}

fn readU32U32Map(r: *Reader, map_ptr: anytype) !void {
    const count = try r.readU32();
    try map_ptr.ensureUnusedCapacity(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        map_ptr.putAssumeCapacity(try r.readU32(), try r.readU32());
    }
}

fn readU32TypeMap(r: *Reader, alloc: std.mem.Allocator, map_ptr: anytype) !void {
    const count = try r.readU32();
    try map_ptr.ensureUnusedCapacity(count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        map_ptr.putAssumeCapacity(try r.readU32(), try readTcType(r, alloc));
    }
}

fn writeStrVoidMap(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, map: anytype) !void {
    try appendU32(buf, gpa, @intCast(map.count()));
    var iter = map.iterator();
    while (iter.next()) |entry| {
        try appendBytes(buf, gpa, entry.key_ptr.*);
    }
}

fn writeU32U32Map(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, map: anytype) !void {
    try appendU32(buf, gpa, @intCast(map.count()));
    var iter = map.iterator();
    while (iter.next()) |entry| {
        try appendU32(buf, gpa, entry.key_ptr.*);
        try appendU32(buf, gpa, entry.value_ptr.*);
    }
}

fn writeU32TypeMap(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, map: anytype) !void {
    try appendU32(buf, gpa, @intCast(map.count()));
    var iter = map.iterator();
    while (iter.next()) |entry| {
        try appendU32(buf, gpa, entry.key_ptr.*);
        try writeTcType(buf, gpa, entry.value_ptr.*);
    }
}

// ── ResolvedAst serialization ──

pub fn serializeResolved(gpa: std.mem.Allocator, ra: *const resolver.ResolvedAst) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 1024);
    errdefer buf.deinit(gpa);

    try appendU32(&buf, gpa, @intCast(ra.functions.items.len));
    for (ra.functions.items) |fn_idx| try appendU32(&buf, gpa, fn_idx);

    try writeStrU32Map(&buf, gpa, ra.function_names);
    try writeStrU32Map(&buf, gpa, ra.comptime_value_names);
    try writeStrVoidMap(&buf, gpa, ra.struct_names);

    try appendU32(&buf, gpa, @intCast(ra.node_refs.count()));
    var nr_iter = ra.node_refs.iterator();
    while (nr_iter.next()) |entry| {
        try appendU32(&buf, gpa, entry.key_ptr.*);
        const ref_tag = std.meta.activeTag(entry.value_ptr.*);
        try appendU8(&buf, gpa, @intFromEnum(ref_tag));
        switch (entry.value_ptr.*) {
            .local, .builtin_type => {},
            .function => |id| try appendU32(&buf, gpa, id),
            .comptime_value => |decl| try appendU32(&buf, gpa, decl),
            .struct_decl => |decl| try appendU32(&buf, gpa, decl),
        }
    }

    return buf.toOwnedSlice(gpa);
}

pub fn deserializeResolved(gpa: std.mem.Allocator, data: []const u8) LoadError!resolver.ResolvedAst {
    var r = Reader{ .data = data };
    var ra = try resolver.ResolvedAst.init(gpa);
    errdefer ra.deinit(gpa);

    const fn_count = try r.readU32();
    try ra.functions.ensureTotalCapacity(gpa, fn_count);
    var fi: u32 = 0;
    while (fi < fn_count) : (fi += 1) {
        ra.functions.appendAssumeCapacity(try r.readU32());
    }

    const arena_alloc = ra.key_arena.allocator();
    try readStrU32Map(&r, arena_alloc, &ra.function_names);
    try readStrU32Map(&r, arena_alloc, &ra.comptime_value_names);
    try readStrVoidMap(&r, arena_alloc, &ra.struct_names);

    const nr_count = try r.readU32();
    try ra.node_refs.ensureUnusedCapacity(nr_count);
    var nri: u32 = 0;
    while (nri < nr_count) : (nri += 1) {
        const node_idx = try r.readU32();
        const ref_tag = try r.readU8();
        switch (ref_tag) {
            0 => ra.node_refs.putAssumeCapacity(node_idx, .local),
            1 => ra.node_refs.putAssumeCapacity(node_idx, .{ .function = try r.readU32() }),
            2 => ra.node_refs.putAssumeCapacity(node_idx, .{ .comptime_value = try r.readU32() }),
            3 => ra.node_refs.putAssumeCapacity(node_idx, .{ .struct_decl = try r.readU32() }),
            4 => ra.node_refs.putAssumeCapacity(node_idx, .builtin_type),
            else => return error.InvalidData,
        }
    }

    if (r.idx != r.data.len) return error.InvalidData;
    return ra;
}

fn writeComptimeValue(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: analyze.ComptimeValue) !void {
    const tag = std.meta.activeTag(value);
    try appendU8(buf, gpa, @intFromEnum(tag));
    switch (value) {
        .unit => {},
        .none => {},
        .bool => |v| try appendU8(buf, gpa, if (v) 1 else 0),
        .int => |v| try appendU32(buf, gpa, @bitCast(v)),
        .float => |v| try appendU32(buf, gpa, @bitCast(v)),
        .func => |fn_id| try appendU32(buf, gpa, fn_id),
        .struct_type => |decl| try appendU32(buf, gpa, decl),
        .struct_value => |sv| {
            try appendU32(buf, gpa, sv.decl);
            try appendU32(buf, gpa, @intCast(sv.fields.len));
            for (sv.fields) |field| try writeComptimeValue(buf, gpa, field);
        },
        .type_value => |ty| try writeTcType(buf, gpa, ty),
    }
}

fn readComptimeValue(r: *Reader, allocator: std.mem.Allocator) LoadError!analyze.ComptimeValue {
    const tag = try r.readU8();
    return switch (tag) {
        0 => .unit,
        1 => .none,
        2 => .{ .bool = (try r.readU8()) == 1 },
        3 => .{ .int = @bitCast(try r.readU32()) },
        4 => .{ .float = @bitCast(try r.readU32()) },
        5 => .{ .func = try r.readU32() },
        6 => .{ .struct_type = try r.readU32() },
        7 => blk: {
            const decl = try r.readU32();
            const field_count = try r.readU32();
            const fields = try allocator.alloc(analyze.ComptimeValue, field_count);
            var i: u32 = 0;
            while (i < field_count) : (i += 1) {
                fields[i] = try readComptimeValue(r, allocator);
            }
            break :blk .{ .struct_value = .{ .decl = decl, .fields = fields } };
        },
        8 => .{ .type_value = try readTcType(r, allocator) },
        else => error.InvalidData,
    };
}

// ── Analyze serialization ──

pub fn serializeTyped(gpa: std.mem.Allocator, ta: *const analyze.AnalyzedAst) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 2048);
    errdefer buf.deinit(gpa);

    try writeU32TypeMap(&buf, gpa, ta.node_types);
    try writeU32U32Map(&buf, gpa, ta.field_index);
    try writeU32TypeMap(&buf, gpa, ta.decl_binding_types);

    try appendU32(&buf, gpa, @intCast(ta.is_variant_tags.count()));
    var iv_iter = ta.is_variant_tags.iterator();
    while (iv_iter.next()) |entry| {
        try appendU32(&buf, gpa, entry.key_ptr.*);
        try appendU32(&buf, gpa, @intCast(entry.value_ptr.*.len));
        for (entry.value_ptr.*) |tag_value| {
            try appendU32(&buf, gpa, tag_value);
        }
    }

    try writeU32U32Map(&buf, gpa, ta.query_none_tags);

    try appendU32(&buf, gpa, @intCast(ta.comptime_node_values.count()));
    var cn_iter = ta.comptime_node_values.iterator();
    while (cn_iter.next()) |entry| {
        try appendU32(&buf, gpa, entry.key_ptr.*);
        try writeComptimeValue(&buf, gpa, entry.value_ptr.*);
    }

    try appendU32(&buf, gpa, @intCast(ta.comptime_values.count()));
    var cv_iter2 = ta.comptime_values.iterator();
    while (cv_iter2.next()) |entry| {
        try appendBytes(&buf, gpa, entry.key_ptr.*);
        try writeComptimeValue(&buf, gpa, entry.value_ptr.*);
    }

    try appendU32(&buf, gpa, @intCast(ta.functions.items.len));
    for (ta.functions.items) |fi| {
        try appendU32(&buf, gpa, fi.decl);
        try writeTcFuncType(&buf, gpa, fi.ty.*);
        try appendU32(&buf, gpa, @intCast(fi.param_modes.len));
        for (fi.param_modes) |mode| {
            try appendU8(&buf, gpa, @intCast(@intFromEnum(mode)));
        }
        try appendU8(&buf, gpa, if (fi.has_explicit_return) 1 else 0);
    }

    try appendU32(&buf, gpa, ta.entry_function);
    return buf.toOwnedSlice(gpa);
}

pub fn deserializeTyped(gpa: std.mem.Allocator, data: []const u8, parse_ast: *const ast.Ast) LoadError!analyze.AnalyzedAst {
    var r = Reader{ .data = data };
    var ta = analyze.AnalyzedAst.init(gpa, parse_ast);
    errdefer ta.deinit();
    const arena = ta.arena.allocator();

    try readU32TypeMap(&r, arena, &ta.node_types);
    try readU32U32Map(&r, &ta.field_index);
    try readU32TypeMap(&r, arena, &ta.decl_binding_types);

    const iv_count = try r.readU32();
    try ta.is_variant_tags.ensureUnusedCapacity(iv_count);
    var ivi: u32 = 0;
    while (ivi < iv_count) : (ivi += 1) {
        const node_idx = try r.readU32();
        const tag_count = try r.readU32();
        const tags = try arena.alloc(u32, tag_count);
        var ti: u32 = 0;
        while (ti < tag_count) : (ti += 1) {
            tags[ti] = try r.readU32();
        }
        ta.is_variant_tags.putAssumeCapacity(node_idx, tags);
    }

    try readU32U32Map(&r, &ta.query_none_tags);

    const cn_count = try r.readU32();
    try ta.comptime_node_values.ensureUnusedCapacity(cn_count);
    var cni: u32 = 0;
    while (cni < cn_count) : (cni += 1) {
        const node_idx = try r.readU32();
        const value = try readComptimeValue(&r, arena);
        ta.comptime_node_values.putAssumeCapacity(node_idx, value);
    }

    const cv_count = try r.readU32();
    var cvi: u32 = 0;
    while (cvi < cv_count) : (cvi += 1) {
        const name = try arena.dupe(u8, try r.readBytes());
        const value = try readComptimeValue(&r, arena);
        try ta.comptime_values.put(name, value);
    }

    const fn_count = try r.readU32();
    try ta.functions.ensureTotalCapacity(gpa, fn_count);
    var fni: u32 = 0;
    while (fni < fn_count) : (fni += 1) {
        const decl = try r.readU32();
        const ft_ptr = try arena.create(analyze.FuncType);
        ft_ptr.* = try readTcFuncType(&r, arena);
        const param_mode_count = try r.readU32();
        const param_modes = try arena.alloc(ast.ParamAccessMode, param_mode_count);
        var pmi: u32 = 0;
        while (pmi < param_mode_count) : (pmi += 1) {
            const mode_value = try r.readU8();
            param_modes[pmi] = @enumFromInt(mode_value);
        }
        const has_ret = (try r.readU8()) == 1;
        ta.functions.appendAssumeCapacity(.{
            .decl = decl,
            .ty = ft_ptr,
            .param_modes = param_modes,
            .has_explicit_return = has_ret,
        });
    }

    ta.entry_function = try r.readU32();

    if (r.idx != r.data.len) return error.InvalidData;
    return ta;
}

// ── ParsedAst serialization ──

pub fn serializeParsed(gpa: std.mem.Allocator, pa: *const parser.ParsedAst) ![]u8 {
    return pa.ast.serialize(gpa);
}

pub fn deserializeParsed(gpa: std.mem.Allocator, data: []const u8) !parser.ParsedAst {
    const ast_value = try ast.Ast.deserialize(gpa, data);
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .ast = ast_value,
    };
}

fn deserialize(gpa: std.mem.Allocator, file_data: []u8, expected_source_hash: u64) LoadError!?LoadPayload {
    var r = Reader{ .data = file_data };

    const magic = try r.readSlice(Magic.len);
    if (!std.mem.eql(u8, magic, &Magic)) return error.InvalidMagic;

    const schema = try r.readU32();
    if (schema != SchemaVersion) return error.InvalidSchema;

    const compiler = try r.readU64();
    if (compiler != compilerFingerprint()) return error.InvalidCompiler;

    const cached_source_hash = try r.readU64();
    if (cached_source_hash != expected_source_hash) return null;

    _ = try r.readBytes(); // stored source path; currently informational only

    var stages: [5]LoadedStage = undefined;
    var stage_count: u32 = 0;
    errdefer for (0..stage_count) |i| stages[i].diagnostics.deinit(gpa);
    for (&stages) |*stage| {
        stage.* = try readStage(&r, gpa);
        stage_count += 1;
    }

    if (r.idx != r.data.len) return error.InvalidData;

    return .{
        .backing = file_data,
        .parse = stages[0],
        .resolve = stages[1],
        .typecheck = stages[2],
        .lower = stages[3],
        .compile = stages[4],
    };
}

fn writeAtomically(io: std.Io, gpa: std.mem.Allocator, cache_path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{cache_path});
    defer gpa.free(tmp_path);

    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes }) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };

    cwd.rename(tmp_path, cwd, cache_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

fn ensureOverrideDir(io: std.Io, options: CacheOptions) !void {
    if (options.cache_dir_override) |override_dir| {
        try std.Io.Dir.cwd().createDirPath(io, override_dir);
    }
}

pub fn save(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, payload: SavePayload) !void {
    try ensureOverrideDir(io, options);
    const cache_path = try cachePathForSource(gpa, payload.source_path, options);
    defer gpa.free(cache_path);

    const bytes = try serialize(gpa, payload);
    defer gpa.free(bytes);

    try writeAtomically(io, gpa, cache_path, bytes);
}

pub fn load(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, source_path: []const u8, source_text: []const u8) !?LoadPayload {
    const cache_path = try cachePathForSource(gpa, source_path, options);
    defer gpa.free(cache_path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, cache_path, gpa, .limited(std.math.maxInt(usize))) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const expected_hash = sourceHash(source_text);
    const result = deserialize(gpa, data, expected_hash) catch {
        gpa.free(data);
        return null;
    };
    if (result) |payload| return payload;
    gpa.free(data);
    return null;
}

fn sweepCacheDir(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!hasCacheExtension(entry.name)) continue;

        const cache_data = dir.readFileAlloc(io, entry.name, gpa, .limited(std.math.maxInt(usize))) catch continue;
        defer gpa.free(cache_data);

        var r = Reader{ .data = cache_data };
        _ = r.readSlice(Magic.len) catch continue;
        const schema = r.readU32() catch continue;
        if (schema != SchemaVersion) continue;
        _ = r.readU64() catch continue;
        _ = r.readU64() catch continue;
        const source_path_bytes = r.readBytes() catch continue;

        const source_exists = blk: {
            std.Io.Dir.cwd().access(io, source_path_bytes, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        };

        if (!source_exists) {
            dir.deleteFile(io, entry.name) catch {};
        }
    }
}

pub fn sweepStaleCaches(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, source_path: []const u8) !void {
    if (options.cache_dir_override) |override_dir| {
        try sweepCacheDir(io, gpa, override_dir);
        return;
    }

    const parts = splitDirAndName(source_path);
    try sweepCacheDir(io, gpa, parts.dir);
}
