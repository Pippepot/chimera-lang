const std = @import("std");
const structures = @import("structures.zig");
const ast = @import("ast_new.zig");
const codegen = @import("codegen_new.zig");
const comptime_interpreter = @import("comptime_interpreter.zig");
const semantic = @import("semantic.zig");
const typing = @import("typing.zig");

pub const SourceText = struct {
    pub const Key = structures.FileId;
    pub const Value = []const u8;

    pub fn cloneValue(gpa: std.mem.Allocator, value: Value) !Value {
        return gpa.dupe(u8, value);
    }

    pub fn eqlValue(a: Value, b: Value) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn deinitValue(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.*);
        value.* = undefined;
    }
};

pub const ParseFile = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.Ast;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const source = (try ctx.input(SourceText, file_id)).*;
        var report = try ast.parseReport(ctx.allocator(), file_id, source);
        defer report.deinit(ctx.allocator());

        for (report.diagnostics) |diagnostic| {
            try ctx.emit(structures.Diagnostic, diagnostic);
        }

        const parsed = report.ast;
        report.ast = null;
        return parsed;
    }
};

pub const FileModule = struct {
    pub const Key = structures.FileId;
    pub const Value = structures.ModuleId;
};

pub const ModuleMembers = struct {
    pub const Key = structures.ModuleId;
    pub const Value = []const structures.FileId;

    pub fn cloneValue(gpa: std.mem.Allocator, value: Value) !Value {
        return gpa.dupe(structures.FileId, value);
    }

    pub fn eqlValue(a: Value, b: Value) bool {
        return std.mem.eql(structures.FileId, a, b);
    }

    pub fn deinitValue(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.*);
        value.* = undefined;
    }
};

pub const ModulePaths = struct {
    pub const Value = structures.ModulePath;
    pub const Id = structures.ModuleId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(value.path);
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, a.path, b.path);
    }

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        return .{ .path = try gpa.dupe(u8, value.path) };
    }

    pub fn deinit(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.path);
        value.* = undefined;
    }
};

pub const DiscoverItems = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemTree;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const parsed = try ctx.get(ParseFile, file_id);
        const ast_value = parsed.* orelse return null;
        const source = (try ctx.input(SourceText, file_id)).*;
        const module = (try ctx.input(FileModule, file_id)).*;
        var tree = try semantic.discoverItems(ctx.allocator(), &ast_value, source, module);
        errdefer tree.deinit(ctx.allocator());

        var names = std.StringHashMap(void).init(ctx.allocator());
        defer names.deinit();
        var has_duplicates = false;
        for (tree.items) |item| {
            if (item.loc.kind == .top_level_entry or item.parent != null) continue;
            if (!(try names.getOrPut(item.loc.name)).found_existing) continue;
            has_duplicates = true;
            const node = ast_value.nodes[item.declaration];
            std.debug.assert(node.tag == .static_binding);
            const token = ast_value.tokens[node.token_index];
            try ctx.emit(structures.Diagnostic, .{
                .file_id = file_id,
                .span = .{ .start = token.loc.start, .end = token.loc.end },
                .kind = .duplicate_top_level_declaration,
            });
        }
        if (has_duplicates) {
            // A duplicated top-level name makes the module's namespace invalid,
            // so no downstream query can index or build from the tree.
            tree.deinit(ctx.allocator());
            return null;
        }
        return tree;
    }
};

pub const ItemLocations = struct {
    pub const Value = structures.ItemLoc;
    pub const Id = structures.ItemId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        if (value.kind == .top_level_entry) {
            std.hash.autoHash(&hasher, value.file_id);
        } else {
            std.hash.autoHash(&hasher, value.module);
        }
        std.hash.autoHash(&hasher, value.owner);
        std.hash.autoHash(&hasher, value.source_site);
        std.hash.autoHash(&hasher, value.kind);
        hasher.update(value.name);
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        return structures.ItemLoc.eql(a, b);
    }

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        var cloned = value;
        cloned.name = try gpa.dupe(u8, value.name);
        return cloned;
    }

    pub fn deinit(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.name);
        value.* = undefined;
    }
};

pub const Types = struct {
    pub const Value = structures.TypeData;
    pub const Id = structures.InternedTypeId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, std.meta.activeTag(value));
        switch (value) {
            .variant => |variant| {
                std.hash.autoHash(&hasher, variant.members.len);
                for (variant.members) |member| std.hash.autoHash(&hasher, member);
            },
            .callable => |callable| {
                std.hash.autoHash(&hasher, callable.parameters.len);
                for (callable.parameters) |parameter| {
                    std.hash.autoHash(&hasher, parameter.mode);
                    std.hash.autoHash(&hasher, parameter.type_id);
                }
                std.hash.autoHash(&hasher, callable.return_type);
                std.hash.autoHash(&hasher, callable.is_fallible);
            },
            .structure => |identity| std.hash.autoHash(&hasher, identity),
        }
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .variant => |variant| std.mem.eql(structures.TypeId, variant.members, b.variant.members),
            .callable => |callable| structures.CallableType.eql(callable, b.callable),
            .structure => |identity| std.meta.eql(identity, b.structure),
        };
    }

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        return switch (value) {
            .variant => |variant| blk: {
                std.debug.assert(variant.members.len >= 2);
                for (variant.members, 0..) |member, index| {
                    if (index > 0) std.debug.assert(@intFromEnum(variant.members[index - 1]) < @intFromEnum(member));
                }
                break :blk .{ .variant = .{ .members = try gpa.dupe(structures.TypeId, variant.members) } };
            },
            .callable => |callable| .{ .callable = .{
                .parameters = try gpa.dupe(structures.CallableParameter, callable.parameters),
                .return_type = callable.return_type,
                .is_fallible = callable.is_fallible,
            } },
            .structure => |identity| .{ .structure = identity },
        };
    }

    pub fn deinit(gpa: std.mem.Allocator, value: *Value) void {
        switch (value.*) {
            .variant => |variant| gpa.free(variant.members),
            .callable => |callable| gpa.free(callable.parameters),
            .structure => {},
        }
        value.* = undefined;
    }
};

pub const CompileTimeValues = struct {
    pub const Value = structures.CompileTimeValue;
    pub const Id = structures.CompileTimeValueId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, value);
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.meta.eql(a, b);
    }

    pub fn clone(_: std.mem.Allocator, value: Value) !Value {
        return value;
    }

    pub fn deinit(_: std.mem.Allocator, value: *Value) void {
        value.* = undefined;
    }
};

pub const CompileTimeValueTuples = struct {
    pub const Value = structures.CompileTimeValueTuple;
    pub const Id = structures.CompileTimeValueTupleId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, value.values.len);
        for (value.values) |argument| std.hash.autoHash(&hasher, argument);
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(structures.CompileTimeValueId, a.values, b.values);
    }

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        return .{ .values = try gpa.dupe(structures.CompileTimeValueId, value.values) };
    }

    pub fn deinit(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.values);
        value.* = undefined;
    }
};

