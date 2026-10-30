const std = @import("std");
const intrinsics = @import("intrinsics.zig");
const profiling = @import("profiling.zig");
const standard_library = @import("standard_library");
const structures = @import("structures.zig");
const value_operations = @import("value.zig");
const ast = @import("frontend/parser.zig");
const codegen = @import("backend/codegen.zig");
const comptime_interpreter = @import("frontend/comptime_interpreter.zig");
const optimizer = @import("optimizer/optimizer.zig");
const semantic = @import("frontend/semantic.zig");
const typing = @import("frontend/typing.zig");
const diagnostic_rendering = @import("diagnostics.zig");

fn CompilerQuery(comptime name: []const u8, comptime category: profiling.Category, comptime run_fn: anytype, comptime options: @import("query/engine.zig").QueryOptions) type {
    return @import("query/engine.zig").Query("queries." ++ name, category, run_fn, options);
}

fn OwnedInterner(comptime ValueType: type, comptime IdType: type) type {
    return struct {
        pub const Value = ValueType;
        pub const Id = IdType;
        pub const hash = value_operations.Owned(Value).hash;
        pub const eql = value_operations.Owned(Value).eql;
        pub const clone = value_operations.Owned(Value).clone;
        pub const deinit = value_operations.Owned(Value).destroy;
    };
}

fn OwnedInput(comptime name: []const u8, comptime KeyType: type, comptime ValueType: type) type {
    return struct {
        pub const cache_name = "queries." ++ name;
        pub const Key = KeyType;
        pub const Value = ValueType;
        pub const cloneValue = value_operations.Owned(Value).clone;
        pub const eqlValue = value_operations.Owned(Value).eql;
        pub const deinitValue = value_operations.Owned(Value).destroy;
    };
}

pub const SourceText = OwnedInput("SourceText", structures.FileId, []const u8);

test "query profiling categories belong to every compiler query" {
    inline for (@typeInfo(@This()).@"struct".decl_names) |name| {
        const Declaration = @field(@This(), name);
        if (@TypeOf(Declaration) == type) {
            if (@typeInfo(Declaration) == .@"struct") {
                if (@hasDecl(Declaration, "run") and @hasDecl(Declaration, "Input") and @hasDecl(Declaration, "Output"))
                    try std.testing.expect(@hasDecl(Declaration, "profile_category"));
            }
        }
    }
    try std.testing.expectEqual(profiling.Category.comptime_execution, profiling.queryCategory(ResolveStaticInstance));
    try std.testing.expectEqual(profiling.Category.comptime_execution, profiling.queryCategory(ExecuteStaticIteration));
}

pub const SourcePath = OwnedInput("SourcePath", structures.FileId, []const u8);

pub const SourceLineStarts = struct {
    pub const profile_category: profiling.Category = .parsing;
    pub const Input = structures.FileId;
    pub const Output = struct {
        offsets: []const usize,

        pub const eql = value_operations.Owned(@This()).eql;
        pub const deinit = value_operations.Owned(@This()).deinit;
    };

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const source = (try ctx.input(SourceText, file_id)).*;
        var offsets: std.ArrayList(usize) = .empty;
        errdefer offsets.deinit(ctx.allocator());
        try offsets.append(ctx.allocator(), 0);
        for (source, 0..) |byte, index| {
            if (byte == '\n') try offsets.append(ctx.allocator(), index + 1);
        }
        return .{ .offsets = try offsets.toOwnedSlice(ctx.allocator()) };
    }
};

pub const ParseFile = struct {
    pub const profile_category: profiling.Category = .parsing;
    pub const Input = structures.FileId;
    pub const Output = ?structures.Ast;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const source = (try ctx.input(SourceText, file_id)).*;
        if (standardAst(source)) |embedded| {
            var parsed = try value_operations.Owned(structures.Ast).clone(ctx.allocator(), embedded);
            parsed.file_id = file_id;
            return parsed;
        }
        var report = try ast.parseReport(ctx.allocator(), file_id, source);
        defer report.deinit(ctx.allocator());

        for (report.diagnostics) |diagnostic| {
            try ctx.emit(structures.Diagnostic, diagnostic);
        }

        const parsed = report.ast;
        report.ast = null;
        return parsed;
    }

    fn standardAst(source: []const u8) ?structures.Ast {
        inline for (standard_library.paths) |path| {
            const embedded = comptime standard_library.source(path);
            if (source.len == embedded.len and std.mem.eql(u8, source, embedded))
                return comptime ast.parseEmbedded(embedded);
        }
        return null;
    }
};

pub const FileModule = OwnedInput("FileModule", structures.FileId, structures.ModuleId);

pub const ModuleMembers = OwnedInput("ModuleMembers", structures.ModuleId, []const structures.FileId);
pub const ModuleCatalog = OwnedInput("ModuleCatalog", void, []const structures.ModuleId);

/// Identifies the compiler-owned prelude independently of the user module
/// catalog, so user module additions cannot invalidate its resolution.
pub const StandardPreludeModule = OwnedInput("StandardPreludeModule", void, structures.ModuleId);
pub const InlineLimit = OwnedInput("InlineLimit", void, u32);
pub const default_inline_limit: u32 = 48;
pub const StandardFile = OwnedInput("StandardFile", u32, structures.FileId);

/// The embedded bundle is valid only for the closed compiler-owned library.
/// Unrelated module changes can recheck this fact without invalidating std.
pub const StandardLibraryUnchanged = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const disk_boundary = true;
    pub const Input = void;
    pub const Output = ?[standard_library.paths.len]structures.FileId;

    pub fn run(ctx: anytype, _: Input) anyerror!Output {
        @setEvalBranchQuota(100_000);
        var files: [standard_library.paths.len]structures.FileId = undefined;
        const catalog = ctx.input(ModuleCatalog, {}) catch |err| switch (err) {
            error.InputNotFound => return null,
            else => return err,
        };
        inline for (standard_library.paths, 0..) |path, index| {
            const registered = ctx.input(StandardFile, index) catch |err| switch (err) {
                error.InputNotFound => return null,
                else => return err,
            };
            const file = registered.*;
            files[index] = file;
            const module = try ctx.intern(ModulePaths, .{ .path = standard_library.standardModulePath(path) });
            if (std.mem.indexOfScalar(structures.ModuleId, catalog.*, module) == null) return null;
            if (!try matches(SourceText, ctx, file, standard_library.source(path))) return null;
            if (!try matches(SourcePath, ctx, file, "$std/" ++ path)) return null;
            if (!try matches(FileModule, ctx, file, module)) return null;
            var members: [standard_library.paths.len]structures.FileId = undefined;
            var count: usize = 0;
            inline for (standard_library.paths, 0..) |other, other_index| {
                if (comptime std.mem.eql(u8, standard_library.standardModulePath(path), standard_library.standardModulePath(other))) {
                    const other_file = ctx.input(StandardFile, other_index) catch |err| switch (err) {
                        error.InputNotFound => return null,
                        else => return err,
                    };
                    members[count] = other_file.*;
                    count += 1;
                }
            }
            std.mem.sort(structures.FileId, members[0..count], {}, std.sort.asc(structures.FileId));
            if (!try matches(ModuleMembers, ctx, module, members[0..count])) return null;
        }
        const prelude = try ctx.intern(ModulePaths, .{ .path = standard_library.File.prelude.modulePath() });
        if (!try matches(StandardPreludeModule, ctx, {}, prelude)) return null;
        return files;
    }

    fn matches(comptime I: type, ctx: anytype, key: I.Key, expected: I.Value) !bool {
        const actual = ctx.input(I, key) catch |err| switch (err) {
            error.InputNotFound => return false,
            else => return err,
        };
        return value_operations.equal(I.Value, actual.*, expected);
    }
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

pub const ModulePaths = OwnedInterner(structures.ModulePath, structures.ModuleId);

pub const DiscoverItems = CompilerQuery("DiscoverItems", .declarations, discoverItems, .{});

fn discoverItems(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ItemTree {
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
        if (item.loc.name == .converter) continue;
        if (!(try names.getOrPut(item.loc.name.text())).found_existing) continue;
        has_duplicates = true;
        std.debug.assert(ast_value.nodes[item.declaration].tag == .static_binding);
        try rejectDeclaration(ctx, file_id, &ast_value, item.declaration, .duplicate_top_level_declaration);
    }
    if (has_duplicates) {
        // A duplicated top-level name makes the module's namespace invalid,
        // so no downstream query can index or build from the tree.
        tree.deinit(ctx.allocator());
        return null;
    }
    return tree;
}

/// Reports an issue at a declaration's first token.
fn rejectDeclaration(ctx: anytype, file_id: structures.FileId, parsed: *const structures.Ast, declaration: u32, kind: structures.Diagnostic.Kind) !void {
    const token = parsed.tokens[parsed.nodes[declaration].token_index];
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = .{ .start = token.loc.start, .end = token.loc.end }, .kind = kind });
}

pub const ItemLocations = OwnedInterner(structures.ItemLoc, structures.ItemId);
pub const FunctionOverloads = OwnedInterner(structures.FunctionOverloadSet, structures.FunctionOverloadId);

pub const ResolveOverloads = CompilerQuery("ResolveOverloads", .declarations, resolveOverloads, .{});

fn resolveOverloads(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionOverloadId {
    const declaration = (try declarationSource(ctx, instance)) orelse return null;
    const parsed = &declaration.parsed;
    const binding = parsed.nodes[declaration.resolved.declaration];
    const value = binding.data.node_node.b;
    std.debug.assert(parsed.nodes[value.index()].tag == .overload);
    const nodes = parsed.nodeList(value);
    std.debug.assert(nodes.len != 0);
    var candidates: std.AutoArrayHashMapUnmanaged(structures.InstanceId, void) = .empty;
    defer candidates.deinit(ctx.allocator());
    for (nodes) |node| {
        const issue: structures.Diagnostic.Kind = issue: {
            const reference = semantic.resolveNamedExpression(parsed, declaration.source, node, declaration.analysis) catch |err| switch (err) {
                error.QueryCycle => break :issue .declaration_cycle,
                else => return err,
            };
            if (reference == null or reference.? != .declaration or (try ctx.lookupInterned(ItemLocations, reference.?.declaration.item)).kind != .function) break :issue .invalid_overload_candidate;
            if ((try candidates.getOrPut(ctx.allocator(), reference.?.declaration)).found_existing) break :issue .duplicate_overload_candidate;
            continue;
        };
        try typing.emitSemanticIssue(ctx, declaration.resolved.file_id, .{ .span = nodeSpan(parsed, node), .kind = issue });
        return null;
    }
    return try ctx.intern(FunctionOverloads, .{ .candidates = candidates.keys(), .declaration = instance });
}

pub const Types = struct {
    pub const Value = structures.TypeData;
    pub const Id = structures.InternedTypeId;

    pub const hash = value_operations.Owned(Value).hash;

    pub const eql = value_operations.Owned(Value).eql;

    pub fn clone(gpa: std.mem.Allocator, value: Value) !Value {
        if (value == .variant) {
            std.debug.assert(value.variant.members.len >= 2);
            for (value.variant.members[0 .. value.variant.members.len - 1], value.variant.members[1..]) |previous, member| {
                std.debug.assert(@backingInt(previous) < @backingInt(member));
            }
        }
        return value_operations.Owned(Value).clone(gpa, value);
    }

    pub const deinit = value_operations.Owned(Value).destroy;
};

pub const ByteStrings = OwnedInterner(structures.ByteString, structures.ByteStringId);

pub const CompileTimeValues = OwnedInterner(structures.CompileTimeValue, structures.CompileTimeValueId);

pub const CompileTimeBindings = OwnedInterner(structures.CompileTimeBindings, structures.CompileTimeBindingsId);
pub const CompileTimeValueTuples = OwnedInterner(structures.CompileTimeValueTuple, structures.CompileTimeValueTupleId);

/// Primitive types have no interned data.
fn typeData(ctx: anytype, type_id: structures.TypeId) !?structures.TypeData {
    return (try ctx.lookupInterned(Types, type_id.interned() orelse return null)).*;
}

fn typePayload(ctx: anytype, type_id: structures.TypeId, comptime tag: std.meta.Tag(structures.TypeData)) !?@FieldType(structures.TypeData, @tagName(tag)) {
    const data = (try typeData(ctx, type_id)) orelse return null;
    return if (data == tag) @field(data, @tagName(tag)) else null;
}

fn staticArgumentValues(ctx: anytype, tuple: ?structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
    return if (tuple) |id| (try ctx.lookupInterned(CompileTimeValueTuples, id)).values else &.{};
}

fn sortIds(comptime Id: type, ids: []Id) void {
    std.mem.sort(Id, ids, {}, struct {
        fn lessThan(_: void, left: Id, right: Id) bool {
            return @backingInt(left) < @backingInt(right);
        }
    }.lessThan);
}

pub fn internVariantType(ctx: anytype, members: []const structures.TypeId) !structures.TypeId {
    std.debug.assert(members.len >= 1);

    var canonical: std.ArrayList(structures.TypeId) = .empty;
    defer canonical.deinit(ctx.allocator());
    for (members) |member| {
        if (try typePayload(ctx, member, .variant)) |nested| {
            try canonical.appendSlice(ctx.allocator(), nested.members);
        } else {
            try canonical.append(ctx.allocator(), member);
        }
    }

    sortIds(structures.TypeId, canonical.items);
    var member_count: usize = 0;
    for (canonical.items) |member| {
        if (member == .never) continue;
        if (member_count != 0 and canonical.items[member_count - 1] == member) continue;
        canonical.items[member_count] = member;
        member_count += 1;
    }
    canonical.items.len = member_count;
    if (canonical.items.len == 0) return .never;
    if (canonical.items.len == 1) return canonical.items[0];

    const interned_id = try ctx.intern(Types, .{ .variant = .{ .members = canonical.items } });
    return .fromInterned(interned_id);
}

pub fn internStructType(ctx: anytype, item_id: structures.ItemId) !structures.TypeId {
    return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .declared = item_id } }));
}

fn internGeneratedStructType(ctx: anytype, identity: structures.GeneratedStructIdentity) !structures.TypeId {
    const location = try ctx.lookupInterned(ItemLocations, identity.owner.item);
    if (location.owner == null and std.mem.eql(u8, location.name.text(), "Array")) {
        const factory = try standardFunction(ctx, .array, "Array");
        if (factory == identity.owner.item) return internStandardArrayType(ctx, identity);
    }
    return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
}

fn semanticValue(ctx: anytype, file_id: structures.FileId, instance: ?structures.InstanceId, result: anytype) !@FieldType(@typeInfo(@TypeOf(result)).error_union.payload, "success") {
    switch (try result) {
        .success => |value| return value,
        .unsupported => |issue| {
            try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = issue.span, .kind = issue.kind, .instance = instance });
            return error.Unavailable;
        },
    }
}

fn availableSemanticValue(ctx: anytype, file_id: structures.FileId, instance: ?structures.InstanceId, result: anytype) !?@FieldType(@typeInfo(@TypeOf(result)).error_union.payload, "success") {
    return semanticValue(ctx, file_id, instance, result) catch |err| switch (err) {
        error.Unavailable => null,
        else => return err,
    };
}

const ItemSource = struct {
    resolved: structures.ResolvedItem,
    parsed: structures.Ast,
};

fn itemSource(ctx: anytype, item: structures.ItemId) !?ItemSource {
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    return .{ .resolved = resolved, .parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null };
}

/// A declaration's syntax and text with an analysis context for one instance.
fn DeclarationSource(comptime Context: type) type {
    return struct {
        resolved: structures.ResolvedItem,
        parsed: structures.Ast,
        source: []const u8,
        analysis: AnalysisContext(Context),
    };
}

fn declarationSource(ctx: anytype, instance: structures.InstanceId) !?DeclarationSource(@TypeOf(ctx)) {
    const item_source = (try itemSource(ctx, instance.item)) orelse return null;
    const file_id = item_source.resolved.file_id;
    return .{
        .resolved = item_source.resolved,
        .parsed = item_source.parsed,
        .source = (try ctx.input(SourceText, file_id)).*,
        .analysis = .{ .ctx = ctx, .file_id = file_id, .instance = instance },
    };
}

/// A compile-time site's owner declaration, analyzed in the site's static environment.
fn siteDeclaration(ctx: anytype, site: structures.CompileTimeSite) !?DeclarationSource(@TypeOf(ctx)) {
    var declaration = (try declarationSource(ctx, site.owner)) orelse return null;
    if (site.node.index() >= declaration.parsed.nodes.len) return null;
    declaration.analysis.public_annotation = site.public_annotation;
    if (site.bindings) |environment| declaration.analysis.static_bindings = (try ctx.lookupInterned(CompileTimeBindings, environment)).bindings;
    return declaration;
}

/// The module an item belongs to, including an entry file's module.
fn itemModule(ctx: anytype, location: structures.ItemLoc) !structures.ModuleId {
    return switch (location.origin) {
        .module => |module| module,
        .entry => |file_id| (try ctx.input(FileModule, file_id)).*,
    };
}

