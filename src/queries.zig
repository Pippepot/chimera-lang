const std = @import("std");
const standard_library = @import("standard_library");
const structures = @import("structures.zig");
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

pub const ModuleCatalog = struct {
    pub const Key = void;
    pub const Value = []const structures.ModuleId;

    pub fn cloneValue(gpa: std.mem.Allocator, value: Value) !Value {
        return gpa.dupe(structures.ModuleId, value);
    }

    pub fn eqlValue(a: Value, b: Value) bool {
        return std.mem.eql(structures.ModuleId, a, b);
    }

    pub fn deinitValue(gpa: std.mem.Allocator, value: *Value) void {
        gpa.free(value.*);
        value.* = undefined;
    }
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
    const registered = ctx.input(StandardFile, @intFromEnum(file)) catch |err| switch (err) {
        error.InputNotFound => return null,
        else => return err,
    };
    return registered.*;
}

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

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, value.origin);
        std.hash.autoHash(&hasher, value.owner);
        std.hash.autoHash(&hasher, value.source_site);
        std.hash.autoHash(&hasher, value.is_hook);
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

pub fn TypeInterner(comptime Context: type) type {
    return struct {
        ctx: Context,
        file_id: ?structures.FileId = null,
        instance: ?structures.InstanceId = null,
        prior_static_arguments: ?[]const structures.CompileTimeValueId = null,

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
                .generated => |generated| blk: {
                    const resolved = (try self.ctx.get(ResolveItem, generated.owner.item)).* orelse return error.Unavailable;
                    const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
                    if (!semantic.isDirectlyReturnedStructSite(&parsed, resolved.declaration, generated.node_offset)) break :blk "anonymous struct";
                    break :blk (try self.ctx.lookupInterned(ItemLocations, generated.owner.item)).name;
                },
            };
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            const identity = (try self.structIdentity(type_id)) orelse return null;
            return (try getStructDefinition(self.ctx, identity)) orelse return error.Unavailable;
        }

        pub fn structIdentity(self: @This(), type_id: structures.TypeId) !?structures.StructIdentity {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            return switch (data.*) {
                .structure => |identity| identity,
                .variant, .callable => null,
            };
        }

        pub fn structNamespaceMember(self: @This(), type_id: structures.TypeId, name: []const u8, span: structures.SourceSpan) !?structures.InstanceId {
            const identity = (try self.structIdentity(type_id)) orelse return null;
            const namespace = (try self.ctx.get(StructNamespace, identity)).* orelse return error.Unavailable;
            return .{
                .item = (try self.visibleStructMember(namespace, name, span)) orelse return null,
                .specialization = switch (identity) {
                    .declared => null,
                    .generated => |generated| generated.owner.specialization,
                },
            };
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

        pub fn staticParameterType(self: @This(), instance: structures.InstanceId, parameter_index: usize, prior: []const structures.CompileTimeValueId) !structures.TypeId {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
            const type_interner: @This() = .{
                .ctx = self.ctx,
                .file_id = resolved.file_id,
                .instance = instance,
                .prior_static_arguments = prior,
            };
            return switch (try semantic.analyzeStaticParameterType(&parsed, source, resolved.declaration, parameter_index, type_interner, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
        }

        pub fn independentParameterType(self: @This(), instance: structures.InstanceId, runtime_index: usize) !?structures.TypeId {
            if (try self.needsInheritedInference(instance)) return null;
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
            const type_interner: @This() = .{
                .ctx = self.ctx,
                .file_id = resolved.file_id,
                .instance = instance,
                .prior_static_arguments = &.{},
            };
            return switch (try semantic.analyzeIndependentParameterType(&parsed, source, resolved.declaration, runtime_index, type_interner, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, resolved.file_id, issue);
                    return error.Unavailable;
                },
            };
        }

        pub fn inferStaticArguments(self: @This(), instance: structures.InstanceId, argument_types: []const structures.TypeId) !semantic.StaticInference {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
            const type_interner: @This() = .{
                .ctx = self.ctx,
                .file_id = resolved.file_id,
                .instance = instance,
                .prior_static_arguments = &.{},
            };
            const inherited_from = if (try self.needsInheritedInference(instance)) blk: {
                const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
                const owner_item = location.owner orelse unreachable;
                const owner = (try self.ctx.get(ResolveItem, owner_item)).* orelse return error.Unavailable;
                const owner_arity = (try self.ctx.get(SpecializationArity, owner_item)).* orelse return error.Unavailable;
                const provided = if (instance.specialization) |tuple|
                    (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len
                else
                    0;
                if (provided < owner_arity.inherited or owner.file_id != resolved.file_id or
                    semantic.parameterizedStructSite(&parsed, owner.declaration) == null) return .missing;
                break :blk owner.declaration;
            } else null;
            return semantic.inferStaticArguments(&parsed, source, resolved.declaration, argument_types, type_interner, self.ctx.allocator(), inherited_from);
        }

        pub fn inferStructArguments(self: @This(), instance: structures.InstanceId, fields: []const semantic.UnresolvedBody.StructFieldValue, field_types: []const structures.TypeId) !semantic.StaticInference {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
            const type_interner: @This() = .{
                .ctx = self.ctx,
                .file_id = resolved.file_id,
                .instance = instance,
                .prior_static_arguments = &.{},
            };
            return semantic.inferStructArguments(&parsed, source, resolved.declaration, fields, field_types, type_interner, self.ctx.allocator());
        }

        pub fn independentStructFieldType(self: @This(), instance: structures.InstanceId, name: []const u8) !?structures.TypeId {
            const resolved = (try self.ctx.get(ResolveItem, instance.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const source = (try self.ctx.input(SourceText, resolved.file_id)).*;
            const type_interner: @This() = .{
                .ctx = self.ctx,
                .file_id = resolved.file_id,
                .instance = instance,
                .prior_static_arguments = &.{},
            };
            return switch (try semantic.analyzeIndependentStructFieldType(&parsed, source, resolved.declaration, name, type_interner, self.ctx.allocator())) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    try typing.emitSemanticIssue(self.ctx, resolved.file_id, issue);
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
            const identity = (try self.structIdentity(type_id)) orelse return null;
            if (identity != .generated or identity.generated.owner.item != factory.item) return null;
            const resolved = (try self.ctx.get(ResolveItem, factory.item)).* orelse return error.Unavailable;
            const parsed = (try self.ctx.get(ParseFile, resolved.file_id)).* orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&parsed, resolved.declaration) orelse return null;
            if (identity.generated.node_offset != site) return null;
            const arity = (try self.ctx.get(SpecializationArity, factory.item)).* orelse return error.Unavailable;
            const values = if (identity.generated.owner.specialization) |tuple|
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

        pub fn structLayout(self: @This(), type_id: structures.TypeId) !?structures.StructLayout {
            return (try self.ctx.get(StructLayout, type_id)).*;
        }

        pub fn ownershipCapabilities(self: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
            return (try self.ctx.get(OwnershipCapabilities, type_id)).*;
        }

        pub fn argumentPassing(self: @This(), type_id: structures.TypeId) !structures.ArgumentPassing {
            const capabilities = (try self.ownershipCapabilities(type_id)) orelse return error.Unavailable;
            return if (capabilities.move == .none or capabilities.move == .custom or capabilities.needs_custom_move)
                .indirect
            else
                .direct;
        }

        fn stdMemoryFunction(self: @This(), name: []const u8) !?structures.ItemId {
            const registered = (try standardFile(self.ctx, .memory_allocation)) orelse return null;
            const module = try self.ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_allocation.modulePath() });
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return null;
            const item = declarations.resolveFunction(name) orelse return null;
            const resolved = (try self.ctx.get(ResolveItem, item)).* orelse return null;
            return if (resolved.file_id == registered) item else null;
        }

        pub fn isStdRefNew(self: @This(), item: structures.ItemId) !bool {
            const location = try self.ctx.lookupInterned(ItemLocations, item);
            if (!std.mem.eql(u8, location.name, "new")) return false;
            const factory = (try self.stdMemoryFunction(@tagName(standard_library.Structure.Ref))) orelse return false;
            if (location.owner != factory) return false;
            const member = (try self.genericStructNamespaceMember(.{ .item = factory }, "new", null)) orelse return false;
            return member.item == item;
        }

        pub fn isStdRefValue(self: @This(), item: structures.ItemId) !bool {
            return item == (try self.stdMemoryFunction("value") orelse return false);
        }

        pub fn isStdRefDestroy(self: @This(), item: structures.ItemId) !bool {
            const name = @tagName(standard_library.External.unsafe_destroy_ref);
            const location = try self.ctx.lookupInterned(ItemLocations, item);
            if (!std.mem.eql(u8, location.name, name)) return false;
            return item == (try self.stdMemoryFunction(name) orelse return false);
        }

        pub fn refTypeElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return refElementType(self.ctx, type_id);
        }

        pub const RefAllocation = struct {
            instance: structures.InstanceId,
            type_id: structures.TypeId,
        };

        pub fn refAllocation(self: @This(), element_type: structures.TypeId) !?RefAllocation {
            const item = (try self.stdMemoryFunction(@tagName(standard_library.External.allocate))) orelse return null;
            if ((try self.ctx.get(ExternalSymbol, item)).* != .allocate) return null;
            const argument = try self.internCompileTimeValue(.{ .type = element_type });
            const instance = try self.specializeFunction(.{ .item = item }, &.{argument});
            const signature = (try self.functionSignature(instance)) orelse return null;
            if (!signature.is_fallible or signature.parameters.len != 1 or
                signature.parameters[0].mode != .imm or signature.parameters[0].type_id != .int or
                (try allocationElementType(self.ctx, signature.return_type)) != element_type) return null;
            return .{ .instance = instance, .type_id = signature.return_type };
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
            const outcome = (try self.ctx.get(ExecuteComptimeThunk, .{ .owner = owner, .node = node, .expected_type = expected_type })).* orelse return null;
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
            return (try self.ctx.get(HostTypeLayout, type_id)).*;
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
            return null;
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
            if (value != .type or try self.structIdentity(value.type) == null) return null;
            if (try self.structNamespaceMember(value.type, name, span)) |instance| return .{ .declaration = instance };
            try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
            return error.Unavailable;
        }

        fn moduleMember(self: @This(), namespace: structures.NamespaceBinding, name: []const u8, span: structures.SourceSpan) !structures.NameReference {
            const imports = (try self.ctx.get(ResolveFileImports, self.file_id.?)).* orelse return error.Unavailable;
            const path = (try self.ctx.lookupInterned(ModulePaths, namespace.module)).path;
            const child_path = try std.fmt.allocPrint(self.ctx.allocator(), "{s}.{s}", .{ path, name });
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
            const shape = (try self.ctx.get(FunctionShape, instance.item)).* orelse return error.Unavailable;
            for (shape.parameters) |parameter| if (parameter.mode == .static) return null;
            const signature = (try self.functionSignature(instance)) orelse return error.Unavailable;
            if (signature.return_type == .type) return null;
            return .{
                .target = instance.item,
                .specialization = instance.specialization,
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

pub const HostTypeLayout = struct {
    pub const Input = structures.TypeId;
    pub const Output = structures.TypeLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id == .int or type_id == .bool) return .{ .byte_size = 4, .byte_alignment = 4 };
        if (type_id == .byte) return .{ .byte_size = 1, .byte_alignment = 1 };
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
            .variant, .callable => return null,
        };
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        var visited: StructVisits = .empty;
        defer visited.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, identity, &visited)) return null;

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
                return @intFromEnum(left) < @intFromEnum(right);
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
            if (entry.is_public) try names.put(entry.name, {});
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
                return @intFromEnum(left.item) < @intFromEnum(right.item);
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
            .span = nodeSpan(&parsed, @enumFromInt(location.declaration)),
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
                .span = nodeSpan(&parsed, @enumFromInt(resolved.declaration)),
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
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
        const result = semantic.analyzeFunctionInstanceSignature(&parsed, source, resolved.declaration, specialization[arity.inherited..], type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |signature| try validateExternalSignature(ctx, instance.item, resolved.file_id, &parsed, resolved.declaration, signature),
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
            .success => |signature| try validateExternalSignature(ctx, item_id, resolved.file_id, &parsed, resolved.declaration, signature),
            .unsupported => |issue| blk: {
                try typing.emitSemanticIssue(ctx, resolved.file_id, issue);
                break :blk null;
            },
        };
    }
};