pub fn internVariantType(ctx: anytype, members: []const structures.TypeId) !structures.InternVariantResult {
    std.debug.assert(members.len >= 2);

    var canonical: std.ArrayList(structures.TypeId) = .empty;
    defer canonical.deinit(ctx.allocator());
    for (members) |member| {
        if (member.isPrimitive()) {
            try canonical.append(ctx.allocator(), member);
            continue;
        }

        if (try lookupVariantMembers(ctx, member)) |nested_members| {
            try canonical.appendSlice(ctx.allocator(), nested_members);
        } else {
            try canonical.append(ctx.allocator(), member);
        }
    }

    std.mem.sort(structures.TypeId, canonical.items, {}, struct {
        fn lessThan(_: void, left: structures.TypeId, right: structures.TypeId) bool {
            return @intFromEnum(left) < @intFromEnum(right);
        }
    }.lessThan);
    for (canonical.items[1..], canonical.items[0 .. canonical.items.len - 1]) |member, previous| {
        if (member == previous) return .{ .duplicate = member };
    }
    for (canonical.items, 0..) |member, index| {
        if (member == .never) {
            _ = canonical.orderedRemove(index);
            break;
        }
    }
    if (canonical.items.len == 0) return .{ .type_id = .never };
    if (canonical.items.len == 1) return .{ .type_id = canonical.items[0] };

    const interned_id = try ctx.intern(Types, .{ .variant = .{ .members = canonical.items } });
    return .{ .type_id = .fromInterned(interned_id) };
}

pub fn internCallableType(ctx: anytype, callable: structures.CallableType) !structures.TypeId {
    return .fromInterned(try ctx.intern(Types, .{ .callable = callable }));
}

pub fn internStructType(ctx: anytype, item_id: structures.ItemId) !structures.TypeId {
    return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .declared = item_id } }));
}

fn internGeneratedStructType(ctx: anytype, identity: structures.GeneratedStructIdentity) !structures.TypeId {
    return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
}

const SpecializationEnvironment = struct {
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    arguments: []const structures.CompileTimeValueId,
};

pub fn TypeInterner(comptime Context: type) type {
    return struct {
        ctx: Context,
        file_id: ?structures.FileId = null,
        instance: ?structures.InstanceId = null,
        specialization: ?SpecializationEnvironment = null,

        pub fn internVariant(self: @This(), members: []const structures.TypeId) !structures.InternVariantResult {
            return internVariantType(self.ctx, members);
        }

        pub fn internCallable(self: @This(), signature: structures.CallableType) !structures.TypeId {
            return internCallableType(self.ctx, signature);
        }

        pub fn variantMembers(self: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
            return lookupVariantMembers(self.ctx, type_id);
        }

        pub fn callable(self: @This(), type_id: structures.TypeId) !?structures.CallableType {
            return lookupCallable(self.ctx, type_id);
        }

        pub fn structName(self: @This(), type_id: structures.TypeId) !?[]const u8 {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
            const identity = switch (data.*) {
                .structure => |structure| structure,
                .variant, .callable => return null,
            };
            return switch (identity) {
                .declared => |item_id| (try self.ctx.lookupInterned(ItemLocations, item_id)).name,
                .generated => "anonymous struct",
            };
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            const identity = switch (data.*) {
                .structure => |structure| structure,
                .variant, .callable => return null,
            };
            return (try getStructDefinition(self.ctx, identity)) orelse return error.Unavailable;
        }

        pub fn structLayout(self: @This(), type_id: structures.TypeId) !?structures.StructLayout {
            return (try self.ctx.get(StructLayout, type_id)).*;
        }

        pub fn ownershipCapabilities(self: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
            return (try self.ctx.get(OwnershipCapabilities, type_id)).*;
        }

        pub fn ownedFunction(self: @This(), identity: structures.StructIdentity, name: []const u8) !?structures.InstanceId {
            const owner, const source_site, const specialization = switch (identity) {
                .declared => |item_id| .{ item_id, @as(?i64, null), @as(?structures.CompileTimeValueTupleId, null) },
                .generated => |generated| .{ generated.owner.item, generated.node_offset, generated.owner.specialization },
            };
            const resolved = (try self.ctx.get(ResolveItem, owner)).* orelse return error.Unavailable;
            const index = (try self.ctx.get(IndexItems, resolved.file_id)).* orelse return error.Unavailable;
            for (index.ids()) |item_id| {
                const item_loc = try self.ctx.lookupInterned(ItemLocations, item_id);
                if (item_loc.owner == owner and item_loc.source_site == source_site and item_loc.kind == .function and std.mem.eql(u8, item_loc.name, name)) {
                    return .{ .item = item_id, .specialization = specialization };
                }
            }
            return null;
        }

        pub fn functionSignature(self: @This(), instance: structures.InstanceId) !?structures.FunctionSignature {
            return if (instance.specialization) |_|
                (try self.ctx.get(FunctionInstanceSignature, instance)).*
            else
                (try self.ctx.get(FunctionSignature, instance.item)).*;
        }

        pub fn functionShape(self: @This(), item_id: structures.ItemId) !?structures.FunctionShape {
            return (try self.ctx.get(FunctionShape, item_id)).*;
        }

        pub fn internFunctionInstance(
            self: @This(),
            item_id: structures.ItemId,
            arguments: []const structures.CompileTimeValueId,
        ) !structures.InstanceId {
            if (arguments.len == 0) return .{ .item = item_id };
            return .{
                .item = item_id,
                .specialization = try self.ctx.intern(CompileTimeValueTuples, .{ .values = arguments }),
            };
        }

        pub fn internCompileTimeValue(self: @This(), value: structures.CompileTimeValue) !structures.CompileTimeValueId {
            return self.ctx.intern(CompileTimeValues, value);
        }

        pub fn lookupCompileTimeValue(self: @This(), value_id: structures.CompileTimeValueId) !structures.CompileTimeValue {
            return (try self.ctx.lookupInterned(CompileTimeValues, value_id)).*;
        }

        pub fn lookupCompileTimeTuple(self: @This(), tuple_id: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
            return (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple_id)).values;
        }

        pub fn executeComptime(self: @This(), node: structures.Node.Index) !?structures.CompileTimeValueId {
            const owner = self.instance orelse unreachable;
            const outcome = (try self.ctx.get(ExecuteComptimeThunk, .{ .owner = owner, .node = node })).* orelse return null;
            return switch (outcome) {
                .returned => |value| value,
                .failure, .exit => null,
            };
        }

        pub fn structIdentityType(self: @This(), identity: structures.StructIdentity) !structures.TypeId {
            return switch (identity) {
                .declared => |item_id| internStructType(self.ctx, item_id),
                .generated => |generated| internGeneratedStructType(self.ctx, generated),
            };
        }

        pub fn generatedStructType(self: @This(), node: structures.Node.Index) !structures.TypeId {
            const owner = self.instance orelse unreachable;
            const resolved = (try self.ctx.get(ResolveItem, owner.item)).* orelse return error.Unavailable;
            const node_offset = @as(i64, node.index()) - @as(i64, resolved.declaration);
            return internGeneratedStructType(self.ctx, .{ .owner = owner, .node_offset = node_offset });
        }

        pub fn variantLayout(self: @This(), type_id: structures.TypeId) !structures.VariantLayout {
            return (try self.ctx.get(VariantLayout, type_id)).*;
        }

        pub fn layout(self: @This(), type_id: structures.TypeId) !structures.TypeLayout {
            return (try self.ctx.get(TypeLayout, type_id)).*;
        }

        pub fn resolveStatic(self: @This(), name: []const u8) !?structures.CompileTimeValueId {
            if (self.specialization) |specialization| {
                if (semantic.resolveSpecializationArgument(
                    specialization.ast,
                    specialization.source,
                    specialization.declaration,
                    specialization.arguments,
                    name,
                )) |argument| return argument;
            }
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            const item_id = scope.resolveStatic(name) orelse return null;
            return (try self.ctx.get(ResolveStatic, item_id)).* orelse return error.Unavailable;
        }

        pub fn resolveFunction(self: @This(), name: []const u8) !?structures.ItemId {
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            return scope.resolveFunction(name);
        }

        pub fn resolveItem(self: @This(), name: []const u8) !?structures.ItemId {
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            return scope.resolve(name);
        }

        pub fn functionReference(self: @This(), name: []const u8) !?structures.FunctionReference {
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            const item_id = scope.resolveFunction(name) orelse return null;
            const shape = (try self.ctx.get(FunctionShape, item_id)).* orelse return error.Unavailable;
            for (shape.parameters) |parameter| if (parameter.mode == .static) return null;
            const signature = (try self.ctx.get(FunctionSignature, item_id)).* orelse return error.Unavailable;
            if (signature.return_type == .type) return null;
            return .{
                .target = item_id,
                .type_id = try self.internCallable(.{
                    .parameters = signature.parameters,
                    .return_type = signature.return_type,
                    .is_fallible = signature.is_fallible,
                }),
            };
        }
    };
}

