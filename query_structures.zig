const std = @import("std");
const structures = @import("structures.zig");
const ast = @import("ast_new.zig");
const codegen = @import("codegen_new.zig");
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

pub const DiscoverItems = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemTree;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const parsed = try ctx.get(ParseFile, file_id);
        const ast_value = parsed.* orelse return null;
        const source = (try ctx.input(SourceText, file_id)).*;
        var tree = try semantic.discoverItems(ctx.allocator(), &ast_value, source);
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
        std.hash.autoHash(&hasher, value.file_id);
        std.hash.autoHash(&hasher, value.owner);
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
            .structure => |item_id| std.hash.autoHash(&hasher, item_id),
        }
        return hasher.final();
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .variant => |variant| std.mem.eql(structures.TypeId, variant.members, b.variant.members),
            .callable => |callable| structures.CallableType.eql(callable, b.callable),
            .structure => |item_id| item_id == b.structure,
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
            .structure => |item_id| .{ .structure = item_id },
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
    return .fromInterned(try ctx.intern(Types, .{ .structure = item_id }));
}

pub fn TypeInterner(comptime Context: type) type {
    return struct {
        ctx: Context,
        file_id: ?structures.FileId = null,

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
            const item_id = switch (data.*) {
                .structure => |item| item,
                .variant, .callable => return null,
            };
            return (try self.ctx.lookupInterned(ItemLocations, item_id)).name;
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            const item_id = switch (data.*) {
                .structure => |item| item,
                .variant, .callable => return null,
            };
            return (try self.ctx.get(StructDefinition, item_id)).* orelse return error.Unavailable;
        }

        pub fn structLayout(self: @This(), type_id: structures.TypeId) !?structures.StructLayout {
            return (try self.ctx.get(StructLayout, type_id)).*;
        }

        pub fn ownershipCapabilities(self: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
            return (try self.ctx.get(OwnershipCapabilities, type_id)).*;
        }

        pub fn ownedFunction(self: @This(), owner: structures.ItemId, name: []const u8) !?structures.ItemId {
            const loc = try self.ctx.lookupInterned(ItemLocations, owner);
            const index = (try self.ctx.get(IndexItems, loc.file_id)).* orelse return error.Unavailable;
            for (index.ids()) |item_id| {
                const item_loc = try self.ctx.lookupInterned(ItemLocations, item_id);
                if (item_loc.owner == owner and item_loc.kind == .function and std.mem.eql(u8, item_loc.name, name)) return item_id;
            }
            return null;
        }

        pub fn functionSignature(self: @This(), item_id: structures.ItemId) !?structures.FunctionSignature {
            return (try self.ctx.get(FunctionSignature, item_id)).*;
        }

        pub fn structType(self: @This(), item_id: structures.ItemId) !structures.TypeId {
            return internStructType(self.ctx, item_id);
        }

        pub fn variantLayout(self: @This(), type_id: structures.TypeId) !structures.VariantLayout {
            return (try self.ctx.get(VariantLayout, type_id)).*;
        }

        pub fn layout(self: @This(), type_id: structures.TypeId) !structures.TypeLayout {
            return (try self.ctx.get(TypeLayout, type_id)).*;
        }

        pub fn resolveStatic(self: @This(), name: []const u8) !?structures.CompileTimeValue {
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
            const signature = (try self.ctx.get(FunctionSignature, item_id)).* orelse return error.Unavailable;
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
        const item_id = switch (data.*) {
            .structure => |item| item,
            .variant, .callable => return null,
        };
        const definition = (try ctx.get(StructDefinition, item_id)).* orelse return null;

        var active: std.ArrayList(structures.ItemId) = .empty;
        defer active.deinit(ctx.allocator());
        var completed: std.ArrayList(structures.ItemId) = .empty;
        defer completed.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, item_id, &active, &completed)) return null;

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
        if (type_id.isPrimitive()) return trivialOwnership();

        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
        return switch (data.*) {
            .callable => trivialOwnership(),
            .variant => |variant| variantOwnership(ctx, variant.members),
            .structure => |item_id| structOwnership(ctx, type_id, item_id),
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

    fn structOwnership(ctx: anytype, type_id: structures.TypeId, item_id: structures.ItemId) !?structures.OwnershipCapabilities {
        if ((try ctx.get(StructLayout, type_id)).* == null) return null;
        const definition = (try ctx.get(StructDefinition, item_id)).* orelse return null;

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
                try emitIncompatibleOwnershipProperty(ctx, item_id, property.span);
                return null;
            }
            break :blk property.capability;
        } else if (can_move) .fieldwise else .none;
        const copy: structures.CopyCapability = if (definition.ownership.copy) |property| blk: {
            if ((property.capability == .trivial and !copies_trivially) or
                (property.capability == .fieldwise and !can_copy))
            {
                try emitIncompatibleOwnershipProperty(ctx, item_id, property.span);
                return null;
            }
            break :blk property.capability;
        } else .none;
        const drop: structures.DropCapability = if (definition.ownership.drop) |property| blk: {
            if (property.capability == .trivial and !drops_trivially) {
                try emitIncompatibleOwnershipProperty(ctx, item_id, property.span);
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

    fn emitIncompatibleOwnershipProperty(ctx: anytype, item_id: structures.ItemId, span: structures.SourceSpan) !void {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        try ctx.emit(structures.Diagnostic, .{
            .file_id = loc.file_id,
            .span = span,
            .kind = .struct_ownership_property_incompatible_with_fields,
        });
    }
};

fn validateStructContainment(
    ctx: anytype,
    item_id: structures.ItemId,
    active: *std.ArrayList(structures.ItemId),
    completed: *std.ArrayList(structures.ItemId),
) !bool {
    if (std.mem.indexOfScalar(structures.ItemId, completed.items, item_id) != null) return true;
    try active.append(ctx.allocator(), item_id);
    defer _ = active.pop();

    const definition = (try ctx.get(StructDefinition, item_id)).* orelse return false;
    const loc = try ctx.lookupInterned(ItemLocations, item_id);
    for (definition.fields) |field| {
        if (!try validateContainedType(ctx, field.type_id, loc.file_id, field.span, active, completed)) return false;
    }
    try completed.append(ctx.allocator(), item_id);
    return true;
}

fn validateContainedType(
    ctx: anytype,
    type_id: structures.TypeId,
    file_id: structures.FileId,
    span: structures.SourceSpan,
    active: *std.ArrayList(structures.ItemId),
    completed: *std.ArrayList(structures.ItemId),
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
        .structure => |contained_item| blk: {
            if (std.mem.indexOfScalar(structures.ItemId, active.items, contained_item) != null) {
                try ctx.emit(structures.Diagnostic, .{
                    .file_id = file_id,
                    .span = span,
                    .kind = .recursive_struct_containment,
                });
                break :blk false;
            }
            break :blk validateStructContainment(ctx, contained_item, active, completed);
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

pub const BuildModuleScope = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const index = (try ctx.get(IndexItems, file_id)).* orelse return null;

        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        defer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        for (index.ids()) |item_id| {
            const loc = try ctx.lookupInterned(ItemLocations, item_id);
            if (loc.kind == .top_level_entry or loc.owner != null) continue;
            std.debug.assert(loc.file_id == file_id);

            const name = try ctx.allocator().dupe(u8, loc.name);
            errdefer ctx.allocator().free(name);
            try entries.append(ctx.allocator(), .{ .name = name, .item_id = item_id, .kind = loc.kind });
        }
        std.mem.sort(structures.ModuleScope.Entry, entries.items, {}, struct {
            fn lessThan(_: void, left: structures.ModuleScope.Entry, right: structures.ModuleScope.Entry) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }
};

pub const ResolveItem = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.ResolvedItem;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        const index = (try ctx.get(IndexItems, loc.file_id)).* orelse return null;
        const declaration = index.resolve(item_id) orelse return null;
        return .{ .file_id = loc.file_id, .declaration = declaration };
    }
};

pub const FunctionSignature = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .function) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id };
        const result = semantic.analyzeFunctionSignature(&parsed, source, resolved.declaration, type_interner, ctx.allocator()) catch |err| switch (err) {
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
    pub const Output = ?structures.CompileTimeValue;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .static and loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        if (loc.kind == .structure) return .{ .type = try internStructType(ctx, item_id) };
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id };
        const result = semantic.analyzeStaticDeclaration(&parsed, source, resolved.declaration, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |value| value,
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const StructDefinition = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id };
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

pub const AnalyzeFunctionBody = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind == .static or loc.kind == .structure) return null;
        var parameters: []const structures.CallableParameter = &.{};
        var return_type: structures.TypeId = .unit;
        var is_fallible = false;
        if (loc.kind == .function) {
            const signature = (try ctx.get(FunctionSignature, item_id)).* orelse return null;
            parameters = signature.parameters;
            return_type = signature.return_type;
            is_fallible = signature.is_fallible;
        }
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id };
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
        return typing.resolveAndTypeBody(ctx, BuildModuleScope, FunctionSignature, item_id, resolved.file_id, parameters, return_type, is_fallible, type_interner, unresolved);
    }
};

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
        const body = (try ctx.get(AnalyzeFunctionBody, instance_id.item)).* orelse return null;
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
