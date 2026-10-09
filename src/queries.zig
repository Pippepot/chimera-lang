const std = @import("std");
const standard_library = @import("standard_library");
const structures = @import("structures.zig");
const value_operations = @import("value.zig");
const ast = @import("frontend/parser.zig");
const codegen = @import("backend/codegen.zig");
const comptime_interpreter = @import("frontend/comptime_interpreter.zig");
const semantic = @import("frontend/semantic.zig");
const typing = @import("frontend/typing.zig");

pub const SourceText = struct {
    pub const Key = structures.FileId;
    pub const Value = []const u8;

    pub fn cloneValue(gpa: std.mem.Allocator, value: Value) !Value {
        return gpa.dupe(u8, value);
    }

    pub const eqlValue = value_operations.Owned(Value).eql;

    pub const deinitValue = value_operations.Owned(Value).destroy;
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

    pub const eqlValue = value_operations.Owned(Value).eql;

    pub const deinitValue = value_operations.Owned(Value).destroy;
};

pub const ModuleCatalog = struct {
    pub const Key = void;
    pub const Value = []const structures.ModuleId;

    pub fn cloneValue(gpa: std.mem.Allocator, value: Value) !Value {
        return gpa.dupe(structures.ModuleId, value);
    }

    pub const eqlValue = value_operations.Owned(Value).eql;

    pub const deinitValue = value_operations.Owned(Value).destroy;
};

/// Identifies the compiler-owned prelude independently of the user module
/// catalog, so user module additions cannot invalidate its resolution.
pub const StandardPreludeModule = struct {
    pub const Key = void;
    pub const Value = structures.ModuleId;
};

pub const StandardFile = struct {
    pub const Key = u32;
    pub const Value = structures.FileId;
};

pub fn standardFileKey(comptime path: []const u8) StandardFile.Key {
    return comptime blk: {
        for (standard_library.paths, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, path)) break :blk @intCast(index);
        }
        @compileError("unknown standard source: " ++ path);
    };
}

fn standardFile(ctx: anytype, file: standard_library.File) !?structures.FileId {
    const registered = ctx.input(StandardFile, @backingInt(file)) catch |err| switch (err) {
        error.InputNotFound => return null,
        else => return err,
    };
    return registered.*;
}

pub const ModulePaths = struct {
    pub const Value = structures.ModulePath;
    pub const Id = structures.ModuleId;

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        return .{ .path = try gpa.dupe(u8, value.path) };
    }

    pub const deinit = value_operations.Owned(Value).destroy;
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
            if (item.loc.kind == .top_level_entry or item.parent != null or item.qualified_owner != null) continue;
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

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        var cloned = value;
        cloned.name = try gpa.dupe(u8, value.name);
        return cloned;
    }

    pub const deinit = value_operations.Owned(Value).destroy;
};

pub const Types = struct {
    pub const Value = structures.TypeData;
    pub const Id = structures.InternedTypeId;

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        switch (value) {
            .variant => |variant| {
                std.debug.assert(variant.members.len >= 2);
                for (variant.members, 0..) |member, index| {
                    if (index > 0) std.debug.assert(@backingInt(variant.members[index - 1]) < @backingInt(member));
                }
                return .{ .variant = .{ .members = try gpa.dupe(structures.TypeId, variant.members) } };
            },
            .callable => |callable| return .{ .callable = try callable.clone(gpa) },
            .structure => |identity| return .{ .structure = identity },
            .array => |array| return .{ .array = array },
        }
    }

    pub const deinit = value_operations.Owned(Value).destroy;
};

pub const CompileTimeValues = struct {
    pub const Value = structures.CompileTimeValue;
    pub const Id = structures.CompileTimeValueId;

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(_: std.mem.Allocator, value: Value) !Value {
        return value;
    }

    pub const deinit = value_operations.Owned(Value).destroy;
};

pub const CompileTimeValueTuples = struct {
    pub const Value = structures.CompileTimeValueTuple;
    pub const Id = structures.CompileTimeValueTupleId;

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        return .{ .values = try gpa.dupe(structures.CompileTimeValueId, value.values) };
    }

    pub const deinit = value_operations.Owned(Value).destroy;
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
            return @backingInt(left) < @backingInt(right);
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
    const location = try ctx.lookupInterned(ItemLocations, identity.owner.item);
    if (location.owner == null and std.mem.eql(u8, location.name, "Array")) {
        const factory = try standardFunction(ctx, .array, "Array");
        if (factory == identity.owner.item) return internStandardArrayType(ctx, identity);
    }
    return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
}

fn standardFunction(ctx: anytype, file: standard_library.File, name: []const u8) !?structures.ItemId {
    const registered = (try standardFile(ctx, file)) orelse return null;
    const module = try ctx.intern(ModulePaths, .{ .path = file.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
    const item = declarations.resolveFunction(name) orelse return null;
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    return if (resolved.file_id == registered) item else null;
}

fn internStandardArrayType(ctx: anytype, identity: structures.GeneratedStructIdentity) !structures.TypeId {
    const resolved = (try ctx.get(ResolveItem, identity.owner.item)).* orelse return error.Unavailable;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse return error.Unavailable;
    if (identity.node_offset != site)
        return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
    const tuple = identity.owner.specialization orelse return error.Unavailable;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != 2) return error.Unavailable;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const count = (try ctx.lookupInterned(CompileTimeValues, arguments[1])).*;
    const span = nodeSpan(&parsed, @fromBackingInt(@intCast(resolved.declaration)));
    if (element != .type or count != .runtime or count.runtime.type_id != .int or count.runtime.value != .int) {
        try rejectImport(ctx, .{ .file_id = resolved.file_id, .span = span }, .static_argument_type_mismatch);
        return error.Unavailable;
    }
    if (count.runtime.value.int < 0) {
        try rejectImport(ctx, .{ .file_id = resolved.file_id, .span = span }, .static_argument_not_supported);
        return error.Unavailable;
    }
    if (!try validArrayElementType(ctx, element.type)) {
        try rejectImport(ctx, .{ .file_id = resolved.file_id, .span = span }, .struct_field_type_not_supported);
        return error.Unavailable;
    }
    return .fromInterned(try ctx.intern(Types, .{ .array = .{
        .element_type = element.type,
        .length = @intCast(count.runtime.value.int),
    } }));
}

fn validArrayElementType(ctx: anytype, type_id: structures.TypeId) anyerror!bool {
    if (type_id.isPrimitive()) return type_id != .type;
    const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
    switch (data.*) {
        .structure, .callable => return true,
        .array => |array| return validArrayElementType(ctx, array.element_type),
        .variant => |variant| {
            for (variant.members) |member| {
                if (!try validArrayElementType(ctx, member)) return false;
            }
            return true;
        },
    }
}

const TypeNamespaceAssociation = struct {
    query_key: StructNamespace.Input,
    specialization: ?structures.CompileTimeValueTupleId = null,
};

fn arrayTypeNamespace(ctx: anytype, array: structures.ArrayType) !?TypeNamespaceAssociation {
    const factory = (try standardFunction(ctx, .array, "Array")) orelse return null;
    const resolved = (try ctx.get(ResolveItem, factory)).* orelse return error.Unavailable;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse return error.Unavailable;
    const element = try ctx.intern(CompileTimeValues, .{ .type = array.element_type });
    const count = try ctx.intern(CompileTimeValues, .{ .runtime = .{
        .type_id = .int,
        .value = .{ .int = std.math.cast(i32, array.length) orelse unreachable },
    } });
    return .{
        .query_key = .{ .generated = .{
            .owner = .{ .item = factory },
            .node_offset = site,
        } },
        .specialization = try ctx.intern(CompileTimeValueTuples, .{ .values = &.{ element, count } }),
    };
}

pub fn TypeFacts(comptime Context: type) type {
    return struct {
        ctx: Context,

        pub fn structName(self: @This(), type_id: structures.TypeId) !?[]const u8 {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
            const identity = switch (data.*) {
                .structure => |structure| structure,
                .variant, .callable => return null,
                .array => return "Array",
            };
            return switch (identity) {
                .declared => |item_id| (try self.ctx.lookupInterned(ItemLocations, item_id)).name,
                .generated => |generated| blk: {
                    const resolved = (try self.ctx.get(ResolveItem, generated.owner.item)).* orelse return error.Unavailable;
                    const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                    if (!semantic.isDirectlyReturnedStructSite(&parsed, resolved.declaration, generated.node_offset)) break :blk "anonymous struct";
                    break :blk (try self.ctx.lookupInterned(ItemLocations, generated.owner.item)).name;
                },
            };
        }

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

        pub fn arrayType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            return lookupArrayType(self.ctx, type_id);
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            return switch (data.*) {
                .structure => |identity| getStructDefinition(self.ctx, identity),
                .variant, .callable, .array => null,
            };
        }

        pub fn borrowElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return borrowElementType(self.ctx, type_id);
        }

        pub fn borrowAccess(self: @This(), type_id: structures.TypeId) !?BorrowAccessType {
            return borrowAccessType(self.ctx, type_id);
        }

        pub fn allocationElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return allocationElementType(self.ctx, type_id);
        }

        pub fn boxElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return boxElementType(self.ctx, type_id);
        }

        pub fn ownershipCapabilities(self: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
            return (try self.ctx.get(OwnershipCapabilities, type_id)).*;
        }

        pub fn isRuntimeCapable(self: @This(), type_id: structures.TypeId) anyerror!bool {
            if (type_id.isPrimitive()) return type_id != .type and type_id != .int_literal;
            if (try standardMemoryInstance(self.ctx, type_id, .collection_literal) != null) return false;
            _ = (try self.ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (try self.arrayType(type_id)) |array| return self.isRuntimeCapable(array.element_type);
            if (try self.structDefinition(type_id)) |definition| {
                if (definition.is_static) return false;
                for (definition.fields) |field| if (!try self.isRuntimeCapable(field.type_id)) return false;
            } else if (try self.variantMembers(type_id)) |members| {
                for (members) |member| if (!try self.isRuntimeCapable(member)) return false;
            }
            return true;
        }

        pub fn argumentPassing(self: @This(), type_id: structures.TypeId) anyerror!structures.ArgumentPassing {
            const capabilities = (try self.ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (!capabilities.isDirectlyMovable()) return .indirect;
            if (try self.arrayType(type_id) != null) return .indirect;
            if (try self.structDefinition(type_id)) |definition| {
                for (definition.fields) |field| if (try self.argumentPassing(field.type_id) == .indirect) return .indirect;
            } else if (try self.variantMembers(type_id)) |members| {
                for (members) |member| if (try self.argumentPassing(member) == .indirect) return .indirect;
            }
            return .direct;
        }
    };
}

pub fn HostTypes(comptime Context: type) type {
    return struct {
        ctx: Context,

        pub fn facts(self: @This()) TypeFacts(Context) {
            return .{ .ctx = self.ctx };
        }

        pub fn structLayout(self: @This(), type_id: structures.TypeId) !?structures.StructLayout {
            return (try self.ctx.get(StructLayout, type_id)).*;
        }

        pub fn variantLayout(self: @This(), type_id: structures.TypeId) !structures.VariantLayout {
            return (try self.ctx.get(VariantLayout, type_id)).*;
        }

        pub fn layout(self: @This(), type_id: structures.TypeId) !structures.TypeLayout {
            return (try self.ctx.get(HostTypeLayout, type_id)).*;
        }
    };
}