fn lookupVariantMembers(ctx: anytype, type_id: structures.TypeId) !?[]const structures.TypeId {
    if (type_id.isPrimitive()) return null;
    const interned_id = type_id.interned() orelse unreachable;
    const data = (try ctx.lookupInternedAs(Types, interned_id)) orelse return null;
    return switch (data.*) {
        .variant => |variant| variant.members,
        .callable, .structure => null,
    };
}

fn lookupCallable(ctx: anytype, type_id: structures.TypeId) !?structures.CallableType {
    if (type_id.isPrimitive()) return null;
    const interned_id = type_id.interned() orelse unreachable;
    const data = (try ctx.lookupInternedAs(Types, interned_id)) orelse return null;
    return switch (data.*) {
        .variant, .structure => null,
        .callable => |callable| callable,
    };
}

pub const TypeLayout = struct {
    pub const Input = structures.TypeId;
    pub const Output = structures.TypeLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id == .int or type_id == .bool) return .{ .byte_size = 4, .byte_alignment = 4 };
        if (type_id == .unit or type_id == .none or type_id == .never) return .{ .byte_size = 0, .byte_alignment = 1 };
        if (type_id == .type) unreachable;

        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
        return switch (data.*) {
            .callable => .{ .byte_size = @sizeOf(u64), .byte_alignment = @alignOf(u64) },
            .variant => (try ctx.get(VariantLayout, type_id)).layout,
            .structure => blk: {
                const layout = (try ctx.get(StructLayout, type_id)).* orelse return error.Unavailable;
                break :blk layout.layout;
            },
        };
    }
};

pub const VariantLayout = struct {
    pub const Input = structures.TypeId;
    pub const Output = structures.VariantLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        const members = (try lookupVariantMembers(ctx, type_id)) orelse unreachable;
        if (members.len > std.math.maxInt(u32)) return error.TypeTooLarge;

        var payload_size: u32 = 0;
        var payload_alignment: u32 = 1;
        for (members) |member| {
            const member_layout = (try ctx.get(TypeLayout, member)).*;
            payload_size = @max(payload_size, member_layout.byte_size);
            payload_alignment = @max(payload_alignment, member_layout.byte_alignment);
        }

        const tag_size: u32 = @sizeOf(u32);
        const tag_alignment: u32 = @alignOf(u32);
        const byte_alignment = @max(tag_alignment, payload_alignment);
        const payload_offset = try alignForward(tag_size, payload_alignment);
        const unaligned_size = std.math.add(u32, payload_offset, payload_size) catch return error.TypeTooLarge;
        return .{
            .layout = .{
                .byte_size = try alignForward(unaligned_size, byte_alignment),
                .byte_alignment = byte_alignment,
            },
            .payload_offset = payload_offset,
        };
    }
};

pub const StructLayout = struct {
    pub const Input = structures.TypeId;
    pub const Output = ?structures.StructLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id.isPrimitive()) return null;
        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
        const identity = switch (data.*) {
            .structure => |structure| structure,
            .variant, .callable => return null,
        };
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        var active: std.ArrayList(structures.StructIdentity) = .empty;
        defer active.deinit(ctx.allocator());
        var completed: std.ArrayList(structures.StructIdentity) = .empty;
        defer completed.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, identity, &active, &completed)) return null;

        const field_offsets = try ctx.allocator().alloc(u32, definition.fields.len);
        var keep_offsets = false;
        defer if (!keep_offsets) ctx.allocator().free(field_offsets);
        var byte_size: u32 = 0;
        var byte_alignment: u32 = 1;
        for (definition.fields, field_offsets) |field, *field_offset| {
            const field_layout = (ctx.get(TypeLayout, field.type_id) catch |err| switch (err) {
                error.Unavailable => return null,
                else => return err,
            }).*;
            field_offset.* = try alignForward(byte_size, field_layout.byte_alignment);
            byte_size = std.math.add(u32, field_offset.*, field_layout.byte_size) catch return error.TypeTooLarge;
            byte_alignment = @max(byte_alignment, field_layout.byte_alignment);
        }
        const aligned_size = try alignForward(byte_size, byte_alignment);
        keep_offsets = true;
        return .{
            .layout = .{
                .byte_size = aligned_size,
                .byte_alignment = byte_alignment,
            },
            .field_offsets = field_offsets,
        };
    }
};