/// Resolves a compiler-known declaration only when it comes from its registered standard file.
fn standardDeclaration(
    ctx: anytype,
    file: standard_library.File,
    name: []const u8,
    comptime resolve: fn (structures.ModuleScope, []const u8) ?structures.ItemId,
) !?structures.ItemId {
    const registered = (try standardFile(ctx, file)) orelse return null;
    const module = try ctx.intern(ModulePaths, .{ .path = file.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
    const item = resolve(declarations, name) orelse return null;
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    return if (resolved.file_id == registered) item else null;
}

fn standardFunction(ctx: anytype, file: standard_library.File, name: []const u8) !?structures.ItemId {
    return standardDeclaration(ctx, file, name, structures.ModuleScope.resolveFunction);
}

fn internStandardArrayType(ctx: anytype, identity: structures.GeneratedStructIdentity) !structures.TypeId {
    const item_source = (try itemSource(ctx, identity.owner.item)) orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return error.Unavailable;
    if (identity.node_offset != site)
        return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
    const arguments = try staticArgumentValues(ctx, identity.owner.specialization);
    if (arguments.len != 2) return error.Unavailable;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const count = (try ctx.lookupInterned(CompileTimeValues, arguments[1])).*;
    const issue: structures.Diagnostic.Kind = issue: {
        if (element != .type or count != .runtime or count.runtime.type_id != .int or count.runtime.value != .int) break :issue .static_argument_type_mismatch;
        if (count.runtime.value.int < 0) break :issue .static_argument_not_supported;
        if (!try validArrayElementType(ctx, element.type)) break :issue .struct_field_type_not_supported;
        return .fromInterned(try ctx.intern(Types, .{ .array = .{
            .element_type = element.type,
            .length = @intCast(count.runtime.value.int),
        } }));
    };
    const span = nodeSpan(&item_source.parsed, @fromBackingInt(@intCast(item_source.resolved.declaration)));
    try typing.emitSemanticIssue(ctx, item_source.resolved.file_id, .{ .span = span, .kind = issue });
    return error.Unavailable;
}

fn validArrayElementType(ctx: anytype, type_id: structures.TypeId) anyerror!bool {
    if (type_id.isPrimitive()) return type_id != .type;
    switch ((try typeData(ctx, type_id)).?) {
        .structure, .callable, .reference => return true,
        .array => |array| return validArrayElementType(ctx, array.element_type),
        .variant => |variant| return for (variant.members) |member| {
            if (!try validArrayElementType(ctx, member)) break false;
        } else true,
        .tuple => |tuple| return for (tuple.members) |member| {
            if (!try validArrayElementType(ctx, member.type_id)) break false;
        } else true,
    }
}

const NamespaceIdentity = union(enum) {
    primitive: structures.ItemId,
    declared: structures.ItemId,
    generated: structures.GeneratedStructIdentity,

    fn fromStruct(identity: structures.StructIdentity) NamespaceIdentity {
        return switch (identity) {
            .declared => |item| .{ .declared = item },
            .generated => |generated| .{ .generated = generated },
        };
    }

    fn owner(self: NamespaceIdentity) structures.ItemId {
        return switch (self) {
            .primitive, .declared => |item| item,
            .generated => |generated| generated.owner.item,
        };
    }
};

const TypeNamespaceAssociation = struct {
    query_key: NamespaceIdentity,
    specialization: ?structures.CompileTimeValueTupleId = null,
    environment: ?structures.CompileTimeBindingsId = null,

    fn member(self: TypeNamespaceAssociation, item: structures.ItemId) structures.InstanceId {
        return .{ .item = item, .specialization = self.specialization, .environment = self.environment };
    }
};

const TypeNamespaceResult = union(enum) {
    missing,
    available: TypeNamespaceAssociation,
    unavailable,
};

pub const ResolveTypeNamespace = CompilerQuery("ResolveTypeNamespace", .type_facts, resolveTypeNamespace, .{ .disk_boundary = true });

fn resolveTypeNamespace(ctx: anytype, type_id: structures.TypeId) anyerror!TypeNamespaceResult {
    const association = computeTypeNamespace(ctx, type_id) catch |err| switch (err) {
        error.Unavailable => return .unavailable,
        else => return err,
    };
    return if (association) |available| .{ .available = available } else .missing;
}

fn computeTypeNamespace(ctx: anytype, type_id: structures.TypeId) !?TypeNamespaceAssociation {
    if (type_id.isPrimitive()) {
        const registered = (try standardFile(ctx, .prelude)) orelse return null;
        const module = (try ctx.input(FileModule, registered)).*;
        const owner = try ctx.intern(ItemLocations, .{ .origin = .{ .module = module }, .kind = .primitive, .name = .{ .identifier = @tagName(type_id) } });
        return .{ .query_key = .{ .primitive = owner } };
    }
    switch ((try typeData(ctx, type_id)).?) {
        .structure => |identity| {
            switch (identity) {
                .declared => return .{ .query_key = .fromStruct(identity) },
                .generated => |generated| return .{
                    .query_key = .{ .generated = .{
                        .owner = .{ .item = generated.owner.item, .environment = generated.owner.environment },
                        .node_offset = generated.node_offset,
                    } },
                    .specialization = generated.owner.specialization,
                    .environment = generated.owner.environment,
                },
            }
        },
        .array => |array| return (try arrayTypeNamespace(ctx, array)) orelse return error.Unavailable,
        .reference, .variant, .callable, .tuple => return null,
    }
}

fn arrayTypeNamespace(ctx: anytype, array: structures.ArrayType) !?TypeNamespaceAssociation {
    const factory = (try standardFunction(ctx, .array, "Array")) orelse return null;
    const item_source = (try itemSource(ctx, factory)) orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return error.Unavailable;
    return .{
        .query_key = .{ .generated = .{
            .owner = .{ .item = factory },
            .node_offset = site,
        } },
        .specialization = try arrayShapeArguments(ctx, array),
    };
}

/// The `(element type, length)` static arguments of array-shaped standard factories.
fn arrayShapeArguments(ctx: anytype, shape: structures.ArrayType) !structures.CompileTimeValueTupleId {
    const element = try ctx.intern(CompileTimeValues, .{ .type = shape.element_type });
    const length = std.math.cast(i32, shape.length) orelse unreachable;
    const count = try ctx.intern(CompileTimeValues, .{ .runtime = .{ .type_id = .int, .value = .{ .int = length } } });
    return ctx.intern(CompileTimeValueTuples, .{ .values = &.{ element, count } });
}

pub fn TypeFacts(comptime Context: type) type {
    return struct {
        ctx: Context,

        pub fn itemLocation(self: @This(), item: structures.ItemId) !structures.ItemLoc {
            return (try self.ctx.lookupInterned(ItemLocations, item)).*;
        }

        pub fn staticArguments(self: @This(), tuple: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
            return (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
        }

        pub fn staticValue(self: @This(), value: structures.CompileTimeValueId) !structures.CompileTimeValue {
            return (try self.ctx.lookupInterned(CompileTimeValues, value)).*;
        }

        pub fn staticParameterCounts(self: @This(), item: structures.ItemId) !?SpecializationArity.Counts {
            return (try self.ctx.get(SpecializationArity, item)).*;
        }

        pub fn structIdentity(self: @This(), type_id: structures.TypeId) !?structures.StructIdentity {
            return typePayload(self.ctx, type_id, .structure);
        }

        pub fn byteString(self: @This(), id: structures.ByteStringId) ![]const u8 {
            return (try self.ctx.lookupInterned(ByteStrings, id)).bytes;
        }

        pub fn structName(self: @This(), type_id: structures.TypeId) !?[]const u8 {
            const identity = switch ((try typeData(self.ctx, type_id)) orelse return null) {
                .structure => |structure| structure,
                .reference, .variant, .callable => return null,
                .array => return "Array",
                .tuple => return "tuple",
            };
            return switch (identity) {
                .declared => |item_id| (try self.ctx.lookupInterned(ItemLocations, item_id)).name.text(),
                .generated => |generated| blk: {
                    const item_source = (try itemSource(self.ctx, generated.owner.item)) orelse return error.Unavailable;
                    if (!semantic.isDirectlyReturnedStructSite(&item_source.parsed, item_source.resolved.declaration, generated.node_offset)) break :blk "anonymous struct";
                    break :blk (try self.ctx.lookupInterned(ItemLocations, generated.owner.item)).name.text();
                },
            };
        }

        pub fn internVariant(self: @This(), members: []const structures.TypeId) !structures.TypeId {
            return internVariantType(self.ctx, members);
        }

        pub fn referenceType(self: @This(), element_type: structures.TypeId) !structures.TypeId {
            return structures.TypeId.fromInterned(try self.ctx.intern(Types, .{ .reference = element_type }));
        }

        pub fn memberStorageType(self: @This(), member: structures.MemberSpec) !structures.TypeId {
            return if (member.kind == .reference) self.referenceType(member.type_id) else member.type_id;
        }

        pub fn memberSpec(self: @This(), storage_type: structures.TypeId) !structures.MemberSpec {
            if (try self.borrowElement(storage_type)) |element_type|
                return .{ .type_id = element_type, .kind = .reference };
            return .{ .type_id = storage_type };
        }

        pub fn internVariantMembers(self: @This(), members: []const structures.MemberSpec) !structures.TypeId {
            var storage_types: std.ArrayList(structures.TypeId) = .empty;
            defer storage_types.deinit(self.ctx.allocator());
            for (members) |member| try storage_types.append(self.ctx.allocator(), try self.memberStorageType(member));
            return internVariantType(self.ctx, storage_types.items);
        }

        pub fn internTuple(self: @This(), members: []const structures.MemberSpec) !structures.TypeId {
            std.debug.assert(members.len >= 1);
            return .fromInterned(try self.ctx.intern(Types, .{ .tuple = .{ .members = members } }));
        }

        pub fn tupleMembers(self: @This(), type_id: structures.TypeId) !?[]const structures.MemberSpec {
            const tuple = (try typePayload(self.ctx, type_id, .tuple)) orelse return null;
            return tuple.members;
        }

        pub fn fieldStorageType(self: @This(), field: structures.StructField) !structures.TypeId {
            return self.memberStorageType(.{ .kind = field.kind, .type_id = field.type_id });
        }

        pub fn internCallable(self: @This(), signature: structures.CallableType) !structures.TypeId {
            return .fromInterned(try self.ctx.intern(Types, .{ .callable = signature }));
        }

        pub fn variantMembers(self: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
            const variant = (try typePayload(self.ctx, type_id, .variant)) orelse return null;
            return variant.members;
        }

        pub fn callable(self: @This(), type_id: structures.TypeId) !?structures.CallableType {
            return typePayload(self.ctx, type_id, .callable);
        }

        pub fn arrayType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            return typePayload(self.ctx, type_id, .array);
        }

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?*const structures.StructDefinition {
            switch ((try typeData(self.ctx, type_id)) orelse return null) {
                .structure => |identity| return (try getStructDefinition(self.ctx, identity)) orelse error.Unavailable,
                .tuple => {
                    const definition = try self.ctx.get(TupleDefinition, type_id);
                    return if (definition.*) |*value| value else error.Unavailable;
                },
                .reference, .variant, .callable, .array => return null,
            }
        }

        pub fn components(self: @This(), type_id: structures.TypeId) !structures.TypeComponents {
            return switch ((try typeData(self.ctx, type_id)) orelse return .{}) {
                .array => |array| .{ .shape = .{ .array = array } },
                .tuple => |tuple| .{ .shape = .{ .tuple = tuple } },
                .variant => |variant| .{ .shape = .{ .variant = variant.members } },
                .structure => |identity| .{ .shape = .{ .structure = (try getStructDefinition(self.ctx, identity)) orelse return error.Unavailable } },
                .reference, .callable => .{},
            };
        }

        pub fn borrowElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return typePayload(self.ctx, type_id, .reference);
        }

        pub fn storageCursorAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .StorageCursor)) orelse return null;
            const definition = (try getStructDefinition(self.ctx, .{ .generated = instance.generated })) orelse return null;
            return if (intrinsics.validStorageCursor(definition)) instance.element_type else null;
        }

        pub fn storageAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return (try self.storageCursorAccess(type_id)) orelse try self.spanAccess(type_id);
        }

        pub fn spanAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .Span)) orelse return null;
            const definition = (try getStructDefinition(self.ctx, .{ .generated = instance.generated })) orelse return null;
            return if (try intrinsics.validSpan(self, definition, instance.element_type)) instance.element_type else null;
        }

        pub fn staticStringBytes(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const identity = (try self.structIdentity(type_id)) orelse return null;
            const definition = (try getStructDefinition(self.ctx, identity)) orelse return null;
            return if (try intrinsics.validStaticString(self, definition)) definition.fields[0].type_id else null;
        }

        pub fn isStaticString(self: @This(), type_id: structures.TypeId) !bool {
            const static_string = (try self.ctx.get(TextType, .StaticString)).* orelse return false;
            return static_string == type_id;
        }

        pub fn allocationElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .Allocation)) orelse return null;
            if (instance.element_type == .type) return null;
            const definition = (try getStructDefinition(self.ctx, .{ .generated = instance.generated })) orelse return null;
            const storage_type = (try self.hostStorage()) orelse return null;
            return if (intrinsics.validAllocation(definition, storage_type)) instance.element_type else null;
        }

        pub fn boxElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .Box)) orelse return null;
            const definition = (try getStructDefinition(self.ctx, .{ .generated = instance.generated })) orelse return null;
            if (!intrinsics.validBox(definition) or (try self.allocationElement(definition.fields[0].type_id)) != instance.element_type) return null;
            return instance.element_type;
        }

        pub fn hostStorage(self: @This()) !?structures.TypeId {
            const item = (try standardDeclaration(self.ctx, .memory_host, @tagName(standard_library.Structure.HostStorage), structures.ModuleScope.resolveStatic)) orelse return null;
            const definition = (try getStructDefinition(self.ctx, .{ .declared = item })) orelse return null;
            if (!intrinsics.validHostStorage(definition)) return null;
            return try internStructType(self.ctx, item);
        }

        pub fn panicMessageType(self: @This()) !structures.TypeId {
            return (try self.ctx.get(TextType, .StringView)).* orelse error.Unavailable;
        }
        pub fn collectionLiteralType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .collection_literal)) orelse return null;
            const count = (try self.ctx.lookupInterned(CompileTimeValues, instance.arguments[1])).*;
            if (count != .runtime or count.runtime.type_id != .int or count.runtime.value != .int or count.runtime.value.int < 0) return error.Unavailable;
            return .{ .element_type = instance.element_type, .length = @intCast(count.runtime.value.int) };
        }

        pub fn listElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .List)) orelse return null;
            return instance.element_type;
        }

        pub fn containsBorrow(self: @This(), type_id: structures.TypeId) !bool {
            if (type_id.isPrimitive()) return false;
            return ((try self.ctx.get(BorrowShape, type_id)).* orelse return error.Unavailable).contains;
        }

        pub fn canStoreBorrow(self: @This(), type_id: structures.TypeId) !bool {
            if (type_id.isPrimitive()) return false;
            return ((try self.ctx.get(BorrowShape, type_id)).* orelse return error.Unavailable).stores;
        }

        /// Inline storage excludes the contents of allocations the source owns.
        pub fn canBorrowStorage(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId, include_allocated_storage: bool) !bool {
            if (!try self.canStoreBorrow(result_type)) return false;
            var visited: std.ArrayList(structures.TypeId) = .empty;
            defer visited.deinit(self.ctx.allocator());
            return self.canBorrowStorageOfAt(result_type, source_type, &visited, include_allocated_storage);
        }

        fn canBorrowStorageOfAt(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_storage: bool) anyerror!bool {
            if (result_type.isPrimitive()) return false;
            if (try self.borrowElement(result_type)) |element|
                return self.containsStorage(source_type, element, include_allocated_storage);
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, result_type) != null) return false;
            try visited.append(self.ctx.allocator(), result_type);
            if (try self.storageAccess(result_type)) |element_type|
                return self.containsStorage(source_type, element_type, include_allocated_storage);
            if (try self.collectionLiteralType(result_type)) |array|
                return array.length != 0 and try self.canBorrowStorageOfAt(array.element_type, source_type, visited, include_allocated_storage);
            if ((try self.allocationElement(result_type)) orelse try self.boxElement(result_type)) |element|
                return self.canBorrowStorageOfAt(element, source_type, visited, include_allocated_storage);
            var components_iterator = try self.components(result_type);
            while (components_iterator.next()) |component| {
                if (component.count == 0) continue;
                if (component.kind == .reference) {
                    if (try self.containsStorage(source_type, component.type_id, include_allocated_storage)) return true;
                } else if (try self.canBorrowStorageOfAt(component.type_id, source_type, visited, include_allocated_storage)) return true;
            }
            return false;
        }

        fn containsStorage(self: @This(), source_type: structures.TypeId, referent_type: structures.TypeId, include_allocated_storage: bool) !bool {
            var visited: std.ArrayList(structures.TypeId) = .empty;
            defer visited.deinit(self.ctx.allocator());
            return self.containsStorageType(source_type, referent_type, &visited, include_allocated_storage);
        }

        fn containsStorageType(self: @This(), source_type: structures.TypeId, referent_type: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_storage: bool) anyerror!bool {
            if (source_type == referent_type) return true;
            if (source_type.isPrimitive()) return false;
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, source_type) != null) return false;
            try visited.append(self.ctx.allocator(), source_type);
            if (try self.storageAccess(source_type) != null) return false;
            if (try self.collectionLiteralType(source_type)) |array|
                return array.length != 0 and try self.containsStorageType(array.element_type, referent_type, visited, include_allocated_storage);
            if ((try self.allocationElement(source_type)) orelse try self.boxElement(source_type)) |element|
                return include_allocated_storage and try self.containsStorageType(element, referent_type, visited, include_allocated_storage);
            var components_iterator = try self.components(source_type);
            while (components_iterator.next()) |component| {
                if (component.kind == .reference or component.count == 0) continue;
                if (try self.containsStorageType(component.type_id, referent_type, visited, include_allocated_storage)) return true;
            }
            return false;
        }

        fn containsBorrowAt(self: @This(), type_id: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_contents: bool) anyerror!bool {
            if (type_id.isPrimitive()) return false;
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, type_id) != null) return false;
            try visited.append(self.ctx.allocator(), type_id);
            if (try self.borrowElement(type_id) != null or try self.storageAccess(type_id) != null) return true;
            if (try self.collectionLiteralType(type_id)) |array|
                return array.length != 0 and try self.containsBorrowAt(array.element_type, visited, include_allocated_contents);
            if (try self.listElement(type_id)) |element| return self.containsBorrowAt(element, visited, include_allocated_contents);
            if (try self.allocationElement(type_id)) |element|
                return include_allocated_contents and try self.containsBorrowAt(element, visited, true);
            if (try self.boxElement(type_id)) |element| {
                if (try self.containsBorrowAt(element, visited, include_allocated_contents)) return true;
            }
            var components_iterator = try self.components(type_id);
            if ((components_iterator.shape == .structure or components_iterator.shape == .tuple) and try self.isStaticString(type_id)) return false;
            while (components_iterator.next()) |component| {
                if (component.count == 0) continue;
                if (component.kind == .reference or try self.containsBorrowAt(component.type_id, visited, include_allocated_contents)) return true;
            }
            return false;
        }

        pub fn mayContainStorage(self: @This(), type_id: structures.TypeId) anyerror!bool {
            if (type_id.isPrimitive()) return false;
            if (try self.borrowElement(type_id) != null or try self.storageAccess(type_id) != null or try self.allocationElement(type_id) != null or try self.boxElement(type_id) != null) return true;
            var components_iterator = try self.components(type_id);
            if ((components_iterator.shape == .structure or components_iterator.shape == .tuple) and try self.hostStorage() == type_id) return true;
            while (components_iterator.next()) |component| {
                if (component.count == 0) continue;
                if (component.kind == .reference or try self.mayContainStorage(component.type_id)) return true;
            }
            return false;
        }

        pub fn ownershipCapabilities(self: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
            if (type_id.isPrimitive()) return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
            return (try self.ctx.get(OwnershipCapabilities, type_id)).*;
        }

        pub fn isRuntimeCapable(self: @This(), type_id: structures.TypeId) anyerror!bool {
            return (try self.runtimeCapableResult(type_id)) orelse error.Unavailable;
        }

        fn runtimeCapableResult(self: @This(), type_id: structures.TypeId) anyerror!?bool {
            if (type_id.isPrimitive()) return type_id != .type and type_id != .int_literal and type_id != .string_literal;
            return (try self.ctx.get(RuntimeCapable, type_id)).*;
        }

        fn runtimeCapableUncached(self: @This(), type_id: structures.TypeId) anyerror!?bool {
            if (try standardMemoryInstance(self.ctx, type_id, .collection_literal) != null or try standardMemoryInstance(self.ctx, type_id, .collection_sequence) != null) return false;
            _ = (try self.ownershipCapabilities(type_id)) orelse return null;
            var components_iterator = try self.components(type_id);
            if (components_iterator.shape == .structure and components_iterator.shape.structure.is_static) return false;
            while (components_iterator.next()) |component| {
                if (component.kind == .owned and !(try self.runtimeCapableResult(component.type_id) orelse return null)) return false;
            }
            return true;
        }

        pub fn argumentPassing(self: @This(), type_id: structures.TypeId) anyerror!structures.ArgumentPassing {
            return (try self.argumentPassingResult(type_id)) orelse error.Unavailable;
        }

        fn argumentPassingResult(self: @This(), type_id: structures.TypeId) anyerror!?structures.ArgumentPassing {
            if (type_id.isPrimitive()) return .direct;
            return (try self.ctx.get(ArgumentPassing, type_id)).*;
        }

        fn argumentPassingUncached(self: @This(), type_id: structures.TypeId) anyerror!?structures.ArgumentPassing {
            const capabilities = (try self.ownershipCapabilities(type_id)) orelse return null;
            if (!capabilities.isDirectlyMovable()) return .indirect;
            if (try self.arrayType(type_id) != null) return .indirect;
            var components_iterator = try self.components(type_id);
            while (components_iterator.next()) |component| {
                if (component.kind != .owned) continue;
                const passing = (try self.argumentPassingResult(component.type_id)) orelse return null;
                if (passing == .indirect) return .indirect;
            }
            return .direct;
        }
    };
}

pub fn HostTypes(comptime Context: type) type {
    return struct {
        ctx: Context,
        trace_source: ?codegen.TraceSource = null,
        inline_sources: []const codegen.InlineSource = &.{},

        pub fn facts(self: @This()) TypeFacts(Context) {
            return .{ .ctx = self.ctx };
        }

        pub fn structLayout(self: @This(), type_id: structures.TypeId) !?structures.StructLayout {
            return (try self.ctx.get(StructLayout, type_id)).*;
        }

        pub fn variantLayout(self: @This(), type_id: structures.TypeId) !structures.VariantLayout {
            return (try self.ctx.get(VariantLayout, type_id)).*;
        }

        pub fn byteString(self: @This(), id: structures.ByteStringId) ![]const u8 {
            return (try self.ctx.lookupInterned(ByteStrings, id)).bytes;
        }

        pub fn layout(self: @This(), type_id: structures.TypeId) !structures.TypeLayout {
            if (type_id.isPrimitive()) return HostTypeLayout.primitiveLayout(type_id) orelse error.Unavailable;
            return (try self.ctx.get(HostTypeLayout, type_id)).*;
        }
    };
}