fn validateExternalSignature(ctx: anytype, item: structures.ItemId, file_id: structures.FileId, parsed: *const structures.Ast, declaration: u32, signature: structures.FunctionSignature) !?structures.FunctionSignature {
    if (!semantic.isExternalFunction(parsed, declaration)) return signature;
    const symbol = (try ctx.get(ExternalSymbol, item)).* orelse return null;
    const valid = switch (symbol) {
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
        .unsafe_initialize, .unsafe_take => blk: {
            if (signature.is_fallible or signature.parameters.len != (if (symbol == .unsafe_initialize) @as(usize, 3) else 2)) break :blk false;
            const allocation = signature.parameters[0];
            if (allocation.mode != .mut) break :blk false;
            const element_type = (try allocationElementType(ctx, allocation.type_id)) orelse break :blk false;
            const capabilities = (try ctx.get(OwnershipCapabilities, element_type)).* orelse break :blk false;
            if (capabilities.move == .none or capabilities.move == .custom or capabilities.needs_custom_move) break :blk false;
            if (signature.parameters[1].mode != .imm or signature.parameters[1].type_id != .int) break :blk false;
            break :blk if (symbol == .unsafe_initialize)
                signature.return_type == .unit and signature.parameters[2].mode == .@"var" and signature.parameters[2].type_id == element_type
            else
                signature.return_type == element_type;
        },
        .unsafe_own_ref => blk: {
            if (signature.is_fallible or signature.parameters.len != 1 or signature.parameters[0].mode != .deinit) break :blk false;
            const element_type = (try allocationElementType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            break :blk (try refElementType(ctx, signature.return_type)) == element_type;
        },
        .unsafe_take_ref, .unsafe_destroy_ref, .deallocate_ref => blk: {
            if (signature.is_fallible or signature.parameters.len != 1) break :blk false;
            const element_type = (try refElementType(ctx, signature.parameters[0].type_id)) orelse break :blk false;
            if (symbol == .deallocate_ref) break :blk signature.parameters[0].mode == .deinit and signature.return_type == .unit;
            if (symbol == .unsafe_destroy_ref) break :blk signature.parameters[0].mode == .imm and signature.return_type == .unit;
            const capabilities = (try ctx.get(OwnershipCapabilities, element_type)).* orelse break :blk false;
            break :blk signature.parameters[0].mode == .mut and signature.return_type == element_type and
                capabilities.move != .none and capabilities.move != .custom and !capabilities.needs_custom_move;
        },
    };
    if (valid) return signature;
    ctx.allocator().free(signature.parameters);
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = nodeSpan(parsed, @enumFromInt(declaration)),
        .kind = .invalid_external_signature,
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

fn allocationElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return null;
    const generated = switch (data.*) {
        .structure => |identity| switch (identity) {
            .generated => |value| value,
            .declared => return null,
        },
        .variant, .callable => return null,
    };
    const memory_module = try ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_allocation.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, memory_module)).* orelse return null;
    const allocation_item = declarations.resolveFunction(@tagName(standard_library.Structure.Allocation)) orelse return null;
    if (generated.owner.item != allocation_item) return null;
    const registered = (try standardFile(ctx, .memory_allocation)) orelse return null;
    const resolved = (try ctx.get(ResolveItem, allocation_item)).* orelse return null;
    if (resolved.file_id != registered) return null;
    const tuple = generated.owner.specialization orelse return null;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != 1) return null;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const element_type = switch (element) {
        .type => |value| value,
        .runtime => return null,
    };
    if (element_type == .type) return null;
    const definition = (try ctx.get(GeneratedStructDefinition, generated)).* orelse return null;
    if (definition.fields.len != 2 or
        definition.accessible_fields or
        definition.ownership.move != null or definition.ownership.copy != null or
        definition.ownership.drop == null or definition.ownership.drop.?.capability != .explicit)
    {
        return null;
    }
    const storage_type = (try hostStorageType(ctx, declarations)) orelse return null;
    if (!std.mem.eql(u8, definition.fields[0].name, "storage") or
        definition.fields[0].type_id != storage_type or
        !std.mem.eql(u8, definition.fields[1].name, "count") or
        definition.fields[1].type_id != .int)
    {
        return null;
    }
    return element_type;
}