pub const OwnershipCapabilities = struct {
    pub const Input = structures.TypeId;
    pub const Output = ?structures.OwnershipCapabilities;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id == .type) return trivialOwnership();
        if (type_id.isPrimitive()) return trivialOwnership();

        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
        return switch (data.*) {
            .callable => trivialOwnership(),
            .variant => |variant| variantOwnership(ctx, variant.members),
            .structure => |identity| structOwnership(ctx, type_id, identity),
        };
    }

    fn trivialOwnership() structures.OwnershipCapabilities {
        return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    }

    fn variantOwnership(ctx: anytype, members: []const structures.TypeId) !?structures.OwnershipCapabilities {
        var can_move = true;
        var can_copy = true;
        var drops_trivially = true;
        var fields_need_custom_move = false;
        var fields_need_custom_copy = false;
        var contains_custom_copy = false;
        var needs_automatic_drop = false;
        var requires_explicit_drop = false;
        for (members) |member| {
            const capabilities = (try ctx.get(OwnershipCapabilities, member)).* orelse return null;
            can_move = can_move and capabilities.move != .none;
            can_copy = can_copy and capabilities.copy != .none;
            drops_trivially = drops_trivially and capabilities.drop == .trivial;
            fields_need_custom_move = fields_need_custom_move or capabilities.needs_custom_move;
            fields_need_custom_copy = fields_need_custom_copy or capabilities.needs_custom_copy;
            contains_custom_copy = contains_custom_copy or capabilities.contains_custom_copy;
            needs_automatic_drop = needs_automatic_drop or capabilities.needs_automatic_drop;
            requires_explicit_drop = requires_explicit_drop or capabilities.requires_explicit_drop;
        }
        return .{
            .move = if (can_move) .fieldwise else .none,
            .copy = if (can_copy) .fieldwise else .none,
            .drop = if (drops_trivially) .trivial else .fieldwise,
            .needs_custom_move = can_move and fields_need_custom_move,
            .needs_custom_copy = can_copy and fields_need_custom_copy,
            .contains_custom_copy = contains_custom_copy,
            .needs_automatic_drop = needs_automatic_drop,
            .requires_explicit_drop = requires_explicit_drop,
        };
    }

    fn structOwnership(ctx: anytype, type_id: structures.TypeId, identity: structures.StructIdentity) !?structures.OwnershipCapabilities {
        if ((try ctx.get(StructLayout, type_id)).* == null) return null;
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        var can_move = true;
        var moves_trivially = true;
        var can_copy = true;
        var copies_trivially = true;
        var drops_trivially = true;
        var fields_need_custom_move = false;
        var fields_need_custom_copy = false;
        var fields_need_automatic_drop = false;
        var fields_require_explicit_drop = false;
        for (definition.fields) |field| {
            const capabilities = (try ctx.get(OwnershipCapabilities, field.type_id)).* orelse return null;
            can_move = can_move and capabilities.move != .none;
            moves_trivially = moves_trivially and capabilities.move == .trivial;
            can_copy = can_copy and capabilities.copy != .none;
            copies_trivially = copies_trivially and capabilities.copy == .trivial;
            drops_trivially = drops_trivially and capabilities.drop == .trivial;
            fields_need_custom_move = fields_need_custom_move or capabilities.needs_custom_move;
            fields_need_custom_copy = fields_need_custom_copy or capabilities.needs_custom_copy;
            fields_need_automatic_drop = fields_need_automatic_drop or capabilities.needs_automatic_drop;
            fields_require_explicit_drop = fields_require_explicit_drop or capabilities.requires_explicit_drop;
        }

        const move: structures.MoveCapability = if (definition.ownership.move) |property| blk: {
            if ((property.capability == .trivial and !moves_trivially) or
                (property.capability == .fieldwise and !can_move))
            {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_move else .fieldwise_move);
                return null;
            }
            break :blk property.capability;
        } else if (can_move) .fieldwise else .none;
        const copy: structures.CopyCapability = if (definition.ownership.copy) |property| blk: {
            if ((property.capability == .trivial and !copies_trivially) or
                (property.capability == .fieldwise and !can_copy))
            {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_copy else .fieldwise_copy);
                return null;
            }
            break :blk property.capability;
        } else .none;
        const drop: structures.DropCapability = if (definition.ownership.drop) |property| blk: {
            if (property.capability == .trivial and !drops_trivially) {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, .trivial_drop);
                return null;
            }
            break :blk property.capability;
        } else if (drops_trivially) .trivial else .fieldwise;
        return .{
            .move = move,
            .copy = copy,
            .drop = drop,
            .needs_custom_move = move == .custom or (move == .fieldwise and fields_need_custom_move),
            .needs_custom_copy = copy == .custom or (copy == .fieldwise and fields_need_custom_copy),
            .contains_custom_copy = copy == .custom or (copy == .fieldwise and fields_need_custom_copy),
            .needs_automatic_drop = drop == .custom or (drop == .fieldwise and fields_need_automatic_drop),
            .requires_explicit_drop = drop == .explicit or (drop == .fieldwise and fields_require_explicit_drop),
        };
    }

    fn emitIncompatibleOwnershipProperty(
        ctx: anytype,
        identity: structures.StructIdentity,
        span: structures.SourceSpan,
        reason: structures.Diagnostic.IncompatibleStructOwnershipProperty,
    ) !void {
        const item_id = structOwnerItem(identity);
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return error.Unavailable;
        try ctx.emit(structures.Diagnostic, .{
            .file_id = resolved.file_id,
            .span = span,
            .kind = .{ .struct_ownership_property_incompatible_with_fields = reason },
        });
    }
};

fn validateStructContainment(
    ctx: anytype,
    identity: structures.StructIdentity,
    active: *std.ArrayList(structures.StructIdentity),
    completed: *std.ArrayList(structures.StructIdentity),
) !bool {
    if (containsStructIdentity(completed.items, identity)) return true;
    try active.append(ctx.allocator(), identity);
    defer _ = active.pop();

    const definition = (try getStructDefinition(ctx, identity)) orelse return false;
    const resolved = (try ctx.get(ResolveItem, structOwnerItem(identity))).* orelse return error.Unavailable;
    for (definition.fields) |field| {
        if (!try validateContainedType(ctx, field.type_id, resolved.file_id, field.span, active, completed)) return false;
    }
    try completed.append(ctx.allocator(), identity);
    return true;
}

fn structOwnerItem(identity: structures.StructIdentity) structures.ItemId {
    return switch (identity) {
        .declared => |item_id| item_id,
        .generated => |generated| generated.owner.item,
    };
}

fn containsStructIdentity(identities: []const structures.StructIdentity, target: structures.StructIdentity) bool {
    for (identities) |identity| if (std.meta.eql(identity, target)) return true;
    return false;
}

fn validateContainedType(
    ctx: anytype,
    type_id: structures.TypeId,
    file_id: structures.FileId,
    span: structures.SourceSpan,
    active: *std.ArrayList(structures.StructIdentity),
    completed: *std.ArrayList(structures.StructIdentity),
) !bool {
    if (type_id.isPrimitive()) return true;
    const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
    return switch (data.*) {
        .callable => true,
        .variant => |variant| blk: {
            for (variant.members) |member| {
                if (!try validateContainedType(ctx, member, file_id, span, active, completed)) break :blk false;
            }
            break :blk true;
        },
        .structure => |contained_identity| blk: {
            if (containsStructIdentity(active.items, contained_identity)) {
                try ctx.emit(structures.Diagnostic, .{
                    .file_id = file_id,
                    .span = span,
                    .kind = .recursive_struct_containment,
                });
                break :blk false;
            }
            break :blk validateStructContainment(ctx, contained_identity, active, completed);
        },
    };
}