pub fn AnalysisContext(comptime Context: type) type {
    return struct {
        ctx: Context,
        file_id: ?structures.FileId = null,
        instance: ?structures.InstanceId = null,
        prior_static_arguments: ?[]const structures.CompileTimeValueId = null,
        public_annotation: bool = false,

        pub fn facts(self: @This()) TypeFacts(Context) {
            return .{ .ctx = self.ctx };
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            switch (data.*) {
                .structure => |identity| return (try getStructDefinition(self.ctx, identity)) orelse return error.Unavailable,
                .variant, .callable, .array => return null,
            }
        }

        pub fn arrayType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            return self.facts().arrayType(type_id);
        }

        pub fn collectionLiteralType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .collection_literal)) orelse return null;
            const count = (try self.ctx.lookupInterned(CompileTimeValues, instance.arguments[1])).*;
            if (count != .runtime or count.runtime.type_id != .int or count.runtime.value != .int or count.runtime.value.int < 0) return error.Unavailable;
            return .{ .element_type = instance.element_type, .length = @intCast(count.runtime.value.int) };
        }

        pub fn internCollectionLiteralType(self: @This(), shape: structures.ArrayType) !structures.TypeId {
            const factory = (try standardFunction(self.ctx, .array, "collection_literal")) orelse return error.Unavailable;
            const element = try self.internCompileTimeValue(.{ .type = shape.element_type });
            const count = try self.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(shape.length) } } });
            return self.specializedStructType(try self.internFunctionInstance(factory, &.{ element, count }));
        }

        pub fn internArrayType(self: @This(), array: structures.ArrayType) !structures.TypeId {
            return .fromInterned(try self.ctx.intern(Types, .{ .array = array }));
        }

        pub fn canAccessPrivateFields(self: @This(), type_id: structures.TypeId) !bool {
            const identity = (try self.structIdentity(type_id)) orelse return false;
            const location = try self.ctx.lookupInterned(ItemLocations, structOwnerItem(identity));
            const module = switch (location.origin) {
                .module => |module| module,
                .entry => |file_id| (try self.ctx.input(FileModule, file_id)).*,
            };
            const file_id = self.file_id orelse unreachable;
            return module == (try self.ctx.input(FileModule, file_id)).*;
        }

        pub fn structIdentity(self: @This(), type_id: structures.TypeId) !?structures.StructIdentity {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            return switch (data.*) {
                .structure => |identity| identity,
                .variant, .callable, .array => null,
            };
        }

        pub fn typeNamespace(self: @This(), type_id: structures.TypeId) !?TypeNamespaceAssociation {
            if (type_id == .int or type_id == .bool) {
                const name: []const u8 = if (type_id == .int) "IntOperations" else "BoolOperations";
                const registered = (try standardFile(self.ctx, .prelude)) orelse return null;
                const module = (try self.ctx.input(FileModule, registered)).*;
                const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
                const owner = declarations.resolve(name) orelse return error.Unavailable;
                const resolved = (try self.ctx.get(ResolveItem, owner)).* orelse return error.Unavailable;
                if (resolved.file_id != registered) return error.Unavailable;
                return .{ .query_key = .{ .declared = owner } };
            }
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            switch (data.*) {
                .structure => |identity| {
                    switch (identity) {
                        .declared => return .{ .query_key = identity },
                        .generated => |generated| return .{
                            .query_key = .{ .generated = .{
                                .owner = .{ .item = generated.owner.item },
                                .node_offset = generated.node_offset,
                            } },
                            .specialization = generated.owner.specialization,
                        },
                    }
                },
                .array => |array| return (try arrayTypeNamespace(self.ctx, array)) orelse return error.Unavailable,
                .variant, .callable => return null,
            }
        }

        pub fn structNamespaceMember(self: @This(), type_id: structures.TypeId, name: []const u8, span: structures.SourceSpan) !?structures.InstanceId {
            if (std.meta.stringToEnum(structures.OwnershipMember, name)) |operation|
                return self.ownershipMember(type_id, operation);
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const namespace = (try self.ctx.get(StructNamespace, association.query_key)).* orelse return error.Unavailable;
            return .{
                .item = (try self.visibleStructMember(namespace, name, span)) orelse return null,
                .specialization = association.specialization,
            };
        }

        pub fn ownershipMember(self: @This(), type_id: structures.TypeId, operation: structures.OwnershipMember) !?structures.InstanceId {
            const capabilities = (try self.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (try self.typeNamespace(type_id)) |association| {
                if ((try self.ctx.get(StructNamespace, association.query_key)).* == null) return error.Unavailable;
            }
            switch (operation) {
                .copy => if (capabilities.copy == .none) return null,
                .move => if (capabilities.move == .none) return null,
            }
            const name = switch (operation) {
                .copy => "copy_value",
                .move => "move_value",
            };
            const registered = (try standardFile(self.ctx, .ownership)) orelse return error.Unavailable;
            const module = try self.ctx.intern(ModulePaths, .{ .path = standard_library.File.ownership.modulePath() });
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
            const item = declarations.resolveFunction(name) orelse return error.Unavailable;
            const resolved = (try self.ctx.get(ResolveItem, item)).* orelse return error.Unavailable;
            if (resolved.file_id != registered) return error.Unavailable;
            const argument = try self.ctx.intern(CompileTimeValues, .{ .type = type_id });
            return try self.specializeFunction(.{ .item = item }, &.{argument});
        }

        fn genericStructNamespaceMember(self: @This(), factory: structures.InstanceId, name: []const u8, span: ?structures.SourceSpan) !?structures.InstanceId {
            const resolved = (try self.ctx.get(ResolveItem, factory.item)).* orelse return null;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return null;
            const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse return null;
            const namespace = (try self.ctx.get(StructNamespace, .{ .generated = .{
                .owner = factory,
                .node_offset = site,
            } })).* orelse return error.Unavailable;
            return .{ .item = (try self.visibleStructMember(namespace, name, span)) orelse return null, .specialization = factory.specialization };
        }

        fn visibleStructMember(self: @This(), namespace: structures.ModuleScope, name: []const u8, span: ?structures.SourceSpan) !?structures.ItemId {
            const entry = namespace.resolveEntry(name) orelse return null;
            if (span) |access_span| {
                const member = try self.ctx.lookupInterned(ItemLocations, entry.item_id);
                const owner_module = switch (member.origin) {
                    .module => |module| module,
                    .entry => unreachable,
                };
                if (!entry.is_public and (try self.ctx.input(FileModule, self.file_id.?)).* != owner_module) {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = access_span }, .private_access);
                    return error.Unavailable;
                }
            }
            return entry.item_id;
        }

        pub fn staticCallArgument(self: @This(), node: structures.Node.Index, is_meta_type: bool, expected_type: ?structures.TypeId) !?structures.CompileTimeValueId {
            if (!is_meta_type) return self.executeComptimeWithType(node, expected_type);
            const file_id = self.file_id orelse unreachable;
            const parsed = (try self.ctx.get(ParseFile, file_id)).* orelse return null;
            const source = (try self.ctx.input(SourceText, file_id)).*;
            const result = try semantic.analyzeStaticTypeArgument(&parsed, source, node, self, self.ctx.allocator());
            return switch (result) {
                .success => |value| try self.internCompileTimeValue(value),
                .unsupported => |issue| blk: {
                    try typing.emitSemanticIssue(self.ctx, file_id, issue);
                    break :blk null;
                },
            };
        }

        const DeclarationContext = struct {
            resolved: structures.ResolvedItem,
            parsed: structures.Ast,
            source: []const u8,
            analysis: AnalysisContext(Context),
        };

        fn declarationContext(self: @This(), instance: structures.InstanceId, prior: []const structures.CompileTimeValueId) !DeclarationContext {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            return .{
                .resolved = resolved,
                .parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable,
                .source = (try self.ctx.input(SourceText, resolved.file_id)).*,
                .analysis = .{ .ctx = self.ctx, .file_id = resolved.file_id, .instance = instance, .prior_static_arguments = prior },
            };
        }

        pub fn staticParameterType(self: @This(), instance: structures.InstanceId, parameter_index: usize, prior: []const structures.CompileTimeValueId) !structures.TypeId {
            const declaration = try self.declarationContext(instance, prior);
            return switch (try semantic.analyzeStaticParameterType(&declaration.parsed, declaration.source, declaration.resolved.declaration, parameter_index, declaration.analysis, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
        }

        pub fn independentParameterType(self: @This(), instance: structures.InstanceId, runtime_index: usize) !?structures.TypeId {
            if (try self.needsInheritedInference(instance)) return null;
            const declaration = try self.declarationContext(instance, &.{});
            return switch (try semantic.analyzeIndependentParameterType(&declaration.parsed, declaration.source, declaration.resolved.declaration, runtime_index, declaration.analysis, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
        }

        pub fn inferStaticArguments(self: @This(), instance: structures.InstanceId, argument_types: []const structures.TypeId) !semantic.StaticInference {
            const declaration = try self.declarationContext(instance, &.{});
            const inherited_from = if (try self.needsInheritedInference(instance)) blk: {
                const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
                const owner_item = location.owner orelse unreachable;
                const owner = (try self.ctx.get(ResolveItem, owner_item)).* orelse return error.Unavailable;
                const owner_arity = (try self.ctx.get(SpecializationArity, owner_item)).* orelse return error.Unavailable;
                const provided = if (instance.specialization) |tuple|
                    (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len
                else
                    0;
                if (provided < owner_arity.inherited or owner.file_id != declaration.resolved.file_id or
                    semantic.parameterizedStructSite(&declaration.parsed, owner.declaration) == null) return .missing;
                break :blk owner.declaration;
            } else null;
            return semantic.inferStaticArguments(&declaration.parsed, declaration.source, declaration.resolved.declaration, argument_types, declaration.analysis, self.ctx.allocator(), inherited_from);
        }

        pub fn inferStructArguments(self: @This(), instance: structures.InstanceId, fields: []const semantic.UnresolvedBody.StructFieldValue, field_types: []const structures.TypeId) !semantic.StaticInference {
            const declaration = try self.declarationContext(instance, &.{});
            return semantic.inferStructArguments(&declaration.parsed, declaration.source, declaration.resolved.declaration, fields, field_types, declaration.analysis, self.ctx.allocator());
        }

        pub fn currentModule(self: @This()) !structures.ModuleId {
            return (try self.ctx.input(FileModule, self.file_id.?)).*;
        }

        fn converterAnnotationReference(self: @This(), annotation: structures.Node.Index) !?structures.NameReference {
            const declaration = try self.declarationContext(self.instance.?, &.{});
            const node = declaration.parsed.nodes[annotation.index()];
            const root = if (node.tag == .call) node.data.node_node.a else annotation;
            const root_node = declaration.parsed.nodes[root.index()];
            if (root_node.tag != .identifier and root_node.tag != .type and root_node.tag != .field_access) return null;
            if (root_node.tag != .field_access) {
                const span = nodeSpan(&declaration.parsed, root);
                const name = declaration.source[span.start..span.end];
                if (std.meta.stringToEnum(structures.TypeId, name)) |primitive|
                    return .{ .constant = try self.ctx.intern(CompileTimeValues, .{ .type = primitive }) };
            }
            return semantic.resolveNamedExpression(&declaration.parsed, declaration.source, root, declaration.analysis);
        }

        pub fn converterAnnotationOwner(self: @This(), annotation: structures.Node.Index) !?structures.ModuleId {
            const reference = (try self.converterAnnotationReference(annotation)) orelse return null;
            if (reference == .declaration) {
                if (try self.isGenericStruct(reference.declaration.item)) {
                    const location = try self.ctx.lookupInterned(ItemLocations, reference.declaration.item);
                    return location.origin.module;
                }
                const constant = (try self.staticItem(reference.declaration)) orelse return null;
                const value = try self.lookupCompileTimeValue(constant);
                return if (value == .type) self.conversionOwner(value.type) else null;
            }
            if (reference == .constant) {
                const value = try self.lookupCompileTimeValue(reference.constant);
                return if (value == .type) self.conversionOwner(value.type) else null;
            }
            return null;
        }

        pub fn isCollectionConverterAnnotation(self: @This(), annotation: structures.Node.Index) !bool {
            const reference = (try self.converterAnnotationReference(annotation)) orelse return false;
            if (reference == .declaration and try self.isGenericStruct(reference.declaration.item))
                return reference.declaration.item == (try standardFunction(self.ctx, .array, "collection_literal"));
            const constant = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (try self.staticItem(instance)) orelse return false,
                .namespace => return false,
            };
            const value = try self.lookupCompileTimeValue(constant);
            return value == .type and try self.collectionLiteralType(value.type) != null;
        }

        pub fn isStaticConverterAnnotation(self: @This(), annotation: structures.Node.Index) !bool {
            const context = try self.declarationContext(self.instance.?, &.{});
            if (context.parsed.nodes[annotation.index()].tag == .call and
                !semantic.converterAnnotationDependsOnStaticParameters(&context.parsed, context.source, context.resolved.declaration, annotation))
            {
                const resolved_type = switch (try semantic.analyzeStaticTypeArgument(&context.parsed, context.source, annotation, context.analysis, self.ctx.allocator())) {
                    .success => |value| value.type,
                    .unsupported => return false,
                };
                return !try self.facts().isRuntimeCapable(resolved_type);
            }
            const reference = (try self.converterAnnotationReference(annotation)) orelse return false;
            if (reference == .declaration and try self.isGenericStruct(reference.declaration.item)) {
                const declaration = try self.declarationContext(reference.declaration, &.{});
                const binding = declaration.parsed.nodes[declaration.resolved.declaration];
                const function = declaration.parsed.nodes[binding.data.node_node.b.index()];
                const body = declaration.parsed.nodes[function.data.node_node.b.index()];
                return declaration.parsed.nodes[body.data.node.index()].is_static_struct;
            }
            const constant = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (try self.staticItem(instance)) orelse return false,
                .namespace => return false,
            };
            const value = try self.lookupCompileTimeValue(constant);
            return value == .type and !try self.facts().isRuntimeCapable(value.type);
        }

        fn conversionOwner(self: @This(), type_id: structures.TypeId) !?structures.ModuleId {
            if (type_id.isPrimitive()) {
                const file = (try standardFile(self.ctx, .prelude)) orelse return null;
                return (try self.ctx.input(FileModule, file)).*;
            }
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const location = try self.ctx.lookupInterned(ItemLocations, structOwnerItem(association.query_key));
            return switch (location.origin) {
                .module => |module| module,
                .entry => |file| (try self.ctx.input(FileModule, file)).*,
            };
        }

        fn visibleConverters(self: @This(), source_owner: ?structures.ModuleId, target_type: structures.TypeId) ![]structures.ItemId {
            var items: std.ArrayList(structures.ItemId) = .empty;
            errdefer items.deinit(self.ctx.allocator());
            const current_module = (try self.ctx.input(FileModule, self.file_id.?)).*;
            const owners = [_]?structures.ModuleId{ source_owner, try self.conversionOwner(target_type) };
            for (owners, 0..) |maybe_owner, owner_index| {
                const owner = maybe_owner orelse continue;
                if (owner_index != 0 and owners[0] == owner) continue;
                const declarations = (try self.ctx.get(ModuleDeclarations, owner)).* orelse return error.Unavailable;
                for (declarations.entries) |entry| {
                    if (entry.kind != .function or (!entry.is_public and owner != current_module)) continue;
                    const resolved = (try self.ctx.get(ResolveItem, entry.item_id)).* orelse return error.Unavailable;
                    const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                    if (parsed.nodes[parsed.nodes[resolved.declaration].data.node_node.b.index()].is_converter)
                        try items.append(self.ctx.allocator(), entry.item_id);
                }
            }
            return items.toOwnedSlice(self.ctx.allocator());
        }

        fn probeConverterSignature(self: @This(), item: structures.ItemId, source_type: ?structures.TypeId, target_type: structures.TypeId, source_value: ?structures.CompileTimeValueId, collection_length: ?u32) !?struct { instance: structures.InstanceId, signature: structures.FunctionSignature } {
            const base: structures.InstanceId = .{ .item = item };
            const declaration = try self.declarationContext(base, &.{});
            const inference = try semantic.inferConverterArguments(&declaration.parsed, declaration.source, declaration.resolved.declaration, source_type, target_type, source_value, collection_length, declaration.analysis, self.ctx.allocator());
            const arguments = switch (inference) {
                .arguments => |arguments| arguments,
                .missing, .conflict => return null,
            };
            defer self.ctx.allocator().free(arguments);
            const instance = try self.specializeFunction(base, arguments);
            const specialized = try self.declarationContext(instance, arguments);
            const signature = switch (try semantic.analyzeFunctionInstanceSignature(&specialized.parsed, specialized.source, declaration.resolved.declaration, arguments, specialized.analysis, self.ctx.allocator())) {
                .success => |signature| signature,
                .unsupported => |issue| {
                    // Contextual collection probing has not selected a source type yet.
                    if (source_type == null or issue.kind == .static_argument_type_mismatch) return null;
                    try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
            return .{ .instance = instance, .signature = signature };
        }

        pub fn conversionCandidates(self: @This(), source_type: structures.TypeId, target_type: structures.TypeId, source_value: ?structures.CompileTimeValueId) ![]structures.ConversionCandidate {
            var candidates: std.ArrayList(structures.ConversionCandidate) = .empty;
            errdefer candidates.deinit(self.ctx.allocator());
            const source_owner = try self.conversionOwner(source_type);
            var targets: std.ArrayList(structures.TypeId) = .empty;
            defer targets.deinit(self.ctx.allocator());
            try targets.append(self.ctx.allocator(), target_type);
            if (try self.facts().variantMembers(target_type)) |members| try targets.appendSlice(self.ctx.allocator(), members);
            for (targets.items) |target| {
                const items = try self.visibleConverters(source_owner, target);
                defer self.ctx.allocator().free(items);
                for (items) |item| {
                    var probe = (try self.probeConverterSignature(item, source_type, target, source_value, null)) orelse continue;
                    defer probe.signature.deinit(self.ctx.allocator());
                    const signature = probe.signature;
                    if (signature.return_type != target) continue;
                    if (signature.parameters.len != 0 and signature.parameters[0].type_id != source_type) continue;
                    const static_source = source_value != null and !try self.facts().isRuntimeCapable(source_type);
                    if (signature.parameters.len != @as(usize, if (static_source) 0 else 1) or signature.is_fallible or
                        (!static_source and signature.parameters[0].mode != .imm and signature.parameters[0].mode != .init))
                    {
                        const resolved = (try self.ctx.get(ResolveItem, item)).* orelse return error.Unavailable;
                        const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                        try self.ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(&parsed, @fromBackingInt(@intCast(resolved.declaration))), .kind = .invalid_converter });
                        return error.Unavailable;
                    }
                    try candidates.append(self.ctx.allocator(), .{ .instance = probe.instance, .target_type = target, .source_mode = if (static_source) .static else signature.parameters[0].mode });
                }
            }
            return candidates.toOwnedSlice(self.ctx.allocator());
        }

        pub fn contextualCollectionElement(self: @This(), target_type: structures.TypeId, length: u32, span: structures.SourceSpan) !?structures.TypeId {
            const source_file = (try standardFile(self.ctx, .array)) orelse return null;
            const source_owner = (try self.ctx.input(FileModule, source_file)).*;
            const single_target = [_]structures.TypeId{target_type};
            const targets = (try self.facts().variantMembers(target_type)) orelse &single_target;
            var element_type: ?structures.TypeId = null;
            for (targets) |target| {
                const items = try self.visibleConverters(source_owner, target);
                defer self.ctx.allocator().free(items);
                for (items) |item| {
                    var probe = (try self.probeConverterSignature(item, null, target, null, length)) orelse continue;
                    defer probe.signature.deinit(self.ctx.allocator());
                    const signature = probe.signature;
                    if (signature.return_type != target or signature.parameters.len != 1 or signature.parameters[0].mode != .init) continue;
                    const collection = (try self.collectionLiteralType(signature.parameters[0].type_id)) orelse continue;
                    if (collection.length != length) continue;
                    if (element_type != null and element_type.? != collection.element_type) {
                        try self.ctx.emit(structures.Diagnostic, .{ .file_id = self.file_id.?, .span = span, .kind = .{ .ambiguous_conversion = .{ .expected = target_type, .found = signature.parameters[0].type_id } } });
                        return error.Unavailable;
                    }
                    element_type = collection.element_type;
                }
            }
            return element_type;
        }

        pub fn independentStructFieldType(self: @This(), instance: structures.InstanceId, name: []const u8) !?structures.TypeId {
            const declaration = try self.declarationContext(instance, &.{});
            return switch (try semantic.analyzeIndependentStructFieldType(&declaration.parsed, declaration.source, declaration.resolved.declaration, name, declaration.analysis, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
        }

        pub fn specializedStructType(self: @This(), instance: structures.InstanceId) !structures.TypeId {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse unreachable;
            return internGeneratedStructType(self.ctx, .{ .owner = instance, .node_offset = site });
        }

        pub fn structFactoryArguments(self: @This(), factory: structures.InstanceId, type_id: structures.TypeId) !?[]const structures.CompileTimeValueId {
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const identity = association.query_key;
            if (identity != .generated or identity.generated.owner.item != factory.item) return null;
            const resolved = (try self.ctx.get(ResolveItem, factory.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse return null;
            if (identity.generated.node_offset != site) return null;
            const arity = (try self.ctx.get(SpecializationArity, factory.item)).* orelse return error.Unavailable;
            const values = if (association.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values
            else
                &.{};
            if (values.len != arity.total()) return null;
            const inherited = if (factory.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values
            else
                &.{};
            if (inherited.len != arity.inherited or !std.mem.eql(structures.CompileTimeValueId, values[0..arity.inherited], inherited)) return null;
            return values[arity.inherited..];
        }

        fn stdMemoryFunction(self: @This(), name: []const u8) !?structures.ItemId {
            return standardFunction(self.ctx, .memory_allocation, name);
        }

        pub fn callBehavior(self: @This(), item: structures.ItemId) !structures.CallBehavior {
            const location = try self.ctx.lookupInterned(ItemLocations, item);
            const names = std.StaticStringMap(structures.CallBehavior).initComptime(.{
                .{ "value", .box_value },
                .{ "borrow_box", .box_borrow },
                .{ "borrow_mut_box", .box_borrow_mut },
                .{ "borrow_local", .local_borrow },
                .{ "unsafe_borrow_element", .allocation_element_borrow },
                .{ "unsafe_borrow_mut_element", .allocation_element_borrow },
                .{ "read", .reference_read },
                .{ "write", .reference_write },
                .{ "attenuate_ref", .reference_attenuate },
                .{ "unsafe_destroy_box", .box_destroy },
                .{ "unsafe_destroy", .allocation_destroy },
                .{ "unsafe_borrow_initialized", .allocation_read },
            });
            if (location.owner == null) {
                const behavior = names.get(location.name) orelse return .ordinary;
                return if (item == (try self.stdMemoryFunction(location.name))) behavior else .ordinary;
            }
            const Member = struct { factory: []const u8, name: []const u8, behavior: structures.CallBehavior };
            const members = [_]Member{
                .{ .factory = "Box", .name = "new", .behavior = .box_new },
                .{ .factory = "Box", .name = "borrow", .behavior = .box_borrow },
                .{ .factory = "Box", .name = "borrow_mut", .behavior = .box_borrow_mut },
                .{ .factory = "Ref", .name = "replace", .behavior = .reference_write },
                .{ .factory = "Ref", .name = "as_imm", .behavior = .reference_attenuate },
                .{ .factory = "Buffer", .name = "new", .behavior = .buffer_new },
                .{ .factory = "Buffer", .name = "append", .behavior = .buffer_append },
                .{ .factory = "Buffer", .name = "reserve", .behavior = .buffer_reserve },
            };
            for (members) |member| {
                if (!std.mem.eql(u8, location.name, member.name)) continue;
                const factory = (try self.stdMemoryFunction(member.factory)) orelse continue;
                if (location.owner != factory) continue;
                const resolved = (try self.genericStructNamespaceMember(.{ .item = factory }, member.name, null)) orelse continue;
                if (resolved.item == item) return member.behavior;
            }
            return .ordinary;
        }

        pub fn bufferElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .Buffer)) orelse return null;
            return instance.element_type;
        }

        pub fn listElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .List)) orelse return null;
            return instance.element_type;
        }

        pub fn referenceType(self: @This(), element_type: structures.TypeId, writable: bool) !?structures.TypeId {
            const factory = (try self.stdMemoryFunction(@tagName(standard_library.Structure.Ref))) orelse return null;
            const element = try self.internCompileTimeValue(.{ .type = element_type });
            const access = try self.internCompileTimeValue(.{ .runtime = .{
                .type_id = .bool,
                .value = .{ .bool = writable },
            } });
            return try self.specializedStructType(try self.specializeFunction(.{ .item = factory }, &.{ element, access }));
        }

        pub fn containsBorrow(self: @This(), type_id: structures.TypeId) !bool {
            var visited: std.ArrayList(structures.TypeId) = .empty;
            defer visited.deinit(self.ctx.allocator());
            return self.containsBorrowAt(type_id, &visited, false);
        }

        pub fn canStoreBorrow(self: @This(), type_id: structures.TypeId) !bool {
            var visited: std.ArrayList(structures.TypeId) = .empty;
            defer visited.deinit(self.ctx.allocator());
            return self.containsBorrowAt(type_id, &visited, true);
        }

        fn containsBorrowAt(self: @This(), type_id: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_contents: bool) !bool {
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, type_id) != null) return false;
            try visited.append(self.ctx.allocator(), type_id);
            if (try self.facts().borrowElement(type_id) != null) return true;
            if (try self.collectionLiteralType(type_id)) |collection|
                return collection.length != 0 and try self.containsBorrowAt(collection.element_type, visited, include_allocated_contents);
            if (try self.arrayType(type_id)) |array|
                return array.length != 0 and try self.containsBorrowAt(array.element_type, visited, include_allocated_contents);
            if (try self.bufferElement(type_id)) |element| return self.containsBorrowAt(element, visited, include_allocated_contents);
            if (try self.listElement(type_id)) |element| return self.containsBorrowAt(element, visited, include_allocated_contents);
            if (try self.facts().allocationElement(type_id)) |element|
                return include_allocated_contents and try self.containsBorrowAt(element, visited, true);
            if (try self.facts().boxElement(type_id)) |element| {
                if (try self.containsBorrowAt(element, visited, include_allocated_contents)) return true;
            }
            if (try self.structDefinition(type_id)) |definition| {
                for (definition.fields) |field| {
                    if (try self.containsBorrowAt(field.type_id, visited, include_allocated_contents)) return true;
                }
            }
            if (try self.facts().variantMembers(type_id)) |members| {
                for (members) |member| {
                    if (try self.containsBorrowAt(member, visited, include_allocated_contents)) return true;
                }
            }
            return false;
        }

        pub fn ownedFunction(self: @This(), identity: structures.StructIdentity, name: []const u8) !?structures.InstanceId {
            const owner, const struct_site, const specialization = switch (identity) {
                .declared => |item_id| .{ item_id, @as(?i64, null), @as(?structures.CompileTimeValueTupleId, null) },
                .generated => |generated| .{ generated.owner.item, generated.node_offset, generated.owner.specialization },
            };
            const owner_loc = try self.ctx.lookupInterned(ItemLocations, owner);
            const source_site = if (owner_loc.kind == .structure) null else struct_site;
            const resolved = (try self.ctx.get(ResolveItem, owner)).* orelse return error.Unavailable;
            const index = (try self.ctx.get(IndexItems, resolved.file_id)).* orelse return error.Unavailable;
            for (index.ids()) |item_id| {
                const item_loc = try self.ctx.lookupInterned(ItemLocations, item_id);
                if (item_loc.owner == owner and item_loc.source_site == source_site and item_loc.is_hook and item_loc.kind == .function and std.mem.eql(u8, item_loc.name, name)) {
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

        pub fn inheritsInitializerFailure(self: @This(), instance: structures.InstanceId) !bool {
            const external = (try self.ctx.get(ExternalSymbol, instance.item)).*;
            if (external == .array_from or external == .initialize_collection) return true;
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            if (!parsed.nodes[parsed.nodes[resolved.declaration].data.node_node.b.index()].is_converter) return false;
            const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
            for (shape.parameters) |parameter| if (parameter.mode == .init) return true;
            return false;
        }

        pub fn needsInheritedInference(self: @This(), instance: structures.InstanceId) !bool {
            const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
            const count = if (instance.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len
            else
                0;
            return count < arity.inherited;
        }

        pub fn isGenericStruct(self: @This(), item_id: structures.ItemId) !bool {
            const resolved = (try self.ctx.get(ResolveItem, item_id)).* orelse return false;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return false;
            return semantic.parameterizedStructSite(&parsed, resolved.declaration) != null;
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
            return self.executeComptimeWithType(node, null);
        }

        pub fn executeComptimeWithType(self: @This(), node: structures.Node.Index, expected_type: ?structures.TypeId) !?structures.CompileTimeValueId {
            const owner = self.instance orelse unreachable;
            const outcome = (try self.ctx.get(ExecuteComptimeThunk, .{
                .owner = owner,
                .node = node,
                .expected_type = expected_type,
                .public_annotation = self.public_annotation,
            })).* orelse return null;
            return switch (outcome) {
                .returned => |value| value,
                .failure, .exit => null,
            };
        }

        pub fn evaluateWhereMembership(self: @This(), operand: structures.Node.Index, target: structures.TypeId) !?bool {
            const file_id = self.file_id orelse unreachable;
            const parsed = (try self.ctx.get(ParseFile, file_id)).* orelse return null;
            const source = (try self.ctx.input(SourceText, file_id)).*;
            const node = parsed.nodes[operand.index()];
            if (node.tag == .field_access) {
                const owner_reference = try semantic.resolveNamedExpression(&parsed, source, node.data.node, self);
                if (owner_reference == null or owner_reference.? != .namespace) {
                    const owner_id = (try self.executeComptime(node.data.node)) orelse return null;
                    const owner = try self.lookupCompileTimeValue(owner_id);
                    const span = nodeSpan(&parsed, operand);
                    const name = source[span.start..span.end];
                    switch (owner) {
                        .type => |type_id| if (try self.structNamespaceMember(type_id, name, span) == null) return false,
                        .runtime => |runtime| if (try self.structDefinition(runtime.type_id)) |definition| {
                            const field = definition.resolveField(name) orelse return false;
                            if (!definition.fields[field.index].is_public and !try self.canAccessPrivateFields(runtime.type_id)) {
                                try rejectImport(self.ctx, .{ .file_id = file_id, .span = span }, .{ .private_struct_field = runtime.type_id });
                                return error.Unavailable;
                            }
                        },
                    }
                }
            }
            const value_id = (try self.executeComptime(operand)) orelse return null;
            const value = try self.lookupCompileTimeValue(value_id);
            const source_type = switch (value) {
                .type => |type_id| type_id,
                .runtime => |runtime| runtime.type_id,
            };
            const members = (try self.facts().variantMembers(source_type)) orelse &.{source_type};
            const target_members = try self.facts().variantMembers(target);
            for (members) |member| {
                if (target_members) |accepted| {
                    if (std.mem.indexOfScalar(structures.TypeId, accepted, member) == null) return false;
                } else if (member != target) return false;
            }
            return true;
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

        fn staticParameter(self: @This(), name: []const u8) !?structures.CompileTimeValueId {
            var instance = self.instance orelse return null;
            var arguments: []const structures.CompileTimeValueId = if (instance.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values
            else if (self.prior_static_arguments != null)
                &.{}
            else
                return null;
            if (self.prior_static_arguments) |prior| {
                const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
                const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
                if (semantic.resolveSpecializationArgument(&parsed, source, resolved.declaration, prior, name)) |value| return value;
                const loc = try self.ctx.lookupInterned(ItemLocations, instance.item);
                instance.item = loc.owner orelse return null;
                if (arguments.len == 0) return null;
            }
            while (true) {
                const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
                if (arguments.len != arity.total()) return error.Unavailable;
                const loc = try self.ctx.lookupInterned(ItemLocations, instance.item);
                if (loc.kind == .function) {
                    const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
                    const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                    const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
                    if (semantic.resolveSpecializationArgument(&parsed, source, resolved.declaration, arguments[arity.inherited..], name)) |value| return value;
                }
                instance.item = loc.owner orelse return null;
                arguments = arguments[0..arity.inherited];
            }
        }

        pub fn specializeFunction(self: @This(), instance: structures.InstanceId, arguments: []const structures.CompileTimeValueId) !structures.InstanceId {
            if (arguments.len == 0) return instance;
            const inherited = if (instance.specialization) |tuple| (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
            const combined = try self.ctx.allocator().alloc(structures.CompileTimeValueId, inherited.len + arguments.len);
            defer self.ctx.allocator().free(combined);
            @memcpy(combined[0..inherited.len], inherited);
            @memcpy(combined[inherited.len..], arguments);
            return self.internFunctionInstance(instance.item, combined);
        }

        pub fn resolveLocalConflict(self: @This(), name: []const u8) !?structures.ItemId {
            const module = (try self.ctx.input(FileModule, self.file_id.?)).*;
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
            return declarations.resolve(name);
        }

        pub fn resolveName(self: @This(), name: []const u8) !?structures.NameReference {
            if (try self.staticParameter(name)) |value| return .{ .constant = value };
            if (try self.resolveDeclaration(name)) |instance| return .{ .declaration = instance };
            const imports = (try self.ctx.get(ResolveFileImports, self.file_id.?)).* orelse return error.Unavailable;
            for (imports.imports) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                return switch (binding.target) {
                    .declaration => |item| .{ .declaration = .{ .item = item } },
                    .namespace => |namespace| .{ .namespace = namespace },
                };
            }
            if (std.meta.stringToEnum(structures.TypeId, name)) |type_id|
                return .{ .constant = try self.ctx.intern(CompileTimeValues, .{ .type = type_id }) };
            return null;
        }

        pub fn isPublicAnnotationReference(self: @This(), reference: structures.NameReference) !bool {
            return switch (reference) {
                .declaration => |instance| self.declarationIsPublic(instance.item),
                .constant, .namespace => true,
            };
        }

        fn declarationIsPublic(self: @This(), item_id: structures.ItemId) !bool {
            var current = item_id;
            while (true) {
                const location = try self.ctx.lookupInterned(ItemLocations, current);
                const module = switch (location.origin) {
                    .module => |module| module,
                    .entry => return false,
                };
                const scope = if (location.owner) |owner| scope: {
                    const identity: structures.StructIdentity = if (location.source_site) |site|
                        .{ .generated = .{ .owner = .{ .item = owner }, .node_offset = site } }
                    else
                        .{ .declared = owner };
                    break :scope (try self.ctx.get(StructNamespace, identity)).* orelse return error.Unavailable;
                } else (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
                const entry = scope.resolveEntry(location.name) orelse return error.Unavailable;
                std.debug.assert(entry.item_id == current);
                if (!entry.is_public) return false;
                current = location.owner orelse return true;
            }
        }

        pub fn isPublicType(self: @This(), type_id: structures.TypeId) anyerror!bool {
            if (type_id.isPrimitive()) return true;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            switch (data.*) {
                .structure => |identity| {
                    if (!try self.declarationIsPublic(structOwnerItem(identity))) return false;
                    if (identity == .generated) {
                        if (identity.generated.owner.specialization) |tuple| {
                            const arguments = (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
                            for (arguments) |argument| {
                                const value = (try self.ctx.lookupInterned(CompileTimeValues, argument)).*;
                                if (value == .type and !try self.isPublicType(value.type)) return false;
                            }
                        }
                    }
                    return true;
                },
                .variant => |variant| {
                    for (variant.members) |member| {
                        if (!try self.isPublicType(member)) return false;
                    }
                    return true;
                },
                .callable => |callable| {
                    for (callable.parameters) |parameter| {
                        if (!try self.isPublicType(parameter.type_id)) return false;
                    }
                    return self.isPublicType(callable.return_type);
                },
                .array => |array| return self.isPublicType(array.element_type),
            }
        }

        pub fn staticItem(self: @This(), instance: structures.InstanceId) !?structures.CompileTimeValueId {
            const identity = try self.ctx.lookupInterned(ItemLocations, instance.item);
            if (identity.kind != .static and identity.kind != .structure) return null;
            return if (instance.specialization == null)
                (try self.ctx.get(ResolveStatic, instance.item)).* orelse return error.Unavailable
            else
                (try self.ctx.get(ResolveStaticInstance, instance)).* orelse return error.Unavailable;
        }

        pub fn resolveMember(self: @This(), reference: structures.NameReference, name: []const u8, span: structures.SourceSpan) !?structures.NameReference {
            switch (reference) {
                .namespace => |namespace| return try self.moduleMember(namespace, name, span),
                .declaration => |item| {
                    if (try self.isGenericStruct(item.item)) {
                        if (try self.genericStructNamespaceMember(item, name, span)) |member| return .{ .declaration = member };
                        try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
                        return error.Unavailable;
                    }
                    const value = (try self.staticItem(item)) orelse return null;
                    return self.constantMember(value, name, span);
                },
                .constant => |value| return self.constantMember(value, name, span),
            }
        }

        fn constantMember(self: @This(), value_id: structures.CompileTimeValueId, name: []const u8, span: structures.SourceSpan) !?structures.NameReference {
            const value = try self.lookupCompileTimeValue(value_id);
            if (value == .runtime) {
                const definition = (try self.facts().structDefinition(value.runtime.type_id)) orelse return null;
                const field = definition.resolveField(name) orelse return null;
                if (!definition.fields[field.index].is_public and !try self.canAccessPrivateFields(value.runtime.type_id)) {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .{ .private_struct_field = value.runtime.type_id });
                    return error.Unavailable;
                }
                std.debug.assert(value.runtime.value == .structure);
                const fields = (try self.ctx.lookupInterned(CompileTimeValueTuples, value.runtime.value.structure)).values;
                std.debug.assert(field.index < fields.len);
                return .{ .constant = fields[field.index] };
            }
            if (std.meta.stringToEnum(structures.OwnershipMember, name)) |operation| {
                if (try self.ownershipMember(value.type, operation)) |instance| {
                    const reference = (try self.functionItemReference(instance)) orelse return error.Unavailable;
                    return .{ .constant = try self.ctx.intern(CompileTimeValues, .{ .runtime = .{
                        .type_id = reference.type_id,
                        .value = .{ .function_ref = reference },
                    } }) };
                }
                try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
                return error.Unavailable;
            }
            if (try self.typeNamespace(value.type) == null) return null;
            if (try self.structNamespaceMember(value.type, name, span)) |instance| return .{ .declaration = instance };
            try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
            return error.Unavailable;
        }

        fn moduleMember(self: @This(), namespace: structures.NamespaceBinding, name: []const u8, span: structures.SourceSpan) !structures.NameReference {
            const imports = (try self.ctx.get(ResolveFileImports, self.file_id.?)).* orelse return error.Unavailable;
            const path = (try self.ctx.lookupInterned(ModulePaths, namespace.module)).path;
            const child_path = try self.ctx.allocator().print("{s}.{s}", .{ path, name });
            defer self.ctx.allocator().free(child_path);
            var child: ?structures.NamespaceBinding = null;
            for (imports.modules) |imported| {
                const imported_path = (try self.ctx.lookupInterned(ModulePaths, imported)).path;
                if (std.mem.eql(u8, imported_path, child_path)) {
                    child = .{ .module = imported };
                    break;
                }
                if (std.mem.startsWith(u8, imported_path, child_path) and imported_path.len > child_path.len and imported_path[child_path.len] == '.') {
                    child = .{ .module = try self.ctx.intern(ModulePaths, .{ .path = child_path }), .members_visible = false };
                }
            }
            // Only explicit paths grant access to filesystem children.
            if (child) |found| return .{ .namespace = found };
            const origin: ImportOrigin = .{ .file_id = self.file_id.?, .span = span };
            if (!namespace.members_visible) {
                try rejectImport(self.ctx, origin, .unknown_imported_name);
                return error.Unavailable;
            }
            var visited: std.ArrayList(ExportVisit) = .empty;
            defer visited.deinit(self.ctx.allocator());
            const importer = (try self.ctx.input(FileModule, self.file_id.?)).*;
            const exported = (try resolveModuleExport(self.ctx, importer, namespace.module, name, origin, &visited)) orelse return error.Unavailable;
            return switch (exported) {
                .declaration => |item| .{ .declaration = .{ .item = item } },
                .namespace => |target| .{ .namespace = target },
            };
        }

        pub fn resolveStatic(self: @This(), name: []const u8) !?structures.CompileTimeValueId {
            if (try self.staticParameter(name)) |value| return value;
            const instance = (try self.resolveDeclaration(name)) orelse return null;
            return self.staticItem(instance);
        }

        fn resolveDeclaration(self: @This(), name: []const u8) !?structures.InstanceId {
            var current = self.instance;
            while (current) |instance| {
                const loc = try self.ctx.lookupInterned(ItemLocations, instance.item);
                const inferring = self.prior_static_arguments != null and std.meta.eql(instance, self.instance.?);
                const parent = (try enclosingInstance(self.ctx, instance, inferring)) orelse break;
                const parent_loc = try self.ctx.lookupInterned(ItemLocations, parent.item);
                const identity: ?structures.StructIdentity = if (loc.source_site) |site|
                    .{ .generated = .{ .owner = parent, .node_offset = site } }
                else if (parent_loc.kind == .structure) identity: {
                    const value = (try self.staticItem(parent)) orelse unreachable;
                    const type_id = (try self.lookupCompileTimeValue(value)).type;
                    break :identity (try self.ctx.lookupInterned(Types, type_id.interned().?)).structure;
                } else null;
                if (identity) |structure| {
                    const namespace = (try self.ctx.get(StructNamespace, structure)).* orelse return error.Unavailable;
                    if (namespace.resolve(name)) |item| return .{ .item = item, .specialization = parent.specialization };
                }
                current = parent;
            }
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            const item = scope.resolve(name) orelse return null;
            return .{ .item = item };
        }

        pub fn functionItemReference(self: @This(), instance: structures.InstanceId) !?structures.FunctionReference {
            const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
            const supplied = if (instance.specialization) |tuple| (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len else 0;
            if (supplied != arity.total()) return null;
            const signature = (try self.functionSignature(instance)) orelse return error.Unavailable;
            if (signature.return_type == .type) return null;
            return .{
                .target = instance.item,
                .specialization = instance.specialization,
                .type_id = try self.facts().internCallable(signature),
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
        .callable, .structure, .array => null,
    };
}

fn lookupCallable(ctx: anytype, type_id: structures.TypeId) !?structures.CallableType {
    if (type_id.isPrimitive()) return null;
    const interned_id = type_id.interned() orelse unreachable;
    const data = (try ctx.lookupInternedAs(Types, interned_id)) orelse return null;
    return switch (data.*) {
        .variant, .structure, .array => null,
        .callable => |callable| callable,
    };
}

fn lookupArrayType(ctx: anytype, type_id: structures.TypeId) !?structures.ArrayType {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
    return switch (data.*) {
        .array => |array| array,
        .variant, .callable, .structure => null,
    };
}

pub const HostTypeLayout = struct {
    pub const Input = structures.TypeId;
    pub const Output = structures.TypeLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        if (!try facts.isRuntimeCapable(type_id)) return error.Unavailable;
        if (type_id == .int or type_id == .bool) return .{ .byte_size = 4, .byte_alignment = 4 };
        if (type_id == .byte) return .{ .byte_size = 1, .byte_alignment = 1 };
        if (type_id == .unit or type_id == .none or type_id == .never) return .{ .byte_size = 0, .byte_alignment = 1 };
        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
        switch (data.*) {
            .callable => return .{ .byte_size = @sizeOf(u64), .byte_alignment = @alignOf(u64) },
            .variant => return (try ctx.get(VariantLayout, type_id)).layout,
            .structure => {
                const layout = (try ctx.get(StructLayout, type_id)).* orelse return error.Unavailable;
                return layout.layout;
            },
            .array => |array| return arrayLayout(ctx, array),
        }
    }

    fn arrayLayout(ctx: anytype, array: structures.ArrayType) !structures.TypeLayout {
        const element = (try ctx.get(HostTypeLayout, array.element_type)).*;
        return .{
            .byte_size = std.math.mul(u32, array.length, element.byte_size) catch return error.TypeTooLarge,
            .byte_alignment = element.byte_alignment,
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
            const member_layout = (try ctx.get(HostTypeLayout, member)).*;
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
            .variant, .callable, .array => return null,
        };
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        if ((try ctx.get(OwnershipCapabilities, type_id)).* == null) return null;
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        if (!try facts.isRuntimeCapable(type_id)) return null;

        const field_offsets = try ctx.allocator().alloc(u32, definition.fields.len);
        var keep_offsets = false;
        defer if (!keep_offsets) ctx.allocator().free(field_offsets);
        var byte_size: u32 = 0;
        var byte_alignment: u32 = 1;
        for (definition.fields, field_offsets) |field, *field_offset| {
            const field_layout = (ctx.get(HostTypeLayout, field.type_id) catch |err| switch (err) {
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
            .structure => |identity| structOwnership(ctx, identity),
            .array => |array| arrayOwnership(ctx, array),
        };
    }

    fn trivialOwnership() structures.OwnershipCapabilities {
        return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    }

    fn arrayOwnership(ctx: anytype, array: structures.ArrayType) !?structures.OwnershipCapabilities {
        if (array.length == 0) return trivialOwnership();
        const element = (try ctx.get(OwnershipCapabilities, array.element_type)).* orelse return null;
        return .{
            .move = switch (element.move) {
                .trivial => .trivial,
                .none => .none,
                .fieldwise, .custom => .fieldwise,
            },
            .copy = switch (element.copy) {
                .trivial => .trivial,
                .none => .none,
                .fieldwise, .custom => .fieldwise,
            },
            .drop = if (element.drop == .trivial) .trivial else .fieldwise,
            .needs_custom_move = element.needs_custom_move,
            .needs_custom_copy = element.needs_custom_copy,
            .needs_automatic_drop = element.needs_automatic_drop,
            .requires_explicit_drop = element.requires_explicit_drop,
        };
    }

    fn variantOwnership(ctx: anytype, members: []const structures.TypeId) !?structures.OwnershipCapabilities {
        var can_move = true;
        var can_copy = true;
        var drops_trivially = true;
        var fields_need_custom_move = false;
        var fields_need_custom_copy = false;
        var needs_automatic_drop = false;
        var requires_explicit_drop = false;
        for (members) |member| {
            const capabilities = (try ctx.get(OwnershipCapabilities, member)).* orelse return null;
            can_move = can_move and capabilities.move != .none;
            can_copy = can_copy and capabilities.copy != .none;
            drops_trivially = drops_trivially and capabilities.drop == .trivial;
            fields_need_custom_move = fields_need_custom_move or capabilities.needs_custom_move;
            fields_need_custom_copy = fields_need_custom_copy or capabilities.needs_custom_copy;
            needs_automatic_drop = needs_automatic_drop or capabilities.needs_automatic_drop;
            requires_explicit_drop = requires_explicit_drop or capabilities.requires_explicit_drop;
        }
        return .{
            .move = if (can_move) .fieldwise else .none,
            .copy = if (can_copy) .fieldwise else .none,
            .drop = if (drops_trivially) .trivial else .fieldwise,
            .needs_custom_move = can_move and fields_need_custom_move,
            .needs_custom_copy = can_copy and fields_need_custom_copy,
            .needs_automatic_drop = needs_automatic_drop,
            .requires_explicit_drop = requires_explicit_drop,
        };
    }

    fn structOwnership(ctx: anytype, identity: structures.StructIdentity) !?structures.OwnershipCapabilities {
        var visited: StructVisits = .empty;
        defer visited.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, identity, &visited)) return null;
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
            if (property.capability == .custom and !can_move) {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, .custom_move);
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

const StructVisits = std.AutoHashMapUnmanaged(structures.StructIdentity, enum { active, complete });

fn validateStructContainment(
    ctx: anytype,
    identity: structures.StructIdentity,
    visited: *StructVisits,
) !bool {
    if (visited.get(identity)) |state| {
        std.debug.assert(state == .complete);
        return true;
    }
    try visited.put(ctx.allocator(), identity, .active);

    const definition = (try getStructDefinition(ctx, identity)) orelse return false;
    const resolved = (try ctx.get(ResolveItem, structOwnerItem(identity))).* orelse return error.Unavailable;
    for (definition.fields) |field| {
        if (!try validateContainedType(ctx, field.type_id, resolved.file_id, field.span, visited)) return false;
    }
    visited.getPtr(identity).?.* = .complete;
    return true;
}

fn structOwnerItem(identity: structures.StructIdentity) structures.ItemId {
    return switch (identity) {
        .declared => |item_id| item_id,
        .generated => |generated| generated.owner.item,
    };
}

fn validateContainedType(
    ctx: anytype,
    type_id: structures.TypeId,
    file_id: structures.FileId,
    span: structures.SourceSpan,
    visited: *StructVisits,
) !bool {
    if (type_id.isPrimitive()) return true;
    const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
    return switch (data.*) {
        .callable => true,
        .array => |array| validateContainedType(ctx, array.element_type, file_id, span, visited),
        .variant => |variant| blk: {
            for (variant.members) |member| {
                if (!try validateContainedType(ctx, member, file_id, span, visited)) break :blk false;
            }
            break :blk true;
        },
        .structure => |contained_identity| blk: {
            if (visited.get(contained_identity) == .active) {
                try ctx.emit(structures.Diagnostic, .{
                    .file_id = file_id,
                    .span = span,
                    .kind = .recursive_struct_containment,
                });
                break :blk false;
            }
            break :blk validateStructContainment(ctx, contained_identity, visited);
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
        const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
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
            } else if (item.qualified_owner) |owner_path| {
                const module = switch (loc.origin) {
                    .module => |value| value,
                    .entry => unreachable,
                };
                var segments = std.mem.splitScalar(u8, owner_path, '.');
                var owner: ?structures.ItemId = null;
                while (segments.next()) |segment| {
                    std.debug.assert(segment.len != 0);
                    owner = try ctx.intern(ItemLocations, .{
                        .origin = .{ .module = module },
                        .owner = owner,
                        .kind = .structure,
                        .name = segment,
                    });
                }
                loc.owner = owner orelse unreachable;
            }
            const item_id = try ctx.intern(ItemLocations, loc);
            item_ids[index] = item_id;
            if (entries.contains(item_id)) {
                const token = parsed.tokens[parsed.nodes[item.declaration].token_index];
                try ctx.emit(structures.Diagnostic, .{
                    .file_id = file_id,
                    .span = .{ .start = token.loc.start, .end = token.loc.end },
                    .kind = .duplicate_struct_member,
                });
                entries.deinit(ctx.allocator());
                return null;
            }
            entries.putAssumeCapacityNoClobber(item_id, item.declaration);
        }
        return .{ .file_id = file_id, .entries = entries };
    }
};

pub const ModuleDeclarations = struct {
    pub const disk_boundary = true;
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
            const discovered = try ctx.get(DiscoverItems, file_id);
            const tree = discovered.* orelse return null;
            const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
            std.debug.assert(tree.items.len == index.count());
            for (tree.items, index.ids()) |item, item_id| {
                if (item.loc.kind == .top_level_entry or item.parent != null or item.qualified_owner != null) continue;
                std.debug.assert(item.loc.origin.module == module);
                if ((try names.getOrPut(item.loc.name)).found_existing) {
                    const token = parsed.tokens[parsed.nodes[item.declaration].token_index];
                    try ctx.emit(structures.Diagnostic, .{
                        .file_id = file_id,
                        .span = .{ .start = token.loc.start, .end = token.loc.end },
                        .kind = .duplicate_top_level_declaration,
                    });
                    return null;
                }
                const name = try ctx.allocator().dupe(u8, item.loc.name);
                errdefer ctx.allocator().free(name);
                try entries.append(ctx.allocator(), .{ .name = name, .item_id = item_id, .kind = item.loc.kind, .is_public = item.is_public });
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
    pub const disk_boundary = true;
    pub const Input = structures.FileId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const file_module = (try ctx.input(FileModule, file_id)).*;
        const declarations = (try ctx.get(ModuleDeclarations, file_module)).* orelse return null;
        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        defer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        for (declarations.entries) |entry| {
            const name = try ctx.allocator().dupe(u8, entry.name);
            errdefer ctx.allocator().free(name);
            try entries.append(ctx.allocator(), .{ .name = name, .item_id = entry.item_id, .kind = entry.kind, .is_public = entry.is_public });
        }
        const imports = (try ctx.get(ResolveFileImports, file_id)).* orelse return null;
        for (imports.imports) |binding| {
            if (binding.target != .declaration) continue;
            const item = binding.target.declaration;
            const loc = try ctx.lookupInterned(ItemLocations, item);
            const name = try ctx.allocator().dupe(u8, binding.name);
            errdefer ctx.allocator().free(name);
            try entries.append(ctx.allocator(), .{ .name = name, .item_id = item, .kind = loc.kind, .is_public = false });
        }
        std.mem.sort(structures.ModuleScope.Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: structures.ModuleScope.Entry, b: structures.ModuleScope.Entry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }
};

pub const CollectFileImports = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ImportDeclarations;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, file_id)).*;
        return try semantic.collectImports(ctx.allocator(), &parsed, source);
    }
};

pub const ResolveFileImports = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.FileImports;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const collected = (try ctx.get(CollectFileImports, file_id)).* orelse return null;
        const module = (try ctx.input(FileModule, file_id)).*;
        const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
        var modules: std.ArrayList(structures.ModuleId) = .empty;
        defer modules.deinit(ctx.allocator());
        var imports: std.ArrayList(structures.FileImport) = .empty;
        defer {
            for (imports.items) |binding| ctx.allocator().free(binding.name);
            imports.deinit(ctx.allocator());
        }
        var bound: std.StringHashMap(u32) = .init(ctx.allocator());
        defer bound.deinit();
        var failed = false;
        const module_path = (try ctx.lookupInterned(ModulePaths, module)).path;
        const standard_module = std.mem.eql(u8, module_path, standard_library.root_module) or std.mem.startsWith(u8, module_path, standard_library.root_module ++ ".");
        if (!standard_module and !explicitlyImportsPrelude(collected.entries)) {
            const configured = ctx.input(StandardPreludeModule, {}) catch |err| switch (err) {
                error.InputNotFound => null,
                else => return err,
            };
            if (configured != null) {
                const defaults = (try ctx.get(ResolvePreludeImports, {})).* orelse return null;
                for (defaults.imports) |binding| {
                    if (declarations.resolve(binding.name) != null) continue;
                    const origin: ImportOrigin = .{ .file_id = file_id, .span = .{ .start = 0, .end = 0 } };
                    if (!try bindImport(ctx, origin, declarations, binding.name, binding.target, false, &imports, &bound)) failed = true;
                }
            }
        }
        for (collected.entries) |entry| {
            if (!try resolveImportStatement(ctx, file_id, module, declarations, entry, &modules, &imports, &bound)) failed = true;
        }
        if (failed) return null;
        std.mem.sort(structures.ModuleId, modules.items, {}, struct {
            fn lessThan(_: void, left: structures.ModuleId, right: structures.ModuleId) bool {
                return @backingInt(left) < @backingInt(right);
            }
        }.lessThan);
        var unique: usize = 0;
        for (modules.items) |candidate| {
            if (unique != 0 and modules.items[unique - 1] == candidate) continue;
            modules.items[unique] = candidate;
            unique += 1;
        }
        modules.shrinkRetainingCapacity(unique);
        std.mem.sort(structures.FileImport, imports.items, {}, struct {
            fn lessThan(_: void, left: structures.FileImport, right: structures.FileImport) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        const owned_modules = try modules.toOwnedSlice(ctx.allocator());
        errdefer ctx.allocator().free(owned_modules);
        return .{ .modules = owned_modules, .imports = try imports.toOwnedSlice(ctx.allocator()) };
    }
};

const ExportVisit = struct { module: structures.ModuleId, name: []const u8 };
const ImportOrigin = struct { file_id: structures.FileId, span: structures.SourceSpan };
const prelude_module_path = standard_library.File.prelude.modulePath();

fn explicitlyImportsPrelude(entries: []const structures.ImportDeclaration) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path.spelling, prelude_module_path)) return true;
    }
    return false;
}

fn rejectImport(ctx: anytype, origin: ImportOrigin, kind: structures.Diagnostic.Kind) !void {
    try ctx.emit(structures.Diagnostic, .{ .file_id = origin.file_id, .span = origin.span, .kind = kind });
}

fn resolveImportedModule(ctx: anytype, origin: ImportOrigin, path: []const u8) !?structures.ModuleId {
    const module = try ctx.intern(ModulePaths, .{ .path = path });
    const catalog = (try ctx.input(ModuleCatalog, {})).*;
    if (std.mem.indexOfScalar(structures.ModuleId, catalog, module) == null) {
        try rejectImport(ctx, origin, .unknown_module);
        return null;
    }
    return module;
}

fn mergeImportTarget(existing: *structures.ImportTarget, candidate: structures.ImportTarget) bool {
    switch (existing.*) {
        .declaration => |item| return candidate == .declaration and candidate.declaration == item,
        .namespace => |*namespace| {
            if (candidate != .namespace or candidate.namespace.module != namespace.module) return false;
            namespace.members_visible = namespace.members_visible or candidate.namespace.members_visible;
            return true;
        },
    }
}

fn mergeExport(ctx: anytype, origin: ImportOrigin, result: *?structures.ImportTarget, candidate: structures.ImportTarget, has_declaration: bool) !bool {
    if (has_declaration or (result.* != null and !mergeImportTarget(&result.*.?, candidate))) {
        try rejectImport(ctx, origin, .import_conflict);
        return false;
    }
    if (result.* == null) result.* = candidate;
    return true;
}

fn resolveModuleExport(
    ctx: anytype,
    importer: structures.ModuleId,
    target: structures.ModuleId,
    name: []const u8,
    origin: ImportOrigin,
    visited: *std.ArrayList(ExportVisit),
) anyerror!?structures.ImportTarget {
    return resolveModuleExportInternal(ctx, importer, target, name, origin, visited, true);
}

fn resolveModuleExportInternal(
    ctx: anytype,
    importer: structures.ModuleId,
    target: structures.ModuleId,
    name: []const u8,
    origin: ImportOrigin,
    visited: *std.ArrayList(ExportVisit),
    validate_module_catalog: bool,
) anyerror!?structures.ImportTarget {
    for (visited.items) |seen| {
        if (seen.module != target or !std.mem.eql(u8, seen.name, name)) continue;
        try rejectImport(ctx, origin, .declaration_cycle);
        return null;
    }
    try visited.append(ctx.allocator(), .{ .module = target, .name = name });
    defer _ = visited.pop();
    const declarations = (try ctx.get(ModuleDeclarations, target)).* orelse return null;
    const declaration = declarations.resolveEntry(name);
    var result: ?structures.ImportTarget = null;
    if (declaration) |entry| result = .{ .declaration = entry.item_id };
    const members = (try ctx.input(ModuleMembers, target)).*;
    for (members) |file_id| {
        const collected = (try ctx.get(CollectFileImports, file_id)).* orelse return null;
        for (collected.entries) |entry| {
            if (!entry.is_public) continue;
            if (entry.selective) |items| {
                for (items) |item| {
                    if (!std.mem.eql(u8, item.bound.spelling, name)) continue;
                    const path_origin: ImportOrigin = .{ .file_id = file_id, .span = entry.path.span };
                    const reexported = if (validate_module_catalog)
                        (try resolveImportedModule(ctx, path_origin, entry.path.spelling)) orelse return null
                    else
                        try ctx.intern(ModulePaths, .{ .path = entry.path.spelling });
                    const candidate = (try resolveModuleExportInternal(ctx, target, reexported, item.original.spelling, origin, visited, validate_module_catalog)) orelse return null;
                    if (!try mergeExport(ctx, origin, &result, candidate, declaration != null)) return null;
                }
                continue;
            }
            const exported_name = if (entry.alias) |alias| alias.spelling else entry.path.spelling;
            const leaf = std.mem.lastIndexOfScalar(u8, exported_name, '.');
            const bound_name = if (leaf) |dot| exported_name[dot + 1 ..] else exported_name;
            if (!std.mem.eql(u8, bound_name, name)) continue;
            const path_origin: ImportOrigin = .{ .file_id = file_id, .span = entry.path.span };
            const reexported = if (validate_module_catalog)
                (try resolveImportedModule(ctx, path_origin, entry.path.spelling)) orelse return null
            else
                try ctx.intern(ModulePaths, .{ .path = entry.path.spelling });
            if (!try mergeExport(ctx, origin, &result, .{ .namespace = .{ .module = reexported } }, declaration != null)) return null;
        }
    }
    if (declaration) |entry| {
        if (importer != target and !entry.is_public) {
            try rejectImport(ctx, origin, .private_access);
            return null;
        }
    }
    if (result) |exported| return exported;
    try rejectImport(ctx, origin, .unknown_imported_name);
    return null;
}

fn bindImport(
    ctx: anytype,
    origin: ImportOrigin,
    declarations: structures.ModuleScope,
    name: []const u8,
    target: structures.ImportTarget,
    reexport: bool,
    imports: *std.ArrayList(structures.FileImport),
    bound: *std.StringHashMap(u32),
) anyerror!bool {
    if (bound.get(name)) |index| {
        if (!mergeImportTarget(&imports.items[index].target, target)) {
            try rejectImport(ctx, origin, .import_conflict);
            return false;
        }
        imports.items[index].reexport = imports.items[index].reexport or reexport;
        return true;
    }
    if (declarations.resolve(name) != null) {
        try rejectImport(ctx, origin, .import_conflict);
        return false;
    }
    try imports.ensureUnusedCapacity(ctx.allocator(), 1);
    try bound.ensureUnusedCapacity(1);
    const owned = try ctx.allocator().dupe(u8, name);
    const index: u32 = @intCast(imports.items.len);
    imports.appendAssumeCapacity(.{ .name = owned, .target = target, .reexport = reexport });
    bound.putAssumeCapacity(owned, index);
    return true;
}

pub const ResolvePreludeImports = struct {
    pub const Input = void;
    pub const Output = ?structures.FileImports;

    pub fn run(ctx: anytype, _: Input) anyerror!Output {
        const prelude = (try ctx.input(StandardPreludeModule, {})).*;
        const importer = try ctx.intern(ModulePaths, .{ .path = "$default-prelude" });
        const members = (try ctx.input(ModuleMembers, prelude)).*;
        std.debug.assert(members.len != 0);

        var imports: std.ArrayList(structures.FileImport) = .empty;
        defer {
            for (imports.items) |binding| ctx.allocator().free(binding.name);
            imports.deinit(ctx.allocator());
        }
        var names = std.StringHashMap(void).init(ctx.allocator());
        defer names.deinit();
        const prelude_declarations = (try ctx.get(ModuleDeclarations, prelude)).* orelse return null;
        for (prelude_declarations.entries) |entry| {
            if (entry.is_public and !std.mem.startsWith(u8, entry.name, "$converter")) try names.put(entry.name, {});
        }
        for (members) |prelude_file| {
            const collected = (try ctx.get(CollectFileImports, prelude_file)).* orelse return null;
            for (collected.entries) |entry| {
                if (!entry.is_public) continue;
                if (entry.selective) |selections| {
                    for (selections) |selection| try names.put(selection.bound.spelling, {});
                    continue;
                }
                const exported_name = if (entry.alias) |alias| alias.spelling else entry.path.spelling;
                const leaf = std.mem.lastIndexOfScalar(u8, exported_name, '.');
                try names.put(if (leaf) |dot| exported_name[dot + 1 ..] else exported_name, {});
            }
        }

        var iterator = names.keyIterator();
        while (iterator.next()) |name_ptr| {
            const name = name_ptr.*;
            var visited: std.ArrayList(ExportVisit) = .empty;
            defer visited.deinit(ctx.allocator());
            const origin: ImportOrigin = .{ .file_id = members[0], .span = .{ .start = 0, .end = 0 } };
            const exported = (try resolveModuleExportInternal(ctx, importer, prelude, name, origin, &visited, false)) orelse return null;
            const owned = try ctx.allocator().dupe(u8, name);
            errdefer ctx.allocator().free(owned);
            try imports.append(ctx.allocator(), .{ .name = owned, .target = exported, .reexport = false });
        }
        std.mem.sort(structures.FileImport, imports.items, {}, struct {
            fn lessThan(_: void, left: structures.FileImport, right: structures.FileImport) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        const modules = try ctx.allocator().alloc(structures.ModuleId, 0);
        errdefer ctx.allocator().free(modules);
        return .{ .modules = modules, .imports = try imports.toOwnedSlice(ctx.allocator()) };
    }
};

fn resolveImportStatement(
    ctx: anytype,
    file_id: structures.FileId,
    module: structures.ModuleId,
    declarations: structures.ModuleScope,
    entry: structures.ImportDeclaration,
    modules: *std.ArrayList(structures.ModuleId),
    imports: *std.ArrayList(structures.FileImport),
    bound: *std.StringHashMap(u32),
) anyerror!bool {
    const path_origin: ImportOrigin = .{ .file_id = file_id, .span = entry.path.span };
    const target_module = (try resolveImportedModule(ctx, path_origin, entry.path.spelling)) orelse return false;
    if (entry.selective) |items| {
        for (items) |item| {
            var visited: std.ArrayList(ExportVisit) = .empty;
            defer visited.deinit(ctx.allocator());
            const origin: ImportOrigin = .{ .file_id = file_id, .span = item.original.span };
            const exported = (try resolveModuleExport(ctx, module, target_module, item.original.spelling, origin, &visited)) orelse return false;
            if (!try bindImport(ctx, .{ .file_id = file_id, .span = item.bound.span }, declarations, item.bound.spelling, exported, entry.is_public, imports, bound)) return false;
        }
        return true;
    }
    if (entry.alias) |alias| {
        return bindImport(ctx, .{ .file_id = file_id, .span = alias.span }, declarations, alias.spelling, .{ .namespace = .{ .module = target_module } }, entry.is_public, imports, bound);
    }
    try modules.append(ctx.allocator(), target_module);
    const root_name = std.mem.sliceTo(entry.path.spelling, '.');
    const top = try ctx.intern(ModulePaths, .{ .path = root_name });
    const direct = root_name.len == entry.path.spelling.len;
    const origin: ImportOrigin = .{ .file_id = file_id, .span = .{ .start = entry.path.span.start, .end = entry.path.span.start + root_name.len } };
    return bindImport(ctx, origin, declarations, root_name, .{ .namespace = .{ .module = top, .members_visible = direct } }, entry.is_public and direct, imports, bound);
}

pub const IndexModuleItems = struct {
    pub const disk_boundary = true;
    pub const Input = structures.ModuleId;
    pub const Output = ?structures.ModuleItemIndex;

    pub fn run(ctx: anytype, module: Input) anyerror!Output {
        // Validate the shared namespace before publishing unique locations.
        _ = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
        const members = (try ctx.input(ModuleMembers, module)).*;
        var entries: std.ArrayList(structures.ModuleItemIndex.Entry) = .empty;
        defer entries.deinit(ctx.allocator());
        for (members) |file_id| {
            const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
            for (index.entries.keys(), index.entries.values()) |item, declaration| {
                const identity = try ctx.lookupInterned(ItemLocations, item);
                if (identity.kind == .top_level_entry) continue;
                try entries.append(ctx.allocator(), .{ .item = item, .location = .{ .file_id = file_id, .declaration = declaration } });
            }
        }
        std.mem.sort(structures.ModuleItemIndex.Entry, entries.items, {}, struct {
            fn lessThan(_: void, left: structures.ModuleItemIndex.Entry, right: structures.ModuleItemIndex.Entry) bool {
                return @backingInt(left.item) < @backingInt(right.item);
            }
        }.lessThan);
        const index: structures.ModuleItemIndex = .{ .entries = entries.items };
        for (entries.items, 0..) |entry, position| {
            if (position != 0 and entries.items[position - 1].item == entry.item)
                return rejectItem(ctx, entry.location, .duplicate_struct_member);
            const loc = try ctx.lookupInterned(ItemLocations, entry.item);
            if (loc.owner) |owner| {
                if (index.resolve(owner) == null)
                    return rejectItem(ctx, entry.location, .invalid_namespace_owner);
            }
        }
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }

    fn rejectItem(ctx: anytype, location: structures.ResolvedItem, kind: structures.Diagnostic.Kind) !Output {
        const parsed = (try ctx.get(ParseFile, location.file_id)).* orelse return null;
        try typing.emitSemanticIssue(ctx, location.file_id, .{
            .span = nodeSpan(&parsed, @fromBackingInt(@intCast(location.declaration))),
            .kind = kind,
        });
        return null;
    }
};

pub const ResolveItem = struct {
    pub const disk_boundary = true;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.ResolvedItem;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const identity = try ctx.lookupInterned(ItemLocations, item_id);
        switch (identity.origin) {
            .entry => |file_id| {
                const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
                const declaration = index.resolve(item_id) orelse return null;
                return .{ .file_id = file_id, .declaration = declaration };
            },
            .module => |module| {
                const index = (try ctx.get(IndexModuleItems, module)).* orelse return null;
                return index.resolve(item_id);
            },
        }
    }
};

const ExternalSymbol = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?standard_library.External;

    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item);
        if (loc.kind != .function or loc.owner != null) return null;
        const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        if (!semantic.isExternalFunction(&parsed, resolved.declaration)) return null;
        const module = switch (loc.origin) {
            .module => |module_id| module_id,
            .entry => return null,
        };
        const symbol = std.meta.stringToEnum(standard_library.External, loc.name) orelse return null;
        const file = symbol.file();
        const path = (try ctx.lookupInterned(ModulePaths, module)).path;
        if (!std.mem.eql(u8, path, file.modulePath())) return null;
        const registered = (try standardFile(ctx, file)) orelse return null;
        return if (registered == resolved.file_id) symbol else null;
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
        if (semantic.isExternalFunction(&parsed, resolved.declaration) and (try ctx.get(ExternalSymbol, item_id)).* == null) {
            try ctx.emit(structures.Diagnostic, .{
                .file_id = resolved.file_id,
                .span = nodeSpan(&parsed, @fromBackingInt(@intCast(resolved.declaration))),
                .kind = .unsupported_external_declaration,
            });
            return null;
        }
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

// A namespace member inherits its lexical owners' static arguments before
// appending its own. Keeping the two counts separate preserves specialization
// through nested namespaces without creating new declaration identities.
pub const SpecializationArity = struct {
    pub const Input = structures.ItemId;
    pub const Counts = struct {
        inherited: usize,
        own: usize,
        pub fn total(self: @This()) usize {
            return self.inherited + self.own;
        }
    };
    pub const Output = ?Counts;

    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item);
        var counts: Counts = .{ .inherited = 0, .own = 0 };
        if (loc.owner) |owner| {
            const parent = (try ctx.get(SpecializationArity, owner)).* orelse return null;
            counts.inherited = parent.total();
        }
        if (loc.kind == .function) {
            const shape = (try ctx.get(FunctionShape, item)).* orelse return null;
            for (shape.parameters) |parameter| {
                if (parameter.mode == .static) counts.own += 1;
            }
        }
        return counts;
    }
};