fn refElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return null;
    const generated = switch (data.*) {
        .structure => |identity| switch (identity) {
            .generated => |value| value,
            .declared => return null,
        },
        .variant, .callable => return null,
    };
    const memory_module = try ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_allocation.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, memory_module)).* orelse return null;
    const ref_item = declarations.resolveFunction(@tagName(standard_library.Structure.Ref)) orelse return null;
    if (generated.owner.item != ref_item) return null;
    const registered = (try standardFile(ctx, .memory_allocation)) orelse return null;
    const resolved = (try ctx.get(ResolveItem, ref_item)).* orelse return null;
    if (resolved.file_id != registered) return null;
    const tuple = generated.owner.specialization orelse return null;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != 1) return null;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const element_type = switch (element) {
        .type => |value| value,
        .runtime => return null,
    };
    const definition = (try ctx.get(GeneratedStructDefinition, generated)).* orelse return null;
    if (definition.fields.len != 1 or definition.accessible_fields or
        definition.ownership.move != null or definition.ownership.copy != null or definition.ownership.drop == null or
        definition.ownership.drop.?.capability != .custom or
        !std.mem.eql(u8, definition.fields[0].name, "allocation") or
        (try allocationElementType(ctx, definition.fields[0].type_id)) != element_type)
    {
        return null;
    }
    return element_type;
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
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
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
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = site.owner,
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
            return switch (symbol) {
                .exit => .{ .completed = .{
                    .outcome = .{ .exit = arguments[0].runtime.int },
                    .arguments = key.arguments,
                } },
                .allocate_host_storage, .deallocate_host_storage, .allocate, .deallocate, .unsafe_initialize, .unsafe_take, .unsafe_own_ref, .unsafe_take_ref, .unsafe_destroy_ref, .deallocate_ref => null,
            };
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
            break :generated @enumFromInt(position);
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
            const member = parsed.nodes[member_index.index()];
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
                if ((try names.getOrPut(loc.name)).found_existing) {
                    const member_parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
                    const declaration = index.resolve(item_id) orelse unreachable;
                    const token = member_parsed.tokens[member_parsed.nodes[declaration].token_index];
                    try ctx.emit(structures.Diagnostic, .{
                        .file_id = file_id,
                        .span = .{ .start = token.loc.start, .end = token.loc.end },
                        .kind = .duplicate_struct_member,
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
        const type_interner: TypeInterner(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = identity.owner,
        };
        const result = semantic.analyzeGeneratedStructDefinition(&parsed, source, struct_node, identity, type_interner, ctx.allocator()) catch |err| switch (err) {
            error.Unavailable => return null,
            else => return err,
        };
        return switch (result) {
            .success => |definition| blk: {
                var owned = definition;
                if (std.mem.eql(u8, loc.name, @tagName(standard_library.Structure.Allocation)) or std.mem.eql(u8, loc.name, @tagName(standard_library.Structure.Ref))) {
                    if ((try standardFile(ctx, .memory_allocation)) == resolved.file_id) owned.accessible_fields = false;
                }
                break :blk owned;
            },
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
    pub const disk_boundary = true;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        return analyzeFunctionBody(ctx, .{ .item = item_id }, false);
    }
};

pub const AnalyzeFunctionInstance = struct {
    pub const disk_boundary = true;
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
    if ((try ctx.get(BuildModuleScope, resolved.file_id)).* == null) return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    if (loc.kind == .function and semantic.isExternalFunction(&parsed, resolved.declaration)) return null;
    const source = (try ctx.input(SourceText, resolved.file_id)).*;
    const type_interner: TypeInterner(@TypeOf(ctx)) = .{
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
    return typing.resolveAndTypeBody(
        ctx,
        instance,
        resolved.file_id,
        parameters,
        return_type,
        is_fallible,
        .{ .publish_instruction_spans = publish_instruction_spans, .allow_type_values = publish_instruction_spans },
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
                .exit => try codegen.compileExternalExit(ctx.allocator()),
                .allocate_host_storage => try codegen.compileExternalAllocateHostStorage(ctx.allocator()),
                .deallocate_host_storage => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .allocate => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const element_type = (try allocationElementType(ctx, signature.return_type)) orelse unreachable;
                    const layout = (try ctx.get(HostTypeLayout, element_type)).*;
                    break :blk try codegen.compileExternalAllocateHostTypedStorage(ctx.allocator(), layout);
                },
                .deallocate => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .unsafe_initialize, .unsafe_take => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const element_type = (try allocationElementType(ctx, signature.parameters[0].type_id)) orelse unreachable;
                    const layout = (try ctx.get(HostTypeLayout, element_type)).*;
                    const allocation_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    break :blk try codegen.compileExternalHostSlotTransfer(ctx.allocator(), allocation_layout, layout, symbol == .unsafe_initialize, true);
                },
                .unsafe_own_ref => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const allocation_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    const ref_layout = (try ctx.get(HostTypeLayout, signature.return_type)).*;
                    std.debug.assert(std.meta.eql(allocation_layout, ref_layout));
                    break :blk try codegen.compileExternalHostRefWrap(ctx.allocator(), ref_layout);
                },
                .unsafe_take_ref => blk: {
                    const signature = (try ctx.get(FunctionInstanceSignature, instance_id)).* orelse return null;
                    const layout = (try ctx.get(HostTypeLayout, signature.return_type)).*;
                    const ref_layout = (try ctx.get(HostTypeLayout, signature.parameters[0].type_id)).*;
                    break :blk try codegen.compileExternalHostSlotTransfer(ctx.allocator(), ref_layout, layout, false, false);
                },
                .unsafe_destroy_ref => unreachable,
                .deallocate_ref => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
            };
        }
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