pub fn AnalysisContext(comptime Context: type) type {
    return struct {
        pub fn panicFunction(self: @This()) !?structures.ItemId {
            return standardFunction(self.ctx, .text, "panic_message");
        }

        pub fn unhandledErrorFunction(self: @This()) !?structures.InstanceId {
            return .{ .item = (try standardFunction(self.ctx, .io, "unhandled_error")) orelse return null };
        }

        pub fn rangeConstructor(self: @This(), inclusive: bool) !?structures.ItemId {
            return standardFunction(self.ctx, .range, if (inclusive) "inclusive" else "exclusive");
        }

        pub fn fromEndConstructor(self: @This()) !?structures.ItemId {
            return standardFunction(self.ctx, .range, "from_end");
        }

        pub fn iterationEndType(self: @This()) !structures.TypeId {
            const item = (try standardDeclaration(self.ctx, .iteration, "End", structures.ModuleScope.resolveStatic)) orelse return error.Unavailable;
            const value = (try self.staticItem(.{ .item = item })) orelse return error.Unavailable;
            return switch (try self.lookupCompileTimeValue(value)) {
                .type => |type_id| type_id,
                .runtime => error.Unavailable,
            };
        }

        ctx: Context,
        file_id: ?structures.FileId = null,
        instance: ?structures.InstanceId = null,
        prior_static_arguments: ?[]const structures.CompileTimeValueId = null,
        public_annotation: bool = false,
        reference_inference: ?*ReferenceInference = null,
        static_bindings: []const structures.StaticBinding = &.{},

        pub fn withStaticBindings(self: @This(), bindings: []const structures.StaticBinding) @This() {
            var result = self;
            result.static_bindings = bindings;
            return result;
        }

        fn staticEnvironment(self: @This()) !?structures.CompileTimeBindingsId {
            if (self.static_bindings.len == 0) return if (self.instance) |instance| instance.environment else null;
            return try self.ctx.intern(CompileTimeBindings, .{ .bindings = self.static_bindings });
        }

        pub fn staticBindings(self: @This()) ![]const structures.StaticBinding {
            if (self.static_bindings.len != 0) return self.static_bindings;
            if (self.instance) |instance| if (instance.environment) |environment|
                return (try self.ctx.lookupInterned(CompileTimeBindings, environment)).bindings;
            return &.{};
        }

        pub fn allocator(self: @This()) std.mem.Allocator {
            return self.ctx.allocator();
        }

        pub fn facts(self: @This()) TypeFacts(Context) {
            return .{ .ctx = self.ctx };
        }

        pub fn collectionSequenceElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .collection_sequence)) orelse return null;
            return instance.element_type;
        }

        pub fn isCollectionConstructionType(self: @This(), type_id: structures.TypeId) !bool {
            return try self.facts().collectionLiteralType(type_id) != null or try self.collectionSequenceElement(type_id) != null;
        }

        pub fn collectionSequenceConstruction(self: @This(), type_id: structures.TypeId, element: structures.TypeId) !?structures.InitializerConstruction {
            const definition = (try self.facts().structDefinition(type_id)) orelse return error.Unavailable;
            if (definition.fields.len != 1 or definition.fields[0].kind != .owned or
                !std.mem.eql(u8, definition.fields[0].name, "value") or
                (try self.facts().listElement((try intrinsics.optionalPayload(self.facts(), definition.fields[0].type_id)) orelse return null)) != element) return null;
            return .{ .type_id = definition.fields[0].type_id, .projection = 0, .optional_allocation = true };
        }

        pub fn initializerConstruction(self: @This(), type_id: structures.TypeId) !structures.InitializerConstruction {
            if (try self.facts().collectionLiteralType(type_id)) |shape| return .{ .type_id = try self.internArrayType(shape) };
            if (try self.collectionSequenceElement(type_id)) |element| {
                if (try self.collectionSequenceConstruction(type_id, element)) |construction| return construction;
                const identity = (try self.facts().structIdentity(type_id)).?;
                const declaration = (try itemSource(self.ctx, structOwnerItem(identity))) orelse return error.Unavailable;
                try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, .{ .span = nodeSpan(&declaration.parsed, @fromBackingInt(declaration.resolved.declaration)), .kind = .invalid_collection_sequence });
                return error.Unavailable;
            }
            return .{ .type_id = type_id };
        }

        pub fn internCollectionLiteralType(self: @This(), shape: structures.ArrayType) !structures.TypeId {
            const factory = (try standardFunction(self.ctx, .array, "collection_literal")) orelse return error.Unavailable;
            return self.specializedStructType(.{ .item = factory, .specialization = try arrayShapeArguments(self.ctx, shape) });
        }

        pub fn internArrayType(self: @This(), array: structures.ArrayType) !structures.TypeId {
            return .fromInterned(try self.ctx.intern(Types, .{ .array = array }));
        }

        pub fn canAccessPrivateFields(self: @This(), type_id: structures.TypeId) !bool {
            const identity = (try self.facts().structIdentity(type_id)) orelse return false;
            const location = try self.ctx.lookupInterned(ItemLocations, structOwnerItem(identity));
            return try itemModule(self.ctx, location.*) == try self.currentModule();
        }

        pub fn typeNamespace(self: @This(), type_id: structures.TypeId) !?TypeNamespaceAssociation {
            switch ((try self.ctx.get(ResolveTypeNamespace, type_id)).*) {
                .missing => return null,
                .available => |association| return association,
                .unavailable => return error.Unavailable,
            }
        }

        pub fn typeNamespaceMember(self: @This(), type_id: structures.TypeId, name: []const u8, span: structures.SourceSpan) !?structures.InstanceId {
            if (std.meta.stringToEnum(structures.OwnershipMember, name)) |operation|
                return self.ownershipMember(type_id, operation);
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
            return association.member((try self.visibleTypeMember(namespace, .fromText(name, null), span)) orelse return null);
        }

        pub fn typeNamespaceCallMember(self: @This(), type_id: structures.TypeId, name: []const u8, operands: usize, span: structures.SourceSpan) !?structures.NameReference {
            const association = (try self.typeNamespace(type_id)) orelse return null;
            return self.namespaceReference(association, name, span, operands);
        }

        pub fn ownershipMember(self: @This(), type_id: structures.TypeId, operation: structures.OwnershipMember) !?structures.InstanceId {
            const capabilities = (try self.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (try self.typeNamespace(type_id)) |association| {
                if ((try self.ctx.get(TypeNamespace, association.query_key)).* == null) return error.Unavailable;
            }
            const supported, const name = switch (operation) {
                .copy => .{ capabilities.copy != .none, "copy_value" },
                .move => .{ capabilities.move != .none, "move_value" },
            };
            if (!supported) return null;
            const item = (try standardFunction(self.ctx, .ownership, name)) orelse return error.Unavailable;
            const argument = try self.ctx.intern(CompileTimeValues, .{ .type = type_id });
            return try self.specializeFunction(.{ .item = item }, &.{argument});
        }

        /// The namespace of the struct a generic factory returns, specialized like the factory.
        fn factoryNamespace(self: @This(), factory: structures.InstanceId) !?TypeNamespaceAssociation {
            const item_source = (try itemSource(self.ctx, factory.item)) orelse return null;
            const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return null;
            return .{ .query_key = .{ .generated = .{ .owner = factory, .node_offset = site } }, .specialization = factory.specialization, .environment = factory.environment };
        }

        fn visibleTypeMember(self: @This(), namespace: structures.ModuleScope, name: structures.Name, span: ?structures.SourceSpan) !?structures.ItemId {
            const entry = namespace.resolveName(name) orelse return null;
            if (span) |access_span| {
                const member = try self.ctx.lookupInterned(ItemLocations, entry.item_id);
                if (!entry.is_public and try self.currentModule() != member.origin.module) {
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
            const value = (try availableSemanticValue(self.ctx, file_id, self.instance, semantic.analyzer(&parsed, source, self, self.ctx.allocator()).run("analyzeStaticTypeArgument", .{node}))) orelse return null;
            return try self.internCompileTimeValue(value);
        }

        fn declarationContext(self: @This(), instance: structures.InstanceId, prior: []const structures.CompileTimeValueId) !DeclarationSource(Context) {
            var declaration = (try declarationSource(self.ctx, instance)) orelse return error.Unavailable;
            declaration.analysis.prior_static_arguments = prior;
            return declaration;
        }

        pub fn staticParameterType(self: @This(), instance: structures.InstanceId, parameter_index: usize, prior: []const structures.CompileTimeValueId) !structures.TypeId {
            const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
            std.debug.assert(parameter_index < shape.parameters.len);
            if (shape.parameters[parameter_index].is_meta_type) return .type;
            const declaration = try self.declarationContext(instance, prior);
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).run("analyzeStaticParameterType", .{ declaration.resolved.declaration, parameter_index }));
        }

        pub fn independentParameterType(self: @This(), instance: structures.InstanceId, runtime_index: usize) !?structures.TypeId {
            if (try self.needsInheritedInference(instance)) return null;
            const declaration = try self.declarationContext(instance, &.{});
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).run("analyzeIndependentParameterType", .{ declaration.resolved.declaration, runtime_index }));
        }

        pub fn inferStaticArguments(self: @This(), instance: structures.InstanceId, argument_types: []const structures.TypeId) !semantic.StaticInference {
            const declaration = try self.declarationContext(instance, &.{});
            const inherited_from = if (try self.needsInheritedInference(instance)) blk: {
                const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
                const owner_item = location.owner orelse unreachable;
                const owner = (try self.ctx.get(ResolveItem, owner_item)).* orelse return error.Unavailable;
                const owner_arity = (try self.ctx.get(SpecializationArity, owner_item)).* orelse return error.Unavailable;
                const provided = (try staticArgumentValues(self.ctx, instance.specialization)).len;
                if (provided < owner_arity.inherited or owner.file_id != declaration.resolved.file_id or
                    semantic.parameterizedStructSite(&declaration.parsed, owner.declaration) == null) return .missing;
                break :blk owner.declaration;
            } else null;
            return semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).inferStaticArguments(declaration.resolved.declaration, argument_types, inherited_from);
        }

        pub fn inferStructArguments(self: @This(), instance: structures.InstanceId, fields: []const semantic.UnresolvedBody.StructFieldValue, field_types: []const structures.TypeId) !semantic.StaticInference {
            const declaration = try self.declarationContext(instance, &.{});
            return semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).inferStructArguments(declaration.resolved.declaration, fields, field_types);
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

        /// The type a constant or static declaration reference names, if any.
        fn referencedType(self: @This(), reference: structures.NameReference) !?structures.TypeId {
            const constant = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (try self.staticItem(instance)) orelse return null,
                .namespace, .overloaded_function => return null,
            };
            return switch (try self.lookupCompileTimeValue(constant)) {
                .type => |type_id| type_id,
                .runtime => null,
            };
        }

        pub fn converterAnnotationOwner(self: @This(), annotation: structures.Node.Index) !?structures.ModuleId {
            const reference = (try self.converterAnnotationReference(annotation)) orelse return null;
            if (reference == .declaration and try self.isGenericStruct(reference.declaration.item))
                return (try self.ctx.lookupInterned(ItemLocations, reference.declaration.item)).origin.module;
            return self.conversionOwner((try self.referencedType(reference)) orelse return null);
        }

        pub fn isCollectionConverterAnnotation(self: @This(), annotation: structures.Node.Index) !bool {
            const reference = (try self.converterAnnotationReference(annotation)) orelse return false;
            if (reference == .declaration and try self.isGenericStruct(reference.declaration.item))
                return reference.declaration.item == (try standardFunction(self.ctx, .array, "collection_literal")) or reference.declaration.item == (try standardFunction(self.ctx, .memory_allocation, "collection_sequence"));
            return self.isCollectionConstructionType((try self.referencedType(reference)) orelse return false);
        }

        pub fn isStaticConverterAnnotation(self: @This(), annotation: structures.Node.Index) !bool {
            const context = try self.declarationContext(self.instance.?, &.{});
            if (context.parsed.nodes[annotation.index()].tag == .call and
                !semantic.converterAnnotationDependsOnStaticParameters(&context.parsed, context.source, context.resolved.declaration, annotation))
            {
                const resolved_type = switch (try semantic.analyzer(&context.parsed, context.source, context.analysis, self.ctx.allocator()).run("analyzeStaticTypeArgument", .{annotation})) {
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
            return !try self.facts().isRuntimeCapable((try self.referencedType(reference)) orelse return false);
        }

        fn conversionOwner(self: @This(), type_id: structures.TypeId) !?structures.ModuleId {
            if (type_id.isPrimitive()) {
                const file = (try standardFile(self.ctx, .prelude)) orelse return null;
                return (try self.ctx.input(FileModule, file)).*;
            }
            const association = (try self.typeNamespace(type_id)) orelse return null;
            return try itemModule(self.ctx, (try self.ctx.lookupInterned(ItemLocations, association.query_key.owner())).*);
        }

        fn probeConverterSignature(self: @This(), item: structures.ItemId, source_type: ?structures.TypeId, target_type: structures.TypeId, source_value: ?structures.CompileTimeValueId, collection_length: ?u32) !?struct { instance: structures.InstanceId, signature: structures.FunctionSignature } {
            const base: structures.InstanceId = .{ .item = item };
            const independent = (try self.ctx.get(IndependentConverterTypes, item)).*;
            if (independent.return_type) |expected| {
                if (expected != target_type) return null;
            }
            const shape = (try self.functionShape(item)) orelse return error.Unavailable;
            if (source_type) |actual| {
                var runtime_count: usize = 0;
                for (shape.parameters) |parameter| if (parameter.mode != .static) {
                    runtime_count += 1;
                };
                if (source_value != null and runtime_count != 0 and !try self.facts().isRuntimeCapable(actual)) return null;
                if (independent.input_type) |expected| if (!try semantic.canWidenTo(self, actual, expected)) return null;
            }
            const declaration = try self.declarationContext(base, &.{});
            const inference = try semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).inferConverterArguments(declaration.resolved.declaration, source_type, target_type, source_value, collection_length);
            const arguments = switch (inference) {
                .arguments => |arguments| arguments,
                .missing, .conflict => return null,
            };
            defer self.ctx.allocator().free(arguments);
            const instance = try self.specializeFunction(base, arguments);
            var specialized = declaration.analysis;
            specialized.instance = instance;
            specialized.prior_static_arguments = arguments;
            const signature = switch (try semantic.analyzer(&declaration.parsed, declaration.source, specialized, self.ctx.allocator()).run("analyzeShapedFunctionSignature", .{ declaration.resolved.declaration, arguments, shape })) {
                .success => |signature| signature,
                .unsupported => |issue| {
                    // Contextual collection probing has not selected a source type yet.
                    if (source_type == null or issue.kind == .static_argument_type_mismatch) return null;
                    try self.ctx.emit(structures.Diagnostic, .{ .file_id = declaration.resolved.file_id, .span = issue.span, .kind = issue.kind, .instance = instance });
                    return error.Unavailable;
                },
            };
            return .{ .instance = instance, .signature = signature };
        }

        /// Query-owned candidates remain valid for the current database revision.
        pub fn hasConverters(self: @This(), source_type: structures.TypeId, target_type: structures.TypeId) !bool {
            const items = (try self.ctx.get(ConverterItems, .{ .source = source_type, .target = target_type, .requester = try self.currentModule() })).*;
            return (items orelse return error.Unavailable).len != 0;
        }

        pub fn conversionCandidates(self: @This(), source_type: structures.TypeId, target_type: structures.TypeId, source_value: ?structures.CompileTimeValueId) ![]const structures.ConversionCandidate {
            return self.candidatesFrom(if (source_value) |value| .{ .constant = value } else .{ .typed = source_type }, target_type);
        }

        inline fn candidatesFrom(self: @This(), source: ConversionSource, target_type: structures.TypeId) ![]const structures.ConversionCandidate {
            return (try self.ctx.get(ConversionCandidates, .{ .source = source, .target = target_type, .requester = try self.currentModule() })).* orelse error.Unavailable;
        }

        pub fn contextualCollectionElement(self: @This(), target_type: structures.TypeId, length: u32, span: structures.SourceSpan) !?structures.TypeId {
            if (try self.facts().variantMembers(target_type)) |members| {
                var array_element: ?structures.TypeId = null;
                for (members) |member| if (try self.facts().arrayType(member)) |array| {
                    if (array.length != length) continue;
                    if (array_element != null and array_element.? != array.element_type) return null;
                    array_element = array.element_type;
                };
                if (array_element != null) return array_element;
            }
            const candidates = try self.candidatesFrom(.{ .collection = length }, target_type);
            var element_type: ?structures.TypeId = null;
            for (candidates) |candidate| {
                const collection = (try self.facts().collectionLiteralType(candidate.input_type)).?;
                if (element_type != null and element_type.? != collection.element_type) {
                    try self.ctx.emit(structures.Diagnostic, .{ .file_id = self.file_id.?, .span = span, .instance = self.instance, .kind = .{ .ambiguous_conversion = .{ .expected = target_type, .found = candidate.input_type } } });
                    return error.Unavailable;
                }
                element_type = collection.element_type;
            }
            return element_type;
        }

        pub fn independentStructFieldType(self: @This(), instance: structures.InstanceId, name: []const u8) !?structures.TypeId {
            const declaration = try self.declarationContext(instance, &.{});
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, self.ctx.allocator()).run("analyzeIndependentStructFieldType", .{ declaration.resolved.declaration, name }));
        }

        pub fn specializedStructType(self: @This(), instance: structures.InstanceId) !structures.TypeId {
            const item_source = (try itemSource(self.ctx, instance.item)) orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse unreachable;
            return internGeneratedStructType(self.ctx, .{ .owner = instance, .node_offset = site });
        }

        pub fn structFactoryArguments(self: @This(), factory: structures.InstanceId, type_id: structures.TypeId) !?[]const structures.CompileTimeValueId {
            // A sequence init pattern receives either pending fixed elements or
            // a List expression. Infer its logical element before preparation
            // supplies the List destination and allocation policy.
            const location = try self.ctx.lookupInterned(ItemLocations, factory.item);
            if (std.mem.eql(u8, location.name.text(), "collection_sequence") and factory.item == (try self.stdMemoryFunction("collection_sequence"))) {
                const shape = (try self.facts().collectionLiteralType(type_id)) orelse try self.facts().arrayType(type_id);
                const element = if (shape) |array| array.element_type else try self.facts().listElement(type_id);
                if (element) |element_type| {
                    const value = try self.internCompileTimeValue(.{ .type = element_type });
                    return try staticArgumentValues(self.ctx, try self.ctx.intern(CompileTimeValueTuples, .{ .values = &.{value} }));
                }
            }
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const identity = association.query_key;
            if (identity != .generated or identity.generated.owner.item != factory.item) return null;
            const item_source = (try itemSource(self.ctx, factory.item)) orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return null;
            if (identity.generated.node_offset != site) return null;
            const arity = (try self.ctx.get(SpecializationArity, factory.item)).* orelse return error.Unavailable;
            const values = try staticArgumentValues(self.ctx, association.specialization);
            if (values.len != arity.total()) return null;
            const inherited = try staticArgumentValues(self.ctx, factory.specialization);
            if (inherited.len != arity.inherited or !std.mem.eql(structures.CompileTimeValueId, values[0..arity.inherited], inherited)) return null;
            return values[arity.inherited..];
        }

        pub fn stdMemoryFunction(self: @This(), name: []const u8) !?structures.ItemId {
            return standardFunction(self.ctx, .memory_allocation, name);
        }

        pub fn inlineBuiltin(self: @This(), item: structures.ItemId) !?typing.BuiltinBody {
            const symbol = (try self.ctx.get(ExternalSymbol, item)).* orelse return null;
            switch (symbol) {
                .primitive_operation => return .{ .symbol = symbol, .operation = (try self.ctx.lookupInterned(ItemLocations, item)).name.operation },
                .literal_byte => return .{ .symbol = symbol },
                else => return null,
            }
        }

        pub fn callBehavior(self: @This(), item: structures.ItemId) !structures.CallBehavior {
            const location = try self.ctx.lookupInterned(ItemLocations, item);
            const names = std.StaticStringMap(structures.CallBehavior).initComptime(.{
                .{ "take", .box_value },
                .{ "append_collection_bounded", .collection_append_bounded },
                .{ "append_collection_growing", .collection_append_growing },
                .{ "append_collection_optional", .collection_append_growing },
            });
            if (location.owner == null) {
                const behavior = names.get(location.name.text()) orelse return .ordinary;
                return if (item == (try self.stdMemoryFunction(location.name.text()))) behavior else .ordinary;
            }
            const Member = struct { factory: []const u8, name: []const u8, behavior: structures.CallBehavior };
            const members = [_]Member{
                .{ .factory = "Box", .name = "new", .behavior = .box_new },
                .{ .factory = "List", .name = "append", .behavior = .list_append },
                .{ .factory = "List", .name = "reserve", .behavior = .list_reserve },
                .{ .factory = "List", .name = "remove", .behavior = .list_remove },
                .{ .factory = "List", .name = "consume_iter", .behavior = .list_consume },
            };
            for (members) |member| {
                if (!std.mem.eql(u8, location.name.text(), member.name)) continue;
                const factory = (try self.stdMemoryFunction(member.factory)) orelse continue;
                if (location.owner != factory) continue;
                const association = (try self.factoryNamespace(.{ .item = factory })) orelse continue;
                const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
                if (namespace.resolve(member.name) == item) return member.behavior;
            }
            return .ordinary;
        }

        pub fn listType(self: @This(), element_type: structures.TypeId) !structures.TypeId {
            const factory = (try self.stdMemoryFunction("List")) orelse return error.Unavailable;
            const argument = try self.internCompileTimeValue(.{ .type = element_type });
            const arguments = try self.ctx.intern(CompileTimeValueTuples, .{ .values = &.{argument} });
            return self.specializedStructType(.{ .item = factory, .specialization = arguments });
        }

        pub fn canBorrowStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.facts().canBorrowStorage(result_type, source_type, true);
        }

        pub fn canBorrowInlineStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.facts().canBorrowStorage(result_type, source_type, false);
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
            const item = try self.ctx.intern(ItemLocations, .{
                .origin = .{ .module = try itemModule(self.ctx, owner_loc.*) },
                .owner = owner,
                .source_site = source_site,
                .is_hook = true,
                .kind = .function,
                .name = .{ .identifier = name },
            });
            if (index.resolve(item) == null) return null;
            return .{ .item = item, .specialization = specialization, .environment = if (identity == .generated) identity.generated.owner.environment else null };
        }

        pub fn functionReferenceContract(self: @This(), instance: structures.InstanceId) !?structures.ReferenceContract {
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return null;
            if ((try self.ctx.get(ExternalSymbol, instance.item)).* == .static_iteration_item) return .{};
            var needs_contract = signature.result_mode == .reference or try self.facts().canStoreBorrow(signature.return_type);
            for (signature.parameters) |parameter| {
                if (parameter.mode == .ref or parameter.mode == .mut or try self.facts().canStoreBorrow(parameter.type_id)) needs_contract = true;
            }
            if (!needs_contract) return .{};
            if (self.reference_inference) |inference| return inference.request(self.ctx, instance);
            return (try self.ctx.get(InferReferenceContract, instance)).*;
        }

        pub fn functionSignature(self: @This(), instance: structures.InstanceId) !?structures.FunctionSignature {
            return lookupFunctionSignature(self.ctx, instance);
        }

        pub fn functionShape(self: @This(), item_id: structures.ItemId) !?structures.FunctionShape {
            return (try self.ctx.get(FunctionShape, item_id)).*;
        }

        pub fn functionOverloads(self: @This(), overload: structures.FunctionOverloadId) !structures.FunctionOverloadSet {
            return (try self.ctx.lookupInterned(FunctionOverloads, overload)).*;
        }

        pub fn overloadOperation(self: @This(), overload: structures.FunctionOverloadId) !?structures.Operation {
            const set = try self.functionOverloads(overload);
            const declaration = set.declaration orelse return null;
            const location = try self.ctx.lookupInterned(ItemLocations, declaration.item);
            return if (location.name == .operation) location.name.operation else null;
        }

        pub fn candidateSignature(self: @This(), instance: structures.InstanceId) !?structures.FunctionSignature {
            return (try self.ctx.get(FunctionCandidateSignature, instance)).*;
        }

        pub fn validateOverloadHeader(self: @This(), overload: structures.FunctionOverloadId, instance: structures.InstanceId, signature: structures.FunctionSignature, span: structures.SourceSpan) !void {
            const set = try self.functionOverloads(overload);
            if (set.declaration) |declaration| {
                const location = try self.ctx.lookupInterned(ItemLocations, declaration.item);
                if (location.name == .operation) {
                    const operation = structures.Operation.fromName(location.name.text(), signature.parameters.len).?;
                    if (!try validOperationShape(self, location.owner, operation, signature)) {
                        const source = (try itemSource(self.ctx, declaration.item)) orelse return error.Unavailable;
                        try typing.emitSemanticIssue(self.ctx, source.resolved.file_id, .{ .span = nodeSpan(&source.parsed, @fromBackingInt(source.resolved.declaration)), .kind = .invalid_operation_signature });
                        return error.Unavailable;
                    }
                }
            } else {
                const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
                if (location.origin.module != try self.currentModule() and !try self.declarationIsPublic(instance.item)) {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .private_access);
                    return error.Unavailable;
                }
            }
        }

        pub fn needsInheritedInference(self: @This(), instance: structures.InstanceId) !bool {
            const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
            if (location.owner == null) return false;
            const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
            return (try staticArgumentValues(self.ctx, instance.specialization)).len < arity.inherited;
        }

        pub fn isGenericStruct(self: @This(), item_id: structures.ItemId) !bool {
            const location = try self.ctx.lookupInterned(ItemLocations, item_id);
            if (location.kind != .function) return false;
            const item_source = (try itemSource(self.ctx, item_id)) orelse return false;
            return semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) != null;
        }

        pub fn internByteString(self: @This(), bytes: []const u8) !structures.ByteStringId {
            return self.ctx.intern(ByteStrings, .{ .bytes = bytes });
        }

        pub fn stringType(self: @This()) !structures.TypeId {
            return (try self.ctx.get(TextType, .String)).* orelse error.Unavailable;
        }

        pub fn staticStringType(self: @This()) !structures.TypeId {
            return (try self.ctx.get(TextType, .StaticString)).* orelse error.Unavailable;
        }

        pub fn isMatchTextType(self: @This(), type_id: structures.TypeId) !bool {
            inline for (std.meta.tags(TextType.Name)) |name| {
                const text_type = (try self.ctx.get(TextType, name)).* orelse return error.Unavailable;
                if (type_id == text_type) return true;
            }
            return false;
        }

        pub fn matchTextFunction(self: @This(), type_id: structures.TypeId) !structures.InstanceId {
            const item = (try standardFunction(self.ctx, .text, "match_literal")) orelse return error.Unavailable;
            const argument = try self.internCompileTimeValue(.{ .type = type_id });
            return self.specializeFunction(.{ .item = item }, &.{argument});
        }

        pub fn byteIntFunction(self: @This()) !structures.InstanceId {
            return .{ .item = (try standardFunction(self.ctx, .text, "byte_int")) orelse return error.Unavailable };
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

        pub fn staticCondition(self: @This(), node: structures.Node.Index) !?bool {
            const outcome = (try self.ctx.get(ExecuteComptimeThunk, .{
                .owner = self.instance.?,
                .node = node,
                .bindings = try self.staticEnvironment(),
                .condition = true,
            })).* orelse return null;
            return switch (outcome) {
                .returned => |value| (try self.lookupCompileTimeValue(value)).runtime.value.bool,
                .exit => null,
            };
        }

        pub fn staticIteration(self: @This(), node: structures.Node.Index) !?[]const structures.CompileTimeValueId {
            const tuple = (try self.ctx.get(ExecuteStaticIteration, .{ .owner = self.instance.?, .node = node, .bindings = try self.staticEnvironment() })).* orelse return null;
            return (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
        }

        pub fn overloadCallReturnsType(self: @This(), overload: structures.FunctionOverloadId, node: structures.Node.Index) !bool {
            const set = try self.functionOverloads(overload);
            var may_return_type = false;
            for (set.candidates) |candidate| {
                const shape = (try self.functionShape(candidate.item)) orelse return error.Unavailable;
                may_return_type = may_return_type or shape.returns_type;
            }
            if (!may_return_type) return false;
            const body = (try self.ctx.get(AnalyzeComptimeThunk, .{ .owner = self.instance.?, .node = node, .public_annotation = self.public_annotation, .bindings = try self.staticEnvironment() })).* orelse return error.Unavailable;
            return body.return_type == .type;
        }

        pub fn executeComptimeWithType(self: @This(), node: structures.Node.Index, expected_type: ?structures.TypeId) !?structures.CompileTimeValueId {
            const owner = self.instance orelse unreachable;
            if (expected_type) |expected| {
                const parsed = (try self.ctx.get(ParseFile, self.file_id.?)).* orelse return null;
                if (parsed.nodes[node.index()].tag == .identifier) {
                    const source = (try self.ctx.input(SourceText, self.file_id.?)).*;
                    const span = nodeSpan(&parsed, node);
                    if (try self.staticParameter(source[span.start..span.end])) |value_id| {
                        const value = (try self.ctx.lookupInterned(CompileTimeValues, value_id)).*;
                        const type_id = switch (value) {
                            .type => structures.TypeId.type,
                            .runtime => |runtime| runtime.type_id,
                        };
                        if (type_id == expected) return value_id;
                    }
                } else if ((expected == .int or expected == .int_literal) and
                    (parsed.nodes[node.index()].tag == .number_literal or parsed.nodes[node.index()].tag == .neg))
                {
                    const source = (try self.ctx.input(SourceText, self.file_id.?)).*;
                    if (semantic.integerLiteralValue(&parsed, source, node)) |integer| {
                        if (expected == .int_literal) return try self.internCompileTimeValue(.{ .runtime = .{ .type_id = .int_literal, .value = .{ .int_literal = integer } } });
                        if (std.math.cast(i32, integer)) |value| return try self.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = value } } });
                    }
                }
            }
            const outcome = (try self.ctx.get(ExecuteComptimeThunk, .{
                .owner = owner,
                .node = node,
                .expected_type = expected_type,
                .public_annotation = self.public_annotation,
                .bindings = try self.staticEnvironment(),
            })).* orelse return null;
            return switch (outcome) {
                .returned => |value| value,
                .exit => null,
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
                        .type => |type_id| if (try self.typeNamespaceMember(type_id, name, span) == null) {
                            if (std.meta.stringToEnum(structures.OwnershipMember, name) != null) return false;
                            switch (try self.conversionMember(type_id, name, span)) {
                                .missing, .ambiguous, .constrained => return false,
                                .function => {},
                            }
                        },
                        .runtime => |runtime| if (try self.facts().structDefinition(runtime.type_id)) |definition| {
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
                .runtime => |runtime| if (runtime.value == .variant) runtime.value.variant.member_type else runtime.type_id,
            };
            const members = (try self.facts().variantMembers(source_type)) orelse &.{source_type};
            const accepted = (try self.facts().variantMembers(target)) orelse &.{target};
            for (members) |member| {
                if (std.mem.indexOfScalar(structures.TypeId, accepted, member) == null) return false;
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
            var owner = self.instance orelse unreachable;
            owner.environment = try self.staticEnvironment();
            const resolved = (try self.ctx.get(ResolveItem, owner.item)).* orelse return error.Unavailable;
            const node_offset = @as(i64, node.index()) - @as(i64, resolved.declaration);
            return internGeneratedStructType(self.ctx, .{ .owner = owner, .node_offset = node_offset });
        }

        fn staticParameter(self: @This(), name: []const u8) !?structures.CompileTimeValueId {
            for (try self.staticBindings()) |binding| if (std.mem.eql(u8, binding.name, name)) return binding.value;
            var instance = self.instance orelse return null;
            if (instance.specialization == null and self.prior_static_arguments == null) return null;
            var arguments = try staticArgumentValues(self.ctx, instance.specialization);
            if (self.prior_static_arguments) |prior| {
                if (prior.len != 0) {
                    const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
                    if (shape.specializationArgument(prior, name)) |value| return value;
                }
                const loc = try self.ctx.lookupInterned(ItemLocations, instance.item);
                instance.item = loc.owner orelse return null;
                if (arguments.len == 0) return null;
            }
            while (true) {
                const loc = try self.ctx.lookupInterned(ItemLocations, instance.item);
                if (loc.owner == null and loc.kind == .function) {
                    const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
                    if (arguments.len != shape.static_names.len) return error.Unavailable;
                    return shape.specializationArgument(arguments, name);
                }
                const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
                if (arguments.len != arity.total()) return error.Unavailable;
                if (loc.kind == .function and arity.own != 0) {
                    const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
                    if (shape.specializationArgument(arguments[arity.inherited..], name)) |value| return value;
                }
                instance.item = loc.owner orelse return null;
                arguments = arguments[0..arity.inherited];
            }
        }

        pub fn specializeFunction(self: @This(), instance: structures.InstanceId, arguments: []const structures.CompileTimeValueId) !structures.InstanceId {
            if (arguments.len == 0) return instance;
            const inherited = try staticArgumentValues(self.ctx, instance.specialization);
            const combined = try self.ctx.allocator().alloc(structures.CompileTimeValueId, inherited.len + arguments.len);
            defer self.ctx.allocator().free(combined);
            @memcpy(combined[0..inherited.len], inherited);
            @memcpy(combined[inherited.len..], arguments);
            const specialization = try self.ctx.intern(CompileTimeValueTuples, .{ .values = combined });
            return .{ .item = instance.item, .specialization = specialization, .environment = instance.environment };
        }

        pub fn resolveLocalConflict(self: @This(), name: []const u8) !?structures.ItemId {
            const declarations = (try self.ctx.get(ModuleDeclarations, try self.currentModule())).* orelse return error.Unavailable;
            return declarations.resolve(name);
        }

        pub fn resolveName(self: @This(), name: []const u8) !?structures.NameReference {
            if (try self.staticParameter(name)) |value| return .{ .constant = value };
            if (try self.resolveDeclaration(name)) |instance| return try self.declarationReference(instance);
            const imports = (try self.ctx.get(ResolveFileImports, self.file_id.?)).* orelse return error.Unavailable;
            for (imports.imports) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                return switch (binding.target) {
                    .declaration => |item| try self.declarationReference(.{ .item = item }),
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
                .overloaded_function => |overload| blk: {
                    const set = try self.functionOverloads(overload);
                    if (set.declaration) |instance| break :blk try self.declarationIsPublic(instance.item);
                    for (set.candidates) |candidate| if (!try self.declarationIsPublic(candidate.item)) break :blk false;
                    break :blk true;
                },
                .constant, .namespace => true,
            };
        }

        fn declarationIsPublic(self: @This(), item_id: structures.ItemId) !bool {
            var current = item_id;
            while (true) {
                const location = try self.ctx.lookupInterned(ItemLocations, current);
                if (location.kind == .primitive) return true;
                if (location.origin == .entry) return false;
                const scope = if (location.owner) |owner| scope: {
                    const owner_location = try self.ctx.lookupInterned(ItemLocations, owner);
                    const identity: NamespaceIdentity = if (owner_location.kind == .primitive)
                        .{ .primitive = owner }
                    else if (location.source_site) |site|
                        .{ .generated = .{ .owner = .{ .item = owner }, .node_offset = site } }
                    else
                        .{ .declared = owner };
                    break :scope (try self.ctx.get(TypeNamespace, identity)).* orelse return error.Unavailable;
                } else (try self.ctx.get(ModuleDeclarations, location.origin.module)).* orelse return error.Unavailable;
                const entry = scope.resolveName(location.name) orelse return error.Unavailable;
                std.debug.assert(entry.item_id == current);
                if (!entry.is_public) return false;
                current = location.owner orelse return true;
            }
        }

        pub fn isPublicFieldType(self: @This(), type_id: structures.TypeId) anyerror!bool {
            return self.publicType(type_id, true);
        }

        fn publicType(self: @This(), type_id: structures.TypeId, allow_type_arguments: bool) anyerror!bool {
            if (allow_type_arguments) if (self.instance) |instance| {
                for (try staticArgumentValues(self.ctx, instance.specialization)) |argument| {
                    const value = (try self.ctx.lookupInterned(CompileTimeValues, argument)).*;
                    if (value == .type and value.type == type_id) return true;
                }
            };
            if (type_id.isPrimitive()) return true;
            switch ((try typeData(self.ctx, type_id)).?) {
                .structure => |identity| {
                    if (!try self.declarationIsPublic(structOwnerItem(identity))) return false;
                    if (identity == .generated) {
                        for (try staticArgumentValues(self.ctx, identity.generated.owner.specialization)) |argument| {
                            const value = (try self.ctx.lookupInterned(CompileTimeValues, argument)).*;
                            if (value == .type and !try self.publicType(value.type, allow_type_arguments)) return false;
                        }
                    }
                    return true;
                },
                .variant => |variant| return for (variant.members) |member| {
                    if (!try self.publicType(member, allow_type_arguments)) break false;
                } else true,
                .callable => |callable| {
                    for (callable.parameters) |parameter| {
                        if (!try self.publicType(parameter.type_id, allow_type_arguments)) return false;
                    }
                    return self.publicType(callable.return_type, allow_type_arguments);
                },
                .array => |array| return self.publicType(array.element_type, allow_type_arguments),
                .tuple => |tuple| return for (tuple.members) |member| {
                    if (!try self.publicType(member.type_id, allow_type_arguments)) break false;
                } else true,
                .reference => |element| return self.publicType(element, allow_type_arguments),
            }
        }

        pub fn staticItem(self: @This(), instance: structures.InstanceId) !?structures.CompileTimeValueId {
            const identity = try self.ctx.lookupInterned(ItemLocations, instance.item);
            if (identity.kind != .static and identity.kind != .structure) return null;
            return if (instance.specialization == null and instance.environment == null)
                (try self.ctx.get(ResolveStatic, instance.item)).* orelse return error.Unavailable
            else
                (try self.ctx.get(ResolveStaticInstance, instance)).* orelse return error.Unavailable;
        }

        pub fn resolveMemberWithOperands(self: @This(), reference: structures.NameReference, name: []const u8, span: structures.SourceSpan, operands: ?usize) !?structures.NameReference {
            switch (reference) {
                .namespace => |namespace| return try self.moduleMember(namespace, name, span),
                .declaration => |item| {
                    if (try self.isGenericStruct(item.item)) {
                        const association = (try self.factoryNamespace(item)) orelse return null;
                        if (try self.namespaceReference(association, name, span, operands)) |member| return member;
                        try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
                        return error.Unavailable;
                    }
                    const value = (try self.staticItem(item)) orelse return null;
                    return self.constantMember(value, name, span, operands);
                },
                .constant => |value| return self.constantMember(value, name, span, operands),
                .overloaded_function => return null,
            }
        }

        fn constantMember(self: @This(), value_id: structures.CompileTimeValueId, name: []const u8, span: structures.SourceSpan, operands: ?usize) !?structures.NameReference {
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
                    return try self.callableMember(instance);
                }
                try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .unknown_namespace_member);
                return error.Unavailable;
            }
            if (try self.typeNamespace(value.type)) |association| {
                if (try self.namespaceReference(association, name, span, operands)) |member| return member;
            }
            switch (try self.conversionMember(value.type, name, span)) {
                .function => |instance| return try self.callableMember(instance),
                .constrained => |instance| {
                    _ = (try self.functionSignature(instance)) orelse return error.Unavailable; // Report the selected converter's failed clause.
                    unreachable;
                },
                .ambiguous => |target| {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .{ .ambiguous_conversion = .{ .expected = target, .found = value.type } });
                    return error.Unavailable;
                },
                .missing => {},
            }
            const kind: structures.Diagnostic.Kind = if (structures.Operation.fromName(name, operands)) |operation|
                .{ .missing_operation = .{ .receiver = value.type, .operation = operation } }
            else
                .unknown_namespace_member;
            try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, kind);
            return error.Unavailable;
        }

        const ConversionMember = union(enum) {
            missing,
            ambiguous: structures.TypeId,
            constrained: structures.InstanceId,
            function: structures.InstanceId,
        };

        fn callableMember(self: @This(), instance: structures.InstanceId) !structures.NameReference {
            const reference = (try self.functionItemReference(instance)) orelse return error.Unavailable;
            return .{ .constant = try self.ctx.intern(CompileTimeValues, .{ .runtime = .{
                .type_id = reference.type_id,
                .value = .{ .function_ref = reference },
            } }) };
        }

        /// A conversion member names an existing specialized declaration. Its
        /// callable signature retains the declaration's actual input and modes.
        fn conversionMember(self: @This(), source_type: structures.TypeId, name: []const u8, span: structures.SourceSpan) !ConversionMember {
            const reference = (try self.resolveName(name)) orelse return .missing;
            const target = (try self.referencedType(reference)) orelse return .missing;
            // A static-source converter needs a concrete value for specialization;
            // its unspecialized declaration cannot be a first-class function.
            if (!try self.facts().isRuntimeCapable(source_type) and try self.facts().collectionLiteralType(source_type) == null) return .missing;
            const candidates = try self.conversionCandidates(source_type, target, null);
            var selected: ?structures.InstanceId = null;
            for (candidates) |candidate| {
                // Widening into a target variant does not declare a converter to
                // that variant. Likewise, lookup synthesizes no identity adapter.
                if (candidate.target_type != target) continue;
                if (selected != null) return .{ .ambiguous = target };
                selected = candidate.instance;
            }
            const instance = selected orelse return .missing;
            const constraints = (self.ctx.get(FunctionConstraints, instance) catch |err| switch (err) {
                error.QueryCycle => {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .declaration_cycle);
                    return error.Unavailable;
                },
                else => return err,
            }).* orelse return error.Unavailable;
            if (constraints.failed_condition != null) return .{ .constrained = instance };
            return .{ .function = instance };
        }

        fn namespaceReference(self: @This(), association: TypeNamespaceAssociation, spelling: []const u8, span: structures.SourceSpan, operands: ?usize) !?structures.NameReference {
            const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
            const first_name = structures.Name.fromText(spelling, 1);
            const second_name = structures.Name.fromText(spelling, 2);
            if (structures.Name.order(first_name, second_name) == .eq)
                return try self.declarationReference(association.member((try self.visibleTypeMember(namespace, first_name, span)) orelse return null));
            const first = namespace.resolveName(first_name);
            const second = namespace.resolveName(second_name);
            if (first == null and second == null) return null;
            if (operands) |count| {
                var selected: ?structures.ModuleScope.Entry = null;
                for ([_]?structures.ModuleScope.Entry{ first, second }) |optional| {
                    const entry = optional orelse continue;
                    if (entry.kind == .overload)
                        return try self.declarationReference(association.member((try self.visibleTypeMember(namespace, entry.name, span)).?));
                    const shape = (try self.functionShape(entry.item_id)) orelse return error.Unavailable;
                    if (count != entry.name.operation.operandCount() and count != shape.parameters.len) continue;
                    if (selected != null) {
                        try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .ambiguous_operation_reference);
                        return error.Unavailable;
                    }
                    selected = entry;
                }
                const entry = selected orelse return null;
                return try self.declarationReference(association.member((try self.visibleTypeMember(namespace, entry.name, span)).?));
            }
            if (first != null and second != null) return .{ .overloaded_function = try self.ctx.intern(FunctionOverloads, .{ .candidates = &.{
                association.member(first.?.item_id),
                association.member(second.?.item_id),
            } }) };
            const entry = first orelse second.?;
            return try self.declarationReference(association.member((try self.visibleTypeMember(namespace, entry.name, span)).?));
        }

        fn declarationReference(self: @This(), instance: structures.InstanceId) !structures.NameReference {
            const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
            if (location.kind == .overload)
                return .{ .overloaded_function = (try self.ctx.get(ResolveOverloads, instance)).* orelse return error.Unavailable };
            return .{ .declaration = instance };
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
            const exported = (try resolveModuleExport(self.ctx, try self.currentModule(), namespace.module, name, origin, &visited, true)) orelse return error.Unavailable;
            return switch (exported) {
                .declaration => |item| try self.declarationReference(.{ .item = item }),
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
                if (loc.owner == null) break;
                const inferring = self.prior_static_arguments != null and std.meta.eql(instance, self.instance.?);
                const parent = (try enclosingInstance(self.ctx, instance, inferring)) orelse break;
                const parent_loc = try self.ctx.lookupInterned(ItemLocations, parent.item);
                const identity: ?NamespaceIdentity = if (parent_loc.kind == .primitive)
                    .{ .primitive = parent.item }
                else if (loc.source_site) |site|
                    .{ .generated = .{ .owner = parent, .node_offset = site } }
                else if (parent_loc.kind == .structure) identity: {
                    const value = (try self.staticItem(parent)) orelse unreachable;
                    const type_id = (try self.lookupCompileTimeValue(value)).type;
                    break :identity .fromStruct((try typePayload(self.ctx, type_id, .structure)).?);
                } else null;
                if (identity) |structure| {
                    const namespace = (try self.ctx.get(TypeNamespace, structure)).* orelse return error.Unavailable;
                    if (namespace.resolve(name)) |item| return .{ .item = item, .specialization = parent.specialization, .environment = parent.environment };
                }
                current = parent;
            }
            const scope = (try self.ctx.get(BuildModuleScope, self.file_id.?)).* orelse return error.Unavailable;
            const item = scope.resolve(name) orelse return null;
            return .{ .item = item };
        }

        pub fn functionItemReference(self: @This(), instance: structures.InstanceId) !?structures.FunctionReference {
            const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
            if ((try staticArgumentValues(self.ctx, instance.specialization)).len != arity.total()) return null;
            const signature = (try self.functionSignature(instance)) orelse return error.Unavailable;
            if (signature.return_type == .type) return null;
            return .{
                .target = instance.item,
                .specialization = instance.specialization,
                .environment = instance.environment,
                .type_id = try self.facts().internCallable(signature),
            };
        }
    };
}