fn enclosingInstance(ctx: anytype, instance: structures.InstanceId, inferring: bool) !?structures.InstanceId {
    const loc = try ctx.lookupInterned(ItemLocations, instance.item);
    const owner = loc.owner orelse return null;
    const arity = (try ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
    const arguments = if (instance.specialization) |tuple| (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
    if (arguments.len != (if (inferring) arity.inherited else arity.total())) return error.Unavailable;
    return .{
        .item = owner,
        .specialization = if (arity.inherited == 0) null else if (inferring)
            instance.specialization
        else
            try ctx.intern(CompileTimeValueTuples, .{ .values = arguments[0..arity.inherited] }),
    };
}

pub const FunctionInstanceSignature = struct {
    pub const disk_boundary = true;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, instance.item);
        if (loc.kind != .function) return null;
        _ = (try ctx.get(FunctionShape, instance.item)).* orelse return null;
        const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const specialization = if (instance.specialization) |tuple| (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
        const arity = (try ctx.get(SpecializationArity, instance.item)).* orelse return null;
        // Instances can outlive the source shape that created them.
        if (specialization.len != arity.total()) return null;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
        const result = semantic.analyzeFunctionInstanceSignature(&parsed, source, resolved.declaration, specialization[arity.inherited..], type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |signature| try validateDemandedSignature(ctx, instance, resolved, &parsed, source, type_interner, signature),
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

pub const FunctionSignature = struct {
    pub const disk_boundary = true;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .function) return null;
        _ = (try ctx.get(FunctionShape, item_id)).* orelse return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
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
            .success => |signature| try validateDemandedSignature(ctx, .{ .item = item_id }, resolved, &parsed, source, type_interner, signature),
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

fn validateDemandedSignature(
    ctx: anytype,
    instance: structures.InstanceId,
    resolved: structures.ResolvedItem,
    parsed: *const structures.Ast,
    source: []const u8,
    type_interner: anytype,
    result: structures.FunctionSignature,
) !?structures.FunctionSignature {
    var signature = result;
    var transferred = false;
    defer if (!transferred) signature.deinit(ctx.allocator());
    if (!try validOperationSignature(type_interner, instance.item, signature)) {
        try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, @fromBackingInt(@intCast(resolved.declaration))), .kind = .invalid_operation_signature });
        return null;
    }
    if (!try validateWhereConditions(ctx, instance, resolved, parsed, source, type_interner)) return null;
    const validated = try validateExternalSignature(ctx, instance.item, resolved.file_id, parsed, resolved.declaration, signature) orelse return null;
    const library_issue = librarySignatureIssue(type_interner, instance.item, validated) catch |err| switch (err) {
        error.Unavailable => return null,
        else => return err,
    };
    if (library_issue) |kind| {
        try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, @fromBackingInt(@intCast(resolved.declaration))), .kind = kind });
        return null;
    }
    transferred = true;
    return validated;
}