fn alignForward(value: u32, alignment: u32) error{TypeTooLarge}!u32 {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const with_padding = std.math.add(u32, value, mask) catch return error.TypeTooLarge;
    return with_padding & ~mask;
}

pub const IndexItems = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemIndex;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const discovered = try ctx.get(DiscoverItems, file_id);
        const tree = discovered.* orelse return null;
        var entries: std.AutoArrayHashMapUnmanaged(structures.ItemId, u32) = .empty;
        errdefer entries.deinit(ctx.allocator());
        try entries.ensureTotalCapacity(ctx.allocator(), tree.items.len);
        const item_ids = try ctx.allocator().alloc(structures.ItemId, tree.items.len);
        defer ctx.allocator().free(item_ids);
        for (tree.items, 0..) |item, index| {
            var loc = item.loc;
            if (item.parent) |parent| {
                std.debug.assert(parent < index);
                loc.owner = item_ids[parent];
            }
            const item_id = try ctx.intern(ItemLocations, loc);
            item_ids[index] = item_id;
            entries.putAssumeCapacityNoClobber(item_id, item.declaration);
        }
        return .{ .file_id = file_id, .entries = entries };
    }
};

pub const ModuleDeclarations = struct {
    pub const Input = structures.ModuleId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, module: Input) anyerror!Output {
        const members = try ctx.input(ModuleMembers, module);

        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        defer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        var names = std.StringHashMap(void).init(ctx.allocator());
        defer names.deinit();
        for (members.*) |file_id| {
            const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
            const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
            for (index.ids()) |item_id| {
                const loc = try ctx.lookupInterned(ItemLocations, item_id);
                if (loc.kind == .top_level_entry or loc.owner != null) continue;
                std.debug.assert(loc.module == module);
                if ((try names.getOrPut(loc.name)).found_existing) {
                    const declaration = index.resolve(item_id) orelse unreachable;
                    const token = parsed.tokens[parsed.nodes[declaration].token_index];
                    try ctx.emit(structures.Diagnostic, .{
                        .file_id = file_id,
                        .span = .{ .start = token.loc.start, .end = token.loc.end },
                        .kind = .duplicate_top_level_declaration,
                    });
                    return null;
                }
                const name = try ctx.allocator().dupe(u8, loc.name);
                errdefer ctx.allocator().free(name);
                try entries.append(ctx.allocator(), .{ .name = name, .item_id = item_id, .kind = loc.kind });
            }
        }
        std.mem.sort(structures.ModuleScope.Entry, entries.items, {}, struct {
            fn lessThan(_: void, left: structures.ModuleScope.Entry, right: structures.ModuleScope.Entry) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }
};

pub const BuildModuleScope = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const file_module = (try ctx.input(FileModule, file_id)).*;
        const declarations = (try ctx.get(ModuleDeclarations, file_module)).* orelse return null;
        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        errdefer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        for (declarations.entries) |entry| {
            const name = try ctx.allocator().dupe(u8, entry.name);
            errdefer ctx.allocator().free(name);
            try entries.append(ctx.allocator(), .{ .name = name, .item_id = entry.item_id, .kind = entry.kind });
        }
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }
};

pub const ResolveItem = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.ResolvedItem;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind == .top_level_entry) {
            const index = (try ctx.get(IndexItems, loc.file_id)).* orelse return null;
            const declaration = index.resolve(item_id) orelse return null;
            return .{ .file_id = loc.file_id, .declaration = declaration };
        }
        const hint = (try ctx.get(IndexItems, loc.file_id)).*;
        if (hint) |index| {
            if (index.resolve(item_id)) |declaration| return .{ .file_id = loc.file_id, .declaration = declaration };
        }
        const members = try ctx.input(ModuleMembers, loc.module);
        for (members.*) |file_id| {
            if (file_id == loc.file_id) continue;
            const index = (try ctx.get(IndexItems, file_id)).* orelse continue;
            if (index.resolve(item_id)) |declaration| return .{ .file_id = file_id, .declaration = declaration };
        }
        return null;
    }
};

pub const FunctionShape = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionShape;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .function) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const result = try semantic.analyzeFunctionShape(&parsed, source, resolved.declaration, ctx.allocator());
        return switch (result) {
            .success => |shape| shape,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const FunctionInstanceSignature = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, instance.item);
        if (loc.kind != .function) return null;
        _ = (try ctx.get(FunctionShape, instance.item)).* orelse return null;
        const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const specialization = if (instance.specialization) |specialization_id|
            (try ctx.lookupInterned(CompileTimeValueTuples, specialization_id)).values
        else
            &.{};
        const specialization_owner = if (loc.source_site != null) loc.owner.? else instance.item;
        const specialization_shape = (try ctx.get(FunctionShape, specialization_owner)).* orelse return null;
        const specialization_resolved = (try ctx.get(ResolveItem, specialization_owner)).* orelse return null;
        var static_parameter_count: usize = 0;
        for (specialization_shape.parameters) |parameter| {
            if (parameter.mode == .static) static_parameter_count += 1;
        }
        // An instance can outlive the declaration shape that created it across
        // a source revision. It is stale query state, not a source error.
        if (specialization.len != static_parameter_count) return null;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = instance,
            .specialization = .{
                .ast = &parsed,
                .source = source,
                .declaration = specialization_resolved.declaration,
                .arguments = specialization,
            },
        };
        const result = (if (loc.source_site != null)
            semantic.analyzeFunctionSignature(
                &parsed,
                source,
                resolved.declaration,
                type_interner,
                ctx.allocator(),
            )
        else
            semantic.analyzeFunctionInstanceSignature(
                &parsed,
                source,
                resolved.declaration,
                specialization,
                type_interner,
                ctx.allocator(),
            )) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |signature| signature,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const FunctionSignature = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .function) return null;
        _ = (try ctx.get(FunctionShape, item_id)).* orelse return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
        const result = semantic.analyzeFunctionSignature(
            &parsed,
            source,
            resolved.declaration,
            type_interner,
            ctx.allocator(),
        ) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |signature| signature,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const ResolveStatic = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.CompileTimeValueId;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .static and loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        if (loc.kind == .structure) return try ctx.intern(CompileTimeValues, .{ .type = try internStructType(ctx, item_id) });
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
        const result = semantic.analyzeStaticDeclaration(&parsed, source, resolved.declaration, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        const plan = switch (result) {
            .success => |value| value,
            .unsupported => |issue| {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                return null;
            },
        };
        const runtime_annotation = switch (plan) {
            .type_value => |type_id| return try ctx.intern(CompileTimeValues, .{ .type = type_id }),
            .interpret => |type_id| type_id,
        };

        const binding = parsed.nodes[resolved.declaration];
        const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
        const site: structures.CompileTimeSite = .{
            .owner = .{ .item = item_id },
            .node = initializer,
        };
        const outcome = (try ctx.get(ExecuteComptimeThunk, site)).* orelse return null;
        const value_id = switch (outcome) {
            .returned => |returned| returned,
            .failure => return null,
            .exit => return null,
        };
        const expected_type = runtime_annotation orelse return value_id;
        var value = (try ctx.lookupInterned(CompileTimeValues, value_id)).*;
        const runtime = switch (value) {
            .type => {
                try typing.emitSemanticIssue(ctx, resolved.file_id, .{
                    .span = nodeSpan(&parsed, initializer),
                    .kind = .type_value_used_as_runtime_value,
                });
                return null;
            },
            .runtime => |runtime| runtime,
        };
        if (!try semantic.canWidenTo(type_interner, runtime.type_id, expected_type)) {
            try typing.emitSemanticIssue(ctx, resolved.file_id, .{
                .span = nodeSpan(&parsed, initializer),
                .kind = .{ .static_initializer_type_mismatch = .{
                    .expected = expected_type,
                    .found = runtime.type_id,
                } },
            });
            return null;
        }
        if (runtime.type_id != expected_type) {
            if (try lookupVariantMembers(ctx, expected_type) != null) {
                const payload = try ctx.intern(CompileTimeValues, value);
                value.runtime.value = .{ .variant = .{ .member_type = runtime.type_id, .payload = payload } };
            } else {
                std.debug.assert(try lookupCallable(ctx, expected_type) != null);
                var reference = value.runtime.value.function_ref;
                reference.type_id = expected_type;
                value.runtime.value = .{ .function_ref = reference };
            }
        }
        value.runtime.type_id = expected_type;
        return try ctx.intern(CompileTimeValues, value);
    }
};