pub const RuntimeCapable = CompilerQuery("RuntimeCapable", .type_facts, runtimeCapable, .{});

fn runtimeCapable(ctx: anytype, type_id: structures.TypeId) anyerror!?bool {
    std.debug.assert(!type_id.isPrimitive());
    return (TypeFacts(@TypeOf(ctx)){ .ctx = ctx }).runtimeCapableUncached(type_id);
}

pub const HostTypeLayout = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = structures.TypeLayout;

    fn primitiveLayout(type_id: structures.TypeId) ?structures.TypeLayout {
        switch (type_id) {
            .int, .bool => return .{ .byte_size = 4, .byte_alignment = 4 },
            .byte => return .{ .byte_size = 1, .byte_alignment = 1 },
            .unit, .none, .never => return .{ .byte_size = 0, .byte_alignment = 1 },
            else => return null,
        }
    }

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id.isPrimitive()) return primitiveLayout(type_id) orelse error.Unavailable;
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        if (!try facts.isRuntimeCapable(type_id)) return error.Unavailable;
        if (try facts.storageCursorAccess(type_id) != null) return .{ .byte_size = 8, .byte_alignment = 8 };
        switch ((try typeData(ctx, type_id)).?) {
            .callable, .reference => return .{ .byte_size = @sizeOf(u64), .byte_alignment = @alignOf(u64) },
            .variant => return (try ctx.get(VariantLayout, type_id)).layout,
            .structure, .tuple => {
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

pub const VariantLayout = CompilerQuery("VariantLayout", .type_facts, variantLayout, .{});

fn variantLayout(ctx: anytype, type_id: structures.TypeId) anyerror!structures.VariantLayout {
    const members = (try typePayload(ctx, type_id, .variant)).?.members;
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

pub const TupleDefinition = CompilerQuery("TupleDefinition", .type_facts, tupleDefinition, .{});

fn tupleDefinition(ctx: anytype, type_id: structures.TypeId) anyerror!?structures.StructDefinition {
    const members = (try typePayload(ctx, type_id, .tuple) orelse return null).members;
    const fields = try ctx.allocator().alloc(structures.StructField, members.len);
    errdefer ctx.allocator().free(fields);
    var completed: usize = 0;
    errdefer for (fields[0..completed]) |field| ctx.allocator().free(field.name);
    for (members, fields, 0..) |member, *field, index| {
        field.* = .{
            .name = try ctx.allocator().print("{d}", .{index}),
            .kind = member.kind,
            .type_id = member.type_id,
            .span = .{ .start = 0, .end = 0 },
            .is_public = true,
        };
        completed += 1;
    }
    return .{ .fields = fields };
}

pub const StructLayout = CompilerQuery("StructLayout", .type_facts, structLayout, .{});

fn structLayout(ctx: anytype, type_id: structures.TypeId) anyerror!?structures.StructLayout {
    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
    const definition = (try facts.structDefinition(type_id)) orelse return null;

    if ((try ctx.get(OwnershipCapabilities, type_id)).* == null) return null;
    if (!try facts.isRuntimeCapable(type_id)) return null;

    const field_offsets = try ctx.allocator().alloc(u32, definition.fields.len);
    var keep_offsets = false;
    defer if (!keep_offsets) ctx.allocator().free(field_offsets);
    var byte_size: u32 = 0;
    var byte_alignment: u32 = 1;
    for (definition.fields, field_offsets) |field, *field_offset| {
        const field_layout = (ctx.get(HostTypeLayout, try facts.fieldStorageType(field)) catch |err| switch (err) {
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

pub const ArgumentPassing = CompilerQuery("ArgumentPassing", .type_facts, argumentPassing, .{});

fn argumentPassing(ctx: anytype, type_id: structures.TypeId) anyerror!?structures.ArgumentPassing {
    return (TypeFacts(@TypeOf(ctx)){ .ctx = ctx }).argumentPassingUncached(type_id);
}

pub const BorrowShape = CompilerQuery("BorrowShape", .type_facts, borrowShape, .{});

fn borrowShape(ctx: anytype, type_id: structures.TypeId) anyerror!?struct { contains: bool, stores: bool } {
    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
    _ = (try facts.ownershipCapabilities(type_id)) orelse return null;
    var visited: std.ArrayList(structures.TypeId) = .empty;
    defer visited.deinit(ctx.allocator());
    const contains = try facts.containsBorrowAt(type_id, &visited, false);
    visited.clearRetainingCapacity();
    return .{ .contains = contains, .stores = contains or try facts.containsBorrowAt(type_id, &visited, true) };
}

pub const OwnershipCapabilities = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?structures.OwnershipCapabilities;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        return switch ((try typeData(ctx, type_id)) orelse return trivialOwnership()) {
            .callable, .reference => trivialOwnership(),
            .variant => |variant| aggregateOwnership(ctx, .{ .shape = .{ .variant = variant.members } }),
            .structure => |identity| structOwnership(ctx, identity),
            .array => |array| aggregateOwnership(ctx, .{ .shape = .{ .array = array } }),
            .tuple => |tuple| aggregateOwnership(ctx, .{ .shape = .{ .tuple = tuple } }),
        };
    }

    fn trivialOwnership() structures.OwnershipCapabilities {
        return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    }

    fn includeOwnership(fields: *structures.OwnershipCapabilities, child: structures.OwnershipCapabilities) void {
        inline for (.{ "move", "copy" }) |name| {
            const aggregate = &@field(fields, name);
            const capability = @field(child, name);
            if (aggregate.* == .none or capability == .none) {
                aggregate.* = .none;
            } else if (aggregate.* != .trivial or capability != .trivial) {
                aggregate.* = .fieldwise;
            }
        }
        if (child.drop != .trivial) fields.drop = .fieldwise;
        inline for (.{ "needs_custom_move", "needs_custom_copy", "needs_automatic_drop", "requires_explicit_drop" }) |name|
            @field(fields, name) = @field(fields, name) or @field(child, name);
    }

    fn aggregateOwnership(ctx: anytype, shape: structures.TypeComponents) !?structures.OwnershipCapabilities {
        var fields = trivialOwnership();
        var components_iterator = shape;
        while (components_iterator.next()) |component| {
            if (component.kind == .reference or component.count == 0) continue;
            includeOwnership(&fields, (try ctx.get(OwnershipCapabilities, component.type_id)).* orelse return null);
        }
        if (shape.shape == .variant) {
            fields.needs_custom_move = fields.move != .none and fields.needs_custom_move;
            fields.needs_custom_copy = fields.copy != .none and fields.needs_custom_copy;
            if (fields.move != .none) fields.move = .fieldwise;
            if (fields.copy != .none) fields.copy = .fieldwise;
        }
        return fields;
    }

    fn structOwnership(ctx: anytype, identity: structures.StructIdentity) !?structures.OwnershipCapabilities {
        var visited: StructVisits = .empty;
        defer visited.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, identity, &visited)) return null;
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        const fields = (try aggregateOwnership(ctx, .{ .shape = .{ .structure = definition } })) orelse return null;

        const move: structures.MoveCapability = if (definition.ownership.move) |property| blk: {
            if ((property.capability == .trivial and fields.move != .trivial) or
                (property.capability == .fieldwise and fields.move == .none))
                return rejectOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_move else .fieldwise_move);
            if (property.capability == .custom and fields.move == .none)
                return rejectOwnershipProperty(ctx, identity, property.span, .custom_move);
            break :blk property.capability;
        } else if (fields.move != .none) .fieldwise else .none;
        const copy: structures.CopyCapability = if (definition.ownership.copy) |property| blk: {
            if ((property.capability == .trivial and fields.copy != .trivial) or
                (property.capability == .fieldwise and fields.copy == .none))
                return rejectOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_copy else .fieldwise_copy);
            break :blk property.capability;
        } else .none;
        const drop: structures.DropCapability = if (definition.ownership.drop) |property| blk: {
            if (property.capability == .trivial and fields.drop != .trivial)
                return rejectOwnershipProperty(ctx, identity, property.span, .trivial_drop);
            break :blk property.capability;
        } else if (fields.drop == .trivial) .trivial else .fieldwise;
        return .{
            .move = move,
            .copy = copy,
            .drop = drop,
            .needs_custom_move = move == .custom or (move == .fieldwise and fields.needs_custom_move),
            .needs_custom_copy = copy == .custom or (copy == .fieldwise and fields.needs_custom_copy),
            .needs_automatic_drop = drop == .custom or (drop == .fieldwise and fields.needs_automatic_drop),
            .requires_explicit_drop = drop == .explicit or (drop == .fieldwise and fields.requires_explicit_drop),
        };
    }

    /// A declared capability cannot promise more than the struct's fields provide.
    fn rejectOwnershipProperty(
        ctx: anytype,
        identity: structures.StructIdentity,
        span: structures.SourceSpan,
        reason: structures.Diagnostic.IncompatibleStructOwnershipProperty,
    ) !Output {
        const resolved = (try ctx.get(ResolveItem, structOwnerItem(identity))).* orelse return error.Unavailable;
        try typing.emitSemanticIssue(ctx, resolved.file_id, .{ .span = span, .kind = .{ .struct_ownership_property_incompatible_with_fields = reason } });
        return null;
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
        if (field.kind == .reference) continue;
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
    return switch ((try typeData(ctx, type_id)) orelse return true) {
        .callable, .reference => true,
        .array => |array| validateContainedType(ctx, array.element_type, file_id, span, visited),
        .variant => |variant| for (variant.members) |member| {
            if (!try validateContainedType(ctx, member, file_id, span, visited)) break false;
        } else true,
        .tuple => |tuple| for (tuple.members) |member| {
            if (member.kind == .owned and !try validateContainedType(ctx, member.type_id, file_id, span, visited)) break false;
        } else true,
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

pub const IndexItems = CompilerQuery("IndexItems", .declarations, indexItems, .{});

fn indexItems(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ItemIndex {
    const tree = (try ctx.get(DiscoverItems, file_id)).* orelse return null;
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
            var segments = std.mem.splitScalar(u8, owner_path, '.');
            var owner: ?structures.ItemId = null;
            while (segments.next()) |segment| {
                std.debug.assert(segment.len != 0);
                const primitive = if (owner == null) std.meta.stringToEnum(structures.TypeId, segment) else null;
                owner = try ctx.intern(ItemLocations, .{
                    .origin = .{ .module = loc.origin.module },
                    .owner = owner,
                    .kind = if (primitive != null) .primitive else .structure,
                    .name = .{ .identifier = segment },
                });
            }
            loc.owner = owner orelse unreachable;
        }
        const item_id = try ctx.intern(ItemLocations, loc);
        item_ids[index] = item_id;
        if (entries.contains(item_id)) {
            try rejectDeclaration(ctx, file_id, &parsed, item.declaration, .duplicate_struct_member);
            entries.deinit(ctx.allocator());
            return null;
        }
        entries.putAssumeCapacityNoClobber(item_id, item.declaration);
    }
    return .{ .file_id = file_id, .entries = entries };
}

pub const ModuleDeclarations = CompilerQuery("ModuleDeclarations", .declarations, moduleDeclarations, .{ .disk_boundary = true });

fn moduleDeclarations(ctx: anytype, module: structures.ModuleId) anyerror!?structures.ModuleScope {
    const members = try ctx.input(ModuleMembers, module);

    var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.name.deinit(ctx.allocator());
        entries.deinit(ctx.allocator());
    }
    var names = structures.Name.Set.init(ctx.allocator());
    defer names.deinit();
    for (members.*) |file_id| {
        const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
        const tree = (try ctx.get(DiscoverItems, file_id)).* orelse return null;
        const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
        std.debug.assert(tree.items.len == index.count());
        for (tree.items, index.ids()) |item, item_id| {
            if (item.loc.kind == .top_level_entry or item.parent != null or item.qualified_owner != null) continue;
            std.debug.assert(item.loc.origin.module == module);
            if ((try names.getOrPut(item.loc.name)).found_existing) {
                try rejectDeclaration(ctx, file_id, &parsed, item.declaration, .duplicate_top_level_declaration);
                return null;
            }
            try appendScopeEntry(ctx, &entries, .{
                .name = item.loc.name,
                .item_id = item_id,
                .kind = item.loc.kind,
                .is_public = item.is_public,
                .is_converter = item.loc.kind == .function and parsed.nodes[parsed.nodes[item.declaration].data.node_node.b.index()].is_converter,
            });
        }
    }
    return try finishScope(ctx, &entries);
}

/// Coarse keys exclude impossible headers; ordinary inference decides matches.
/// Widenable and computed annotations retain the wildcard when necessary.
pub const ConverterHead = union(enum) {
    any,
    primitive: structures.TypeId,
    nominal: structures.ItemId,
    callable,
    tuple,
    variant,
    reference,

    fn order(left: ConverterHead, right: ConverterHead) std.math.Order {
        const tag_order = std.math.order(@backingInt(std.meta.activeTag(left)), @backingInt(std.meta.activeTag(right)));
        if (tag_order != .eq) return tag_order;
        return switch (left) {
            .primitive => |value| std.math.order(@backingInt(value), @backingInt(right.primitive)),
            .nominal => |value| std.math.order(@backingInt(value), @backingInt(right.nominal)),
            else => .eq,
        };
    }
};

fn converterAnnotationHead(ctx: anytype, declaration: anytype, annotation: structures.Node.Index, source: bool) !ConverterHead {
    const node = declaration.parsed.nodes[annotation.index()];
    switch (node.tag) {
        // Flattening and removing never can collapse a variant to one type.
        .type_variant => return .any,
        .type_tuple => return .tuple,
        .type_func => return .callable,
        .reference_type => return if (source) .any else .reference,
        .identifier, .type, .call => {},
        else => return .any,
    }
    const root = if (node.tag == .call) node.data.node_node.a else annotation;
    const root_node = declaration.parsed.nodes[root.index()];
    if (root_node.tag != .identifier and root_node.tag != .type) return .any;
    const span = nodeSpan(&declaration.parsed, root);
    const name = declaration.source[span.start..span.end];
    if (semantic.functionHasParameter(&declaration.parsed, declaration.source, declaration.resolved.declaration, name)) return .any;
    // Inspect the declaration identity directly. Resolving a value reference
    // could demand an overload set or execute a type alias.
    if (try declaration.analysis.resolveDeclaration(name)) |instance| {
        const location = try ctx.lookupInterned(ItemLocations, instance.item);
        if (node.tag != .call and location.kind == .structure) return .{ .nominal = instance.item };
        if (node.tag == .call and try declaration.analysis.isGenericStruct(instance.item)) return .{ .nominal = instance.item };
    } else if (node.tag != .call) {
        if (std.meta.stringToEnum(structures.TypeId, name)) |type_id| return .{ .primitive = type_id };
    }
    return .any;
}

pub const ConverterHeads = CompilerQuery("ConverterHeads", .signatures, converterHeads, .{});

fn converterHeads(ctx: anytype, item: structures.ItemId) anyerror!?struct { source: ConverterHead, target: ConverterHead } {
    const declaration = try (AnalysisContext(@TypeOf(ctx)){ .ctx = ctx }).declarationContext(.{ .item = item }, &.{});
    const source = semantic.converterIndexSource(&declaration.parsed, declaration.source, declaration.resolved.declaration);
    const target = semantic.functionReturnTypeNode(&declaration.parsed, declaration.resolved.declaration) orelse return null;
    return .{
        .source = if (source) |annotation| try converterAnnotationHead(ctx, declaration, annotation, true) else .any,
        .target = try converterAnnotationHead(ctx, declaration, target, false),
    };
}

pub const ModuleConverterIndex = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Input = structures.ModuleId;
    pub const Entry = struct {
        source: ConverterHead,
        target: ConverterHead,
        item: structures.ItemId,
        is_public: bool,

        fn orderKey(entry: Entry, source: ConverterHead, target: ConverterHead) std.math.Order {
            const target_order = ConverterHead.order(entry.target, target);
            return if (target_order == .eq) ConverterHead.order(entry.source, source) else target_order;
        }

        fn lessThan(_: void, left: Entry, right: Entry) bool {
            const order = left.orderKey(right.source, right.target);
            return if (order == .eq) @backingInt(left.item) < @backingInt(right.item) else order == .lt;
        }
    };
    pub const Output = ?[]const Entry;
    pub const eqlOutput = value_operations.Owned(Output).eql;

    pub fn run(ctx: anytype, module: Input) !Output {
        const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
        var entries: std.ArrayList(Entry) = .empty;
        for (declarations.entries) |entry| {
            if (!entry.is_converter) continue;
            const heads = (try ctx.get(ConverterHeads, entry.item_id)).* orelse return null;
            try entries.append(ctx.allocator(), .{ .source = heads.source, .target = heads.target, .item = entry.item_id, .is_public = entry.is_public });
        }
        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
        return try entries.toOwnedSlice(ctx.allocator());
    }
};

/// A separate projection stops unrelated index edits at the bucket boundary.
/// Empty buckets are dependencies too, so additions invalidate cached misses.
pub const ConverterBucket = CompilerQuery("ConverterBucket", .declarations, converterBucket, .{ .content_equality = true });

fn converterBucket(ctx: anytype, key: struct { module: structures.ModuleId, source: ConverterHead, target: ConverterHead, requester: structures.ModuleId }) anyerror!?[]const structures.ItemId {
    const entries = (try ctx.get(ModuleConverterIndex, key.module)).* orelse return null;
    const start, const end = std.sort.equalRange(ModuleConverterIndex.Entry, entries, key, struct {
        fn compare(bucket: ConverterBucket.Input, entry: ModuleConverterIndex.Entry) std.math.Order {
            return entry.orderKey(bucket.source, bucket.target).invert();
        }
    }.compare);
    var items: std.ArrayList(structures.ItemId) = .empty;
    for (entries[start..end]) |entry| {
        if (entry.is_public or key.module == key.requester) try items.append(ctx.allocator(), entry.item);
    }
    return try items.toOwnedSlice(ctx.allocator());
}

fn conversionTypeHead(ctx: anytype, type_id: structures.TypeId) !ConverterHead {
    return switch ((try typeData(ctx, type_id)) orelse return .{ .primitive = type_id }) {
        .structure => |identity| .{ .nominal = structOwnerItem(identity) },
        .array => .{ .nominal = (try standardFunction(ctx, .array, "Array")) orelse return error.Unavailable },
        .callable => .callable,
        .tuple => .tuple,
        .variant => .variant,
        .reference => .reference,
    };
}

pub const ConversionSource = union(enum) {
    typed: structures.TypeId,
    constant: structures.CompileTimeValueId,
    /// Target-first inference for a fixed collection with untyped elements.
    collection: u32,

    fn typeId(self: ConversionSource, ctx: anytype) !?structures.TypeId {
        return switch (self) {
            .typed => |type_id| type_id,
            .constant => |value_id| switch ((try ctx.lookupInterned(CompileTimeValues, value_id)).*) {
                .type => .type,
                .runtime => |value| value.type_id,
            },
            .collection => null,
        };
    }
};

pub const ConversionCandidates = CompilerQuery("ConversionCandidates", .conversion_matching, conversionCandidates, .{ .disk_boundary = true, .content_equality = true });

fn conversionCandidates(ctx: anytype, key: struct { source: ConversionSource, target: structures.TypeId, requester: structures.ModuleId }) anyerror!?[]const structures.ConversionCandidate {
    const items = (try ctx.get(ConverterItems, .{ .source = try key.source.typeId(ctx), .target = key.target, .requester = key.requester })).* orelse return null;
    var candidates: std.ArrayList(structures.ConversionCandidate) = .empty;
    for (items) |entry| {
        const match = (try ctx.get(ConverterMatch, .{ .item = entry.item, .source = key.source, .target = entry.target })).*;
        switch (match) {
            .mismatch => {},
            .candidate => |candidate| try candidates.append(ctx.allocator(), candidate),
        }
    }
    return try candidates.toOwnedSlice(ctx.allocator());
}

pub const TextType = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Name = enum { String, StaticString, StringView };
    pub const Input = Name;
    pub const Output = ?structures.TypeId;

    pub fn run(ctx: anytype, name: Input) anyerror!Output {
        const item = (try standardDeclaration(ctx, .text, @tagName(name), structures.ModuleScope.resolveStatic)) orelse return null;
        const type_id = try internStructType(ctx, item);
        if (name == .StaticString and try (TypeFacts(@TypeOf(ctx)){ .ctx = ctx }).staticStringBytes(type_id) == null) return null;
        return type_id;
    }
};