fn validOperationSignature(types: anytype, item: structures.ItemId, signature: structures.FunctionSignature) !bool {
    const location = try types.ctx.lookupInterned(ItemLocations, item);
    const name = location.name;
    const arithmetic = std.mem.eql(u8, name, "+") or std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "/");
    const comparison = std.mem.eql(u8, name, "==") or std.mem.eql(u8, name, "<>") or std.mem.eql(u8, name, "<") or std.mem.eql(u8, name, ">") or std.mem.eql(u8, name, "<=") or std.mem.eql(u8, name, ">=");
    const negation = location.owner != null and std.mem.eql(u8, name, "neg");
    const logical_not = std.mem.eql(u8, name, "not");
    const index_read = std.mem.eql(u8, name, "[]");
    const index_write = std.mem.eql(u8, name, "[]=");
    if (!arithmetic and !comparison and !negation and !logical_not and !index_read and !index_write) return true;
    if (location.owner == null) return false;
    const count: usize = if (negation or logical_not) 1 else if (index_write) 3 else 2;
    if (signature.parameters.len != count) return false;
    const receiver = signature.parameters[0];
    const association = (try types.typeNamespace(receiver.type_id)) orelse return false;
    if (structOwnerItem(association.query_key) != location.owner.?) return false;
    if (receiver.mode != (if (index_write) structures.ParameterMode.mut else .imm)) return false;
    if (index_read or index_write) {
        if (signature.parameters[1].mode != .imm or signature.parameters[1].type_id != .int) return false;
        if (index_write and (signature.parameters[2].mode != .init or signature.return_type != .unit)) return false;
        return true;
    }
    if (signature.is_fallible) return false;
    if (count == 2 and (signature.parameters[1].mode != .imm or signature.parameters[1].type_id != receiver.type_id)) return false;
    return signature.return_type == (if (comparison or logical_not) structures.TypeId.bool else receiver.type_id);
}