pub const AnalyzeComptimeThunk = struct {
    pub const Input = structures.CompileTimeSite;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, site: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, site.owner.item);
        if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry) return null;
        if (loc.kind == .static and site.owner.specialization != null) return null;
        const resolved = (try ctx.get(ResolveItem, site.owner.item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        if (site.node.index() >= parsed.nodes.len) return null;
        // Static arguments inside an initializer are independent demanded
        // thunks, so a static-owned site is not limited to the initializer root.
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const specialization = if (site.owner.specialization) |specialization_id|
            (try ctx.lookupInterned(CompileTimeValueTuples, specialization_id)).values
        else
            &.{};
        const specialization_declaration = if (loc.source_site != null) blk: {
            const owner = (try ctx.get(ResolveItem, loc.owner.?)).* orelse return null;
            break :blk owner.declaration;
        } else resolved.declaration;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = site.owner,
            .specialization = if (site.owner.specialization != null) .{
                .ast = &parsed,
                .source = source,
                .declaration = specialization_declaration,
                .arguments = specialization,
            } else null,
        };
        const result = semantic.buildUnresolvedComptimeThunk(
            &parsed,
            source,
            site.node,
            type_interner,
            ctx.allocator(),
        ) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        var unresolved = switch (result) {
            .success => |body| body,
            .unsupported => |issue| {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                return null;
            },
        };
        defer unresolved.deinit(ctx.allocator());
        return typing.resolveAndTypeComptimeThunk(
            ctx,
            BuildModuleScope,
            FunctionInstanceSignature,
            site.owner.item,
            resolved.file_id,
            type_interner,
            unresolved,
        );
    }
};

pub const ExecuteComptimeThunk = struct {
    pub const Input = structures.CompileTimeSite;
    pub const Output = ?structures.CompileTimeOutcome;

    pub fn run(ctx: anytype, site: Input) anyerror!Output {
        const body = (try ctx.get(AnalyzeComptimeThunk, site)).* orelse return null;
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = site.owner.item };
        var arguments: [0]comptime_interpreter.Value = .{};
        const result = try comptime_interpreter.execute(&body, &arguments, &executor, ctx.allocator());
        return switch (result) {
            .returned => |value| .{ .returned = try internInterpretedValue(ctx, body.return_type, value) },
            .failure => blk: {
                const resolved = (try ctx.get(ResolveItem, site.owner.item)).* orelse return null;
                const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
                try ctx.emit(structures.Diagnostic, .{
                    .file_id = resolved.file_id,
                    .span = nodeSpan(&parsed, site.node),
                    .kind = .compile_time_unhandled_failure,
                });
                break :blk .failure;
            },
            .exit => |status| blk: {
                try ctx.emit(structures.CompilerControl, .{ .exit = status });
                break :blk .{ .exit = status };
            },
            .execution_error => |execution_error| blk: {
                try emitComptimeExecutionIssue(ctx, site.owner.item, site.node, execution_error);
                break :blk null;
            },
            .reported_error => null,
            .unavailable => null,
        };
    }
};

fn internInterpretedValue(ctx: anytype, result_type: structures.TypeId, value: comptime_interpreter.Value) !structures.CompileTimeValueId {
    return switch (value) {
        .type => |type_id| blk: {
            std.debug.assert(result_type == .type);
            break :blk ctx.intern(CompileTimeValues, .{ .type = type_id });
        },
        .runtime => |runtime| ctx.intern(CompileTimeValues, .{ .runtime = .{ .type_id = result_type, .value = runtime } }),
    };
}

pub const ExecuteComptimeCall = struct {
    pub const Input = structures.CompileTimeCallKey;
    pub const Output = ?structures.CompileTimeCallOutcome;

    pub fn run(ctx: anytype, key: Input) anyerror!Output {
        const signature = if (key.instance.specialization) |_|
            (try ctx.get(FunctionInstanceSignature, key.instance)).* orelse return null
        else
            (try ctx.get(FunctionSignature, key.instance.item)).* orelse return null;
        const argument_tuple = try ctx.lookupInterned(CompileTimeValueTuples, key.arguments);
        if (argument_tuple.values.len != signature.parameters.len) return null;

        const arguments = try ctx.allocator().alloc(comptime_interpreter.Value, argument_tuple.values.len);
        defer ctx.allocator().free(arguments);
        var has_mut_arguments = false;
        for (argument_tuple.values, signature.parameters, arguments) |value_id, parameter, *argument| {
            has_mut_arguments = has_mut_arguments or parameter.mode == .mut;
            const value = (try ctx.lookupInterned(CompileTimeValues, value_id)).*;
            const runtime = switch (value) {
                .type => return null,
                .runtime => |runtime| runtime,
            };
            if (runtime.type_id != parameter.type_id) return null;
            argument.* = .{ .runtime = runtime.value };
        }

        const body = (try ctx.get(AnalyzeComptimeFunctionBody, key.instance)).* orelse return null;
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = key.instance.item };
        const result = try comptime_interpreter.execute(&body, arguments, &executor, ctx.allocator());
        const outcome: structures.CompileTimeOutcome = switch (result) {
            .returned => |value| structures.CompileTimeOutcome{ .returned = try internInterpretedValue(ctx, body.return_type, value) },
            .failure => structures.CompileTimeOutcome.failure,
            .exit => |status| structures.CompileTimeOutcome{ .exit = status },
            .execution_error => |execution_error| {
                try emitComptimeExecutionIssue(ctx, key.instance.item, null, execution_error);
                return .execution_error;
            },
            .reported_error => return .execution_error,
            .unavailable => null,
        } orelse return null;

        if (!has_mut_arguments) return .{ .completed = .{ .outcome = outcome, .arguments = key.arguments } };
        const final_argument_ids = try ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
        defer ctx.allocator().free(final_argument_ids);
        for (arguments, signature.parameters, final_argument_ids) |argument, parameter, *value_id| value_id.* =
            try ctx.intern(CompileTimeValues, .{ .runtime = .{ .type_id = parameter.type_id, .value = argument.runtime } });
        return .{ .completed = .{
            .outcome = outcome,
            .arguments = try ctx.intern(CompileTimeValueTuples, .{ .values = final_argument_ids }),
        } };
    }
};