pub const ConverterItems = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Input = struct { source: ?structures.TypeId, target: structures.TypeId, requester: structures.ModuleId };
    pub const Output = ?[]const Entry;
    pub const eqlOutput = value_operations.Owned(Output).eql;
    pub const Entry = struct { item: structures.ItemId, target: structures.TypeId };

    pub fn run(ctx: anytype, key: Input) anyerror!Output {
        const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
        const source_owner = if (key.source) |type_id| try analysis.conversionOwner(type_id) else owner: {
            const file = (try standardFile(ctx, .array)) orelse return null;
            break :owner (try ctx.input(FileModule, file)).*;
        };
        const source_head: ConverterHead = if (key.source) |type_id| try conversionTypeHead(ctx, type_id) else .any;
        const source_heads = [_]ConverterHead{ source_head, .any };
        const targets = (try analysis.facts().variantMembers(key.target)) orelse &.{};
        var entries: std.ArrayList(Entry) = .empty;
        for (0..targets.len + 1) |target_index| {
            const target = if (target_index == 0) key.target else targets[target_index - 1];
            const target_heads = [_]ConverterHead{ try conversionTypeHead(ctx, target), .any };
            const owners = [_]?structures.ModuleId{ source_owner, try analysis.conversionOwner(target) };
            for (owners, 0..) |maybe_owner, owner_index| {
                const owner = maybe_owner orelse continue;
                if (owner_index != 0 and owners[0] == owner) continue;
                for (source_heads[0..if (source_head == .any) @as(usize, 1) else 2]) |input_head| {
                    for (target_heads) |target_head| {
                        const items = (try ctx.get(ConverterBucket, .{ .module = owner, .source = input_head, .target = target_head, .requester = key.requester })).* orelse return null;
                        for (items) |item| try entries.append(ctx.allocator(), .{ .item = item, .target = target });
                    }
                }
            }
        }
        return try entries.toOwnedSlice(ctx.allocator());
    }
};

/// Declaration matching is independent of the requesting module and use site.
/// Its fixed-size result also stops equal signature rechecks after file edits.
pub const ConverterMatch = CompilerQuery("ConverterMatch", .signatures, converterMatch, .{});

fn converterMatch(ctx: anytype, key: struct { item: structures.ItemId, source: ConversionSource, target: structures.TypeId }) anyerror!union(enum) { mismatch, candidate: structures.ConversionCandidate } {
    const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
    const source_value: ?structures.CompileTimeValueId = if (key.source == .constant) key.source.constant else null;
    const source_type = try key.source.typeId(ctx);
    const length: ?u32 = if (key.source == .collection) key.source.collection else null;
    var probe = (try analysis.probeConverterSignature(key.item, source_type, key.target, source_value, length)) orelse return .mismatch;
    defer probe.signature.deinit(ctx.allocator());
    const signature = probe.signature;
    if (signature.return_type != key.target) return .mismatch;
    if (length) |count| {
        if (signature.parameters.len != 1 or signature.parameters[0].mode != .init) return .mismatch;
        const collection = (try analysis.facts().collectionLiteralType(signature.parameters[0].type_id)) orelse return .mismatch;
        if (collection.length != count) return .mismatch;
    } else if (signature.parameters.len != 0 and !try semantic.canWidenTo(analysis, source_type.?, signature.parameters[0].type_id)) return .mismatch;
    const static_source = source_value != null and !try analysis.facts().isRuntimeCapable(source_type.?);
    if (signature.parameters.len != @as(usize, if (static_source) 0 else 1) or
        (!static_source and signature.parameters[0].mode != .imm and signature.parameters[0].mode != .ref and signature.parameters[0].mode != .init))
    {
        const declaration = (try itemSource(ctx, key.item)) orelse return error.Unavailable;
        try ctx.emit(structures.Diagnostic, .{ .file_id = declaration.resolved.file_id, .span = nodeSpan(&declaration.parsed, @fromBackingInt(declaration.resolved.declaration)), .kind = .invalid_converter, .instance = probe.instance });
        return error.Unavailable;
    }
    return .{ .candidate = .{
        .instance = probe.instance,
        .input_type = if (static_source) source_type.? else signature.parameters[0].type_id,
        .target_type = key.target,
        .source_mode = if (static_source) .static else signature.parameters[0].mode,
    } };
}

pub const BuildModuleScope = CompilerQuery("BuildModuleScope", .declarations, buildModuleScope, .{ .disk_boundary = true });

fn buildModuleScope(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ModuleScope {
    const file_module = (try ctx.input(FileModule, file_id)).*;
    const declarations = (try ctx.get(ModuleDeclarations, file_module)).* orelse return null;
    var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.name.deinit(ctx.allocator());
        entries.deinit(ctx.allocator());
    }
    for (declarations.entries) |entry| {
        try appendScopeEntry(ctx, &entries, entry);
    }
    const imports = (try ctx.get(ResolveFileImports, file_id)).* orelse return null;
    for (imports.imports) |binding| {
        if (binding.target != .declaration) continue;
        const item = binding.target.declaration;
        const loc = try ctx.lookupInterned(ItemLocations, item);
        try appendScopeEntry(ctx, &entries, .{ .name = .{ .identifier = binding.name }, .item_id = item, .kind = loc.kind });
    }
    return try finishScope(ctx, &entries);
}

fn appendScopeEntry(ctx: anytype, entries: *std.ArrayList(structures.ModuleScope.Entry), entry: structures.ModuleScope.Entry) !void {
    var owned = try value_operations.Owned(structures.ModuleScope.Entry).clone(ctx.allocator(), entry);
    errdefer value_operations.Owned(structures.ModuleScope.Entry).deinit(&owned, ctx.allocator());
    try entries.append(ctx.allocator(), owned);
}

fn finishScope(ctx: anytype, entries: *std.ArrayList(structures.ModuleScope.Entry)) !structures.ModuleScope {
    std.mem.sort(structures.ModuleScope.Entry, entries.items, {}, struct {
        fn lessThan(_: void, left: structures.ModuleScope.Entry, right: structures.ModuleScope.Entry) bool {
            return structures.Name.order(left.name, right.name) == .lt;
        }
    }.lessThan);
    return .{ .entries = try entries.toOwnedSlice(ctx.allocator()) };
}

pub const CollectFileImports = CompilerQuery("CollectFileImports", .declarations, collectFileImports, .{});

fn collectFileImports(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ImportDeclarations {
    const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
    const source = (try ctx.input(SourceText, file_id)).*;
    return try semantic.collectImports(ctx.allocator(), &parsed, source);
}

pub const ResolveFileImports = CompilerQuery("ResolveFileImports", .declarations, resolveFileImports, .{});

fn resolveFileImports(ctx: anytype, file_id: structures.FileId) anyerror!?structures.FileImports {
    const collected = (try ctx.get(CollectFileImports, file_id)).* orelse return null;
    const module = (try ctx.input(FileModule, file_id)).*;
    const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
    var modules: std.AutoArrayHashMapUnmanaged(structures.ModuleId, void) = .empty;
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
    const explicit_prelude = for (collected.entries) |entry| {
        if (std.mem.eql(u8, entry.path.spelling, standard_library.File.prelude.modulePath())) break true;
    } else false;
    if (!standard_module and !explicit_prelude) {
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
    sortImports(imports.items);
    const owned_modules = try ctx.allocator().dupe(structures.ModuleId, modules.keys());
    errdefer ctx.allocator().free(owned_modules);
    sortIds(structures.ModuleId, owned_modules);
    return .{ .modules = owned_modules, .imports = try imports.toOwnedSlice(ctx.allocator()) };
}

const ExportVisit = struct { module: structures.ModuleId, name: []const u8 };
const ImportOrigin = struct { file_id: structures.FileId, span: structures.SourceSpan };
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

/// Prelude defaults skip the catalog check; the module graph validates their paths.
fn resolveModuleExport(
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
                    const reexported = (try reexportedModule(ctx, file_id, entry, validate_module_catalog)) orelse return null;
                    const candidate = (try resolveModuleExport(ctx, target, reexported, item.original.spelling, origin, visited, validate_module_catalog)) orelse return null;
                    if (!try mergeExport(ctx, origin, &result, candidate, declaration != null)) return null;
                }
                continue;
            }
            if (!std.mem.eql(u8, importBoundName(entry), name)) continue;
            const reexported = (try reexportedModule(ctx, file_id, entry, validate_module_catalog)) orelse return null;
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

/// The module a public import statement of a target module re-exports.
fn reexportedModule(ctx: anytype, file_id: structures.FileId, entry: structures.ImportDeclaration, validate_module_catalog: bool) !?structures.ModuleId {
    if (!validate_module_catalog) return try ctx.intern(ModulePaths, .{ .path = entry.path.spelling });
    return resolveImportedModule(ctx, .{ .file_id = file_id, .span = entry.path.span }, entry.path.spelling);
}

/// A whole-module import binds its alias or the last segment of its path.
fn importBoundName(entry: structures.ImportDeclaration) []const u8 {
    const spelling = (entry.alias orelse entry.path).spelling;
    const dot = std.mem.lastIndexOfScalar(u8, spelling, '.') orelse return spelling;
    return spelling[dot + 1 ..];
}

fn sortImports(imports: []structures.FileImport) void {
    std.mem.sort(structures.FileImport, imports, {}, struct {
        fn lessThan(_: void, left: structures.FileImport, right: structures.FileImport) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);
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

pub const ResolvePreludeImports = CompilerQuery("ResolvePreludeImports", .declarations, resolvePreludeImports, .{});

fn resolvePreludeImports(ctx: anytype, _: void) anyerror!?structures.FileImports {
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
        if (entry.is_public and entry.name != .converter) try names.put(entry.name.text(), {});
    }
    for (members) |prelude_file| {
        const collected = (try ctx.get(CollectFileImports, prelude_file)).* orelse return null;
        for (collected.entries) |entry| {
            if (!entry.is_public) continue;
            if (entry.selective) |selections| {
                for (selections) |selection| try names.put(selection.bound.spelling, {});
                continue;
            }
            try names.put(importBoundName(entry), {});
        }
    }

    var iterator = names.keyIterator();
    while (iterator.next()) |name_ptr| {
        const name = name_ptr.*;
        var visited: std.ArrayList(ExportVisit) = .empty;
        defer visited.deinit(ctx.allocator());
        const origin: ImportOrigin = .{ .file_id = members[0], .span = .{ .start = 0, .end = 0 } };
        const exported = (try resolveModuleExport(ctx, importer, prelude, name, origin, &visited, false)) orelse return null;
        const owned = try ctx.allocator().dupe(u8, name);
        errdefer ctx.allocator().free(owned);
        try imports.append(ctx.allocator(), .{ .name = owned, .target = exported, .reexport = false });
    }
    sortImports(imports.items);
    return .{ .modules = &.{}, .imports = try imports.toOwnedSlice(ctx.allocator()) };
}

fn resolveImportStatement(
    ctx: anytype,
    file_id: structures.FileId,
    module: structures.ModuleId,
    declarations: structures.ModuleScope,
    entry: structures.ImportDeclaration,
    modules: *std.AutoArrayHashMapUnmanaged(structures.ModuleId, void),
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
            const exported = (try resolveModuleExport(ctx, module, target_module, item.original.spelling, origin, &visited, true)) orelse return false;
            if (!try bindImport(ctx, .{ .file_id = file_id, .span = item.bound.span }, declarations, item.bound.spelling, exported, entry.is_public, imports, bound)) return false;
        }
        return true;
    }
    if (entry.alias) |alias| {
        return bindImport(ctx, .{ .file_id = file_id, .span = alias.span }, declarations, alias.spelling, .{ .namespace = .{ .module = target_module } }, entry.is_public, imports, bound);
    }
    try modules.put(ctx.allocator(), target_module, {});
    const root_name = std.mem.sliceTo(entry.path.spelling, '.');
    const top = try ctx.intern(ModulePaths, .{ .path = root_name });
    const direct = root_name.len == entry.path.spelling.len;
    const origin: ImportOrigin = .{ .file_id = file_id, .span = .{ .start = entry.path.span.start, .end = entry.path.span.start + root_name.len } };
    return bindImport(ctx, origin, declarations, root_name, .{ .namespace = .{ .module = top, .members_visible = direct } }, entry.is_public and direct, imports, bound);
}

pub const IndexModuleItems = struct {
    pub const profile_category: profiling.Category = .declarations;
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
                // Entry members stay in their file; primitive namespaces belong to the prelude.
                const owner_location = try ctx.lookupInterned(ItemLocations, owner);
                const valid_owner = switch (owner_location.kind) {
                    .top_level_entry => owner_location.origin.entry == entry.location.file_id,
                    .primitive => entry.location.file_id == try standardFile(ctx, .prelude),
                    else => index.resolve(owner) != null,
                };
                if (!valid_owner) return rejectItem(ctx, entry.location, .invalid_namespace_owner);
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

pub const ResolveItem = CompilerQuery("ResolveItem", .declarations, resolveItem, .{ .disk_boundary = true });

fn resolveItem(ctx: anytype, item_id: structures.ItemId) anyerror!?structures.ResolvedItem {
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

const ExternalSymbol = struct {
    pub const Input = structures.ItemId;
    pub const Output = ?standard_library.External;

    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item);
        if (loc.kind != .function) return null;
        const item_source = (try itemSource(ctx, item)) orelse return null;
        if (!semantic.isExternalFunction(&item_source.parsed, item_source.resolved.declaration) or loc.origin == .entry) return null;
        const symbol = if (loc.owner) |owner| primitive: {
            const owner_location = try ctx.lookupInterned(ItemLocations, owner);
            if (owner_location.kind != .primitive) return null;
            if (loc.name != .operation) return null;
            const type_id = std.meta.stringToEnum(structures.TypeId, owner_location.name.text()) orelse unreachable;
            if (!loc.name.operation.supportsPrimitive(type_id)) return null;
            break :primitive standard_library.External.primitive_operation;
        } else std.meta.stringToEnum(standard_library.External, loc.name.text()) orelse return null;
        if (symbol == .primitive_operation and loc.owner == null) return null;
        const file = symbol.file();
        const path = (try ctx.lookupInterned(ModulePaths, loc.origin.module)).path;
        if (!std.mem.eql(u8, path, file.modulePath())) return null;
        const registered = (try standardFile(ctx, file)) orelse return null;
        return if (registered == item_source.resolved.file_id) symbol else null;
    }
};

pub const FunctionShape = CompilerQuery("FunctionShape", .signatures, functionShape, .{});

fn functionShape(ctx: anytype, item_id: structures.ItemId) anyerror!?structures.FunctionShape {
    const loc = try ctx.lookupInterned(ItemLocations, item_id);
    if (loc.kind != .function) return null;
    const declaration = (try declarationSource(ctx, .{ .item = item_id })) orelse return null;
    const file_id = declaration.resolved.file_id;
    if (semantic.isExternalFunction(&declaration.parsed, declaration.resolved.declaration) and (try ctx.get(ExternalSymbol, item_id)).* == null) {
        const span = nodeSpan(&declaration.parsed, @fromBackingInt(@intCast(declaration.resolved.declaration)));
        try typing.emitSemanticIssue(ctx, file_id, .{ .span = span, .kind = .unsupported_external_declaration });
        return null;
    }
    return availableSemanticValue(ctx, file_id, .{ .item = item_id }, semantic.analyzeFunctionShape(&declaration.parsed, declaration.source, declaration.resolved.declaration, ctx.allocator()));
}

pub const IndependentConverterTypes = CompilerQuery("IndependentConverterTypes", .signatures, independentConverterTypes, .{});

fn independentConverterTypes(ctx: anytype, item: structures.ItemId) anyerror!semantic.IndependentConverterTypes {
    const declaration = try (AnalysisContext(@TypeOf(ctx)){ .ctx = ctx }).declarationContext(.{ .item = item }, &.{});
    return semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).analyzeIndependentConverterTypes(declaration.resolved.declaration);
}

// A namespace member inherits its lexical owners' static arguments before
// appending its own. Keeping the two counts separate preserves specialization
// through nested namespaces without creating new declaration identities.
pub const SpecializationArity = struct {
    pub const profile_category: profiling.Category = .signatures;
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
    const arguments = try staticArgumentValues(ctx, instance.specialization);
    const partial = inferring or loc.kind == .overload;
    if (partial) {
        if (arguments.len > arity.inherited) return error.Unavailable;
    } else if (arguments.len != arity.total()) return error.Unavailable;
    return .{
        .item = owner,
        .environment = instance.environment,
        .specialization = if (arity.inherited == 0 or arguments.len == 0) null else if (partial)
            instance.specialization
        else
            try ctx.intern(CompileTimeValueTuples, .{ .values = arguments[0..arity.inherited] }),
    };
}

pub const FunctionInstanceSignature = CompilerQuery("FunctionInstanceSignature", .signatures, functionInstanceSignature, .{ .disk_boundary = true });