fn librarySignatureIssue(types: anytype, item: structures.ItemId, signature: structures.FunctionSignature) !?structures.Diagnostic.Kind {
    const behavior = try types.callBehavior(item);
    switch (behavior) {
        .box_new => {
            if (signature.parameters.len != 1) return null;
            const element = signature.parameters[0].type_id;
            const capabilities = (try types.facts().ownershipCapabilities(element)) orelse return error.Unavailable;
            if (capabilities.requires_explicit_drop) return .{ .box_requires_automatic_drop = element };
        },
        .box_value => {
            const capabilities = (try types.facts().ownershipCapabilities(signature.return_type)) orelse return error.Unavailable;
            if (!capabilities.isDirectlyMovable())
                return .{ .box_extraction_requires_direct_move = signature.return_type };
        },
        .buffer_new => {
            const element = (try types.bufferElement(signature.return_type)) orelse return error.Unavailable;
            if (try types.containsBorrow(element)) return .{ .buffer_cannot_store_borrow_element = element };
        },
        .reference_write => return typing.referenceReplacementIssue(types, signature.parameters[1].type_id),
        .buffer_append, .buffer_reserve => {
            const element = (try types.bufferElement(signature.parameters[0].type_id)) orelse return error.Unavailable;
            const capabilities = (try types.facts().ownershipCapabilities(element)) orelse return error.Unavailable;
            if (capabilities.requires_explicit_drop) return .{ .buffer_requires_automatic_drop = element };
            if (!capabilities.isDirectlyMovable())
                return .{ .buffer_requires_direct_move = element };
        },
        else => {},
    }
    return null;
}

fn validateWhereConditions(
    ctx: anytype,
    instance: structures.InstanceId,
    resolved: structures.ResolvedItem,
    parsed: *const structures.Ast,
    source: []const u8,
    type_interner: anytype,
) !bool {
    for (semantic.functionWhereConditions(parsed, resolved.declaration)) |condition| {
        const result = semantic.buildUnresolvedWhereCondition(parsed, source, condition, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return false,
            else => return err,
        };
        var unresolved = switch (result) {
            .success => |body| body,
            .unsupported => |issue| {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                return false;
            },
        };
        defer unresolved.deinit(ctx.allocator());
        var body = (try typing.resolveAndTypeBody(ctx, instance, resolved.file_id, &.{}, .unit, true, .{ .publish_instruction_spans = true, .allow_type_values = true }, type_interner, unresolved)) orelse return false;
        defer body.deinit(ctx.allocator());
        var arguments: [0]comptime_interpreter.Value = .{};
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = instance.item };
        switch (try comptime_interpreter.execute(&body, &arguments, &executor, ctx.allocator())) {
            .returned => {},
            .failure => {
                try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, condition), .kind = .where_condition_failed });
                return false;
            },
            .exit => |status| {
                try ctx.emit(structures.CompilerControl, .{ .exit = status });
                return false;
            },
            .execution_error => |execution_error| {
                try emitComptimeExecutionIssue(ctx, instance.item, condition, execution_error);
                return false;
            },
            .reported_error, .unavailable => return false,
        }
    }
    return true;
}

fn validateExternalSignature(ctx: anytype, item: structures.ItemId, file_id: structures.FileId, parsed: *const structures.Ast, declaration: u32, signature: structures.FunctionSignature) !?structures.FunctionSignature {
    if (!semantic.isExternalFunction(parsed, declaration)) return signature;
    const symbol = (try ctx.get(ExternalSymbol, item)).* orelse return null;
    const valid = switch (symbol) {
        .copy_value, .move_value => !signature.is_fallible and signature.parameters.len == 1 and
            signature.parameters[0].type_id == signature.return_type and
            signature.parameters[0].mode == (if (symbol == .copy_value) structures.ParameterMode.imm else .deinit),
        .array_filled => try validArrayFilledSignature(ctx, signature),
        .initialize_collection => try validCollectionInitializerSignature(ctx, signature),
        .array_from => blk: {
            if (signature.is_fallible or signature.parameters.len != 1 or signature.parameters[0].mode != .init) break :blk false;
            const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
            const shape = (try analysis.collectionLiteralType(signature.parameters[0].type_id)) orelse break :blk false;
            const array = (try lookupArrayType(ctx, signature.return_type)) orelse break :blk false;
            break :blk std.meta.eql(shape, array);
        },
        .literal_byte => signature.parameters.len == 0 and signature.return_type == .byte and !signature.is_fallible,
        .array_borrow, .array_borrow_mut => try validArrayBorrowSignature(ctx, symbol, signature),
        .exit => !signature.is_fallible and signature.return_type == .never and
            signature.parameters.len == 1 and signature.parameters[0].mode == .imm and signature.parameters[0].type_id == .int,
        .allocate_host_storage, .deallocate_host_storage => blk: {
            const memory_module = try ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_host.modulePath() });
            const declarations = (try ctx.get(ModuleDeclarations, memory_module)).* orelse break :blk false;
            const storage_type = (try hostStorageType(ctx, declarations)) orelse break :blk false;
            break :blk switch (symbol) {
                .allocate_host_storage => signature.is_fallible and signature.return_type == storage_type and
                    signature.parameters.len == 1 and signature.parameters[0].mode == .imm and signature.parameters[0].type_id == .int,
                .deallocate_host_storage => !signature.is_fallible and signature.return_type == .unit and
                    signature.parameters.len == 1 and signature.parameters[0].mode == .deinit and signature.parameters[0].type_id == storage_type,
                else => unreachable,
            };
        },
        .allocate, .deallocate => blk: {
            if (signature.parameters.len != 1) break :blk false;
            const type_id = if (symbol == .allocate) signature.return_type else signature.parameters[0].type_id;
            if (try allocationElementType(ctx, type_id) == null) break :blk false;
            break :blk if (symbol == .allocate)
                signature.is_fallible and signature.parameters[0].mode == .imm and signature.parameters[0].type_id == .int
            else
                !signature.is_fallible and signature.return_type == .unit and signature.parameters[0].mode == .deinit;
        },
        .allocation_count => !signature.is_fallible and signature.return_type == .int and signature.parameters.len == 1 and
            signature.parameters[0].mode == .imm and (try allocationElementType(ctx, signature.parameters[0].type_id)) != null,
        .unsafe_initialize, .unsafe_take, .unsafe_destroy, .unsafe_borrow_initialized, .unsafe_borrow_element, .unsafe_borrow_mut_element => blk: {
            if (signature.is_fallible != (symbol == .unsafe_initialize)) break :blk false;
            if (signature.parameters.len != (if (symbol == .unsafe_initialize) @as(usize, 3) else 2)) break :blk false;
            const allocation = signature.parameters[0];
            if (allocation.mode != (if (symbol == .unsafe_borrow_initialized or symbol == .unsafe_borrow_element or symbol == .unsafe_borrow_mut_element) structures.ParameterMode.imm else .mut)) break :blk false;
            const element_type = (try allocationElementType(ctx, allocation.type_id)) orelse break :blk false;
            if (symbol == .unsafe_take) {
                const capabilities = (try ctx.get(OwnershipCapabilities, element_type)).* orelse break :blk false;
                if (!capabilities.isDirectlyMovable()) break :blk false;
            }
            if (signature.parameters[1].mode != .imm or signature.parameters[1].type_id != .int) break :blk false;
            break :blk switch (symbol) {
                .unsafe_initialize => signature.return_type == .unit and signature.parameters[2].mode == .init and signature.parameters[2].type_id == element_type,
                .unsafe_take, .unsafe_borrow_initialized => signature.return_type == element_type,
                .unsafe_borrow_element, .unsafe_borrow_mut_element => if (try borrowAccessType(ctx, signature.return_type)) |borrow|
                    borrow.element_type == element_type and borrow.writable == (symbol == .unsafe_borrow_mut_element)
                else
                    false,
                .unsafe_destroy => signature.return_type == .unit,
                else => unreachable,
            };
        },
        .borrow_box, .borrow_mut_box, .borrow_local => blk: {
            if (signature.is_fallible or signature.parameters.len != 1) break :blk false;
            const borrow = (try borrowAccessType(ctx, signature.return_type)) orelse break :blk false;
            if (symbol == .borrow_local) {
                break :blk signature.parameters[0].mode == .imm and !borrow.writable and borrow.element_type == signature.parameters[0].type_id;
            }
            const element_type = (try boxElementType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            break :blk borrow.element_type == element_type and
                signature.parameters[0].mode == (if (symbol == .borrow_box) structures.ParameterMode.imm else .mut) and
                borrow.writable == (symbol == .borrow_mut_box);
        },
        .read, .write => blk: {
            if (signature.is_fallible or signature.parameters.len != (if (symbol == .read) @as(usize, 1) else 2) or
                signature.parameters[0].mode != .imm) break :blk false;
            const borrow = (try borrowAccessType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            if (symbol == .read) break :blk signature.return_type == borrow.element_type;
            break :blk borrow.writable and signature.return_type == .unit and
                signature.parameters[1].mode == .@"var" and signature.parameters[1].type_id == borrow.element_type;
        },
        .attenuate_ref => blk: {
            if (signature.is_fallible or signature.parameters.len != 1 or signature.parameters[0].mode != .imm) break :blk false;
            const source = (try borrowAccessType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            const target = (try borrowAccessType(ctx, signature.return_type)) orelse break :blk false;
            break :blk source.writable and !target.writable and source.element_type == target.element_type;
        },
        .unsafe_own_box => blk: {
            if (signature.is_fallible or signature.parameters.len != 1 or signature.parameters[0].mode != .deinit) break :blk false;
            const element_type = (try allocationElementType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            break :blk (try boxElementType(ctx, signature.return_type)) == element_type;
        },
        .unsafe_take_box, .unsafe_destroy_box, .deallocate_box => blk: {
            if (signature.is_fallible or signature.parameters.len != 1) break :blk false;
            const element_type = (try boxElementType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            if (symbol == .deallocate_box) break :blk signature.parameters[0].mode == .deinit and signature.return_type == .unit;
            if (symbol == .unsafe_destroy_box) break :blk signature.parameters[0].mode == .imm and signature.return_type == .unit;
            const capabilities = (try ctx.get(OwnershipCapabilities, element_type)).* orelse break :blk false;
            break :blk signature.parameters[0].mode == .mut and signature.return_type == element_type and
                capabilities.isDirectlyMovable();
        },
    };
    if (valid) return switch (symbol) {
        .copy_value, .move_value, .array_filled => validateOwnershipSignature(ctx, symbol, signature, file_id, nodeSpan(parsed, @fromBackingInt(@intCast(declaration)))),
        else => signature,
    };
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = nodeSpan(parsed, @fromBackingInt(@intCast(declaration))),
        .kind = .invalid_external_signature,
    });
    return null;
}

fn validArrayFilledSignature(ctx: anytype, signature: structures.FunctionSignature) !bool {
    if (signature.is_fallible or signature.parameters.len != 1 or signature.parameters[0].mode != .imm) return false;
    const array = (try lookupArrayType(ctx, signature.return_type)) orelse return false;
    return signature.parameters[0].type_id == array.element_type;
}

fn validArrayBorrowSignature(ctx: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    if (signature.is_fallible or signature.parameters.len != 2) return false;
    const writable = symbol == .array_borrow_mut;
    if (signature.parameters[0].mode != (if (writable) structures.ParameterMode.mut else .imm) or
        signature.parameters[1].mode != .imm or signature.parameters[1].type_id != .int) return false;
    const array = (try lookupArrayType(ctx, signature.parameters[0].type_id)) orelse return false;
    const borrow = (try borrowAccessType(ctx, signature.return_type)) orelse return false;
    return borrow.element_type == array.element_type and borrow.writable == writable;
}

fn validateOwnershipSignature(ctx: anytype, symbol: standard_library.External, signature: structures.FunctionSignature, file_id: structures.FileId, span: structures.SourceSpan) !?structures.FunctionSignature {
    const type_id = if (symbol == .array_filled) signature.parameters[0].type_id else signature.return_type;
    const capabilities = (try ctx.get(OwnershipCapabilities, type_id)).* orelse return null;
    switch (symbol) {
        .copy_value, .array_filled => if (capabilities.copy != .none) return signature,
        .move_value => if (capabilities.move != .none) return signature,
        else => unreachable,
    }
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = span,
        .kind = if (symbol == .copy_value or symbol == .array_filled)
            .{ .type_not_copyable = .{ .type_id = type_id, .is_movable = capabilities.move != .none } }
        else
            .{ .type_not_movable = type_id },
    });
    return null;
}