fn ComptimeCallExecutor(comptime Context: type) type {
    return struct {
        ctx: Context,
        owner: structures.ItemId,

        pub fn call(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan) !comptime_interpreter.Result {
            const signature = if (instance.specialization == null)
                (try self.ctx.get(FunctionSignature, instance.item)).* orelse return .unavailable
            else
                (try self.ctx.get(FunctionInstanceSignature, instance)).* orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            var has_mut_arguments = false;

            const value_ids = try self.ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
            defer self.ctx.allocator().free(value_ids);
            for (arguments, signature.parameters, value_ids) |argument, parameter, *value_id| {
                has_mut_arguments = has_mut_arguments or parameter.mode == .mut;
                value_id.* = try self.ctx.intern(CompileTimeValues, .{ .runtime = .{
                    .type_id = parameter.type_id,
                    .value = argument.runtime,
                } });
            }
            const tuple = try self.ctx.intern(CompileTimeValueTuples, .{ .values = value_ids });
            const outcome = self.ctx.get(ExecuteComptimeCall, .{
                .instance = instance,
                .arguments = tuple,
            }) catch |err| switch (err) {
                error.QueryCycle => return .{ .execution_error = .{ .reason = .call_cycle, .span = call_span } },
                else => return err,
            };
            const call_result = outcome.* orelse return .unavailable;
            const call_outcome = switch (call_result) {
                .completed => |completed| completed,
                .execution_error => {
                    try emitComptimeCallTrace(self.ctx, self.owner, call_span);
                    return .reported_error;
                },
            };
            if (has_mut_arguments and call_outcome.outcome != .exit) {
                const final_arguments = try self.ctx.lookupInterned(CompileTimeValueTuples, call_outcome.arguments);
                std.debug.assert(final_arguments.values.len == arguments.len);
                for (final_arguments.values, signature.parameters, arguments) |value_id, parameter, *argument| {
                    const runtime = switch ((try self.ctx.lookupInterned(CompileTimeValues, value_id)).*) {
                        .runtime => |runtime| runtime,
                        .type => unreachable,
                    };
                    std.debug.assert(runtime.type_id == parameter.type_id);
                    argument.* = .{ .runtime = runtime.value };
                }
            }
            return switch (call_outcome.outcome) {
                .returned => |returned| switch ((try self.ctx.lookupInterned(CompileTimeValues, returned)).*) {
                    .runtime => |runtime| .{ .returned = .{ .runtime = runtime.value } },
                    .type => |type_id| .{ .returned = .{ .type = type_id } },
                },
                .failure => .failure,
                .exit => |status| .{ .exit = status },
            };
        }

        pub fn internRuntime(self: *@This(), type_id: structures.TypeId, value: structures.CompileTimeValue.RuntimeValue) !structures.CompileTimeValueId {
            return self.ctx.intern(CompileTimeValues, .{ .runtime = .{ .type_id = type_id, .value = value } });
        }

        pub fn lookupRuntime(self: *@This(), value_id: structures.CompileTimeValueId) !?structures.CompileTimeValue.Runtime {
            return switch ((try self.ctx.lookupInterned(CompileTimeValues, value_id)).*) {
                .runtime => |runtime| runtime,
                .type => null,
            };
        }

        pub fn internTuple(self: *@This(), values: []const structures.CompileTimeValueId) !structures.CompileTimeValueTupleId {
            return self.ctx.intern(CompileTimeValueTuples, .{ .values = values });
        }

        pub fn lookupTuple(self: *@This(), tuple: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
            return (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
        }

        pub fn variantMembers(self: *@This(), type_id: structures.TypeId) !?[]const structures.TypeId {
            return lookupVariantMembers(self.ctx, type_id);
        }
    };
}

fn nodeSpan(parsed: *const structures.Ast, node_index: structures.Node.Index) structures.SourceSpan {
    const node = parsed.nodes[node_index.index()];
    if (node.tag == .call) return nodeSpan(parsed, node.data.node_node.a);
    const token = parsed.tokens[node.token_index];
    return .{ .start = token.loc.start, .end = token.loc.end };
}

fn emitComptimeExecutionIssue(
    ctx: anytype,
    owner: structures.ItemId,
    fallback_node: ?structures.Node.Index,
    execution_error: comptime_interpreter.ExecutionError,
) !void {
    const resolved = (try ctx.get(ResolveItem, owner)).* orelse return;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return;
    const fallback_span = nodeSpan(&parsed, fallback_node orelse @enumFromInt(resolved.declaration));
    const span = execution_error.span orelse fallback_span;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = resolved.file_id,
        .span = span,
        .kind = switch (execution_error.reason) {
            .call_cycle => .compile_time_call_cycle,
            .division_by_zero => .compile_time_division_by_zero,
            .integer_overflow => .compile_time_integer_overflow,
        },
    });
}

fn emitComptimeCallTrace(ctx: anytype, owner: structures.ItemId, span: ?structures.SourceSpan) !void {
    const call_span = span orelse return;
    const resolved = (try ctx.get(ResolveItem, owner)).* orelse return;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = resolved.file_id,
        .span = call_span,
        .kind = .compile_time_call_trace,
    });
}