fn functionInstanceSignature(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionSignature {
    return validatedFunctionSignature(ctx, instance);
}

pub const FunctionCandidateSignature = CompilerQuery("FunctionCandidateSignature", .signatures, functionCandidateSignature, .{});

fn functionCandidateSignature(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionSignature {
    const loc = try ctx.lookupInterned(ItemLocations, instance.item);
    if (loc.kind != .function) return null;
    const declaration = (try declarationSource(ctx, instance)) orelse return null;
    const file_id = declaration.resolved.file_id;
    const specialization = try staticArgumentValues(ctx, instance.specialization);
    const arity = (try ctx.get(SpecializationArity, instance.item)).* orelse return null;
    // Instances can outlive the source shape that created them.
    if (specialization.len != arity.total()) return null;
    const shape = (try ctx.get(FunctionShape, instance.item)).* orelse return null;
    var signature = (try availableSemanticValue(ctx, file_id, instance, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).run("analyzeShapedFunctionSignature", .{ declaration.resolved.declaration, specialization[arity.inherited..], shape }))) orelse return null;
    errdefer signature.deinit(ctx.allocator());
    if (loc.name == .operation and !try validOperationShape(declaration.analysis, loc.owner, loc.name.operation, signature)) {
        try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = nodeSpan(&declaration.parsed, @fromBackingInt(declaration.resolved.declaration)), .kind = .invalid_operation_signature, .instance = instance });
        signature.deinit(ctx.allocator());
        return null;
    }
    return signature;
}

pub const FunctionSignature = CompilerQuery("FunctionSignature", .signatures, functionSignature, .{ .disk_boundary = true });

fn functionSignature(ctx: anytype, item_id: structures.ItemId) anyerror!?structures.FunctionSignature {
    return validatedFunctionSignature(ctx, .{ .item = item_id });
}

pub const FunctionConstraints = CompilerQuery("FunctionConstraints", .signatures, functionConstraints, .{});

fn functionConstraints(ctx: anytype, instance: structures.InstanceId) anyerror!?struct { failed_condition: ?structures.Node.Index = null } {
    _ = (try ctx.get(FunctionCandidateSignature, instance)).* orelse return null; // Validate the instance's header before its constraints.
    const declaration = (try declarationSource(ctx, instance)) orelse return null;
    const file_id = declaration.resolved.file_id;
    for (semantic.functionWhereConditions(&declaration.parsed, declaration.resolved.declaration)) |condition| {
        var unresolved = (try availableSemanticValue(ctx, file_id, instance, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).buildUnresolvedBody(.{ .where_condition = condition }))) orelse return null;
        defer unresolved.deinit(ctx.allocator());
        var body = (try typing.resolveAndTypeBody(ctx, instance, file_id, &.{}, .bool, .{ .publish_instruction_spans = true, .allow_type_values = true }, declaration.analysis, unresolved)) orelse return null;
        defer body.deinit(ctx.allocator());
        switch (try executeThunk(ctx, instance, &body, null)) {
            .returned => |value| if (!value.runtime.bool) return .{ .failed_condition = condition },
            .exit => |status| {
                try ctx.emit(structures.CompilerControl, .{ .exit = status });
                return null;
            },
            .execution_error => |execution_error| {
                try emitComptimeExecutionIssue(ctx, instance, condition, execution_error);
                return null;
            },
            .reported_error, .unavailable => return null,
        }
    }
    return .{};
}

/// A demanded signature also satisfies its where clauses, external
/// implementation, and library contracts beyond the candidate header.
fn validatedFunctionSignature(ctx: anytype, instance: structures.InstanceId) !?structures.FunctionSignature {
    const header = (try ctx.get(FunctionCandidateSignature, instance)).* orelse return null;
    const declaration = (try itemSource(ctx, instance.item)) orelse return null;
    const resolved = declaration.resolved;
    const parsed = &declaration.parsed;
    const span = nodeSpan(parsed, @fromBackingInt(@intCast(resolved.declaration)));
    if (semantic.functionWhereConditions(parsed, resolved.declaration).len != 0) {
        const constraints = (try ctx.get(FunctionConstraints, instance)).* orelse return null;
        if (constraints.failed_condition) |condition| {
            try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, condition), .kind = .where_condition_failed, .instance = instance });
            return null;
        }
    }
    if (semantic.isExternalFunction(parsed, resolved.declaration) and !try validExternalSignature(ctx, instance, resolved.file_id, span, header)) return null;
    const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
    const behavior = try analysis_context.callBehavior(instance.item);
    const iteration_end = if (behavior == .list_consume) analysis_context.iterationEndType() catch |err| switch (err) {
        error.Unavailable => return null,
        else => return err,
    } else null;
    const library_issue = intrinsics.signatureIssue(analysis_context.facts(), behavior, header, iteration_end) catch |err| switch (err) {
        error.Unavailable => return null,
        else => return err,
    };
    if (library_issue) |kind| {
        try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = span, .kind = kind, .instance = instance });
        return null;
    }
    return header;
}

fn lookupFunctionSignature(ctx: anytype, instance: structures.InstanceId) !?structures.FunctionSignature {
    return if (instance.specialization != null or instance.environment != null)
        (try ctx.get(FunctionInstanceSignature, instance)).*
    else
        (try ctx.get(FunctionSignature, instance.item)).*;
}

fn validOperationShape(types: anytype, owner: ?structures.ItemId, operation: structures.Operation, signature: structures.FunctionSignature) !bool {
    if (owner == null or signature.parameters.len == 0) return false;
    const association = (try types.typeNamespace(signature.parameters[0].type_id)) orelse return false;
    if (association.query_key.owner() != owner.?) return false;
    return intrinsics.validOperationShape(operation, signature);
}

/// An external declaration must match its implementation, and an ownership
/// intrinsic must have a copyable or movable operand type.
fn validExternalSignature(ctx: anytype, instance: structures.InstanceId, file_id: structures.FileId, span: structures.SourceSpan, signature: structures.FunctionSignature) !bool {
    const symbol = (try ctx.get(ExternalSymbol, instance.item)).* orelse return false;
    if (!try intrinsics.validExternalSignature(TypeFacts(@TypeOf(ctx)){ .ctx = ctx }, symbol, signature)) {
        try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = span, .instance = instance, .kind = .invalid_external_signature });
        return false;
    }
    const type_id = switch (symbol) {
        .copy_value, .move_value => signature.return_type,
        .array_filled => signature.parameters[0].type_id,
        else => return true,
    };
    const capabilities = (try ctx.get(OwnershipCapabilities, type_id)).* orelse return false;
    const supported = if (symbol == .move_value) capabilities.move != .none else capabilities.copy != .none;
    if (supported) return true;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = span,
        .kind = if (symbol == .move_value)
            .{ .type_not_movable = type_id }
        else
            .{ .type_not_copyable = .{ .type_id = type_id, .is_movable = capabilities.move != .none } },
    });
    return false;
}

const StandardMemoryInstance = struct {
    generated: structures.GeneratedStructIdentity,
    arguments: []const structures.CompileTimeValueId,
    element_type: structures.TypeId,
};

fn standardMemoryInstance(ctx: anytype, type_id: structures.TypeId, structure: standard_library.Structure) !?StandardMemoryInstance {
    const generated = switch ((try typePayload(ctx, type_id, .structure)) orelse return null) {
        .generated => |value| value,
        .declared => return null,
    };
    const location = try ctx.lookupInterned(ItemLocations, generated.owner.item);
    if (location.owner != null or !std.mem.eql(u8, location.name.text(), structure.declarationName())) return null;
    const file: standard_library.File = if (structure == .collection_literal) .array else .memory_allocation;
    if (generated.owner.item != try standardFunction(ctx, file, structure.declarationName())) return null;
    const arguments = try staticArgumentValues(ctx, generated.owner.specialization);
    if (arguments.len != @as(usize, if (structure == .collection_literal) 2 else 1)) return null;
    const element_type = switch ((try ctx.lookupInterned(CompileTimeValues, arguments[0])).*) {
        .type => |value| value,
        .runtime => return null,
    };
    return .{ .generated = generated, .arguments = arguments, .element_type = element_type };
}

pub const ResolveStatic = CompilerQuery("ResolveStatic", .comptime_execution, resolveStatic, .{});

fn resolveStatic(ctx: anytype, item: structures.ItemId) anyerror!?structures.CompileTimeValueId {
    return (try ctx.get(ResolveStaticInstance, .{ .item = item })).*;
}

pub const ResolveStaticInstance = CompilerQuery("ResolveStaticInstance", .comptime_execution, resolveStaticInstance, .{});

fn resolveStaticInstance(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.CompileTimeValueId {
    const item_id = instance.item;
    const loc = try ctx.lookupInterned(ItemLocations, item_id);
    if (loc.kind != .static and loc.kind != .structure) return null;
    if (instance.specialization != null) {
        const arity = (try ctx.get(SpecializationArity, item_id)).* orelse return null;
        // A cached reference may survive a change to its enclosing factory.
        if ((try staticArgumentValues(ctx, instance.specialization)).len != arity.total()) return null;
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
    const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
    const plan = (try availableSemanticValue(ctx, resolved.file_id, instance, semantic.analyzer(&parsed, source, analysis_context, ctx.allocator()).run("analyzeStaticDeclaration", .{resolved.declaration}))) orelse return null;
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
        .exit => return null,
    };
    const expected_type = runtime_annotation orelse return value_id;
    var value = (try ctx.lookupInterned(CompileTimeValues, value_id)).*;
    if (value == .type) {
        try typing.emitSemanticIssue(ctx, resolved.file_id, .{
            .span = nodeSpan(&parsed, initializer),
            .kind = .type_value_used_as_runtime_value,
        });
        return null;
    }
    const typed_runtime = value.runtime;
    if (!try semantic.canWidenTo(analysis_context, typed_runtime.type_id, expected_type)) {
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
        if (try typePayload(ctx, expected_type, .variant)) |variant| {
            const members = variant.members;
            const active_type = if (typed_runtime.value == .variant) typed_runtime.value.variant.member_type else typed_runtime.type_id;
            const payload = if (typed_runtime.value == .variant) typed_runtime.value.variant.payload else value_id;
            const tag = (try semantic.widenedVariantTag(analysis_context, active_type, members)) orelse unreachable;
            value.runtime.value = .{ .variant = .{ .member_type = members[tag], .payload = payload } };
        } else {
            std.debug.assert(try typePayload(ctx, expected_type, .callable) != null);
            var reference = value.runtime.value.function_ref;
            reference.type_id = expected_type;
            value.runtime.value = .{ .function_ref = reference };
        }
    }
    value.runtime.type_id = expected_type;
    return try ctx.intern(CompileTimeValues, value);
}

pub const AnalyzeComptimeThunk = CompilerQuery("AnalyzeComptimeThunk", .body_overhead, analyzeComptimeThunk, .{});

fn analyzeComptimeThunk(ctx: anytype, site: structures.CompileTimeSite) anyerror!?structures.FunctionBodyAnalysis {
    const loc = try ctx.lookupInterned(ItemLocations, site.owner.item);
    if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry and loc.kind != .overload) return null;
    // Static arguments inside an initializer are independent demanded
    // thunks, so a static-owned site is not limited to the initializer root.
    const declaration = (try siteDeclaration(ctx, site)) orelse return null;
    const file_id = declaration.resolved.file_id;
    const root: semantic.BodySource = if (site.condition) .{ .where_condition = site.node } else .{ .comptime_expression = site.node };
    var unresolved = (try availableSemanticValue(ctx, file_id, site.owner, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).buildUnresolvedBody(root))) orelse return null;
    defer unresolved.deinit(ctx.allocator());
    return typing.resolveAndTypeBody(
        ctx,
        site.owner,
        file_id,
        &.{},
        if (site.condition) .bool else .unit,
        .{ .infer_return_type = true, .publish_instruction_spans = true, .allow_type_values = true, .expected_result_type = site.expected_type },
        declaration.analysis,
        unresolved,
    );
}

/// Traverse once and snapshot each item before its carrier is cleaned or the
/// producer is polled again. Only canonical items cross the query boundary.
pub const ExecuteStaticIteration = CompilerQuery("ExecuteStaticIteration", .comptime_execution, executeStaticIteration, .{});

fn executeStaticIteration(ctx: anytype, site: structures.CompileTimeSite) anyerror!?structures.CompileTimeValueTupleId {
    const declaration = (try siteDeclaration(ctx, site)) orelse return null;
    if (declaration.parsed.nodes[site.node.index()].tag != .collection_for) return null;
    const file_id = declaration.resolved.file_id;
    var unresolved = (try availableSemanticValue(ctx, file_id, site.owner, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).buildUnresolvedBody(.{ .static_iteration = site.node }))) orelse return null;
    defer unresolved.deinit(ctx.allocator());
    var body = (try typing.resolveAndTypeBody(ctx, site.owner, file_id, &.{}, .unit, .{ .allow_type_values = true, .publish_instruction_spans = true }, declaration.analysis, unresolved)) orelse return null;
    defer body.deinit(ctx.allocator());
    var values: std.ArrayList(structures.CompileTimeValueId) = .empty;
    defer values.deinit(ctx.allocator());
    const result = try executeThunk(ctx, site.owner, &body, &values);
    if (result == .returned) return try ctx.intern(CompileTimeValueTuples, .{ .values = values.items });
    _ = try reportThunkResult(ctx, site, result); // Iteration has no outcome without its items.
    return null;
}

pub const ExecuteComptimeThunk = CompilerQuery("ExecuteComptimeThunk", .comptime_execution, executeComptimeThunk, .{});

fn executeComptimeThunk(ctx: anytype, site: structures.CompileTimeSite) anyerror!?structures.CompileTimeOutcome {
    if (!site.condition and (site.expected_type == null or site.expected_type == .type)) {
        const declaration = (try siteDeclaration(ctx, site)) orelse return null;
        const prepared = (try availableSemanticValue(ctx, declaration.resolved.file_id, site.owner, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).analyzeStaticTypeCall(site.node))) orelse return null;
        if (prepared) |instance| {
            const result = (try ctx.get(ExecuteComptimeCall, .{ .instance = instance, .arguments = try ctx.intern(CompileTimeValueTuples, .{ .values = &.{} }) })).* orelse return null;
            switch (result) {
                .execution_error => return null,
                .completed => |completed| return reportComptimeOutcome(ctx, site, completed.outcome),
            }
        }
    }
    const body = (try ctx.get(AnalyzeComptimeThunk, site)).* orelse return null;
    const result = try executeThunk(ctx, site.owner, &body, null);
    if (result == .returned) return .{ .returned = try internInterpretedValue(ctx, body.return_type, result.returned) };
    return reportThunkResult(ctx, site, result);
}

/// Executes a typed thunk without arguments on a fresh compile-time heap.
fn executeThunk(ctx: anytype, owner: structures.InstanceId, body: *const structures.FunctionBodyAnalysis, static_items: ?*std.ArrayList(structures.CompileTimeValueId)) !comptime_interpreter.Result {
    var heap: comptime_interpreter.Heap = .init(ctx.allocator());
    defer heap.deinit();
    var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = owner, .heap = &heap, .static_items = static_items };
    var arguments: [0]comptime_interpreter.Value = .{};
    return comptime_interpreter.execute(body, &arguments, &executor, ctx.allocator());
}

/// Reports a thunk result that produced no value at the thunk's site.
fn reportThunkResult(ctx: anytype, site: structures.CompileTimeSite, result: comptime_interpreter.Result) !ExecuteComptimeThunk.Output {
    switch (result) {
        .returned => unreachable,
        .exit => |status| return reportComptimeOutcome(ctx, site, .{ .exit = status }),
        .execution_error => |execution_error| try emitComptimeExecutionIssue(ctx, site.owner, site.node, execution_error),
        .reported_error, .unavailable => {},
    }
    return null;
}

fn reportComptimeOutcome(ctx: anytype, _: structures.CompileTimeSite, outcome: structures.CompileTimeOutcome) !ExecuteComptimeThunk.Output {
    switch (outcome) {
        .returned => {},
        .exit => |status| try ctx.emit(structures.CompilerControl, .{ .exit = status }),
    }
    return outcome;
}

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

pub const ExecuteComptimeCall = CompilerQuery("ExecuteComptimeCall", .comptime_execution, executeComptimeCall, .{});

fn executeComptimeCall(ctx: anytype, key: structures.CompileTimeCallKey) anyerror!?structures.CompileTimeCallOutcome {
    const signature = (try lookupFunctionSignature(ctx, key.instance)) orelse return null;
    const argument_tuple = try ctx.lookupInterned(CompileTimeValueTuples, key.arguments);
    if (argument_tuple.values.len != signature.parameters.len) return null;

    var heap: comptime_interpreter.Heap = .init(ctx.allocator());
    defer heap.deinit();
    var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = key.instance, .heap = &heap };
    const arguments = try ctx.allocator().alloc(comptime_interpreter.Value, argument_tuple.values.len);
    defer ctx.allocator().free(arguments);
    for (argument_tuple.values, signature.parameters, arguments) |value_id, parameter, *argument| {
        const runtime = (try executor.lookupRuntime(value_id)) orelse return null;
        if (runtime.type_id != parameter.type_id) return null;
        argument.* = .{ .runtime = runtime.value };
    }
    var storage_arena: std.heap.ArenaAllocator = .init(ctx.allocator());
    defer storage_arena.deinit();
    const execution = if ((try ctx.get(ExternalSymbol, key.instance.item)).* != null)
        try executor.callTransient(key.instance, arguments, null, storage_arena.allocator())
    else blk: {
        const body = (try ctx.get(AnalyzeComptimeFunctionBody, key.instance)).* orelse return null;
        break :blk try comptime_interpreter.executeInStorage(&body, arguments, &executor, ctx.allocator(), storage_arena.allocator());
    };
    const modes = try ctx.allocator().alloc(structures.ParameterMode, signature.parameters.len);
    defer ctx.allocator().free(modes);
    for (signature.parameters, modes) |parameter, *mode| mode.* = parameter.mode;
    const result = try comptime_interpreter.publish(execution, arguments, modes, &executor, ctx.allocator());
    const outcome: structures.CompileTimeOutcome = switch (result) {
        .returned => |value| structures.CompileTimeOutcome{ .returned = try internInterpretedValue(ctx, signature.return_type, value) },
        .exit => |status| structures.CompileTimeOutcome{ .exit = status },
        .execution_error => |execution_error| {
            try emitComptimeExecutionIssue(ctx, key.instance, null, execution_error);
            return .execution_error;
        },
        .reported_error => return .execution_error,
        .unavailable => null,
    } orelse return null;

    if (!writesArguments(signature.parameters) or outcome == .exit) return .{ .completed = .{ .outcome = outcome, .arguments = key.arguments } };
    const final_argument_ids = try ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
    defer ctx.allocator().free(final_argument_ids);
    for (arguments, signature.parameters, final_argument_ids) |argument, parameter, *value_id|
        value_id.* = try executor.internRuntime(parameter.type_id, argument.runtime);
    return .{ .completed = .{
        .outcome = outcome,
        .arguments = try ctx.intern(CompileTimeValueTuples, .{ .values = final_argument_ids }),
    } };
}

/// Mutable and reference parameters publish updated arguments after a call.
fn writesArguments(parameters: []const structures.CallableParameter) bool {
    for (parameters) |parameter| if (parameter.mode == .mut or parameter.mode == .ref) return true;
    return false;
}