fn hostStorageType(ctx: anytype, declarations: structures.ModuleScope) !?structures.TypeId {
    const storage_item = declarations.resolveStatic(@tagName(standard_library.Structure.HostStorage)) orelse return null;
    const storage_file = (try ctx.get(ResolveItem, storage_item)).* orelse return null;
    const registered = (try standardFile(ctx, .memory_host)) orelse return null;
    if (storage_file.file_id != registered) return null;
    const definition = (try ctx.get(StructDefinition, storage_item)).* orelse return null;
    if (definition.fields.len != 3 or
        definition.ownership.drop == null or definition.ownership.drop.?.capability != .explicit or
        definition.ownership.move != null or definition.ownership.copy != null)
    {
        return null;
    }
    for (definition.fields, [_][]const u8{ "address_low", "address_high", "byte_size" }) |field, name| {
        if (!std.mem.eql(u8, field.name, name) or field.type_id != .int) return null;
    }
    return try internStructType(ctx, storage_item);
}

const StandardMemoryInstance = struct {
    generated: structures.GeneratedStructIdentity,
    declarations: structures.ModuleScope,
    arguments: []const structures.CompileTimeValueId,
    element_type: structures.TypeId,
};

fn validCollectionInitializerSignature(ctx: anytype, signature: structures.FunctionSignature) !bool {
    if (signature.is_fallible or signature.return_type != .unit or signature.parameters.len != 2) return false;
    if (signature.parameters[0].mode != .mut or signature.parameters[1].mode != .init) return false;
    const element = (try allocationElementType(ctx, signature.parameters[0].type_id)) orelse return false;
    const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
    const collection = (try analysis.collectionLiteralType(signature.parameters[1].type_id)) orelse return false;
    return collection.element_type == element;
}

fn standardMemoryInstance(ctx: anytype, type_id: structures.TypeId, structure: standard_library.Structure) !?StandardMemoryInstance {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return null;
    const generated = switch (data.*) {
        .structure => |identity| switch (identity) {
            .generated => |value| value,
            .declared => return null,
        },
        .variant, .callable, .array => return null,
    };
    const file: standard_library.File = if (structure == .collection_literal) .array else .memory_allocation;
    const registered = (try standardFile(ctx, file)) orelse return null;
    const memory_module = try ctx.intern(ModulePaths, .{ .path = file.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, memory_module)).* orelse return null;
    const item = declarations.resolveFunction(@tagName(structure)) orelse return null;
    if (generated.owner.item != item) return null;
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    if (resolved.file_id != registered) return null;
    const tuple = generated.owner.specialization orelse return null;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != @as(usize, if (structure == .Ref or structure == .collection_literal) 2 else 1)) return null;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const element_type = switch (element) {
        .type => |value| value,
        .runtime => return null,
    };
    return .{ .generated = generated, .declarations = declarations, .arguments = arguments, .element_type = element_type };
}

fn allocationElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const instance = (try standardMemoryInstance(ctx, type_id, .Allocation)) orelse return null;
    const element_type = instance.element_type;
    if (element_type == .type) return null;
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (definition.fields.len != 2 or
        definition.ownership.move != null or definition.ownership.copy != null or
        definition.ownership.drop == null or definition.ownership.drop.?.capability != .explicit)
    {
        return null;
    }
    const storage_type = (try hostStorageType(ctx, instance.declarations)) orelse return null;
    if (!std.mem.eql(u8, definition.fields[0].name, "storage") or
        definition.fields[0].type_id != storage_type or
        !std.mem.eql(u8, definition.fields[1].name, "count") or
        definition.fields[1].type_id != .int)
    {
        return null;
    }
    return element_type;
}

fn boxElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const instance = (try standardMemoryInstance(ctx, type_id, .Box)) orelse return null;
    const element_type = instance.element_type;
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (definition.fields.len != 1 or
        definition.ownership.move != null or definition.ownership.copy != null or definition.ownership.drop == null or
        definition.ownership.drop.?.capability != .custom or
        !std.mem.eql(u8, definition.fields[0].name, "allocation") or
        (try allocationElementType(ctx, definition.fields[0].type_id)) != element_type)
    {
        return null;
    }
    return element_type;
}

const BorrowAccessType = struct { element_type: structures.TypeId, writable: bool };

fn borrowElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    return if (try borrowAccessType(ctx, type_id)) |borrow| borrow.element_type else null;
}

fn borrowAccessType(ctx: anytype, type_id: structures.TypeId) !?BorrowAccessType {
    const instance = (try standardMemoryInstance(ctx, type_id, .Ref)) orelse return null;
    const access = (try ctx.lookupInterned(CompileTimeValues, instance.arguments[1])).*;
    const runtime = switch (access) {
        .runtime => |value| value,
        .type => return null,
    };
    if (runtime.type_id != .bool) return null;
    const writable = switch (runtime.value) {
        .bool => |value| value,
        else => return null,
    };
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (definition.fields.len != 2 or
        definition.ownership.move != null or definition.ownership.copy == null or
        definition.ownership.copy.?.capability != .trivial or definition.ownership.drop != null or
        !std.mem.eql(u8, definition.fields[0].name, "address_low") or definition.fields[0].type_id != .int or
        !std.mem.eql(u8, definition.fields[1].name, "address_high") or definition.fields[1].type_id != .int)
    {
        return null;
    }
    return .{ .element_type = instance.element_type, .writable = writable };
}

pub const ResolveStatic = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.CompileTimeValueId;
    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        return (try ctx.get(ResolveStaticInstance, .{ .item = item })).*;
    }
};

pub const ResolveStaticInstance = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.CompileTimeValueId;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const item_id = instance.item;
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .static and loc.kind != .structure) return null;
        if (instance.specialization) |tuple| {
            const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
            const arity = (try ctx.get(SpecializationArity, item_id)).* orelse return null;
            // A cached reference may survive a change to its enclosing factory.
            if (arguments.len != arity.total()) return null;
        }
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        if (loc.kind == .structure and instance.specialization == null)
            return try ctx.intern(CompileTimeValues, .{ .type = try internStructType(ctx, item_id) });
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        if (loc.kind == .structure) {
            const initializer = parsed.nodes[resolved.declaration].data.node_node.b;
            const type_id = try internGeneratedStructType(ctx, .{ .owner = instance, .node_offset = @as(i64, initializer.index()) - @as(i64, resolved.declaration) });
            return try ctx.intern(CompileTimeValues, .{ .type = type_id });
        }
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
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
            .owner = instance,
            .node = initializer,
            .expected_type = runtime_annotation,
        };
        const outcome = (try ctx.get(ExecuteComptimeThunk, site)).* orelse return null;
        const value_id = switch (outcome) {
            .returned => |returned| returned,
            .failure => return null,
            .exit => return null,
        };
        const expected_type = runtime_annotation orelse return value_id;
        var value = (try ctx.lookupInterned(CompileTimeValues, value_id)).*;
        switch (value) {
            .type => {
                try typing.emitSemanticIssue(ctx, resolved.file_id, .{
                    .span = nodeSpan(&parsed, initializer),
                    .kind = .type_value_used_as_runtime_value,
                });
                return null;
            },
            .runtime => {},
        }
        const typed_runtime = value.runtime;
        if (!try semantic.canWidenTo(type_interner, typed_runtime.type_id, expected_type)) {
            try typing.emitSemanticIssue(ctx, resolved.file_id, .{
                .span = nodeSpan(&parsed, initializer),
                .kind = .{ .static_initializer_type_mismatch = .{
                    .expected = expected_type,
                    .found = typed_runtime.type_id,
                } },
            });
            return null;
        }
        if (typed_runtime.type_id != expected_type) {
            if (try lookupVariantMembers(ctx, expected_type)) |members| {
                const active_type = if (typed_runtime.value == .variant) typed_runtime.value.variant.member_type else typed_runtime.type_id;
                const payload = if (typed_runtime.value == .variant) typed_runtime.value.variant.payload else value_id;
                const tag = (try semantic.widenedVariantTag(type_interner, active_type, members)) orelse unreachable;
                value.runtime.value = .{ .variant = .{ .member_type = members[tag], .payload = payload } };
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
        const resolved = (try ctx.get(ResolveItem, site.owner.item)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        if (site.node.index() >= parsed.nodes.len) return null;
        // Static arguments inside an initializer are independent demanded
        // thunks, so a static-owned site is not limited to the initializer root.
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = site.owner,
            .public_annotation = site.public_annotation,
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
        return typing.resolveAndTypeBody(
            ctx,
            site.owner,
            resolved.file_id,
            &.{},
            .unit,
            true,
            .{ .infer_return_type = true, .publish_instruction_spans = true, .allow_type_values = true, .expected_result_type = site.expected_type },
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
        .place, .initializer => unreachable,
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

        if ((try ctx.get(ExternalSymbol, key.instance.item)).*) |symbol| {
            switch (symbol) {
                .copy_value, .move_value, .array_filled, .array_from, .array_borrow, .array_borrow_mut, .literal_byte, .initialize_collection => {},
                .exit => return .{ .completed = .{
                    .outcome = .{ .exit = arguments[0].runtime.int },
                    .arguments = key.arguments,
                } },
                .allocate_host_storage, .deallocate_host_storage, .allocate, .deallocate, .allocation_count, .unsafe_initialize, .unsafe_take, .unsafe_destroy, .unsafe_borrow_initialized, .borrow_box, .borrow_mut_box, .borrow_local, .unsafe_borrow_element, .unsafe_borrow_mut_element, .read, .write, .attenuate_ref, .unsafe_own_box, .unsafe_take_box, .unsafe_destroy_box, .deallocate_box => {
                    try emitComptimeExecutionIssue(ctx, key.instance.item, null, .{ .reason = .unsupported_operation });
                    return .execution_error;
                },
            }
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
        const Frame = struct { instance: structures.InstanceId, arguments: comptime_interpreter.ValueSnapshot };
        ctx: Context,
        owner: structures.ItemId,
        transient_frames: std.ArrayList(Frame) = .empty,

        pub fn callInStorage(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            for (arguments) |argument| switch (argument) {
                .place, .initializer => return self.callTransient(instance, arguments, call_span, storage),
                .runtime, .type => {},
            };
            return self.call(instance, arguments, call_span);
        }

        pub fn call(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan) anyerror!comptime_interpreter.Result {
            const signature = if (instance.specialization == null)
                (try self.ctx.get(FunctionSignature, instance.item)).* orelse return .unavailable
            else
                (try self.ctx.get(FunctionInstanceSignature, instance)).* orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            var has_mut_arguments = false;

            const value_ids = try self.ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
            defer self.ctx.allocator().free(value_ids);
            for (arguments, signature.parameters, value_ids) |argument, parameter, *value_id| {
                std.debug.assert(argument == .runtime);
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

        pub fn convertStaticValue(self: *@This(), source_type: structures.TypeId, source: structures.CompileTimeValue.RuntimeValue, target_type: structures.TypeId, span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const resolved = (try self.ctx.get(ResolveItem, self.owner)).* orelse return .unavailable;
            const analysis: AnalysisContext(Context) = .{ .ctx = self.ctx, .file_id = resolved.file_id, .instance = .{ .item = self.owner } };
            if (source_type == .int_literal) {
                const members = try analysis.facts().variantMembers(target_type);
                if (target_type == .int or (members != null and std.mem.indexOfScalar(structures.TypeId, members.?, .int) != null)) {
                    const integer = std.math.cast(i32, source.int_literal) orelse {
                        try self.ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = span, .kind = .integer_literal_out_of_range });
                        return .reported_error;
                    };
                    const value: comptime_interpreter.Value = .{ .runtime = .{ .int = integer } };
                    if (target_type == .int) return .{ .returned = value };
                    return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, .int, value, self) };
                }
            }
            const value_id = try self.internRuntime(source_type, source);
            const candidates = try analysis.conversionCandidates(source_type, target_type, value_id);
            defer self.ctx.allocator().free(candidates);
            const builtin = try semantic.canWidenTo(analysis, source_type, target_type);
            const count = candidates.len + @intFromBool(builtin);
            if (count != 1) {
                const mismatch: structures.Diagnostic.TypeMismatch = .{ .expected = target_type, .found = source_type };
                try self.ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = span, .kind = if (count == 0) .{ .local_type_mismatch = mismatch } else .{ .ambiguous_conversion = mismatch } });
                return .reported_error;
            }
            if (builtin) {
                if (source == .variant) return .{ .returned = .{ .runtime = source } };
                return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, source_type, .{ .runtime = source }, self) };
            }
            const candidate = candidates[0];
            std.debug.assert(candidate.source_mode == .static);
            const result = try self.callInStorage(candidate.instance, &.{}, span, storage);
            if (result != .returned or candidate.target_type == target_type) return result;
            return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, candidate.target_type, result.returned, self) };
        }

        fn callTransient(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const signature = if (instance.specialization == null)
                (try self.ctx.get(FunctionSignature, instance.item)).* orelse return .unavailable
            else
                (try self.ctx.get(FunctionInstanceSignature, instance)).* orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            if ((try self.ctx.get(ExternalSymbol, instance.item)).*) |symbol| {
                switch (symbol) {
                    .copy_value, .move_value, .array_filled, .array_from, .array_borrow, .array_borrow_mut, .literal_byte, .initialize_collection => {},
                    .read, .write, .attenuate_ref => return self.referenceCall(symbol, signature.return_type, arguments, call_span, storage),
                    .borrow_local => return .{ .returned = try comptime_interpreter.referenceValue(signature.return_type, arguments[0].place, storage) },
                    .exit => return .{ .exit = switch (arguments[0]) {
                        .runtime => |runtime| runtime.int,
                        .place => |cell| cell.contents.value.int,
                        .type, .initializer => unreachable,
                    } },
                    else => return .{ .execution_error = .{ .reason = .unsupported_operation, .span = call_span } },
                }
            }
            var snapshot_arena: std.heap.ArenaAllocator = .init(self.ctx.allocator());
            defer snapshot_arena.deinit();
            const snapshot_storage = snapshot_arena.allocator();
            const saved_arguments = try comptime_interpreter.ValueSnapshot.init(arguments, snapshot_storage);
            for (self.transient_frames.items) |frame| {
                if (std.meta.eql(frame.instance, instance) and try frame.arguments.eql(saved_arguments, snapshot_storage))
                    return .{ .execution_error = .{ .reason = .call_cycle, .span = call_span } };
            }
            const body = (try self.ctx.get(AnalyzeComptimeFunctionBody, instance)).* orelse return .unavailable;
            try self.transient_frames.append(self.ctx.allocator(), .{ .instance = instance, .arguments = saved_arguments });
            defer {
                _ = self.transient_frames.pop();
                if (self.transient_frames.items.len == 0) {
                    self.transient_frames.deinit(self.ctx.allocator());
                    self.transient_frames = .empty;
                }
            }
            const previous_owner = self.owner;
            self.owner = instance.item;
            defer self.owner = previous_owner;
            const result = try comptime_interpreter.executeInStorage(&body, arguments, self, self.ctx.allocator(), storage);
            if (result == .execution_error) try emitComptimeExecutionIssue(self.ctx, instance.item, null, result.execution_error);
            if (result == .execution_error or result == .reported_error) {
                try emitComptimeCallTrace(self.ctx, previous_owner, call_span);
                return .reported_error;
            }
            return result;
        }

        fn referenceCall(self: *@This(), symbol: standard_library.External, return_type: structures.TypeId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) !comptime_interpreter.Result {
            const target = comptime_interpreter.referenceTarget(arguments[0]) orelse
                return .{ .execution_error = .{ .reason = .unsupported_operation, .span = call_span } };
            switch (symbol) {
                .read => return self.readReference(target, storage),
                .write => {
                    try comptime_interpreter.assignCell(target, arguments[1], self);
                    return .{ .returned = .{ .runtime = .unit } };
                },
                .attenuate_ref => return .{ .returned = try comptime_interpreter.referenceValue(return_type, target, storage) },
                else => unreachable,
            }
        }

        fn readReference(self: *@This(), target: *comptime_interpreter.Cell, storage: std.mem.Allocator) !comptime_interpreter.Result {
            if (target.contents == .value) return .{ .returned = .{ .runtime = target.contents.value } };
            const copy = try storage.create(comptime_interpreter.Cell);
            copy.* = .{ .type_id = target.type_id, .storage = storage, .contents = .uninitialized };
            try comptime_interpreter.assignCell(copy, .{ .place = target }, self);
            return .{ .returned = .{ .place = copy } };
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

        pub fn arrayType(self: *@This(), type_id: structures.TypeId) !?structures.ArrayType {
            return lookupArrayType(self.ctx, type_id);
        }

        pub fn argumentPassing(self: *@This(), type_id: structures.TypeId) !structures.ArgumentPassing {
            const facts: TypeFacts(Context) = .{ .ctx = self.ctx };
            return facts.argumentPassing(type_id);
        }

        pub fn structFieldCount(self: *@This(), type_id: structures.TypeId) !?usize {
            const facts: TypeFacts(Context) = .{ .ctx = self.ctx };
            const definition = (try facts.structDefinition(type_id)) orelse return null;
            return definition.fields.len;
        }

        pub fn structFieldType(self: *@This(), type_id: structures.TypeId, index: usize) !?structures.TypeId {
            const facts: TypeFacts(Context) = .{ .ctx = self.ctx };
            const definition = (try facts.structDefinition(type_id)) orelse return null;
            std.debug.assert(index < definition.fields.len);
            return definition.fields[index].type_id;
        }
    };
}

fn nodeSpan(parsed: *const structures.Ast, node_index: structures.Node.Index) structures.SourceSpan {
    const node = parsed.nodes[node_index.index()];
    if (node.tag == .call) return nodeSpan(parsed, node.data.node_node.a);
    return parsed.tokenSpan(node.token_index);
}