pub const StructDefinition = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
        const result = semantic.analyzeStructDefinition(&parsed, source, item_id, resolved.declaration, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |definition| definition,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const GeneratedStructDefinition = struct {
    pub const Input = structures.GeneratedStructIdentity;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, identity: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, identity.owner.item);
        if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry) return null;
        const resolved = (try ctx.get(ResolveItem, identity.owner.item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const node_position = @as(i64, resolved.declaration) + @as(i64, identity.node_offset);
        const node_index = std.math.cast(u32, node_position) orelse return null;
        if (node_index >= parsed.nodes.len or parsed.nodes[node_index].tag != .@"struct") return null;
        const struct_node: structures.Node.Index = @enumFromInt(node_index);
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const specialization = if (identity.owner.specialization) |specialization_id|
            (try ctx.lookupInterned(CompileTimeValueTuples, specialization_id)).values
        else
            &.{};
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = identity.owner,
            .specialization = if (identity.owner.specialization != null) .{
                .ast = &parsed,
                .source = source,
                .declaration = resolved.declaration,
                .arguments = specialization,
            } else null,
        };
        const result = semantic.analyzeGeneratedStructDefinition(&parsed, source, struct_node, identity, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |definition| definition,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

fn getStructDefinition(ctx: anytype, identity: structures.StructIdentity) !?structures.StructDefinition {
    return switch (identity) {
        .declared => |item_id| (try ctx.get(StructDefinition, item_id)).*,
        .generated => |generated| (try ctx.get(GeneratedStructDefinition, generated)).*,
    };
}

pub const AnalyzeFunctionBody = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        return analyzeFunctionBody(ctx, .{ .item = item_id }, false);
    }
};

pub const AnalyzeFunctionInstance = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        std.debug.assert(instance.specialization != null);
        return analyzeFunctionBody(ctx, instance, false);
    }
};

pub const AnalyzeComptimeFunctionBody = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        return analyzeFunctionBody(ctx, instance, true);
    }
};

fn analyzeFunctionBody(ctx: anytype, instance: structures.InstanceId, publish_instruction_spans: bool) !?structures.FunctionBodyAnalysis {
    const loc = try ctx.lookupInterned(ItemLocations, instance.item);
    if (loc.kind == .static or loc.kind == .structure) return null;
    if (loc.kind != .function) std.debug.assert(instance.specialization == null);
    var parameters: []const structures.CallableParameter = &.{};
    var return_type: structures.TypeId = .unit;
    var is_fallible = false;
    if (loc.kind == .function) {
        const signature = if (instance.specialization == null)
            (try ctx.get(FunctionSignature, instance.item)).* orelse return null
        else
            (try ctx.get(FunctionInstanceSignature, instance)).* orelse return null;
        parameters = signature.parameters;
        return_type = signature.return_type;
        is_fallible = signature.is_fallible;
    }
    if (!publish_instruction_spans and return_type == .type) return null;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    const source = (try ctx.input(SourceText, resolved.file_id)).*;
    const specialization = if (instance.specialization) |specialization_id|
        (try ctx.lookupInterned(CompileTimeValueTuples, specialization_id)).values
    else
        &.{};
    const specialization_declaration = if (loc.source_site != null) blk: {
        const owner = (try ctx.get(ResolveItem, loc.owner.?)).* orelse return null;
        break :blk owner.declaration;
    } else resolved.declaration;
    const type_interner: TypeInterner(@TypeOf(ctx)) = .{
        .ctx = ctx,
        .file_id = resolved.file_id,
        .instance = instance,
        .specialization = if (instance.specialization != null) .{
            .ast = &parsed,
            .source = source,
            .declaration = specialization_declaration,
            .arguments = specialization,
        } else null,
    };
    const result = semantic.buildUnresolvedBody(&parsed, source, resolved.declaration, loc.kind, parameters, type_interner, ctx.allocator()) catch |err| switch (err) {
        error.Unavailable => return null,
        else => return err,
    };
    var unresolved = switch (result) {
        .success => |unresolved_value| unresolved_value,
        .unsupported => |issue| {
            try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
            return null;
        },
    };
    defer unresolved.deinit(ctx.allocator());
    return if (publish_instruction_spans)
        typing.resolveAndTypeBodyForComptime(
            ctx,
            BuildModuleScope,
            FunctionInstanceSignature,
            instance.item,
            resolved.file_id,
            parameters,
            return_type,
            is_fallible,
            type_interner,
            unresolved,
        )
    else
        typing.resolveAndTypeBody(
            ctx,
            BuildModuleScope,
            FunctionInstanceSignature,
            instance.item,
            resolved.file_id,
            parameters,
            return_type,
            is_fallible,
            type_interner,
            unresolved,
        );
}

pub const SelectEntry = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemId;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
        // Successful discovery contributes exactly one synthetic entry. Keep
        // this selection as a query so unrelated index changes do not invalidate
        // entry consumers when the selected identity stays equal.
        for (index.ids()) |item_id| {
            const loc = try ctx.lookupInterned(ItemLocations, item_id);
            if (loc.kind == .top_level_entry) return item_id;
        }
        unreachable;
    }
};

pub const CompileFunction = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.CompiledFunction;

    pub fn run(ctx: anytype, instance_id: Input) anyerror!Output {
        const body = if (instance_id.specialization == null)
            (try ctx.get(AnalyzeFunctionBody, instance_id.item)).* orelse return null
        else
            (try ctx.get(AnalyzeFunctionInstance, instance_id)).* orelse return null;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx };
        return try codegen.compileFunction(&body, type_interner, ctx.allocator());
    }
};

pub const CollectReachableInstances = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ReachableInstances;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const entry_id = (try ctx.get(SelectEntry, file_id)).* orelse return null;
        const entry: structures.InstanceId = .{ .item = entry_id };

        var instances: std.ArrayList(structures.InstanceId) = .empty;
        defer instances.deinit(ctx.allocator());
        var seen = std.AutoHashMap(structures.InstanceId, void).init(ctx.allocator());
        defer seen.deinit();

        try instances.append(ctx.allocator(), entry);
        try seen.put(entry, {});
        var next: usize = 0;
        while (next < instances.items.len) : (next += 1) {
            const instance = instances.items[next];
            const artifact = (try ctx.get(CompileFunction, instance)).* orelse return null;
            for (artifact.referenced_instances) |referenced| {
                const result = try seen.getOrPut(referenced);
                if (!result.found_existing) try instances.append(ctx.allocator(), referenced);
            }
        }

        return .{ .instances = try instances.toOwnedSlice(ctx.allocator()) };
    }
};

pub const BuildExecutable = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.Executable;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const reachable = (try ctx.get(CollectReachableInstances, file_id)).* orelse return null;
        std.debug.assert(reachable.instances.len != 0);

        var functions: std.ArrayList(codegen.ReachableFunction) = .empty;
        defer functions.deinit(ctx.allocator());
        try functions.ensureTotalCapacity(ctx.allocator(), reachable.instances.len);
        for (reachable.instances) |instance| {
            const artifact = (try ctx.get(CompileFunction, instance)).* orelse unreachable;
            functions.appendAssumeCapacity(.{ .instance = instance, .artifact = artifact });
        }

        const entry = reachable.instances[0];
        return try codegen.buildExecutable(entry, functions.items, ctx.allocator());
    }
};