fn ComptimeCallExecutor(comptime Context: type) type {
    return struct {
        const Frame = struct { instance: structures.InstanceId, arguments: comptime_interpreter.ValueSnapshot };
        ctx: Context,
        owner: structures.InstanceId,
        heap: *comptime_interpreter.Heap,
        transient_frames: std.ArrayList(Frame) = .empty,
        static_items: ?*std.ArrayList(structures.CompileTimeValueId) = null,

        pub fn callInStorage(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const external = (try self.ctx.get(ExternalSymbol, instance.item)).*;
            if (external == .primitive_operation or external == .panic_message or external == .static_iteration_item)
                return self.callTransient(instance, arguments, call_span, storage);
            for (arguments) |argument| switch (argument) {
                .place, .initializer => return self.callTransient(instance, arguments, call_span, storage),
                .runtime, .type => {},
            };
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return .unavailable;
            if (signature.result_mode == .reference or try self.facts().mayContainStorage(signature.return_type)) return self.callTransient(instance, arguments, call_span, storage);
            for (signature.parameters) |parameter| {
                if ((parameter.mode == .mut or parameter.mode == .ref) and try self.facts().mayContainStorage(parameter.type_id)) return self.callTransient(instance, arguments, call_span, storage);
            }
            return self.call(instance, arguments, call_span);
        }

        pub fn call(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan) anyerror!comptime_interpreter.Result {
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            const value_ids = try self.ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
            defer self.ctx.allocator().free(value_ids);
            for (arguments, signature.parameters, value_ids) |argument, parameter, *value_id| {
                std.debug.assert(argument == .runtime);
                value_id.* = try self.internRuntime(parameter.type_id, argument.runtime);
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
            if (writesArguments(signature.parameters) and call_outcome.outcome != .exit) {
                const final_arguments = try self.lookupTuple(call_outcome.arguments);
                std.debug.assert(final_arguments.len == arguments.len);
                for (final_arguments, signature.parameters, arguments) |value_id, parameter, *argument| {
                    const runtime = (try self.lookupRuntime(value_id)).?;
                    std.debug.assert(runtime.type_id == parameter.type_id);
                    argument.* = .{ .runtime = runtime.value };
                }
            }
            return switch (call_outcome.outcome) {
                .returned => |returned| switch ((try self.ctx.lookupInterned(CompileTimeValues, returned)).*) {
                    .runtime => |runtime| .{ .returned = .{ .runtime = runtime.value } },
                    .type => |type_id| .{ .returned = .{ .type = type_id } },
                },
                .exit => |status| .{ .exit = status },
            };
        }

        pub fn convertStaticValue(self: *@This(), source_type: structures.TypeId, source: structures.CompileTimeValue.RuntimeValue, target_type: structures.TypeId, span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const resolved = (try self.ctx.get(ResolveItem, self.owner.item)).* orelse return .unavailable;
            const analysis: AnalysisContext(Context) = .{ .ctx = self.ctx, .file_id = resolved.file_id, .instance = self.owner };
            if (source_type == .int_literal) {
                const members = try analysis.facts().variantMembers(target_type);
                if (target_type == .int or (members != null and std.mem.indexOfScalar(structures.TypeId, members.?, .int) != null)) {
                    const integer = std.math.cast(i32, source.int_literal) orelse {
                        try self.ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = span, .instance = self.owner, .kind = .integer_literal_out_of_range });
                        return .reported_error;
                    };
                    const value: comptime_interpreter.Value = .{ .runtime = .{ .int = integer } };
                    if (target_type == .int) return .{ .returned = value };
                    return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, .int, value, self) };
                }
            }
            const candidates = if (source_type == .string_literal and !try analysis.hasConverters(source_type, target_type))
                &.{}
            else
                try analysis.conversionCandidates(source_type, target_type, try self.internRuntime(source_type, source));
            const builtin = try semantic.canWidenTo(analysis, source_type, target_type);
            const count = candidates.len + @intFromBool(builtin);
            if (count == 0 and source_type == .string_literal) return self.convertStaticString(analysis, source.string_literal, target_type, span, storage);
            if (count != 1) return self.rejectConversion(resolved.file_id, span, .{ .expected = target_type, .found = source_type }, count);
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

        fn convertStaticString(self: *@This(), analysis: AnalysisContext(Context), data: structures.ByteStringId, target_type: structures.TypeId, span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const static_string = try analysis.staticStringType();
            var arguments = [_]comptime_interpreter.Value{.{ .runtime = try self.staticString(.{ .type_id = static_string, .data = data }) }};
            if (static_string == target_type) return .{ .returned = arguments[0] };
            if (try semantic.canWidenTo(analysis, static_string, target_type)) return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, static_string, arguments[0], self) };
            const candidates = try analysis.conversionCandidates(static_string, target_type, null);
            if (candidates.len != 1 or candidates[0].source_mode != .imm)
                return self.rejectConversion(analysis.file_id.?, span, .{ .expected = target_type, .found = .string_literal }, candidates.len);
            const result = try self.callInStorage(candidates[0].instance, &arguments, span, storage);
            if (result != .returned or candidates[0].target_type == target_type) return result;
            return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, candidates[0].target_type, result.returned, self) };
        }

        /// Without exactly one usable candidate, a static conversion is missing or ambiguous.
        fn rejectConversion(self: *@This(), file_id: structures.FileId, span: ?structures.SourceSpan, mismatch: structures.Diagnostic.TypeMismatch, candidates: usize) !comptime_interpreter.Result {
            try self.ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = span, .instance = self.owner, .kind = if (candidates == 0) .{ .local_type_mismatch = mismatch } else .{ .ambiguous_conversion = mismatch } });
            return .reported_error;
        }

        fn captureStaticItem(self: *@This(), type_id: structures.TypeId, value: comptime_interpreter.Value, span: ?structures.SourceSpan) !comptime_interpreter.Result {
            const items = self.static_items orelse return .{ .execution_error = .{ .reason = .unsupported_operation, .span = span } };
            const result = try comptime_interpreter.publish(.{ .returned = value }, &.{}, &.{}, self, self.ctx.allocator());
            if (result != .returned) return result;
            try items.append(self.ctx.allocator(), try internInterpretedValue(self.ctx, type_id, result.returned));
            return .{ .returned = .{ .runtime = .unit } };
        }

        fn callTransient(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            const external = (try self.ctx.get(ExternalSymbol, instance.item)).*;
            if (external) |symbol| {
                switch (symbol) {
                    .static_iteration_item => return self.captureStaticItem(signature.parameters[0].type_id, arguments[0], call_span),
                    .primitive_operation, .copy_value, .move_value, .array_filled, .array_borrow, .unsafe_borrow, .unsafe_take, .unsafe_destroy, .unsafe_initialize, .literal_byte, .byte_int, .initialize_collection, .initialize_collection_element, .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => {},
                    .allocate, .allocate_host_storage => return self.allocateStorage(symbol, signature.return_type, arguments, storage),
                    .deallocate, .deallocate_host_storage => {
                        comptime_interpreter.releaseAllocation(arguments[0]);
                        return .{ .returned = .{ .runtime = .unit } };
                    },
                    .allocation_count => return .{ .returned = .{ .runtime = .{ .int = comptime_interpreter.allocationCount(arguments[0]) } } },
                    .exit => return .{ .exit = comptime_interpreter.integerValue(arguments[0]) },
                    .panic_message => return .{ .execution_error = .{
                        .reason = .{ .panic = try comptime_interpreter.panicMessage(arguments[0], self, self.ctx.allocator()) },
                        .span = call_span,
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
            self.owner = instance;
            defer self.owner = previous_owner;
            var result = try comptime_interpreter.executeInStorage(&body, arguments, self, self.ctx.allocator(), storage);
            if (external != null) {
                if (result == .execution_error) result.execution_error.span = call_span;
                return result;
            }
            if (result == .execution_error) try emitComptimeExecutionIssue(self.ctx, instance, null, result.execution_error);
            if (result == .execution_error or result == .reported_error) {
                try emitComptimeCallTrace(self.ctx, previous_owner, call_span);
                return .reported_error;
            }
            return result;
        }

        fn allocateStorage(self: *@This(), symbol: standard_library.External, return_type: structures.TypeId, arguments: []comptime_interpreter.Value, storage: std.mem.Allocator) !comptime_interpreter.Result {
            const payload = (try intrinsics.optionalPayload(self.facts(), return_type)) orelse unreachable;
            const element_type = if (symbol == .allocate) (try self.facts().allocationElement(payload)) orelse unreachable else structures.TypeId.byte;
            const layout = (try self.ctx.get(HostTypeLayout, element_type)).*;
            const count = comptime_interpreter.integerValue(arguments[0]);
            const value = try self.heap.allocateValue(payload, element_type, layout.byte_size, count, storage);
            return .{ .returned = try comptime_interpreter.storedVariantValue(return_type, if (value != null) payload else .none, value orelse .{ .runtime = .none }, self) };
        }

        pub fn byteString(self: *@This(), id: structures.ByteStringId) ![]const u8 {
            return (try self.ctx.lookupInterned(ByteStrings, id)).bytes;
        }

        pub fn internBytes(self: *@This(), bytes: []const u8) !structures.ByteStringId {
            return self.ctx.intern(ByteStrings, .{ .bytes = bytes });
        }

        pub fn internRuntime(self: *@This(), type_id: structures.TypeId, value: structures.CompileTimeValue.RuntimeValue) !structures.CompileTimeValueId {
            return self.ctx.intern(CompileTimeValues, .{ .runtime = .{ .type_id = type_id, .value = value } });
        }

        pub fn staticString(self: *@This(), constant: structures.StaticStringConstant) !structures.CompileTimeValue.RuntimeValue {
            const span_type = (try self.facts().staticStringBytes(constant.type_id)) orelse return error.Unavailable;
            const span = (try self.facts().structDefinition(span_type)) orelse return error.Unavailable;
            const cursor_type = span.fields[0].type_id;
            const size = std.math.cast(i32, (try self.ctx.lookupInterned(ByteStrings, constant.data)).bytes.len) orelse return error.TypeTooLarge;
            const fields = [_]structures.CompileTimeValueId{
                try self.internRuntime(cursor_type, .{ .storage_cursor = .{ .type_id = cursor_type, .data = constant.data } }),
                try self.internRuntime(.int, .{ .int = size }),
            };
            const bytes = try self.internRuntime(span_type, .{ .structure = try self.internTuple(&fields) });
            return .{ .structure = try self.internTuple(&.{bytes}) };
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

        fn facts(self: *@This()) TypeFacts(Context) {
            return .{ .ctx = self.ctx };
        }

        pub fn variantMembers(self: *@This(), type_id: structures.TypeId) !?[]const structures.TypeId {
            return self.facts().variantMembers(type_id);
        }

        pub fn arrayType(self: *@This(), type_id: structures.TypeId) !?structures.ArrayType {
            return self.facts().arrayType(type_id);
        }

        pub fn argumentPassing(self: *@This(), type_id: structures.TypeId) !structures.ArgumentPassing {
            return self.facts().argumentPassing(type_id);
        }

        pub fn structFieldCount(self: *@This(), type_id: structures.TypeId) !?usize {
            const definition = (try self.facts().structDefinition(type_id)) orelse return null;
            return definition.fields.len;
        }

        pub fn structFieldType(self: *@This(), type_id: structures.TypeId, index: usize) !?structures.TypeId {
            const definition = (try self.facts().structDefinition(type_id)) orelse return null;
            std.debug.assert(index < definition.fields.len);
            return try self.facts().fieldStorageType(definition.fields[index]);
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
    owner: structures.InstanceId,
    fallback_node: ?structures.Node.Index,
    execution_error: comptime_interpreter.ExecutionError,
) !void {
    const resolved = (try ctx.get(ResolveItem, owner.item)).* orelse return;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return;
    const fallback_span = nodeSpan(&parsed, fallback_node orelse @fromBackingInt(@intCast(resolved.declaration)));
    const span = execution_error.span orelse fallback_span;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = resolved.file_id,
        .instance = owner,
        .span = span,
        .kind = switch (execution_error.reason) {
            .panic => |message| .{ .compile_time_panic = message },
            .call_cycle => .compile_time_call_cycle,
            .division_by_zero => .compile_time_division_by_zero,
            .unsupported_operation => .compile_time_unsupported_operation,
            .escaping_storage => .compile_time_escaping_storage,
        },
    });
}

fn emitComptimeCallTrace(ctx: anytype, owner: structures.InstanceId, span: ?structures.SourceSpan) !void {
    const call_span = span orelse return;
    const resolved = (try ctx.get(ResolveItem, owner.item)).* orelse return;
    try ctx.emit(structures.Diagnostic, .{
        .file_id = resolved.file_id,
        .instance = owner,
        .span = call_span,
        .kind = .compile_time_call_trace,
    });
}

pub const TypeNamespace = CompilerQuery("TypeNamespace", .type_facts, typeNamespace, .{});

fn typeNamespace(ctx: anytype, identity: NamespaceIdentity) anyerror!?structures.ModuleScope {
    const owner = identity.owner();
    const owner_loc = try ctx.lookupInterned(ItemLocations, owner);
    const site: ?i64 = if (identity == .generated) identity.generated.node_offset else null;
    const member_site = if (owner_loc.kind == .structure) null else site;
    var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.name.deinit(ctx.allocator());
        entries.deinit(ctx.allocator());
    }
    var names = structures.Name.Set.init(ctx.allocator());
    defer names.deinit();
    if (identity != .primitive and !try reserveStructNamespaceFields(ctx, identity, &names)) return null;
    const module = try itemModule(ctx, owner_loc.*);
    if ((try ctx.get(IndexModuleItems, module)).* == null) return null;
    const files = (try ctx.input(ModuleMembers, module)).*;
    for (files) |file_id| {
        const index = (try ctx.get(IndexItems, file_id)).* orelse return null;
        const discovered = (try ctx.get(DiscoverItems, file_id)).* orelse return null;
        std.debug.assert(discovered.items.len == index.count());
        for (discovered.items, index.ids()) |item, item_id| {
            const loc = try ctx.lookupInterned(ItemLocations, item_id);
            if (loc.owner != owner or loc.source_site != member_site or loc.is_hook) continue;
            const reserved = std.meta.stringToEnum(structures.OwnershipMember, loc.name.text()) != null;
            var duplicate = (try names.getOrPut(loc.name)).found_existing;
            if (loc.kind == .overload and loc.name == .operation and loc.name.operation == .@"-") {
                // An explicit minus set reserves both declaration forms.
                duplicate = (try names.getOrPut(.{ .operation = .unary_minus })).found_existing or duplicate;
            }
            if (reserved or duplicate) {
                const member_parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
                try rejectDeclaration(ctx, file_id, &member_parsed, index.resolve(item_id).?, if (reserved) .reserved_ownership_member else .duplicate_struct_member);
                return null;
            }
            try appendScopeEntry(ctx, &entries, .{ .name = loc.name, .item_id = item_id, .kind = loc.kind, .is_public = item.is_public });
        }
    }
    return try finishScope(ctx, &entries);
}

fn reserveStructNamespaceFields(ctx: anytype, identity: NamespaceIdentity, names: *structures.Name.Set) !bool {
    const item_source = (try itemSource(ctx, identity.owner())) orelse return false;
    const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
    const struct_index: structures.Node.Index = if (identity == .generated) generated: {
        const position = std.math.cast(u32, @as(i64, item_source.resolved.declaration) + identity.generated.node_offset) orelse return false;
        if (position >= item_source.parsed.nodes.len or item_source.parsed.nodes[position].tag != .@"struct") return false;
        break :generated @fromBackingInt(@intCast(position));
    } else item_source.parsed.nodes[item_source.resolved.declaration].data.node_node.b;
    if (try semantic.validateStructNamespace(&item_source.parsed, source, struct_index, ctx.allocator())) |issue| {
        try typing.emitSemanticIssue(ctx, item_source.resolved.file_id, issue);
        return false;
    }
    const struct_node = item_source.parsed.nodes[struct_index.index()];
    for (item_source.parsed.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
        const item = item_source.parsed.nodes[member_index.index()];
        const member = if (item.tag == .@"pub") item_source.parsed.nodes[item.data.node.index()] else item;
        if (member.tag != .struct_field) continue;
        const token = item_source.parsed.tokens[member.token_index];
        try names.put(.{ .identifier = source[token.loc.start..token.loc.end] }, {});
    }
    return true;
}

pub const StructDefinition = CompilerQuery("StructDefinition", .type_facts, structDefinition, .{});

fn structDefinition(ctx: anytype, item_id: structures.ItemId) anyerror!?structures.StructDefinition {
    const loc = try ctx.lookupInterned(ItemLocations, item_id);
    if (loc.kind != .structure) return null;
    // Validate the complete member scope, including qualified declarations.
    _ = (try ctx.get(TypeNamespace, .{ .declared = item_id })).* orelse return null;
    const declaration = (try declarationSource(ctx, .{ .item = item_id })) orelse return null;
    const file_id = declaration.resolved.file_id;
    return availableSemanticValue(ctx, file_id, null, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).run("analyzeStructDefinition", .{ item_id, declaration.resolved.declaration }));
}

pub const GeneratedStructDefinition = CompilerQuery("GeneratedStructDefinition", .query_other, generatedStructDefinition, .{});

fn generatedStructDefinition(ctx: anytype, identity: structures.GeneratedStructIdentity) anyerror!?structures.StructDefinition {
    const loc = try ctx.lookupInterned(ItemLocations, identity.owner.item);
    if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry) return null;
    const declaration = (try declarationSource(ctx, identity.owner)) orelse return null;
    const node_position = @as(i64, declaration.resolved.declaration) + @as(i64, identity.node_offset);
    const node_index = std.math.cast(u32, node_position) orelse return null;
    if (node_index >= declaration.parsed.nodes.len or declaration.parsed.nodes[node_index].tag != .@"struct") return null;
    const struct_node: structures.Node.Index = @fromBackingInt(@intCast(node_index));
    const file_id = declaration.resolved.file_id;
    return availableSemanticValue(ctx, file_id, identity.owner, semantic.analyzer(&declaration.parsed, declaration.source, declaration.analysis, ctx.allocator()).run("analyzeGeneratedStructDefinition", .{ struct_node, identity }));
}

fn getStructDefinition(ctx: anytype, identity: structures.StructIdentity) !?*const structures.StructDefinition {
    const result = switch (identity) {
        .declared => |item_id| try ctx.get(StructDefinition, item_id),
        .generated => |generated| try ctx.get(GeneratedStructDefinition, generated),
    };
    return if (result.*) |*definition| definition else null;
}

/// Recursive reference summaries reach a fixed point within their call component.
/// Acyclic callees use independently cached contracts instead of joining each round.
const ReferenceInference = struct {
    const Entry = struct { instance: structures.InstanceId, contract: ?structures.ReferenceContract = .{} };
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    component: ?[]const structures.InstanceId = null,
    recursive: bool = false,

    fn request(self: *ReferenceInference, ctx: anytype, instance: structures.InstanceId) !?structures.ReferenceContract {
        if (self.component) |component| {
            if (!containsInstance(component, instance)) return (try ctx.get(InferReferenceContract, instance)).*;
        }
        for (self.entries.items) |entry| if (std.meta.eql(entry.instance, instance)) return entry.contract;
        try self.entries.append(self.allocator, .{ .instance = instance });
        return .{};
    }

    fn deinit(self: *ReferenceInference, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| if (entry.contract) |*contract| contract.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

fn containsInstance(instances: []const structures.InstanceId, instance: structures.InstanceId) bool {
    for (instances) |member| if (std.meta.eql(member, instance)) return true;
    return false;
}

fn hasReferenceContractBody(ctx: anytype, instance: structures.InstanceId) !bool {
    if ((try ctx.get(ExternalSymbol, instance.item)).*) |symbol| return intrinsics.hasTypedBody(symbol);
    return true;
}

pub const ReferenceCallees = struct {
    pub const profile_category: profiling.Category = .query_other;
    pub const Input = structures.InstanceId;
    pub const Output = ?struct {
        instances: []const structures.InstanceId,
        initial_contract: structures.ReferenceContract = .{},

        pub const eql = value_operations.Owned(@This()).eql;
        pub const deinit = value_operations.Owned(@This()).deinit;
    };

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        if (!try hasReferenceContractBody(ctx, instance)) return .{ .instances = &.{} };
        var inference: ReferenceInference = .{ .allocator = ctx.allocator() };
        defer inference.deinit(ctx.allocator());
        var contract = (try analyzeFunctionBody(ctx, true, instance, false, &inference)) orelse return null;
        errdefer contract.deinit(ctx.allocator());
        const callees = try ctx.allocator().alloc(structures.InstanceId, inference.entries.items.len);
        for (callees, inference.entries.items) |*callee, entry| callee.* = entry.instance;
        return .{ .instances = callees, .initial_contract = contract };
    }
};

fn referenceComponent(ctx: anytype, instance: structures.InstanceId) !?[]const structures.InstanceId {
    const allocator = ctx.allocator();
    var graph: std.AutoArrayHashMapUnmanaged(structures.InstanceId, std.ArrayList(usize)) = .empty;
    defer {
        for (graph.values()) |*callers| callers.deinit(allocator);
        graph.deinit(allocator);
    }
    try graph.put(allocator, instance, .empty);
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        const callees = (try ctx.get(ReferenceCallees, graph.keys()[next])).* orelse return null;
        for (callees.instances) |callee| {
            const entry = try graph.getOrPut(allocator, callee);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, next);
        }
    }
    const visited = try allocator.alloc(bool, graph.count());
    defer allocator.free(visited);
    @memset(visited, false);
    visited[0] = true;
    var members: std.ArrayList(usize) = .empty;
    defer members.deinit(allocator);
    try members.append(allocator, 0);
    next = 0;
    while (next < members.items.len) : (next += 1) {
        for (graph.values()[members.items[next]].items) |caller| {
            if (visited[caller]) continue;
            visited[caller] = true;
            try members.append(allocator, caller);
        }
    }
    const component = try allocator.alloc(structures.InstanceId, members.items.len);
    for (component, members.items) |*member, index| member.* = graph.keys()[index];
    return component;
}

pub const InferReferenceContract = CompilerQuery("InferReferenceContract", .type_facts, inferReferenceContract, .{ .disk_boundary = true });

fn inferReferenceContract(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.ReferenceContract {
    if (!try hasReferenceContractBody(ctx, instance)) return .{};
    const analyzed = ctx.get(AnalyzeFunctionInstance, instance) catch |err| switch (err) {
        error.QueryCycle => null,
        else => return err,
    };
    if (analyzed) |cached| {
        const body = cached.* orelse return null;
        return body.reference_contract;
    }
    const component = (try referenceComponent(ctx, instance)) orelse return null;
    defer ctx.allocator().free(component);
    var inference: ReferenceInference = .{ .allocator = ctx.allocator(), .component = component };
    defer inference.deinit(ctx.allocator());
    _ = try inference.request(ctx, instance);
    const seed = (try ctx.get(ReferenceCallees, instance)).* orelse return null;
    if (component.len == 1 and !containsInstance(seed.instances, instance)) {
        var unchanged = true;
        for (seed.instances) |callee| {
            const contract = (try ctx.get(InferReferenceContract, callee)).* orelse return null;
            if (!structures.ReferenceContract.equivalent(contract, .{})) unchanged = false;
        }
        if (unchanged) return seed.initial_contract;
        return analyzeFunctionBody(ctx, true, instance, false, &inference);
    }
    inference.recursive = true;
    while (true) {
        var changed = false;
        const count = inference.entries.items.len;
        for (0..count) |index| {
            const target = inference.entries.items[index].instance;
            if (!try hasReferenceContractBody(ctx, target)) continue;
            var contract = (try analyzeFunctionBody(ctx, true, target, false, &inference)) orelse {
                if (inference.entries.items[index].contract) |*contract| {
                    contract.deinit(ctx.allocator());
                    inference.entries.items[index].contract = null;
                    changed = true;
                }
                continue;
            };
            defer contract.deinit(ctx.allocator());
            const previous = inference.entries.items[index].contract;
            if (previous != null and structures.ReferenceContract.equivalent(previous.?, contract)) continue;
            if (inference.entries.items[index].contract) |*previous_contract| previous_contract.deinit(ctx.allocator());
            inference.entries.items[index].contract = contract;
            contract = .{};
            changed = true;
        }
        if (!changed and count == inference.entries.items.len) break;
    }
    const result = inference.entries.items[0].contract;
    inference.entries.items[0].contract = null;
    return result;
}

pub const AnalyzeFunctionInstance = CompilerQuery("AnalyzeFunctionInstance", .body_overhead, analyzeFunctionInstance, .{ .disk_boundary = true });

fn analyzeFunctionInstance(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionBodyAnalysis {
    return analyzeFunctionBody(ctx, false, instance, false, null);
}

pub const AnalyzeComptimeFunctionBody = CompilerQuery("AnalyzeComptimeFunctionBody", .body_overhead, analyzeComptimeFunctionBody, .{});

fn analyzeComptimeFunctionBody(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionBodyAnalysis {
    return analyzeFunctionBody(ctx, false, instance, true, null);
}

fn analyzeFunctionBody(ctx: anytype, comptime contract_only: bool, instance: structures.InstanceId, allow_type_values: bool, reference_inference: ?*ReferenceInference) !?if (contract_only) structures.ReferenceContract else structures.FunctionBodyAnalysis {
    const loc = try ctx.lookupInterned(ItemLocations, instance.item);
    if (loc.kind == .static or loc.kind == .structure) return null;
    if (loc.kind != .function) std.debug.assert(instance.specialization == null);
    const signature: structures.FunctionSignature = if (loc.kind == .function)
        (try lookupFunctionSignature(ctx, instance)) orelse return null
    else
        .{ .parameters = &.{}, .return_type = .unit };
    if (!allow_type_values and signature.return_type == .type) return null;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    if ((try ctx.get(BuildModuleScope, resolved.file_id)).* == null) return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    const symbol = (try ctx.get(ExternalSymbol, instance.item)).*;
    const builtin_body: ?typing.BuiltinBody = if (symbol != null and intrinsics.hasTypedBody(symbol.?)) .{
        .symbol = symbol.?,
        .operation = if (symbol == .primitive_operation) loc.name.operation else null,
    } else null;
    if (loc.kind == .function and semantic.isExternalFunction(&parsed, resolved.declaration) and builtin_body == null) return null;
    const source = (try ctx.input(SourceText, resolved.file_id)).*;
    const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{
        .ctx = ctx,
        .file_id = resolved.file_id,
        .instance = instance,
        .reference_inference = reference_inference,
    };
    var unresolved = (try availableSemanticValue(ctx, resolved.file_id, instance, semantic.analyzer(&parsed, source, analysis_context, ctx.allocator()).buildUnresolvedBody(switch (loc.kind) {
        .function => .{ .function = .{ .declaration = resolved.declaration, .parameters = signature.parameters } },
        .top_level_entry => .{ .entry = resolved.declaration },
        .static, .structure, .primitive, .overload => unreachable,
    }))) orelse return null;
    defer unresolved.deinit(ctx.allocator());

    return typing.resolveBody(
        contract_only,
        ctx,
        instance,
        resolved.file_id,
        signature.parameters,
        signature.return_type,
        .{ .publish_instruction_spans = true, .is_entry = loc.kind == .top_level_entry, .allow_type_values = allow_type_values, .builtin_body = builtin_body, .result_mode = signature.result_mode, .infer_reference_contract = reference_inference != null, .widen_reference_indices = if (reference_inference) |inference| inference.recursive else false },
        analysis_context,
        unresolved,
    );
}

pub const SelectEntry = CompilerQuery("SelectEntry", .declarations, selectEntry, .{});

fn selectEntry(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ItemId {
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

pub const OptimizeFunctionInstance = CompilerQuery("OptimizeFunctionInstance", .optimization, optimizeFunctionInstance, .{});

pub const PrepareFunctionInstance = CompilerQuery("PrepareFunctionInstance", .optimization, prepareFunctionInstance, .{});

pub const InlineFunctionFacts = CompilerQuery("InlineFunctionFacts", .optimization_inline, inlineFunctionFacts, .{ .content_equality = true });

fn inlineFunctionFacts(ctx: anytype, instance: structures.InstanceId) anyerror!?@import("optimizer/inline.zig").Facts {
    const body = (try ctx.get(OptimizeFunctionInstance, instance)).* orelse return null;
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator());
    defer arena.deinit();
    const facts = try @import("optimizer/inline.zig").analyzeCallee(arena.allocator(), &body);
    return try value_operations.Owned(@TypeOf(facts)).clone(ctx.allocator(), facts);
}

fn prepareFunctionInstance(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionBodyAnalysis {
    const body = (try ctx.get(AnalyzeFunctionInstance, instance)).* orelse return null;
    return try optimizer.prepare(ctx.allocator(), &body, TypeLayoutContext(@TypeOf(ctx)){ .ctx = ctx });
}

fn optimizeFunctionInstance(ctx: anytype, instance: structures.InstanceId) anyerror!?structures.FunctionBodyAnalysis {
    const body = (try ctx.get(PrepareFunctionInstance, instance)).* orelse return null;
    const component = (try ctx.get(CallComponent, instance)).* orelse return null;
    const context: OptimizationContext(@TypeOf(ctx)) = .{ .ctx = ctx, .instance = instance, .component = component.members };
    if (ctx.hasParallelWorkers()) try prefetchOptimizationCallees(ctx, &body);
    return try optimizer.optimize(ctx.allocator(), &body, context);
}

fn prefetchOptimizationCallees(ctx: anytype, body: *const structures.FunctionBodyAnalysis) anyerror!void {
    for (body.instructions) |instruction| {
        if (instruction == .call and instruction.call.target == .direct)
            try ctx.prefetch(OptimizeFunctionInstance, instruction.call.target.direct);
    }
    for (body.initializer_regions) |*region| try prefetchOptimizationCallees(ctx, region);
}

fn OptimizationContext(comptime Context: type) type {
    return struct {
        ctx: Context,
        instance: structures.InstanceId,
        component: []const structures.InstanceId,

        pub fn inlineLimit(self: @This()) !u32 {
            return (self.ctx.input(InlineLimit, {}) catch |err| switch (err) {
                error.InputNotFound => &default_inline_limit,
                else => return err,
            }).*;
        }

        pub fn inlineBody(self: @This(), callee: structures.InstanceId) !?*const structures.FunctionBodyAnalysis {
            if (std.meta.eql(callee, self.instance) or containsInstance(self.component, callee)) return null;
            if ((try self.ctx.get(ExternalSymbol, callee.item)).*) |symbol| if (!intrinsics.hasTypedBody(symbol)) return null;
            if (((try self.ctx.get(CallComponent, callee)).* orelse return null).members.len != 0) return null;
            if (!(try self.ctx.get(ValidateRuntimeFunction, callee)).*) return null;
            return if ((try self.ctx.get(OptimizeFunctionInstance, callee)).*) |*body| body else null;
        }

        pub fn inlineFacts(self: @This(), callee: structures.InstanceId) !?@import("optimizer/inline.zig").Facts {
            return (try self.ctx.get(InlineFunctionFacts, callee)).*;
        }

        pub fn passesIndirectly(self: @This(), type_id: structures.TypeId) !bool {
            return (TypeLayoutContext(Context){ .ctx = self.ctx }).passesIndirectly(type_id);
        }

        pub fn structFields(self: @This(), scratch: std.mem.Allocator, type_id: structures.TypeId) !?[]const structures.TypeId {
            return (TypeLayoutContext(Context){ .ctx = self.ctx }).structFields(scratch, type_id);
        }
    };
}

fn TypeLayoutContext(comptime Context: type) type {
    return struct {
        ctx: Context,

        pub fn passesIndirectly(self: @This(), type_id: structures.TypeId) !bool {
            const passing = (TypeFacts(Context){ .ctx = self.ctx }).argumentPassing(type_id) catch |err| switch (err) {
                error.Unavailable => return true,
                else => return err,
            };
            return passing == .indirect;
        }

        pub fn structFields(self: @This(), scratch: std.mem.Allocator, type_id: structures.TypeId) !?[]const structures.TypeId {
            if (type_id.isPrimitive()) return null;
            const facts: TypeFacts(Context) = .{ .ctx = self.ctx };
            const definition = (facts.structDefinition(type_id) catch |err| switch (err) {
                error.Unavailable => return null,
                else => return err,
            }) orelse return null;
            const fields = try scratch.alloc(structures.TypeId, definition.fields.len);
            for (definition.fields, fields) |field, *field_type| field_type.* = facts.fieldStorageType(field) catch |err| switch (err) {
                error.Unavailable => return null,
                else => return err,
            };
            return fields;
        }
    };
}

pub const DirectCallees = struct {
    pub const profile_category: profiling.Category = .optimization;
    pub const Input = structures.InstanceId;
    pub const Output = ?struct {
        instances: []const structures.InstanceId,

        pub const eql = value_operations.Owned(@This()).eql;
        pub const deinit = value_operations.Owned(@This()).deinit;
    };

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const body = (try ctx.get(PrepareFunctionInstance, instance)).* orelse return null;
        var instances: std.ArrayList(structures.InstanceId) = .empty;
        defer instances.deinit(ctx.allocator());
        try collectDirectCallees(ctx.allocator(), &body, &instances);
        std.mem.sort(structures.InstanceId, instances.items, {}, instanceLessThan);
        var unique: usize = 0;
        for (instances.items) |callee| {
            if (unique != 0 and std.meta.eql(instances.items[unique - 1], callee)) continue;
            instances.items[unique] = callee;
            unique += 1;
        }
        return .{ .instances = try ctx.allocator().dupe(structures.InstanceId, instances.items[0..unique]) };
    }
};

fn collectDirectCallees(allocator: std.mem.Allocator, body: *const structures.FunctionBodyAnalysis, instances: *std.ArrayList(structures.InstanceId)) !void {
    for (body.instructions) |instruction| if (instruction == .call and instruction.call.target == .direct) try instances.append(allocator, instruction.call.target.direct);
    for (body.initializer_regions) |*region| try collectDirectCallees(allocator, region, instances);
}

fn instanceLessThan(_: void, left: structures.InstanceId, right: structures.InstanceId) bool {
    if (left.item != right.item) return @backingInt(left.item) < @backingInt(right.item);
    const left_specialization: u64 = if (left.specialization) |specialization| @as(u64, @backingInt(specialization)) + 1 else 0;
    const right_specialization: u64 = if (right.specialization) |specialization| @as(u64, @backingInt(specialization)) + 1 else 0;
    if (left_specialization != right_specialization) return left_specialization < right_specialization;
    const left_environment: u64 = if (left.environment) |environment| @as(u64, @backingInt(environment)) + 1 else 0;
    const right_environment: u64 = if (right.environment) |environment| @as(u64, @backingInt(environment)) + 1 else 0;
    return left_environment < right_environment;
}

pub const CallComponent = struct {
    pub const profile_category: profiling.Category = .optimization;
    pub const Input = structures.InstanceId;
    pub const Output = ?struct {
        members: []const structures.InstanceId,

        pub const eql = value_operations.Owned(@This()).eql;
        pub const deinit = value_operations.Owned(@This()).deinit;
    };

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const callees = (try ctx.get(DirectCallees, instance)).* orelse return .{ .members = &.{} };
        if (ctx.hasParallelWorkers()) {
            for (callees.instances) |callee| {
                if (std.meta.eql(callee, instance)) continue;
                _ = try ctx.spawn(DirectCallees, callee);
            }
        }
        var cyclic = false;
        for (callees.instances) |callee| {
            if (std.meta.eql(callee, instance)) {
                cyclic = true;
                continue;
            }
            const component = ctx.get(CallComponent, callee) catch |err| switch (err) {
                error.QueryCycle => {
                    cyclic = true;
                    continue;
                },
                else => return err,
            };
            const members = (component.* orelse continue).members;
            if (containsInstance(members, instance)) return .{ .members = try ctx.allocator().dupe(structures.InstanceId, members) };
        }
        if (!cyclic) return .{ .members = &.{} };
        return .{ .members = try stronglyConnectedCallers(ctx, instance) };
    }
};

fn stronglyConnectedCallers(ctx: anytype, instance: structures.InstanceId) ![]const structures.InstanceId {
    const allocator = ctx.allocator();
    var graph: std.AutoArrayHashMapUnmanaged(structures.InstanceId, std.ArrayList(usize)) = .empty;
    defer {
        for (graph.values()) |*callers| callers.deinit(allocator);
        graph.deinit(allocator);
    }
    try graph.put(allocator, instance, .empty);
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        const callees = (try ctx.get(DirectCallees, graph.keys()[next])).* orelse continue;
        for (callees.instances) |callee| {
            const entry = try graph.getOrPut(allocator, callee);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, next);
        }
    }
    const visited = try allocator.alloc(bool, graph.count());
    defer allocator.free(visited);
    @memset(visited, false);
    var members: std.ArrayList(structures.InstanceId) = .empty;
    errdefer members.deinit(allocator);
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, 0);
    while (pending.pop()) |member| for (graph.values()[member].items) |caller| {
        if (visited[caller]) continue;
        visited[caller] = true;
        try members.append(allocator, graph.keys()[caller]);
        try pending.append(allocator, caller);
    };
    if (!visited[0]) try members.append(allocator, instance);
    std.mem.sort(structures.InstanceId, members.items, {}, instanceLessThan);
    return members.toOwnedSlice(allocator);
}