fn emitComptimeExecutionIssue(
    ctx: anytype,
    owner: structures.ItemId,
    fallback_node: ?structures.Node.Index,
    execution_error: comptime_interpreter.ExecutionError,
) !void {
    const resolved = (try ctx.get(ResolveItem, owner)).* orelse return;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return;
    const fallback_span = nodeSpan(&parsed, fallback_node orelse @fromBackingInt(@intCast(resolved.declaration)));
    const span = execution_error.span orelse fallback_span;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = resolved.file_id,
        .span = span,
        .kind = switch (execution_error.reason) {
            .call_cycle => .compile_time_call_cycle,
            .division_by_zero => .compile_time_division_by_zero,
            .integer_overflow => .compile_time_integer_overflow,
            .unsupported_operation => .compile_time_unsupported_operation,
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

pub const StructNamespace = struct {
    pub const Input = structures.StructIdentity;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, identity: Input) anyerror!Output {
        const owner = structOwnerItem(identity);
        const resolved = (try ctx.get(ResolveItem, owner)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const site: ?i64 = switch (identity) {
            .declared => null,
            .generated => |generated| generated.node_offset,
        };
        const struct_index: structures.Node.Index = if (site) |offset| generated: {
            const position = std.math.cast(u32, @as(i64, resolved.declaration) + offset) orelse return null;
            if (position >= parsed.nodes.len or parsed.nodes[position].tag != .@"struct") return null;
            break :generated @fromBackingInt(@intCast(position));
        } else parsed.nodes[resolved.declaration].data.node_node.b;
        if (try semantic.validateStructNamespace(&parsed, source, struct_index, ctx.allocator())) |issue| {
            try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
            return null;
        }
        const owner_loc = try ctx.lookupInterned(ItemLocations, owner);
        const member_site = if (owner_loc.kind == .structure) null else site;
        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        defer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        var names = std.StringHashMap(void).init(ctx.allocator());
        defer names.deinit();
        const struct_node = parsed.nodes[struct_index.index()];
        for (parsed.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
            const item = parsed.nodes[member_index.index()];
            const member = if (item.tag == .@"pub") parsed.nodes[item.data.node.index()] else item;
            if (member.tag != .struct_field) continue;
            const token = parsed.tokens[member.token_index];
            try names.put(source[token.loc.start..token.loc.end], {});
        }
        const module = switch (owner_loc.origin) {
            .module => |value| value,
            .entry => unreachable,
        };
        const files = (try ctx.input(ModuleMembers, module)).*;
        for (files) |file_id| {
            const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
            const discovered = (try ctx.get(DiscoverItems, file_id)).* orelse return null;
            std.debug.assert(discovered.items.len == index.count());
            for (discovered.items, index.ids()) |item, item_id| {
                const loc = try ctx.lookupInterned(ItemLocations, item_id);
                if (loc.owner != owner or loc.source_site != member_site or loc.is_hook) continue;
                const reserved = std.meta.stringToEnum(structures.OwnershipMember, loc.name) != null;
                if (reserved or (try names.getOrPut(loc.name)).found_existing) {
                    const member_parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
                    const declaration = index.resolve(item_id) orelse unreachable;
                    const token = member_parsed.tokens[member_parsed.nodes[declaration].token_index];
                    try ctx.emit(structures.Diagnostic, .{
                        .file_id = file_id,
                        .span = .{ .start = token.loc.start, .end = token.loc.end },
                        .kind = if (reserved) .reserved_ownership_member else .duplicate_struct_member,
                    });
                    return null;
                }
                const name = try ctx.allocator().dupe(u8, loc.name);
                errdefer ctx.allocator().free(name);
                try entries.append(ctx.allocator(), .{ .name = name, .item_id = item_id, .kind = loc.kind, .is_public = item.is_public });
            }
        }
        std.mem.sort(structures.ModuleScope.Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: structures.ModuleScope.Entry, b: structures.ModuleScope.Entry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
    }
};

pub const StructDefinition = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        // Validate the complete member scope, including qualified declarations.
        _ = (try ctx.get(StructNamespace, .{ .declared = item_id })).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
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
        const struct_node: structures.Node.Index = @fromBackingInt(@intCast(node_index));
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const type_interner: AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = identity.owner,
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

pub const AnalyzeFunctionInstance = struct {
    pub const disk_boundary = true;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
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
    if ((try ctx.get(BuildModuleScope, resolved.file_id)).* == null) return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    const builtin_body: ?typing.BuiltinBody = if ((try ctx.get(ExternalSymbol, instance.item)).*) |symbol| switch (symbol) {
        .copy_value => .copy,
        .move_value => .move,
        .array_filled => .array_filled,
        .array_from => .array_from,
        .initialize_collection => .initialize_collection,
        .array_borrow => .array_borrow,
        .array_borrow_mut => .array_borrow_mut,
        .literal_byte => .literal_byte,
        .unsafe_initialize => .initialize_slot,
        else => null,
    } else null;
    if (loc.kind == .function and semantic.isExternalFunction(&parsed, resolved.declaration) and builtin_body == null) return null;
    const source = (try ctx.input(SourceText, resolved.file_id)).*;
    const type_interner: AnalysisContext(@TypeOf(ctx)) = .{
        .ctx = ctx,
        .file_id = resolved.file_id,
        .instance = instance,
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
    var consuming_converter = builtin_body == .array_from or builtin_body == .initialize_collection;
    if (loc.kind == .function and parsed.nodes[parsed.nodes[resolved.declaration].data.node_node.b.index()].is_converter) {
        for (parameters) |parameter| if (parameter.mode == .init) {
            consuming_converter = true;
        };
    }
    return typing.resolveAndTypeBody(
        ctx,
        instance,
        resolved.file_id,
        parameters,
        return_type,
        is_fallible,
        .{ .publish_instruction_spans = publish_instruction_spans, .allow_type_values = publish_instruction_spans, .builtin_body = builtin_body, .consuming_converter = consuming_converter },
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
        if ((try ctx.get(ExternalSymbol, instance_id.item)).*) |symbol| {
            // Only publish code for a declaration with the implementation's signature.
            _ = if (instance_id.specialization == null)
                (try ctx.get(FunctionSignature, instance_id.item)).* orelse return null
            else
                (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
            return switch (symbol) {
                .copy_value, .move_value, .array_filled, .array_from, .array_borrow, .array_borrow_mut, .unsafe_initialize, .literal_byte, .initialize_collection => try compileTypedFunction(ctx, instance_id),
                .exit => try codegen.compileExternalExit(ctx.allocator()),
                .allocate_host_storage => try codegen.compileExternalAllocateHostStorage(ctx.allocator()),
                .deallocate_host_storage => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .allocate => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const element_type = (try allocationElementType(ctx, signature.return_type)) orelse unreachable;
                    const resolved = (try ctx.get(ResolveItem, instance_id.item)).* orelse return null;
                    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
                    if (!try validateRuntimeType(ctx, facts, element_type, resolved.file_id, null)) return null;
                    const layout = (try ctx.get(HostTypeLayout, element_type)).*;
                    break :blk try codegen.compileExternalAllocateHostTypedStorage(ctx.allocator(), layout);
                },
                .deallocate => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .allocation_count => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const layout = (try ctx.get(StructLayout, signature.parameters[0].type_id)).* orelse unreachable;
                    break :blk try codegen.compileExternalAllocationCount(ctx.allocator(), layout.field_offsets[1]);
                },
                .unsafe_take => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const element_type = (try allocationElementType(ctx, signature.parameters[0].type_id)) orelse unreachable;
                    const layout = (try ctx.get(HostTypeLayout, element_type)).*;
                    const allocation_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    break :blk try codegen.compileExternalHostSlotTake(ctx.allocator(), allocation_layout, layout, true);
                },
                .unsafe_own_box => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const allocation_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    const box_layout = (try ctx.get(HostTypeLayout, signature.return_type)).*;
                    std.debug.assert(std.meta.eql(allocation_layout, box_layout));
                    break :blk try codegen.compileExternalHostBoxWrap(ctx.allocator(), box_layout);
                },
                .unsafe_take_box => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const layout = (try ctx.get(HostTypeLayout, signature.return_type)).*;
                    const box_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    break :blk try codegen.compileExternalHostSlotTake(ctx.allocator(), box_layout, layout, false);
                },
                .unsafe_destroy, .unsafe_borrow_initialized, .borrow_box, .borrow_mut_box, .borrow_local, .unsafe_borrow_element, .unsafe_borrow_mut_element, .read, .write, .attenuate_ref, .unsafe_destroy_box => unreachable,
                .deallocate_box => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
            };
        }
        return compileTypedFunction(ctx, instance_id);
    }
};

fn compileTypedFunction(ctx: anytype, instance: structures.InstanceId) !?structures.CompiledFunction {
    const body = (try ctx.get(AnalyzeFunctionInstance, instance)).* orelse return null;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    if (!try validateRuntimeBody(ctx, &body, resolved.file_id)) return null;
    const types: HostTypes(@TypeOf(ctx)) = .{ .ctx = ctx };
    return try codegen.compileFunction(&body, types, ctx.allocator());
}

fn validateRuntimeBody(ctx: anytype, body: *const structures.FunctionBodyAnalysis, file_id: structures.FileId) anyerror!bool {
    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
    if (!try validateRuntimeType(ctx, facts, body.return_type, file_id, null)) return false;
    for (body.block_arguments) |argument| if (argument.representation != .initializer and !try validateRuntimeType(ctx, facts, argument.type_id, file_id, null)) return false;
    for (body.instructions, 0..) |instruction, index| {
        const span = if (body.instruction_spans.len == body.instructions.len) body.instruction_spans[index] else null;
        if (instruction == .static_conversion) {
            _ = try validateRuntimeType(ctx, facts, body.valueType(instruction.static_conversion.operand), file_id, span);
            return false;
        }
        if (instruction == .initializer_ref) continue;
        if (!try validateRuntimeType(ctx, facts, instruction.resultType(), file_id, span)) return false;
    }
    for (body.initializer_regions) |*region| if (!try validateRuntimeBody(ctx, region, file_id)) return false;
    return true;
}

fn validateRuntimeType(ctx: anytype, facts: anytype, type_id: structures.TypeId, file_id: structures.FileId, span: ?structures.SourceSpan) !bool {
    if (try facts.isRuntimeCapable(type_id)) return true;
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = span, .kind = .{ .compile_time_only_type = type_id } });
    return false;
}

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
                if (!result.found_existing) {
                    try instances.append(ctx.allocator(), referenced);
                    if (ctx.hasParallelWorkers()) _ = try ctx.spawn(CompileFunction, referenced);
                }
            }
        }

        return .{ .instances = try instances.toOwnedSlice(ctx.allocator()) };
    }
};

// Visit imports without evaluating declarations or any file's entry body.
// An explicit queue permits module cycles; export-name cycles are checked by
// the import resolver at the name that introduces the semantic dependency.
pub const ValidateModuleGraph = struct {
    pub const Input = structures.ModuleId;
    pub const Output = bool;

    pub fn run(ctx: anytype, root: Input) anyerror!Output {
        var modules: std.AutoArrayHashMapUnmanaged(structures.ModuleId, void) = .empty;
        defer modules.deinit(ctx.allocator());
        try modules.put(ctx.allocator(), root, {});
        var next: usize = 0;
        while (next < modules.count()) : (next += 1) {
            const module = modules.keys()[next];
            const members = (try ctx.input(ModuleMembers, module)).*;
            if (ctx.hasParallelWorkers()) {
                _ = try ctx.spawn(IndexModuleItems, module);
                for (members) |file| {
                    _ = try ctx.spawn(IndexItems, file);
                    _ = try ctx.spawn(ResolveFileImports, file);
                    _ = try ctx.spawn(CollectFileImports, file);
                }
            }
            // Validate declaration ownership even when no item is referenced.
            _ = (try ctx.get(IndexModuleItems, module)).* orelse return false;
            for (members) |file| {
                if ((try ctx.get(ResolveFileImports, file)).* == null) return false;
                const tree = (try ctx.get(DiscoverItems, file)).* orelse return false;
                const index = (try ctx.get(IndexItems, file)).* orelse return false;
                const parsed = (try ctx.get(ParseFile, file)).* orelse return false;
                const source = (try ctx.input(SourceText, file)).*;
                for (tree.items, index.ids()) |item, item_id| {
                    if (item.loc.kind != .function or !std.mem.startsWith(u8, item.loc.name, "$converter")) continue;
                    const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = file, .instance = .{ .item = item_id } };
                    switch (try semantic.validateConverterDeclaration(&parsed, source, item.declaration, analysis)) {
                        .success => {},
                        .unsupported => |issue| {
                            try typing.emitSemanticIssue(ctx, file, issue);
                            return false;
                        },
                    }
                }
                const imports = (try ctx.get(CollectFileImports, file)).* orelse return false;
                for (imports.entries) |entry| {
                    const imported = (try resolveImportedModule(ctx, .{ .file_id = file, .span = entry.path.span }, entry.path.spelling)) orelse return false;
                    try modules.put(ctx.allocator(), imported, {});
                    if (entry.is_public and !try validateExport(ctx, module, file, entry)) return false;
                }
            }
        }
        return true;
    }
    fn validateExport(ctx: anytype, module: structures.ModuleId, file: structures.FileId, entry: structures.ImportDeclaration) !bool {
        var visited: std.ArrayList(ExportVisit) = .empty;
        defer visited.deinit(ctx.allocator());
        if (entry.selective) |selections| {
            for (selections) |selection| {
                if (try resolveModuleExport(ctx, module, module, selection.bound.spelling, .{ .file_id = file, .span = selection.bound.span }, &visited) == null)
                    return false;
            }
            return true;
        }
        const bound = entry.alias orelse entry.path;
        const name = if (std.mem.lastIndexOfScalar(u8, bound.spelling, '.')) |dot| bound.spelling[dot + 1 ..] else bound.spelling;
        return try resolveModuleExport(ctx, module, module, name, .{ .file_id = file, .span = bound.span }, &visited) != null;
    }
};

pub const BuildExecutable = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.Executable;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const module = (try ctx.input(FileModule, file_id)).*;
        if (!(try ctx.get(ValidateModuleGraph, module)).*) return null;
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

test "struct public field annotations preserve declaration visibility" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const cases = [_]struct { source: []const u8, accepted: bool }{
        .{ .source = "static Hidden = int\npub struct Visible\n  pub value: Hidden", .accepted = false },
        .{ .source = "pub static Alias = int\npub struct Visible\n  pub value: Alias", .accepted = true },
        .{ .source = "struct Parent\n  pub static Alias = int\npub struct Visible\n  pub value: Parent.Alias", .accepted = false },
        .{ .source = "pub struct Parent\n  static Hidden = int\npub struct Visible\n  pub value: Parent.Hidden", .accepted = false },
        .{ .source = "pub struct Parent\n  pub static Alias = int\npub struct Visible\n  pub value: Parent.Alias", .accepted = true },
        .{ .source = "static Hidden = int\npub struct Visible\n  pub value: Hidden | none", .accepted = false },
        .{ .source = "static Hidden = int\npub struct Visible\n  pub value: func(Hidden) int", .accepted = false },
        .{ .source = "static Hidden = int\npub struct Visible\n  pub value: func(int) Hidden", .accepted = false },
        .{ .source = "struct Hidden\n  value: int\npub struct Visible\n  pub value: Hidden", .accepted = false },
        .{ .source = "struct Factory(T: type)\n  value: T\npub struct Visible\n  pub value: Factory(int)", .accepted = false },
        .{ .source = "static Hidden = int\npub struct Factory(T: type)\n  value: T\npub struct Visible\n  pub value: Factory(Hidden)", .accepted = false },
        .{ .source = "pub struct Factory(T: type)\n  value: T\npub struct Visible\n  pub value: Factory(int)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(hidden_count)", .accepted = false },
        .{ .source = "pub static count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(count)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(hidden_count + 1)", .accepted = false },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(2 * (3 - hidden_count) / 2)", .accepted = false },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(-hidden_count)", .accepted = false },
        .{ .source = "pub static count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(-(count + 1) * 2 / 2)", .accepted = true },
        .{ .source = "pub struct Counts\n  static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(Counts.hidden_count + 1)", .accepted = false },
        .{ .source = "pub struct Counts\n  pub static count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(Counts.count + 1)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub func increment(n: int) int -> n + 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(increment(hidden_count))", .accepted = false },
        .{ .source = "pub static count = 1\npub func increment(n: int) int -> n + 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(increment(count))", .accepted = true },
        .{ .source = "func hidden_count() int -> 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(hidden_count())", .accepted = false },
        .{ .source = "static hidden_count = 1\npub func Sized(n: int) type -> int\npub struct Visible\n  pub value: Sized(hidden_count)", .accepted = false },
        .{ .source = "pub static count = 1\npub func Sized(n: int) type -> int\npub struct Visible\n  pub value: Sized(count)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(if hidden_count > 0 -> 1 else 2)", .accepted = false },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(if 0 < 1 -> 1 else hidden_count)", .accepted = false },
        .{ .source = "pub static count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(if count > 0 -> count else 2)", .accepted = true },
        .{ .source = "import std.exit as counts\npub struct Count\n  copy = trivial\n  pub value: int\npub static optional: Count | none = Count{value = 1}\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(if const counts = optional as Count -> counts.value else 0)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(comptime -> hidden_count + 1)", .accepted = false },
        .{ .source = "pub static count = 1\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(comptime -> count + 1)", .accepted = true },
        .{ .source = "static hidden_count = 1\npub struct Count\n  pub value: int\npub struct Sized(n: Count)\n  value: int\npub struct Visible\n  pub value: Sized(Count{value = hidden_count})", .accepted = false },
        .{ .source = "pub static count = 1\npub struct Count\n  pub value: int\npub struct Sized(n: Count)\n  value: int\npub struct Visible\n  pub value: Sized(Count{value = count})", .accepted = true },
        .{ .source = "pub struct Sized(n: int)\n  static unused = unknown()\n  value: int\npub struct Visible\n  pub value: Sized(1)", .accepted = true },
        .{ .source = "struct Hidden\n  value: int\npub struct Phantom(T: type)\n  value: int\npub static Alias = Phantom(Hidden)\npub struct Visible\n  pub value: Alias", .accepted = false },
        .{ .source = "pub struct Published\n  value: int\npub struct Phantom(T: type)\n  value: int\npub static Alias = Phantom(Published)\npub struct Visible\n  pub value: Alias", .accepted = true },
        .{ .source = "struct Hidden\n  value: int\npub struct Factory(T: type)\n  pub struct Phantom(U: type)\n    value: int\npub static Alias = Factory(Hidden).Phantom(int)\npub struct Visible\n  pub value: Alias", .accepted = false },
        .{ .source = "pub struct Published\n  value: int\npub struct Factory(T: type)\n  pub struct Phantom(U: type)\n    value: int\npub static Alias = Factory(Published).Phantom(int)\npub struct Visible\n  pub value: Alias", .accepted = true },
        .{ .source = "static Hidden = int\npub struct Visible\n  value: Hidden\nfunc unused() int -> unknown()", .accepted = true },
    };
    for (cases) |case| {
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
        defer db.deinit();
        try modules.registerSources(db, std.testing.allocator, case.source, &.{}, &.{});
        const module = (try db.input(FileModule, 0)).*;
        const scope = (try db.get(ModuleDeclarations, module)).*.?;
        const item = scope.resolve("Visible").?;
        const definition = (try db.get(StructDefinition, item)).*;
        const diagnostics = try db.transitiveAccumulatorValues(StructDefinition, item, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        if (case.accepted != (definition != null)) {
            std.debug.print("public field annotation source:\n{s}\n", .{case.source});
            for (diagnostics) |diagnostic| std.debug.print("at {d}: {s}\n", .{ if (diagnostic.span) |span| span.start else 0, @tagName(diagnostic.kind) });
        }
        try std.testing.expectEqual(case.accepted, definition != null);
        if (case.accepted) {
            try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
        } else {
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
            try std.testing.expectEqual(structures.Diagnostic.Kind.public_field_private_type, diagnostics[0].kind);
        }
    }
}

test "public annotation thunks do not reuse ordinary visibility results" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const source =
        \\static hidden_count = 1
        \\pub func select(count: int) type -> int
        \\struct Example
        \\    value: select(hidden_count)
    ;
    for ([_]bool{ false, true }) |public_first| {
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
        defer db.deinit();
        try modules.registerSources(db, std.testing.allocator, source, &.{}, &.{});
        const scope = (try db.get(BuildModuleScope, 0)).*.?;
        const owner: structures.InstanceId = .{ .item = scope.resolve("Example").? };
        const parsed = (try db.get(ParseFile, 0)).*.?;
        const node = for (parsed.nodes) |candidate| {
            if (candidate.tag == .struct_field) break candidate.data.node;
        } else unreachable;
        for ([_]bool{ public_first, !public_first, public_first }) |public_annotation| {
            const site: structures.CompileTimeSite = .{
                .owner = owner,
                .node = node,
                .public_annotation = public_annotation,
            };
            const result = (try db.get(ExecuteComptimeThunk, site)).*;
            const diagnostics = try db.transitiveAccumulatorValues(ExecuteComptimeThunk, site, structures.Diagnostic, std.testing.allocator);
            defer std.testing.allocator.free(diagnostics);
            if (public_annotation) {
                try std.testing.expect(result == null);
                try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
                try std.testing.expectEqual(structures.Diagnostic.Kind.public_field_private_type, diagnostics[0].kind);
            } else {
                try std.testing.expectEqual(structures.TypeId.int, (try db.lookupInterned(CompileTimeValues, result.?.returned)).type);
                try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
            }
        }
    }
}