pub const ValidateRuntimeFunction = CompilerQuery("ValidateRuntimeFunction", .query_other, validateRuntimeFunction, .{});

fn validateRuntimeFunction(ctx: anytype, instance: structures.InstanceId) anyerror!bool {
    const body = (try ctx.get(AnalyzeFunctionInstance, instance)).* orelse return false;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return false;
    return validateRuntimeBody(ctx, &body, resolved.file_id, instance);
}

pub const CompileFunction = CompilerQuery("CompileFunction", .codegen, compileFunction, .{});

fn compileFunction(ctx: anytype, instance_id: structures.InstanceId) anyerror!?structures.CompiledFunction {
    const symbol = (try ctx.get(ExternalSymbol, instance_id.item)).* orelse return compileTypedFunction(ctx, instance_id);
    // Only publish code for a declaration with the implementation's signature.
    const signature = (try lookupFunctionSignature(ctx, instance_id)) orelse return null;
    const types: HostTypes(@TypeOf(ctx)) = .{ .ctx = ctx };
    if (intrinsics.hasTypedBody(symbol)) return compileTypedFunction(ctx, instance_id);
    return switch (symbol) {
        .static_iteration_item => null,
        .primitive_operation, .copy_value, .move_value, .array_filled, .array_borrow, .unsafe_borrow, .unsafe_take, .unsafe_destroy, .unsafe_initialize, .literal_byte, .byte_int, .initialize_collection, .initialize_collection_element, .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => unreachable,
        .io_read, .io_write => try codegen.compileExternalByteIo(symbol == .io_read, signature, types, ctx.allocator()),
        .exit => try codegen.compileExternalExit(ctx.allocator()),
        .panic_message => try codegen.compileExternalPanic(signature, types, ctx.allocator()),
        .allocate_host_storage => try codegen.compileExternalAllocateHostStorage(signature, types, ctx.allocator()),
        .deallocate_host_storage, .deallocate => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
        .allocate => blk: {
            const payload = (try intrinsics.optionalPayload(types.facts(), signature.return_type)).?;
            const element_type = (try types.facts().allocationElement(payload)).?;
            const resolved = (try ctx.get(ResolveItem, instance_id.item)).* orelse return null;
            if (!try validateRuntimeType(ctx, types.facts(), element_type, resolved.file_id, null, instance_id)) return null;
            const layout = (try ctx.get(HostTypeLayout, element_type)).*;
            break :blk try codegen.compileExternalAllocateHostTypedStorage(signature, types, ctx.allocator(), layout);
        },
        .allocation_count => blk: {
            const layout = (try ctx.get(StructLayout, signature.parameters[0].type_id)).* orelse unreachable;
            break :blk try codegen.compileExternalAllocationCount(ctx.allocator(), layout.field_offsets[1]);
        },
    };
}

fn compileTypedFunction(ctx: anytype, instance: structures.InstanceId) !?structures.CompiledFunction {
    if (!(try ctx.get(ValidateRuntimeFunction, instance)).*) return null;
    const optimized = (try ctx.get(OptimizeFunctionInstance, instance)).* orelse return null;
    var sources: std.ArrayList(codegen.InlineSource) = .empty;
    defer {
        for (sources.items) |inline_source| ctx.allocator().free(inline_source.source.name);
        sources.deinit(ctx.allocator());
    }
    const root = (try traceSource(ctx, instance)) orelse return null;
    defer ctx.allocator().free(root.name);
    if (!try collectInlineSources(ctx, &optimized, &sources)) return null;
    const types: HostTypes(@TypeOf(ctx)) = .{ .ctx = ctx, .trace_source = root, .inline_sources = sources.items };
    return try codegen.compileFunction(&optimized, types, ctx.allocator());
}

fn traceSource(ctx: anytype, instance: structures.InstanceId) !?codegen.TraceSource {
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    var name: std.Io.Writer.Allocating = .init(ctx.allocator());
    defer name.deinit();
    try diagnostic_rendering.writeFunctionName(TypeFacts(@TypeOf(ctx)){ .ctx = ctx }, &name.writer, instance);
    return .{
        .path = (try ctx.input(SourcePath, resolved.file_id)).*,
        .source = (try ctx.input(SourceText, resolved.file_id)).*,
        .line_starts = (try ctx.get(SourceLineStarts, resolved.file_id)).offsets,
        .name = try name.toOwnedSlice(),
        .fallback_span = nodeSpan(&parsed, @fromBackingInt(@intCast(resolved.declaration))),
    };
}

fn collectInlineSources(ctx: anytype, body: *const structures.FunctionBodyAnalysis, sources: *std.ArrayList(codegen.InlineSource)) !bool {
    if (body.root_instance) |owner| if (!try addInlineSource(ctx, sources, owner)) return false;
    for (body.inline_frames) |frame| if (!try addInlineSource(ctx, sources, frame.instance)) return false;
    for (body.initializer_regions) |*region| if (!try collectInlineSources(ctx, region, sources)) return false;
    return true;
}

fn addInlineSource(ctx: anytype, sources: *std.ArrayList(codegen.InlineSource), instance: structures.InstanceId) !bool {
    for (sources.items) |existing| if (std.meta.eql(existing.instance, instance)) return true;
    const source = (try traceSource(ctx, instance)) orelse return false;
    sources.append(ctx.allocator(), .{ .instance = instance, .source = source }) catch |err| {
        ctx.allocator().free(source.name);
        return err;
    };
    return true;
}

fn validateRuntimeBody(ctx: anytype, body: *const structures.FunctionBodyAnalysis, file_id: structures.FileId, instance: structures.InstanceId) anyerror!bool {
    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
    if (!try validateRuntimeType(ctx, facts, body.return_type, file_id, null, instance)) return false;
    for (body.block_arguments) |argument| if (argument.representation != .initializer and !try validateRuntimeType(ctx, facts, argument.type_id, file_id, null, instance)) return false;
    for (body.instructions, 0..) |instruction, index| {
        const span = if (body.instruction_spans.len == body.instructions.len) body.instruction_spans[index] else null;
        if (instruction == .static_conversion) {
            _ = try validateRuntimeType(ctx, facts, body.valueType(instruction.static_conversion.operand), file_id, span, instance);
            return false;
        }
        if (instruction == .initializer_ref) continue;
        if (!try validateRuntimeType(ctx, facts, instruction.resultType(), file_id, span, instance)) return false;
    }
    for (body.initializer_regions) |*region| if (!try validateRuntimeBody(ctx, region, file_id, instance)) return false;
    return true;
}

fn validateRuntimeType(ctx: anytype, facts: anytype, type_id: structures.TypeId, file_id: structures.FileId, span: ?structures.SourceSpan, instance: structures.InstanceId) !bool {
    if (try facts.isRuntimeCapable(type_id)) return true;
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = span, .instance = instance, .kind = .{ .compile_time_only_type = type_id } });
    return false;
}

pub const CollectReachableInstances = CompilerQuery("CollectReachableInstances", .query_other, collectReachableInstances, .{});

fn collectReachableInstances(ctx: anytype, file_id: structures.FileId) anyerror!?structures.ReachableInstances {
    const entry_id = (try ctx.get(SelectEntry, file_id)).* orelse return null;
    const entry: structures.InstanceId = .{ .item = entry_id };

    var instances: std.AutoArrayHashMapUnmanaged(structures.InstanceId, void) = .empty;
    defer instances.deinit(ctx.allocator());
    try instances.put(ctx.allocator(), entry, {});
    var next: usize = 0;
    while (next < instances.count()) : (next += 1) {
        const instance = instances.keys()[next];
        const artifact = (try ctx.get(CompileFunction, instance)).* orelse return null;
        for (artifact.referenced_instances) |referenced| {
            const result = try instances.getOrPut(ctx.allocator(), referenced);
            if (!result.found_existing and ctx.hasParallelWorkers()) _ = try ctx.spawn(CompileFunction, referenced);
        }
    }

    return .{ .instances = try ctx.allocator().dupe(structures.InstanceId, instances.keys()) };
}

// Visit imports without evaluating declarations or any file's entry body.
// An explicit queue permits module cycles; export-name cycles are checked by
// the import resolver at the name that introduces the semantic dependency.
pub const ValidateModuleGraph = struct {
    pub const profile_category: profiling.Category = .declarations;
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
                    if (item.loc.kind != .function or item.loc.name != .converter) continue;
                    const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = file, .instance = .{ .item = item_id } };
                    if (try availableSemanticValue(ctx, file, null, semantic.validateConverterDeclaration(&parsed, source, item.declaration, analysis)) == null) return false;
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
                if (try resolveModuleExport(ctx, module, module, selection.bound.spelling, .{ .file_id = file, .span = selection.bound.span }, &visited, true) == null)
                    return false;
            }
            return true;
        }
        const origin: ImportOrigin = .{ .file_id = file, .span = (entry.alias orelse entry.path).span };
        return try resolveModuleExport(ctx, module, module, importBoundName(entry), origin, &visited, true) != null;
    }
};

pub const BuildExecutable = CompilerQuery("BuildExecutable", .query_other, buildExecutable, .{ .result_arena = true });

fn buildExecutable(ctx: anytype, file_id: structures.FileId) anyerror!?structures.Executable {
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
    return try codegen.buildExecutableWithResultAllocator(entry, functions.items, ctx.allocator(), ctx.resultAllocator());
}

test "embedded source syntax preserves ordinary parser results" {
    inline for (standard_library.paths) |path| {
        const source = comptime standard_library.source(path);
        var ordinary = try ast.parseReport(std.testing.allocator, 42, source);
        defer ordinary.deinit(std.testing.allocator);
        var embedded = try value_operations.Owned(structures.Ast).clone(std.testing.allocator, ParseFile.standardAst(source).?);
        defer value_operations.Owned(structures.Ast).deinit(&embedded, std.testing.allocator);
        embedded.file_id = 42;
        try std.testing.expectEqual(@as(usize, 0), ordinary.diagnostics.len);
        try std.testing.expect(structures.Ast.eql(ordinary.ast.?, embedded));
        try std.testing.expect(ParseFile.standardAst(source ++ "\n") == null);
    }
}

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
        .{ .source = "import std.exit as counts\npub struct Count\n  copy = trivial\n  pub value: int\npub static optional: Count | none = Count{value = 1}\npub struct Sized(n: int)\n  value: int\npub struct Visible\n  pub value: Sized(match optional\n    counts and counts is Count -> counts.value\n    _ -> 0)", .accepted = true },
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
            if (candidate.tag == .struct_field) break candidate.data.field.type_annotation;
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
        .{ .annotation = "T", .hidden_argument = true, .accepted = true },
        .{ .annotation = "T | none", .hidden_argument = true, .accepted = true },
        .{ .annotation = "func(T) int", .hidden_argument = true, .accepted = true },
        .{ .annotation = "func(int) T", .hidden_argument = true, .accepted = true },
        .{ .annotation = "HiddenAlias", .hidden_argument = false, .accepted = false },
        .{ .annotation = "PublicAlias", .hidden_argument = false, .accepted = true },
    };
    for (cases) |case| {
        errdefer std.debug.print("generated annotation {s}, hidden argument={any}\n", .{ case.annotation, case.hidden_argument });
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
    const identity: NamespaceIdentity = .{ .declared = item };
    try std.testing.expect((try db.get(TypeNamespace, identity)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(TypeNamespace, identity, structures.Diagnostic, std.testing.allocator);
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
            try std.testing.expect(try analysis.facts().structDefinition(three) == null);
            try std.testing.expect((try ctx.get(StructLayout, three)).* == null);
            try std.testing.expect(try facts.structIdentity(three) == null);
            const namespace = (try analysis.typeNamespace(three)).?;
            const identity = namespace.query_key.generated;
            try std.testing.expectEqual((try standardFunction(ctx, .array, "Array")).?, identity.owner.item);
            const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, namespace.specialization.?)).values;
            try std.testing.expectEqual(structures.TypeId.int, (try ctx.lookupInterned(CompileTimeValues, arguments[0])).type);
            try std.testing.expectEqual(@as(i32, 3), (try ctx.lookupInterned(CompileTimeValues, arguments[1])).runtime.value.int);
            const inferred = (try analysis.structFactoryArguments(.{ .item = identity.owner.item }, three)).?;
            try std.testing.expect(std.mem.eql(structures.CompileTimeValueId, arguments, inferred));
            const filled = (try analysis.typeNamespaceMember(three, "filled", .{ .start = 0, .end = 0 })).?;
            try std.testing.expectEqual(structures.CallBehavior.ordinary, try analysis.callBehavior(filled.item));
            try std.testing.expectEqual(three, (try ctx.get(FunctionInstanceSignature, filled)).*.?.return_type);
            for ([_][]const u8{ "Empty", "Nonempty" }) |name| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expect(try facts.arrayType(type_id) != null);
                const unavailable = (try analysis.typeNamespaceMember(type_id, "filled", .{ .start = 0, .end = 0 })).?;
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

test "canonical type namespace facts retain diagnostics and recover after standard source edits" {
    const query = @import("query/engine.zig");
    const modules = @import("modules.zig");
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 0 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator, "exit(0)", &.{}, &.{});
    const array: structures.TypeId = .fromInterned(try db.intern(Types, .{ .array = .{ .element_type = .int, .length = 3 } }));
    const association = try db.get(ResolveTypeNamespace, array);
    try std.testing.expect(association.* == .available);
    const primitive = try db.get(ResolveTypeNamespace, structures.TypeId.int);
    try std.testing.expect(primitive.* == .available);
    const reference: structures.TypeId = .fromInterned(try db.intern(Types, .{ .reference = .int }));
    try std.testing.expect((try db.get(ResolveTypeNamespace, reference)).* == .missing);
    try db.setInput(SourceText, 0, "exit(1)");
    try std.testing.expectEqual(association, try db.get(ResolveTypeNamespace, array));
    try std.testing.expectEqual(primitive, try db.get(ResolveTypeNamespace, structures.TypeId.int));

    const array_file = (try standardFile(db, .array)).?;
    const source = try std.testing.allocator.dupe(u8, (try db.input(SourceText, array_file)).*);
    defer std.testing.allocator.free(source);
    try db.setInput(SourceText, array_file, "pub struct Array(\n");
    try std.testing.expect((try db.get(ResolveTypeNamespace, array)).* == .unavailable);
    const analysis: AnalysisContext(@TypeOf(db)) = .{ .ctx = db, .file_id = 0 };
    try std.testing.expectError(error.Unavailable, analysis.typeNamespace(array));
    const diagnostics = try db.transitiveAccumulatorValues(ResolveTypeNamespace, array, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expect(diagnostics.len != 0);
    try db.setInput(SourceText, array_file, source);
    try std.testing.expect((try db.get(ResolveTypeNamespace, array)).* == .available);
    const recovered = try db.transitiveAccumulatorValues(ResolveTypeNamespace, array, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(recovered);
    try std.testing.expectEqual(@as(usize, 0), recovered.len);
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
            for (
                [_][]const u8{ "References", "EmptyReferences", "AllocatedReferences" },
                [_]bool{ true, false, false },
                [_]bool{ true, false, true },
            ) |name, contains, stores| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expectEqual(contains, try analysis.facts().containsBorrow(type_id));
                try std.testing.expectEqual(stores, try analysis.facts().canStoreBorrow(type_id));
            }
            for ([_][]const u8{ "HiddenArray", "VisibleArray" }, [_]bool{ false, true }) |name, visible| {
                const type_id = (try ctx.lookupInterned(CompileTimeValues, (try ctx.get(ResolveStatic, scope.resolve(name).?)).*.?)).type;
                try std.testing.expectEqual(visible, try analysis.isPublicFieldType(type_id));
            }
        }
    };
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, std.testing.allocator,
        \\import std.memory.{Allocation}
        \\struct Hidden
        \\    value: int
        \\pub struct Visible
        \\    value: int
        \\static References = Array(Ref(int), 2)
        \\static EmptyReferences = Array(Ref(int), 0)
        \\static AllocatedReferences = Array(Allocation(Ref(int)), 2)
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
            const len = (try analysis.typeNamespaceMember(type_id, "len", .{ .start = 0, .end = 0 })).?;
            const len_signature = (try ctx.get(FunctionInstanceSignature, len)).*.?;
            try std.testing.expectEqual(structures.TypeId.int, len_signature.return_type);
            const getter = (try analysis.typeNamespaceCallMember(type_id, "get", 2, .{ .start = 0, .end = 0 })).?;
            const getters = try analysis.functionOverloads(getter.overloaded_function);
            for (getters.candidates) |member| {
                const signature = (try ctx.get(FunctionInstanceSignature, member)).*.?;
                if (signature.parameters[1].type_id != .int) continue;
                try std.testing.expectEqual(structures.CallBehavior.ordinary, try analysis.callBehavior(member.item));
                try std.testing.expectEqual(@as(usize, 2), signature.parameters.len);
                try std.testing.expectEqual(structures.ParameterMode.ref, signature.parameters[0].mode);
                try std.testing.expectEqual(type_id, signature.parameters[0].type_id);
                try std.testing.expectEqual(structures.ParameterMode.imm, signature.parameters[1].mode);
                try std.testing.expectEqual(structures.TypeId.int, signature.parameters[1].type_id);
                const members = (try analysis.facts().variantMembers(signature.return_type)).?;
                try std.testing.expectEqual(@as(usize, 2), members.len);
                try std.testing.expectEqual(structures.ResultMode.owned, signature.result_mode);
                break;
            } else return error.ExpectedIntegerGetter;
            for ([_]standard_library.External{.array_borrow}) |symbol| {
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