test "generated struct public annotations validate names and nominal substitutions" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const cases = [_]struct { annotation: []const u8, hidden_argument: bool, accepted: bool }{
        .{ .annotation = "T", .hidden_argument = false, .accepted = true },
        .{ .annotation = "T", .hidden_argument = true, .accepted = false },
        .{ .annotation = "T | none", .hidden_argument = true, .accepted = false },
        .{ .annotation = "func(T) int", .hidden_argument = true, .accepted = false },
        .{ .annotation = "func(int) T", .hidden_argument = true, .accepted = false },
        .{ .annotation = "HiddenAlias", .hidden_argument = false, .accepted = false },
        .{ .annotation = "PublicAlias", .hidden_argument = false, .accepted = true },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.print(
            "struct Hidden\n  value: int\nstatic HiddenAlias = int\npub static PublicAlias = int\npub struct Factory(T: type)\n  pub value: {s}\n  private: int",
            .{case.annotation},
        );
        defer std.testing.allocator.free(source);
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
        defer db.deinit();
        try modules.registerSources(db, std.testing.allocator, source, &.{}, &.{});
        const module = (try db.input(FileModule, 0)).*;
        const scope = (try db.get(ModuleDeclarations, module)).*.?;
        const factory = scope.resolve("Factory").?;
        const argument_type: structures.TypeId = if (case.hidden_argument) try internStructType(db, scope.resolve("Hidden").?) else .int;
        const argument = try db.intern(CompileTimeValues, .{ .type = argument_type });
        const tuple = try db.intern(CompileTimeValueTuples, .{ .values = &.{argument} });
        const resolved = (try db.get(ResolveItem, factory)).*.?;
        const parsed = (try db.get(ParseFile, resolved.file_id)).*.?;
        const identity: structures.GeneratedStructIdentity = .{
            .owner = .{ .item = factory, .specialization = tuple },
            .node_offset = semantic.parameterizedStructSite(&parsed, resolved.declaration).?,
        };
        const definition = (try db.get(GeneratedStructDefinition, identity)).*;
        try std.testing.expectEqual(case.accepted, definition != null);
        const diagnostics = try db.transitiveAccumulatorValues(GeneratedStructDefinition, identity, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        if (case.accepted) {
            try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
            try std.testing.expect(definition.?.fields[0].is_public);
            try std.testing.expect(!definition.?.fields[1].is_public);
        } else {
            try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
            try std.testing.expectEqual(structures.Diagnostic.Kind.public_field_private_type, diagnostics[0].kind);
        }
    }
}

test "struct private field access uses defining module and definitions recompute visibility" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator, "", &.{
        .{ .path = "lib/a.chi", .module_path = "lib", .source = "pub struct Visible\n  value: int\npub struct Factory(T: type)\n  value: T" },
        .{ .path = "lib/b.chi", .module_path = "lib", .source = "" },
        .{ .path = "api/a.chi", .module_path = "api", .source = "pub import lib.{Visible}" },
    }, &.{});
    const module = (try db.input(FileModule, 1)).*;
    const scope = (try db.get(ModuleDeclarations, module)).*.?;
    const item = scope.resolve("Visible").?;
    const type_id = try internStructType(db, item);
    const factory = scope.resolve("Factory").?;
    const argument = try db.intern(CompileTimeValues, .{ .type = .int });
    const tuple = try db.intern(CompileTimeValueTuples, .{ .values = &.{argument} });
    const call = (try db.get(ExecuteComptimeCall, .{
        .instance = .{ .item = factory, .specialization = tuple },
        .arguments = try db.intern(CompileTimeValueTuples, .{ .values = &.{} }),
    })).*.?;
    const generated_type = (try db.lookupInterned(CompileTimeValues, call.completed.outcome.returned)).type;
    for ([_]structures.FileId{ 0, 1, 2, 3 }) |file_id| {
        const analysis: AnalysisContext(@TypeOf(db)) = .{ .ctx = db, .file_id = file_id };
        try std.testing.expectEqual(file_id == 1 or file_id == 2, try analysis.canAccessPrivateFields(type_id));
        try std.testing.expectEqual(file_id == 1 or file_id == 2, try analysis.canAccessPrivateFields(generated_type));
    }
    try std.testing.expect(!(try db.get(StructDefinition, item)).*.?.fields[0].is_public);
    try db.setInput(SourceText, 1, "pub struct Visible\n  pub value: int\npub struct Factory(T: type)\n  value: T");
    try std.testing.expect((try db.get(StructDefinition, item)).*.?.fields[0].is_public);
}

test "struct namespace reserves pub wrapped field names for qualified members" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator, "struct Visible\n  pub value: int\nfunc Visible.value() int -> 42", &.{}, &.{});
    const module = (try db.input(FileModule, 0)).*;
    const item = (try db.get(ModuleDeclarations, module)).*.?.resolve("Visible").?;
    const identity: structures.StructIdentity = .{ .declared = item };
    try std.testing.expect((try db.get(StructNamespace, identity)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(StructNamespace, identity, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(structures.Diagnostic.Kind.duplicate_struct_member, diagnostics[0].kind);
}

test "inline array canonical identity and namespace do not depend on filled availability" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const CheckCanonicalIdentity = struct {
        pub const Input = structures.FileId;
        pub const Output = void;

        pub fn run(ctx: *query.Context, file_id: Input) anyerror!Output {
            const scope = (try ctx.get(BuildModuleScope, file_id)).*.?;
            const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
            const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = file_id };
            const three = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve("Three").?)).*.?)).type;
            const canonical: structures.TypeId = .fromInterned(try ctx.intern(Types, .{ .array = .{ .element_type = .int, .length = 3 } }));
            try std.testing.expectEqual(canonical, three);
            try std.testing.expectEqualDeep(structures.ArrayType{ .element_type = .int, .length = 3 }, (try facts.arrayType(three)).?);
            try std.testing.expect(try facts.structDefinition(three) == null);
            try std.testing.expect(try analysis.structDefinition(three) == null);
            try std.testing.expect((try ctx.get(StructLayout, three)).* == null);
            try std.testing.expect(try analysis.structIdentity(three) == null);
            const namespace = (try analysis.typeNamespace(three)).?;
            const identity = namespace.query_key.generated;
            try std.testing.expectEqual((try standardFunction(ctx, .array, "Array")).?, identity.owner.item);
            const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, namespace.specialization.?)).values;
            try std.testing.expectEqual(structures.TypeId.int, (try ctx.lookupInterned(CompileTimeValues, arguments[0])).type);
            try std.testing.expectEqual(@as(i32, 3), (try ctx.lookupInterned(CompileTimeValues, arguments[1])).runtime.value.int);
            const inferred = (try analysis.structFactoryArguments(.{ .item = identity.owner.item }, three)).?;
            try std.testing.expect(std.mem.eql(structures.CompileTimeValueId, arguments, inferred));
            const filled = (try analysis.structNamespaceMember(three, "filled", .{ .start = 0, .end = 0 })).?;
            try std.testing.expectEqual(structures.CallBehavior.ordinary, try analysis.callBehavior(filled.item));
            try std.testing.expectEqual(three, (try ctx.get(FunctionInstanceSignature, filled)).*.?.return_type);
            for ([_][]const u8{ "Empty", "Nonempty" }) |name| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expect(try facts.arrayType(type_id) != null);
                const unavailable = (try analysis.structNamespaceMember(type_id, "filled", .{ .start = 0, .end = 0 })).?;
                try std.testing.expect((try ctx.get(FunctionInstanceSignature, unavailable)).* == null);
                const diagnostics = try ctx.db.transitiveAccumulatorValues(FunctionInstanceSignature, unavailable, structures.Diagnostic, std.testing.allocator);
                defer std.testing.allocator.free(diagnostics);
                try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
                try std.testing.expectEqual(structures.Diagnostic.Kind.where_condition_failed, diagnostics[0].kind);
            }
        }
    };
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\struct Item
        \\    value: int
        \\static Three = Array(int, 3)
        \\static Empty = Array(Item, 0)
        \\static Nonempty = Array(Item, 2)
    , &.{}, &.{});
    _ = try db.get(CheckCanonicalIdentity, 0);
}

test "inline array host layout uses checked element stride and retains empty alignment" {
    const query = @import("query/engine.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    const inner: structures.TypeId = .fromInterned(try db.intern(Types, .{ .array = .{ .element_type = .int, .length = 3 } }));
    const cases = [_]struct { array: structures.ArrayType, layout: structures.TypeLayout }{
        .{ .array = .{ .element_type = .int, .length = 0 }, .layout = .{ .byte_size = 0, .byte_alignment = 4 } },
        .{ .array = .{ .element_type = .int, .length = 3 }, .layout = .{ .byte_size = 12, .byte_alignment = 4 } },
        .{ .array = .{ .element_type = inner, .length = 2 }, .layout = .{ .byte_size = 24, .byte_alignment = 4 } },
        .{ .array = .{ .element_type = .unit, .length = 10 }, .layout = .{ .byte_size = 0, .byte_alignment = 1 } },
    };
    for (cases) |case| {
        const type_id: structures.TypeId = .fromInterned(try db.intern(Types, .{ .array = case.array }));
        try std.testing.expectEqualDeep(case.layout, (try db.get(HostTypeLayout, type_id)).*);
    }
    const oversized: structures.TypeId = .fromInterned(try db.intern(Types, .{ .array = .{ .element_type = .int, .length = std.math.maxInt(i32) } }));
    try std.testing.expectError(error.TypeTooLarge, db.get(HostTypeLayout, oversized));
}

test "inline array ownership derives element hooks and explicit drop obligations" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\struct Custom
        \\    value: int
        \\    copy = func(imm self: Custom) Custom -> Custom{value = self.value}
        \\    move = func(deinit self: Custom) Custom -> Custom{value = self.value}
        \\    drop = func(deinit self: Custom)
        \\        _ = self.value
        \\struct Explicit
        \\    value: int
        \\    move = none
        \\    copy = none
        \\    drop = explicit
    , &.{}, &.{});
    const scope = (try db.get(BuildModuleScope, 0)).*.?;
    const custom = try internStructType(db, scope.resolve("Custom").?);
    const explicit = try internStructType(db, scope.resolve("Explicit").?);
    const cases = [_]struct { element: structures.TypeId, length: u32, capabilities: structures.OwnershipCapabilities }{
        .{ .element = .int, .length = 3, .capabilities = .{ .move = .trivial, .copy = .trivial, .drop = .trivial } },
        .{ .element = custom, .length = 2, .capabilities = .{ .move = .fieldwise, .copy = .fieldwise, .drop = .fieldwise, .needs_custom_move = true, .needs_custom_copy = true, .needs_automatic_drop = true } },
        .{ .element = explicit, .length = 2, .capabilities = .{ .move = .none, .copy = .none, .drop = .fieldwise, .requires_explicit_drop = true } },
        .{ .element = explicit, .length = 0, .capabilities = .{ .move = .trivial, .copy = .trivial, .drop = .trivial } },
    };
    for (cases) |case| {
        const type_id: structures.TypeId = .fromInterned(try db.intern(Types, .{ .array = .{ .element_type = case.element, .length = case.length } }));
        try std.testing.expectEqualDeep(case.capabilities, (try db.get(OwnershipCapabilities, type_id)).*.?);
    }
}

test "inline array invalid factory arguments report source errors" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const cases = [_]struct { source: []const u8, kind: structures.Diagnostic.Kind }{
        .{ .source = "static Invalid = Array(int, -1)", .kind = .static_argument_not_supported },
        .{ .source = "static Invalid = Array(type, 0)", .kind = .struct_field_type_not_supported },
        .{ .source = "static Invalid = Array(int, true)", .kind = .static_argument_type_mismatch },
    };
    for (cases) |case| {
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
        defer db.deinit();
        try modules.registerSources(db, std.testing.allocator, case.source, &.{}, &.{});
        const scope = (try db.get(BuildModuleScope, 0)).*.?;
        const item = scope.resolve("Invalid").?;
        try std.testing.expect((try db.get(ResolveStatic, item)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(ResolveStatic, item, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        try std.testing.expect(diagnostics.len != 0);
        const found = for (diagnostics) |diagnostic| {
            if (std.meta.eql(case.kind, diagnostic.kind)) break true;
        } else false;
        try std.testing.expect(found);
    }
}

test "inline array recursive containment includes zero length arrays" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    for ([_]u32{ 0, 1 }) |length| {
        const source = try std.testing.allocator.print("struct Node\n    children: Array(Node, {d})", .{length});
        defer std.testing.allocator.free(source);
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
        defer db.deinit();
        try modules.registerSources(db, std.testing.allocator, source, &.{}, &.{});
        const scope = (try db.get(BuildModuleScope, 0)).*.?;
        const type_id = try internStructType(db, scope.resolve("Node").?);
        try std.testing.expect((try db.get(OwnershipCapabilities, type_id)).* == null);
        const diagnostics = try db.transitiveAccumulatorValues(OwnershipCapabilities, type_id, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
        try std.testing.expectEqual(structures.Diagnostic.Kind.recursive_struct_containment, diagnostics[0].kind);
    }
}

test "inline array borrow containment and public annotations follow elements" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const CheckElementAnnotations = struct {
        pub const Input = structures.FileId;
        pub const Output = void;

        pub fn run(ctx: *query.Context, file_id: Input) anyerror!Output {
            const scope = (try ctx.get(BuildModuleScope, file_id)).*.?;
            const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = file_id };
            for ([_][]const u8{ "References", "EmptyReferences" }, [_]bool{ true, false }) |name, contains| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expectEqual(contains, try analysis.containsBorrow(type_id));
                try std.testing.expectEqual(contains, try analysis.canStoreBorrow(type_id));
            }
            for ([_][]const u8{ "HiddenArray", "VisibleArray" }, [_]bool{ false, true }) |name, visible| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expectEqual(visible, try analysis.isPublicType(type_id));
            }
        }
    };
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\struct Hidden
        \\    value: int
        \\pub struct Visible
        \\    value: int
        \\static References = Array(Ref(int, false), 2)
        \\static EmptyReferences = Array(Ref(int, false), 0)
        \\static HiddenArray = Array(Hidden, 0)
        \\static VisibleArray = Array(Visible, 2)
    , &.{}, &.{});
    _ = try db.get(CheckElementAnnotations, 0);
}

test "inline array namespace signatures and externs use typed builtin bodies" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const CheckNamespaceSignatures = struct {
        pub const Input = structures.FileId;
        pub const Output = void;

        pub fn run(ctx: *query.Context, file_id: Input) anyerror!Output {
            const scope = (try ctx.get(BuildModuleScope, file_id)).*.?;
            const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve("Value").?)).*.?)).type;
            const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = file_id };
            const namespace = (try analysis.typeNamespace(type_id)).?;
            const len = (try analysis.structNamespaceMember(type_id, "len", .{ .start = 0, .end = 0 })).?;
            const len_signature = (try ctx.get(FunctionInstanceSignature, len)).*.?;
            try std.testing.expect(!len_signature.is_fallible);
            try std.testing.expectEqual(structures.TypeId.int, len_signature.return_type);
            for ([_][]const u8{ "get", "get_mut" }, [_]bool{ false, true }) |name, writable| {
                const member = (try analysis.structNamespaceMember(type_id, name, .{ .start = 0, .end = 0 })).?;
                const signature = (try ctx.get(FunctionInstanceSignature, member)).*.?;
                try std.testing.expect(signature.is_fallible);
                try std.testing.expectEqual(structures.CallBehavior.ordinary, try analysis.callBehavior(member.item));
                try std.testing.expectEqual(@as(usize, 2), signature.parameters.len);
                try std.testing.expectEqual(if (writable) structures.ParameterMode.mut else .imm, signature.parameters[0].mode);
                try std.testing.expectEqual(type_id, signature.parameters[0].type_id);
                try std.testing.expectEqual(structures.ParameterMode.imm, signature.parameters[1].mode);
                try std.testing.expectEqual(structures.TypeId.int, signature.parameters[1].type_id);
                const borrow = (try borrowAccessType(ctx, signature.return_type)).?;
                try std.testing.expectEqual(structures.TypeId.int, borrow.element_type);
                try std.testing.expectEqual(writable, borrow.writable);
            }
            for ([_]standard_library.External{ .array_filled, .array_borrow, .array_borrow_mut }) |symbol| {
                const item = (try standardFunction(ctx, .array, @tagName(symbol))).?;
                const instance: structures.InstanceId = .{ .item = item, .specialization = namespace.specialization };
                try std.testing.expectEqual(symbol, (try ctx.get(ExternalSymbol, item)).*.?);
                try std.testing.expect((try ctx.get(FunctionInstanceSignature, instance)).* != null);
                const body = (try ctx.get(AnalyzeFunctionInstance, instance)).*.?;
                const has_element = for (body.instructions) |instruction| {
                    if (instruction == .array_element) break true;
                } else false;
                try std.testing.expect(has_element);
            }
        }
    };
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator, "static Value = Array(int, 3)", &.{}, &.{});
    _ = try db.get(CheckNamespaceSignatures, 0);
}

test "inline array derived facts recompute when element definitions change" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    move = none
        \\    drop = explicit
        \\static Value = Array(Item, 3)
        \\static Empty = Array(Item, 0)
    , &.{}, &.{});
    const scope = (try db.get(BuildModuleScope, 0)).*.?;
    const value_item = scope.resolve("Value").?;
    const empty_item = scope.resolve("Empty").?;
    const type_id = (try db.lookupInterned(CompileTimeValues, (try db.get(ResolveStatic, value_item)).*.?)).type;
    const empty = (try db.lookupInterned(CompileTimeValues, (try db.get(ResolveStatic, empty_item)).*.?)).type;
    try std.testing.expectEqualDeep(structures.TypeLayout{ .byte_size = 12, .byte_alignment = 4 }, (try db.get(HostTypeLayout, type_id)).*);
    try std.testing.expectEqualDeep(structures.TypeLayout{ .byte_size = 0, .byte_alignment = 4 }, (try db.get(HostTypeLayout, empty)).*);
    const previous = (try db.get(OwnershipCapabilities, type_id)).*.?;
    try std.testing.expectEqual(structures.MoveCapability.none, previous.move);
    try std.testing.expectEqual(structures.CopyCapability.none, previous.copy);
    try std.testing.expect(previous.requires_explicit_drop);
    try db.setInput(SourceText, 0,
        \\struct Item
        \\    value: byte
        \\    copy = trivial
        \\static Value = Array(Item, 3)
        \\static Empty = Array(Item, 0)
    );
    try std.testing.expectEqual(type_id, (try db.lookupInterned(CompileTimeValues, (try db.get(ResolveStatic, value_item)).*.?)).type);
    try std.testing.expectEqualDeep(structures.TypeLayout{ .byte_size = 3, .byte_alignment = 1 }, (try db.get(HostTypeLayout, type_id)).*);
    try std.testing.expectEqualDeep(structures.TypeLayout{ .byte_size = 0, .byte_alignment = 1 }, (try db.get(HostTypeLayout, empty)).*);
    const updated = (try db.get(OwnershipCapabilities, type_id)).*.?;
    try std.testing.expectEqual(structures.MoveCapability.fieldwise, updated.move);
    try std.testing.expectEqual(structures.CopyCapability.trivial, updated.copy);
    try std.testing.expectEqual(structures.DropCapability.trivial, updated.drop);
    try std.testing.expect(!updated.requires_explicit_drop);
}

test "inline array factory interception does not recognize unrelated Array declarations" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\import std.prelude.{}
        \\pub struct Array(T: type, N: int)
        \\    value: T
        \\static Value = Array(int, 3)
    , &.{}, &.{});
    const scope = (try db.get(BuildModuleScope, 0)).*.?;
    const type_id = (try db.lookupInterned(CompileTimeValues, (try db.get(ResolveStatic, scope.resolve("Value").?)).*.?)).type;
    const facts: TypeFacts(@TypeOf(db)) = .{ .ctx = db };
    try std.testing.expect(try facts.arrayType(type_id) == null);
    const definition = (try facts.structDefinition(type_id)).?;
    try std.testing.expectEqual(@as(usize, 1), definition.fields.len);
    try std.testing.expectEqualStrings("value", definition.fields[0].name);
}
