const std = @import("std");
const intrinsics = @import("intrinsics.zig");
const profiling = @import("profiling.zig");
const standard_library = @import("standard_library");
const structures = @import("structures.zig");
const value_operations = @import("value.zig");
const ast = @import("frontend/parser.zig");
const codegen = @import("backend/codegen.zig");
const comptime_interpreter = @import("frontend/comptime_interpreter.zig");
const semantic = @import("frontend/semantic.zig");
const typing = @import("frontend/typing.zig");
const diagnostic_rendering = @import("diagnostics.zig");

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

pub const SourceText = struct {
    pub const Key = structures.FileId;
    pub const Value = []const u8;
    pub const cloneValue = value_operations.Owned(Value).clone;
    pub const eqlValue = value_operations.Owned(Value).eql;
    pub const deinitValue = value_operations.Owned(Value).destroy;
};

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

pub const SourcePath = struct {
    pub const Key = structures.FileId;
    pub const Value = []const u8;
    pub const cloneValue = value_operations.Owned(Value).clone;
    pub const eqlValue = value_operations.Owned(Value).eql;
    pub const deinitValue = value_operations.Owned(Value).destroy;
};

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

pub const FileModule = struct {
    pub const Key = structures.FileId;
    pub const Value = structures.ModuleId;
};

pub const ModuleMembers = struct {
    pub const Key = structures.ModuleId;
    pub const Value = []const structures.FileId;
    pub const cloneValue = value_operations.Owned(Value).clone;
    pub const eqlValue = value_operations.Owned(Value).eql;
    pub const deinitValue = value_operations.Owned(Value).destroy;
};

pub const ModuleCatalog = struct {
    pub const Key = void;
    pub const Value = []const structures.ModuleId;
    pub const cloneValue = value_operations.Owned(Value).clone;
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

pub const ModulePaths = OwnedInterner(structures.ModulePath, structures.ModuleId);

pub const DiscoverItems = struct {
    pub const profile_category: profiling.Category = .declarations;
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
            if (!(try names.getOrPut(item.loc.name.text())).found_existing) continue;
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

pub const ItemLocations = OwnedInterner(structures.ItemLoc, structures.ItemId);
pub const FunctionOverloads = OwnedInterner(structures.FunctionOverloadSet, structures.FunctionOverloadId);

pub const ResolveOverloads = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionOverloadId;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const declaration = (try itemSource(ctx, instance.item)) orelse return null;
        const parsed = &declaration.parsed;
        const binding = parsed.nodes[declaration.resolved.declaration];
        const value = binding.data.node_node.b;
        std.debug.assert(parsed.nodes[value.index()].tag == .overload);
        const nodes = parsed.nodeList(value);
        std.debug.assert(nodes.len != 0);
        const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = declaration.resolved.file_id, .instance = instance };
        const source = (try ctx.input(SourceText, declaration.resolved.file_id)).*;
        var candidates: std.AutoArrayHashMapUnmanaged(structures.InstanceId, void) = .empty;
        defer candidates.deinit(ctx.allocator());
        for (nodes) |node| {
            const reference = semantic.resolveNamedExpression(parsed, source, node, analysis) catch |err| switch (err) {
                error.QueryCycle => {
                    try typing.emitSemanticIssue(ctx, declaration.resolved.file_id, .{ .span = nodeSpan(parsed, node), .kind = .declaration_cycle });
                    return null;
                },
                else => return err,
            };
            if (reference == null or reference.? != .declaration or (try ctx.lookupInterned(ItemLocations, reference.?.declaration.item)).kind != .function) {
                try typing.emitSemanticIssue(ctx, declaration.resolved.file_id, .{ .span = nodeSpan(parsed, node), .kind = .invalid_overload_candidate });
                return null;
            }
            if ((try candidates.getOrPut(ctx.allocator(), reference.?.declaration)).found_existing) {
                try typing.emitSemanticIssue(ctx, declaration.resolved.file_id, .{ .span = nodeSpan(parsed, node), .kind = .duplicate_overload_candidate });
                return null;
            }
        }
        return try ctx.intern(FunctionOverloads, .{ .candidates = candidates.keys(), .declaration = instance });
    }
};

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

fn standardFunction(ctx: anytype, file: standard_library.File, name: []const u8) !?structures.ItemId {
    const registered = (try standardFile(ctx, file)) orelse return null;
    const module = try ctx.intern(ModulePaths, .{ .path = file.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
    const item = declarations.resolveFunction(name) orelse return null;
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    return if (resolved.file_id == registered) item else null;
}

fn internStandardArrayType(ctx: anytype, identity: structures.GeneratedStructIdentity) !structures.TypeId {
    const item_source = (try itemSource(ctx, identity.owner.item)) orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return error.Unavailable;
    if (identity.node_offset != site)
        return .fromInterned(try ctx.intern(Types, .{ .structure = .{ .generated = identity } }));
    const tuple = identity.owner.specialization orelse return error.Unavailable;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != 2) return error.Unavailable;
    const element = (try ctx.lookupInterned(CompileTimeValues, arguments[0])).*;
    const count = (try ctx.lookupInterned(CompileTimeValues, arguments[1])).*;
    const span = nodeSpan(&item_source.parsed, @fromBackingInt(@intCast(item_source.resolved.declaration)));
    if (element != .type or count != .runtime or count.runtime.type_id != .int or count.runtime.value != .int) {
        try rejectImport(ctx, .{ .file_id = item_source.resolved.file_id, .span = span }, .static_argument_type_mismatch);
        return error.Unavailable;
    }
    if (count.runtime.value.int < 0) {
        try rejectImport(ctx, .{ .file_id = item_source.resolved.file_id, .span = span }, .static_argument_not_supported);
        return error.Unavailable;
    }
    if (!try validArrayElementType(ctx, element.type)) {
        try rejectImport(ctx, .{ .file_id = item_source.resolved.file_id, .span = span }, .struct_field_type_not_supported);
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
        .structure, .callable, .reference => return true,
        .array => |array| return validArrayElementType(ctx, array.element_type),
        .variant => |variant| {
            for (variant.members) |member| {
                if (!try validArrayElementType(ctx, member)) return false;
            }
            return true;
        },
        .tuple => |tuple| {
            for (tuple.members) |member| if (!try validArrayElementType(ctx, member.type_id)) return false;
            return true;
        },
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
};

fn arrayTypeNamespace(ctx: anytype, array: structures.ArrayType) !?TypeNamespaceAssociation {
    const factory = (try standardFunction(ctx, .array, "Array")) orelse return null;
    const item_source = (try itemSource(ctx, factory)) orelse return error.Unavailable;
    const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return error.Unavailable;
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
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            return switch (data.*) {
                .structure => |identity| identity,
                .reference, .variant, .callable, .array, .tuple => null,
            };
        }

        pub fn byteString(self: @This(), id: structures.ByteStringId) ![]const u8 {
            return (try self.ctx.lookupInterned(ByteStrings, id)).bytes;
        }

        pub fn structName(self: @This(), type_id: structures.TypeId) !?[]const u8 {
            if (type_id.isPrimitive()) return null;
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
            const identity = switch (data.*) {
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

        pub fn internVariant(self: @This(), members: []const structures.TypeId) !structures.InternVariantResult {
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

        pub fn internVariantMembers(self: @This(), members: []const structures.MemberSpec) !structures.InternVariantResult {
            var storage_types: std.ArrayList(structures.TypeId) = .empty;
            defer storage_types.deinit(self.ctx.allocator());
            for (members) |member| try storage_types.append(self.ctx.allocator(), try self.memberStorageType(member));
            return internVariantType(self.ctx, storage_types.items);
        }

        pub fn internTuple(self: @This(), members: []const structures.MemberSpec) !structures.TypeId {
            std.debug.assert(members.len >= 2);
            return .fromInterned(try self.ctx.intern(Types, .{ .tuple = .{ .members = members } }));
        }

        pub fn tupleMembers(self: @This(), type_id: structures.TypeId) !?[]const structures.MemberSpec {
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            return if (data.* == .tuple) data.tuple.members else null;
        }

        pub fn fieldStorageType(self: @This(), field: structures.StructField) !structures.TypeId {
            return self.memberStorageType(.{ .kind = field.kind, .type_id = field.type_id });
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
                .tuple => (try self.ctx.get(TupleDefinition, type_id)).*,
                .reference, .variant, .callable, .array => null,
            };
        }

        pub fn borrowElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return borrowElementType(self.ctx, type_id);
        }

        pub fn storageCursorAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return storageCursorAccessType(self.ctx, type_id);
        }

        pub fn storageAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return (try self.storageCursorAccess(type_id)) orelse try self.spanAccess(type_id);
        }

        pub fn spanAccess(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return spanAccessType(self.ctx, type_id);
        }

        pub fn staticStringBytes(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return staticStringBytesType(self.ctx, type_id);
        }

        pub fn isStaticString(self: @This(), type_id: structures.TypeId) !bool {
            const static_string = (try self.ctx.get(TextType, .StaticString)).* orelse return false;
            return static_string == type_id;
        }

        pub fn allocationElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return allocationElementType(self.ctx, type_id);
        }

        pub fn boxElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return boxElementType(self.ctx, type_id);
        }

        pub fn hostStorage(self: @This()) !?structures.TypeId {
            const module = try self.ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_host.modulePath() });
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return null;
            return hostStorageType(self.ctx, declarations);
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

        pub fn canBorrowStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.canBorrowStorage(result_type, source_type, true);
        }

        pub fn canBorrowInlineStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.canBorrowStorage(result_type, source_type, false);
        }

        fn canBorrowStorage(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId, include_allocated_storage: bool) !bool {
            if (!try self.canStoreBorrow(result_type)) return false;
            var visited: std.ArrayList(structures.TypeId) = .empty;
            defer visited.deinit(self.ctx.allocator());
            return self.canBorrowStorageOfAt(result_type, source_type, &visited, include_allocated_storage);
        }

        fn canBorrowStorageOfAt(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_storage: bool) anyerror!bool {
            if (result_type.isPrimitive()) return false;
            if (try self.borrowElement(result_type)) |element| {
                var sources: std.ArrayList(structures.TypeId) = .empty;
                defer sources.deinit(self.ctx.allocator());
                return self.containsStorageType(source_type, element, &sources, include_allocated_storage);
            }
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, result_type) != null) return false;
            try visited.append(self.ctx.allocator(), result_type);
            if (try self.storageAccess(result_type)) |element_type| {
                var sources: std.ArrayList(structures.TypeId) = .empty;
                defer sources.deinit(self.ctx.allocator());
                return self.containsStorageType(source_type, element_type, &sources, include_allocated_storage);
            }
            if (try self.collectionLiteralType(result_type)) |collection|
                return collection.length != 0 and try self.canBorrowStorageOfAt(collection.element_type, source_type, visited, include_allocated_storage);
            if (try self.arrayType(result_type)) |array|
                return array.length != 0 and try self.canBorrowStorageOfAt(array.element_type, source_type, visited, include_allocated_storage);
            if (try self.allocationElement(result_type)) |element|
                return self.canBorrowStorageOfAt(element, source_type, visited, include_allocated_storage);
            if (try self.boxElement(result_type)) |element|
                return self.canBorrowStorageOfAt(element, source_type, visited, include_allocated_storage);
            if (try self.structDefinition(result_type)) |definition| {
                for (definition.fields) |field| {
                    if (field.kind == .reference) {
                        var sources: std.ArrayList(structures.TypeId) = .empty;
                        defer sources.deinit(self.ctx.allocator());
                        if (try self.containsStorageType(source_type, field.type_id, &sources, include_allocated_storage)) return true;
                    } else if (try self.canBorrowStorageOfAt(field.type_id, source_type, visited, include_allocated_storage)) return true;
                }
            }
            if (try self.variantMembers(result_type)) |members| {
                for (members) |member| if (try self.canBorrowStorageOfAt(member, source_type, visited, include_allocated_storage)) return true;
            }
            return false;
        }

        fn containsStorageType(self: @This(), source_type: structures.TypeId, referent_type: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_storage: bool) anyerror!bool {
            if (source_type == referent_type) return true;
            if (source_type.isPrimitive()) return false;
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, source_type) != null) return false;
            try visited.append(self.ctx.allocator(), source_type);
            if (try self.storageAccess(source_type) != null) return false;
            if (try self.collectionLiteralType(source_type)) |collection|
                return collection.length != 0 and try self.containsStorageType(collection.element_type, referent_type, visited, include_allocated_storage);
            if (try self.arrayType(source_type)) |array|
                return array.length != 0 and try self.containsStorageType(array.element_type, referent_type, visited, include_allocated_storage);
            if (try self.allocationElement(source_type)) |element|
                return include_allocated_storage and try self.containsStorageType(element, referent_type, visited, include_allocated_storage);
            if (try self.boxElement(source_type)) |element|
                return include_allocated_storage and try self.containsStorageType(element, referent_type, visited, include_allocated_storage);
            if (try self.structDefinition(source_type)) |definition| {
                for (definition.fields) |field| if (field.kind == .owned and try self.containsStorageType(field.type_id, referent_type, visited, include_allocated_storage)) return true;
            }
            if (try self.variantMembers(source_type)) |members| {
                for (members) |member| if (try self.containsStorageType(member, referent_type, visited, include_allocated_storage)) return true;
            }
            return false;
        }

        fn containsBorrowAt(self: @This(), type_id: structures.TypeId, visited: *std.ArrayList(structures.TypeId), include_allocated_contents: bool) anyerror!bool {
            if (type_id.isPrimitive()) return false;
            if (std.mem.indexOfScalar(structures.TypeId, visited.items, type_id) != null) return false;
            try visited.append(self.ctx.allocator(), type_id);
            if (try self.borrowElement(type_id) != null or try self.storageAccess(type_id) != null) return true;
            if (try self.collectionLiteralType(type_id)) |collection|
                return collection.length != 0 and try self.containsBorrowAt(collection.element_type, visited, include_allocated_contents);
            if (try self.arrayType(type_id)) |array|
                return array.length != 0 and try self.containsBorrowAt(array.element_type, visited, include_allocated_contents);
            if (try self.listElement(type_id)) |element| return self.containsBorrowAt(element, visited, include_allocated_contents);
            if (try self.allocationElement(type_id)) |element|
                return include_allocated_contents and try self.containsBorrowAt(element, visited, true);
            if (try self.boxElement(type_id)) |element| {
                if (try self.containsBorrowAt(element, visited, include_allocated_contents)) return true;
            }
            if (try self.structDefinition(type_id)) |definition| {
                if (try self.isStaticString(type_id)) return false;
                for (definition.fields) |field| {
                    if (field.kind == .reference or try self.containsBorrowAt(field.type_id, visited, include_allocated_contents)) return true;
                }
            }
            if (try self.variantMembers(type_id)) |members| {
                for (members) |member| if (try self.containsBorrowAt(member, visited, include_allocated_contents)) return true;
            }
            return false;
        }

        pub fn mayContainStorage(self: @This(), type_id: structures.TypeId) anyerror!bool {
            if (type_id.isPrimitive()) return false;
            if (try self.borrowElement(type_id) != null or try self.storageAccess(type_id) != null or try self.allocationElement(type_id) != null or try self.boxElement(type_id) != null) return true;
            if (try self.arrayType(type_id)) |array| return array.length != 0 and try self.mayContainStorage(array.element_type);
            if (try self.structDefinition(type_id)) |definition| {
                if (try standardFile(self.ctx, .memory_host) != null) {
                    const module = try self.ctx.intern(ModulePaths, .{ .path = standard_library.File.memory_host.modulePath() });
                    if ((try self.ctx.get(ModuleDeclarations, module)).*) |declarations| {
                        if (try hostStorageType(self.ctx, declarations) == type_id) return true;
                    }
                }
                for (definition.fields) |field| if (field.kind == .reference or try self.mayContainStorage(field.type_id)) return true;
            } else if (try self.variantMembers(type_id)) |members| {
                for (members) |member| if (try self.mayContainStorage(member)) return true;
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
            if (try self.arrayType(type_id)) |array| return self.runtimeCapableResult(array.element_type);
            if (try self.structDefinition(type_id)) |definition| {
                if (definition.is_static) return false;
                for (definition.fields) |field| {
                    if (field.kind == .owned and !(try self.runtimeCapableResult(field.type_id) orelse return null)) return false;
                }
            } else if (try self.variantMembers(type_id)) |members| {
                for (members) |member| if (!(try self.runtimeCapableResult(member) orelse return null)) return false;
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
            if (try self.structDefinition(type_id)) |definition| {
                for (definition.fields) |field| {
                    if (field.kind != .owned) continue;
                    const passing = (try self.argumentPassingResult(field.type_id)) orelse return null;
                    if (passing == .indirect) return .indirect;
                }
            } else if (try self.variantMembers(type_id)) |members| {
                for (members) |member| {
                    const passing = (try self.argumentPassingResult(member)) orelse return null;
                    if (passing == .indirect) return .indirect;
                }
            }
            return .direct;
        }
    };
}

pub fn HostTypes(comptime Context: type) type {
    return struct {
        ctx: Context,
        trace_source: ?codegen.TraceSource = null,

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

        pub fn rangeConstructor(self: @This(), inclusive: bool) !?structures.ItemId {
            return standardFunction(self.ctx, .range, if (inclusive) "inclusive" else "exclusive");
        }

        pub fn iterationEndType(self: @This()) !structures.TypeId {
            const registered = (try standardFile(self.ctx, .iteration)) orelse return error.Unavailable;
            const module = try self.ctx.intern(ModulePaths, .{ .path = standard_library.File.iteration.modulePath() });
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
            const item = declarations.resolveStatic("End") orelse return error.Unavailable;
            const resolved = (try self.ctx.get(ResolveItem, item)).* orelse return error.Unavailable;
            if (resolved.file_id != registered) return error.Unavailable;
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

        pub fn structDefinition(self: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            switch (data.*) {
                .structure => |identity| return (try getStructDefinition(self.ctx, identity)) orelse return error.Unavailable,
                .tuple => return (try self.ctx.get(TupleDefinition, type_id)).*,
                .reference, .variant, .callable, .array => return null,
            }
        }

        pub fn arrayType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            return self.facts().arrayType(type_id);
        }

        pub fn collectionLiteralType(self: @This(), type_id: structures.TypeId) !?structures.ArrayType {
            return self.facts().collectionLiteralType(type_id);
        }

        pub fn collectionSequenceElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            const instance = (try standardMemoryInstance(self.ctx, type_id, .collection_sequence)) orelse return null;
            return instance.element_type;
        }

        pub fn isCollectionConstructionType(self: @This(), type_id: structures.TypeId) !bool {
            return try self.collectionLiteralType(type_id) != null or try self.collectionSequenceElement(type_id) != null;
        }

        pub fn collectionSequenceConstruction(self: @This(), type_id: structures.TypeId, element: structures.TypeId) !?structures.InitializerConstruction {
            const definition = (try self.structDefinition(type_id)) orelse return error.Unavailable;
            if (definition.fields.len != 1 or definition.fields[0].kind != .owned or
                !std.mem.eql(u8, definition.fields[0].name, "value") or
                (try self.listElement(definition.fields[0].type_id)) != element) return null;
            return .{ .type_id = definition.fields[0].type_id, .projection = 0, .fallible_allocation = true };
        }

        pub fn initializerConstruction(self: @This(), type_id: structures.TypeId) !structures.InitializerConstruction {
            if (try self.collectionLiteralType(type_id)) |shape| return .{ .type_id = try self.internArrayType(shape) };
            if (try self.collectionSequenceElement(type_id)) |element| {
                if (try self.collectionSequenceConstruction(type_id, element)) |construction| return construction;
                const identity = (try self.structIdentity(type_id)).?;
                const declaration = (try itemSource(self.ctx, structOwnerItem(identity))) orelse return error.Unavailable;
                try typing.emitSemanticIssue(self.ctx, declaration.resolved.file_id, .{ .span = nodeSpan(&declaration.parsed, @fromBackingInt(declaration.resolved.declaration)), .kind = .invalid_collection_sequence });
                return error.Unavailable;
            }
            return .{ .type_id = type_id };
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
            return self.facts().structIdentity(type_id);
        }

        pub fn typeNamespace(self: @This(), type_id: structures.TypeId) !?TypeNamespaceAssociation {
            if (type_id.isPrimitive()) {
                const registered = (try standardFile(self.ctx, .prelude)) orelse return null;
                const module = (try self.ctx.input(FileModule, registered)).*;
                const owner = try self.ctx.intern(ItemLocations, .{ .origin = .{ .module = module }, .kind = .primitive, .name = .{ .identifier = @tagName(type_id) } });
                return .{ .query_key = .{ .primitive = owner } };
            }
            const interned = type_id.interned() orelse return null;
            const data = (try self.ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
            switch (data.*) {
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
                .array => |array| return (try arrayTypeNamespace(self.ctx, array)) orelse return error.Unavailable,
                .reference, .variant, .callable, .tuple => return null,
            }
        }

        pub fn typeNamespaceMember(self: @This(), type_id: structures.TypeId, name: []const u8, span: structures.SourceSpan) !?structures.InstanceId {
            if (std.meta.stringToEnum(structures.OwnershipMember, name)) |operation|
                return self.ownershipMember(type_id, operation);
            return self.namedTypeNamespaceMember(type_id, .fromText(name, null), span);
        }

        pub fn namedTypeNamespaceMember(self: @This(), type_id: structures.TypeId, name: structures.Name, span: structures.SourceSpan) !?structures.InstanceId {
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
            return .{
                .item = (try self.visibleTypeMember(namespace, name, span)) orelse return null,
                .specialization = association.specialization,
                .environment = association.environment,
            };
        }

        pub fn typeNamespaceCallMember(self: @This(), type_id: structures.TypeId, name: []const u8, operands: usize, span: structures.SourceSpan) !?structures.NameReference {
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
            return self.namespaceReference(namespace, association.specialization, association.environment, name, span, operands);
        }

        pub fn ownershipMember(self: @This(), type_id: structures.TypeId, operation: structures.OwnershipMember) !?structures.InstanceId {
            const capabilities = (try self.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (try self.typeNamespace(type_id)) |association| {
                if ((try self.ctx.get(TypeNamespace, association.query_key)).* == null) return error.Unavailable;
            }
            switch (operation) {
                .copy => if (capabilities.copy == .none) return null,
                .move => if (capabilities.move == .none) return null,
            }
            const name = switch (operation) {
                .copy => "copy_value",
                .move => "move_value",
            };
            const item = (try standardFunction(self.ctx, .ownership, name)) orelse return error.Unavailable;
            const argument = try self.ctx.intern(CompileTimeValues, .{ .type = type_id });
            return try self.specializeFunction(.{ .item = item }, &.{argument});
        }

        fn genericStructNamespaceMember(self: @This(), factory: structures.InstanceId, name: []const u8, span: ?structures.SourceSpan) !?structures.InstanceId {
            const item_source = (try itemSource(self.ctx, factory.item)) orelse return null;
            const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return null;
            const namespace = (try self.ctx.get(TypeNamespace, .{ .generated = .{
                .owner = factory,
                .node_offset = site,
            } })).* orelse return error.Unavailable;
            return .{ .item = (try self.visibleTypeMember(namespace, .fromText(name, null), span)) orelse return null, .specialization = factory.specialization, .environment = factory.environment };
        }

        fn visibleTypeMember(self: @This(), namespace: structures.ModuleScope, name: structures.Name, span: ?structures.SourceSpan) !?structures.ItemId {
            const entry = namespace.resolveName(name) orelse return null;
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
            const value = (try availableSemanticValue(self.ctx, file_id, self.instance, semantic.analyzeStaticTypeArgument(&parsed, source, node, self, self.ctx.allocator()))) orelse return null;
            return try self.internCompileTimeValue(value);
        }

        const DeclarationContext = struct {
            resolved: structures.ResolvedItem,
            parsed: structures.Ast,
            source: []const u8,
            analysis: AnalysisContext(Context),
        };

        fn declarationContext(self: @This(), instance: structures.InstanceId, prior: []const structures.CompileTimeValueId) !DeclarationContext {
            const item_source = (try itemSource(self.ctx, instance.item)) orelse return error.Unavailable;
            return .{
                .resolved = item_source.resolved,
                .parsed = item_source.parsed,
                .source = (try self.ctx.input(SourceText, item_source.resolved.file_id)).*,
                .analysis = .{ .ctx = self.ctx, .file_id = item_source.resolved.file_id, .instance = instance, .prior_static_arguments = prior },
            };
        }

        pub fn staticParameterType(self: @This(), instance: structures.InstanceId, parameter_index: usize, prior: []const structures.CompileTimeValueId) !structures.TypeId {
            const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
            std.debug.assert(parameter_index < shape.parameters.len);
            if (shape.parameters[parameter_index].is_meta_type) return .type;
            const declaration = try self.declarationContext(instance, prior);
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzeStaticParameterType(&declaration.parsed, declaration.source, declaration.resolved.declaration, parameter_index, declaration.analysis, self.ctx.allocator()));
        }

        pub fn independentParameterType(self: @This(), instance: structures.InstanceId, runtime_index: usize) !?structures.TypeId {
            if (try self.needsInheritedInference(instance)) return null;
            const declaration = try self.declarationContext(instance, &.{});
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzeIndependentParameterType(&declaration.parsed, declaration.source, declaration.resolved.declaration, runtime_index, declaration.analysis, self.ctx.allocator()));
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
                return reference.declaration.item == (try standardFunction(self.ctx, .array, "collection_literal")) or reference.declaration.item == (try standardFunction(self.ctx, .memory_allocation, "collection_sequence"));
            const constant = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (try self.staticItem(instance)) orelse return false,
                .namespace, .overloaded_function => return false,
            };
            const value = try self.lookupCompileTimeValue(constant);
            return value == .type and try self.isCollectionConstructionType(value.type);
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
                .namespace, .overloaded_function => return false,
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
            const location = try self.ctx.lookupInterned(ItemLocations, association.query_key.owner());
            return switch (location.origin) {
                .module => |module| module,
                .entry => |file| (try self.ctx.input(FileModule, file)).*,
            };
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
            const inference = try semantic.inferConverterArguments(&declaration.parsed, declaration.source, declaration.resolved.declaration, source_type, target_type, source_value, collection_length, declaration.analysis, self.ctx.allocator());
            const arguments = switch (inference) {
                .arguments => |arguments| arguments,
                .missing, .conflict => return null,
            };
            defer self.ctx.allocator().free(arguments);
            const instance = try self.specializeFunction(base, arguments);
            var specialized = declaration.analysis;
            specialized.instance = instance;
            specialized.prior_static_arguments = arguments;
            const signature = switch (try semantic.analyzeShapedFunctionSignature(&declaration.parsed, declaration.source, declaration.resolved.declaration, arguments, shape, specialized, self.ctx.allocator())) {
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
            const result = (try self.ctx.get(ConversionCandidates, .{
                .source = if (source_value) |value| .{ .constant = value } else .{ .typed = source_type },
                .target = target_type,
                .requester = try self.currentModule(),
            })).*;
            return result orelse error.Unavailable;
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
            const candidates = (try self.ctx.get(ConversionCandidates, .{
                .source = .{ .collection = length },
                .target = target_type,
                .requester = try self.currentModule(),
            })).* orelse return error.Unavailable;
            var element_type: ?structures.TypeId = null;
            for (candidates) |candidate| {
                const collection = (try self.collectionLiteralType(candidate.input_type)).?;
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
            return semanticValue(self.ctx, declaration.resolved.file_id, instance, semantic.analyzeIndependentStructFieldType(&declaration.parsed, declaration.source, declaration.resolved.declaration, name, declaration.analysis, self.ctx.allocator()));
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
                const shape = (try self.collectionLiteralType(type_id)) orelse try self.arrayType(type_id);
                const element = if (shape) |array| array.element_type else try self.listElement(type_id);
                if (element) |element_type| {
                    const value = try self.internCompileTimeValue(.{ .type = element_type });
                    const tuple = try self.ctx.intern(CompileTimeValueTuples, .{ .values = &.{value} });
                    return (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
                }
            }
            const association = (try self.typeNamespace(type_id)) orelse return null;
            const identity = association.query_key;
            if (identity != .generated or identity.generated.owner.item != factory.item) return null;
            const item_source = (try itemSource(self.ctx, factory.item)) orelse return error.Unavailable;
            const site = semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) orelse return null;
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

        pub fn stdMemoryFunction(self: @This(), name: []const u8) !?structures.ItemId {
            return standardFunction(self.ctx, .memory_allocation, name);
        }

        pub fn inlineBuiltin(self: @This(), item: structures.ItemId) !?typing.BuiltinBody {
            const symbol = (try self.ctx.get(ExternalSymbol, item)).* orelse return null;
            switch (symbol) {
                .primitive_operation => return .{ .primitive_operation = (try self.ctx.lookupInterned(ItemLocations, item)).name.operation },
                .literal_byte => return .literal_byte,
                else => return null,
            }
        }

        pub fn callBehavior(self: @This(), item: structures.ItemId) !structures.CallBehavior {
            const location = try self.ctx.lookupInterned(ItemLocations, item);
            const names = std.StaticStringMap(structures.CallBehavior).initComptime(.{
                .{ "take", .box_value },
                .{ "append_collection_bounded", .collection_append_bounded },
                .{ "append_collection_growing", .collection_append_growing },
                .{ "append_collection_fallible", .collection_append_growing },
            });
            if (location.owner == null) {
                const behavior = names.get(location.name.text()) orelse return .ordinary;
                return if (item == (try self.stdMemoryFunction(location.name.text()))) behavior else .ordinary;
            }
            const Member = struct { factory: []const u8, name: []const u8, behavior: structures.CallBehavior };
            const members = [_]Member{
                .{ .factory = "Box", .name = "new", .behavior = .box_new },
                .{ .factory = "List", .name = "new", .behavior = .list_new },
                .{ .factory = "List", .name = "append", .behavior = .list_append },
                .{ .factory = "List", .name = "reserve", .behavior = .list_reserve },
            };
            for (members) |member| {
                if (!std.mem.eql(u8, location.name.text(), member.name)) continue;
                const factory = (try self.stdMemoryFunction(member.factory)) orelse continue;
                if (location.owner != factory) continue;
                const resolved = (try self.genericStructNamespaceMember(.{ .item = factory }, member.name, null)) orelse continue;
                if (resolved.item == item) return member.behavior;
            }
            return .ordinary;
        }

        pub fn listType(self: @This(), element_type: structures.TypeId) !structures.TypeId {
            const factory = (try self.stdMemoryFunction("List")) orelse return error.Unavailable;
            const argument = try self.internCompileTimeValue(.{ .type = element_type });
            return self.specializedStructType(try self.internFunctionInstance(factory, &.{argument}));
        }

        pub fn listElement(self: @This(), type_id: structures.TypeId) !?structures.TypeId {
            return self.facts().listElement(type_id);
        }

        pub fn containsBorrow(self: @This(), type_id: structures.TypeId) !bool {
            return self.facts().containsBorrow(type_id);
        }

        pub fn canStoreBorrow(self: @This(), type_id: structures.TypeId) !bool {
            return self.facts().canStoreBorrow(type_id);
        }

        pub fn canBorrowStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.facts().canBorrowStorageOf(result_type, source_type);
        }

        pub fn canBorrowInlineStorageOf(self: @This(), result_type: structures.TypeId, source_type: structures.TypeId) !bool {
            return self.facts().canBorrowInlineStorageOf(result_type, source_type);
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
            const module = switch (owner_loc.origin) {
                .module => |module| module,
                .entry => |file| (try self.ctx.input(FileModule, file)).*,
            };
            const item = try self.ctx.intern(ItemLocations, .{
                .origin = .{ .module = module },
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
            var needs_contract = signature.result_mode == .reference or try self.canStoreBorrow(signature.return_type);
            for (signature.parameters) |parameter| {
                if (parameter.mode == .ref or parameter.mode == .mut or try self.canStoreBorrow(parameter.type_id)) needs_contract = true;
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
                if (location.origin.module != (try self.ctx.input(FileModule, self.file_id.?)).* and !try self.declarationIsPublic(instance.item)) {
                    try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .private_access);
                    return error.Unavailable;
                }
            }
        }

        pub fn inheritsInitializerFailure(self: @This(), instance: structures.InstanceId) !bool {
            const external = (try self.ctx.get(ExternalSymbol, instance.item)).*;
            if (external == .array_from or external == .initialize_collection or external == .initialize_collection_element) return true;
            const behavior = try self.callBehavior(instance.item);
            if (behavior == .collection_append_bounded or behavior == .collection_append_growing) return true;
            const item_source = (try itemSource(self.ctx, instance.item)) orelse return error.Unavailable;
            if (!item_source.parsed.nodes[item_source.parsed.nodes[item_source.resolved.declaration].data.node_node.b.index()].is_converter) return false;
            const shape = (try self.functionShape(instance.item)) orelse return error.Unavailable;
            for (shape.parameters) |parameter| if (parameter.mode == .init) return true;
            return false;
        }

        pub fn needsInheritedInference(self: @This(), instance: structures.InstanceId) !bool {
            const location = try self.ctx.lookupInterned(ItemLocations, instance.item);
            if (location.owner == null) return false;
            const arity = (try self.ctx.get(SpecializationArity, instance.item)).* orelse return error.Unavailable;
            const count = if (instance.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len
            else
                0;
            return count < arity.inherited;
        }

        pub fn isGenericStruct(self: @This(), item_id: structures.ItemId) !bool {
            const location = try self.ctx.lookupInterned(ItemLocations, item_id);
            if (location.kind != .function) return false;
            const item_source = (try itemSource(self.ctx, item_id)) orelse return false;
            return semantic.parameterizedStructSite(&item_source.parsed, item_source.resolved.declaration) != null;
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

        pub fn internByteString(self: @This(), bytes: []const u8) !structures.ByteStringId {
            return self.ctx.intern(ByteStrings, .{ .bytes = bytes });
        }

        pub fn byteString(self: @This(), id: structures.ByteStringId) ![]const u8 {
            return (try self.ctx.lookupInterned(ByteStrings, id)).bytes;
        }

        pub fn stringType(self: @This()) !structures.TypeId {
            return self.textType(.String);
        }

        pub fn staticStringType(self: @This()) !structures.TypeId {
            return self.textType(.StaticString);
        }

        pub fn isStaticString(self: @This(), type_id: structures.TypeId) !bool {
            return self.facts().isStaticString(type_id);
        }

        pub fn textType(self: @This(), name: TextType.Name) !structures.TypeId {
            return (try self.ctx.get(TextType, name)).* orelse error.Unavailable;
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
                .returned => true,
                .failure => false,
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
                        .type => |type_id| if (try self.typeNamespaceMember(type_id, name, span) == null) {
                            if (std.meta.stringToEnum(structures.OwnershipMember, name) != null) return false;
                            switch (try self.conversionMember(type_id, name, span)) {
                                .missing, .ambiguous, .constrained => return false,
                                .function => {},
                            }
                        },
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
            var owner = self.instance orelse unreachable;
            owner.environment = try self.staticEnvironment();
            const resolved = (try self.ctx.get(ResolveItem, owner.item)).* orelse return error.Unavailable;
            const node_offset = @as(i64, node.index()) - @as(i64, resolved.declaration);
            return internGeneratedStructType(self.ctx, .{ .owner = owner, .node_offset = node_offset });
        }

        fn staticParameter(self: @This(), name: []const u8) !?structures.CompileTimeValueId {
            for (try self.staticBindings()) |binding| if (std.mem.eql(u8, binding.name, name)) return binding.value;
            var instance = self.instance orelse return null;
            var arguments: []const structures.CompileTimeValueId = if (instance.specialization) |tuple|
                (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values
            else if (self.prior_static_arguments != null)
                &.{}
            else
                return null;
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
            const inherited = if (instance.specialization) |tuple| (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
            const combined = try self.ctx.allocator().alloc(structures.CompileTimeValueId, inherited.len + arguments.len);
            defer self.ctx.allocator().free(combined);
            @memcpy(combined[0..inherited.len], inherited);
            @memcpy(combined[inherited.len..], arguments);
            var specialized = try self.internFunctionInstance(instance.item, combined);
            specialized.environment = instance.environment;
            return specialized;
        }

        pub fn resolveLocalConflict(self: @This(), name: []const u8) !?structures.ItemId {
            const module = (try self.ctx.input(FileModule, self.file_id.?)).*;
            const declarations = (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
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
                const module = switch (location.origin) {
                    .module => |module| module,
                    .entry => return false,
                };
                const scope = if (location.owner) |owner| scope: {
                    const owner_location = try self.ctx.lookupInterned(ItemLocations, owner);
                    const identity: NamespaceIdentity = if (owner_location.kind == .primitive)
                        .{ .primitive = owner }
                    else if (location.source_site) |site|
                        .{ .generated = .{ .owner = .{ .item = owner }, .node_offset = site } }
                    else
                        .{ .declared = owner };
                    break :scope (try self.ctx.get(TypeNamespace, identity)).* orelse return error.Unavailable;
                } else (try self.ctx.get(ModuleDeclarations, module)).* orelse return error.Unavailable;
                const entry = scope.resolveName(location.name) orelse return error.Unavailable;
                std.debug.assert(entry.item_id == current);
                if (!entry.is_public) return false;
                current = location.owner orelse return true;
            }
        }

        pub fn isPublicType(self: @This(), type_id: structures.TypeId) anyerror!bool {
            return self.publicType(type_id, false);
        }

        pub fn isPublicFieldType(self: @This(), type_id: structures.TypeId) anyerror!bool {
            return self.publicType(type_id, true);
        }

        fn publicType(self: @This(), type_id: structures.TypeId, allow_type_arguments: bool) anyerror!bool {
            if (allow_type_arguments) if (self.instance) |instance| if (instance.specialization) |tuple| {
                for ((try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values) |argument| {
                    const value = (try self.ctx.lookupInterned(CompileTimeValues, argument)).*;
                    if (value == .type and value.type == type_id) return true;
                }
            };
            if (type_id.isPrimitive()) return true;
            if (try self.facts().borrowElement(type_id)) |element| return self.publicType(element, allow_type_arguments);
            const data = (try self.ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return error.Unavailable;
            switch (data.*) {
                .structure => |identity| {
                    if (!try self.declarationIsPublic(structOwnerItem(identity))) return false;
                    if (identity == .generated) {
                        if (identity.generated.owner.specialization) |tuple| {
                            const arguments = (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
                            for (arguments) |argument| {
                                const value = (try self.ctx.lookupInterned(CompileTimeValues, argument)).*;
                                if (value == .type and !try self.publicType(value.type, allow_type_arguments)) return false;
                            }
                        }
                    }
                    return true;
                },
                .variant => |variant| {
                    for (variant.members) |member| {
                        if (!try self.publicType(member, allow_type_arguments)) return false;
                    }
                    return true;
                },
                .callable => |callable| {
                    for (callable.parameters) |parameter| {
                        if (!try self.publicType(parameter.type_id, allow_type_arguments)) return false;
                    }
                    return self.publicType(callable.return_type, allow_type_arguments);
                },
                .array => |array| return self.publicType(array.element_type, allow_type_arguments),
                .tuple => |tuple| {
                    for (tuple.members) |member| if (!try self.publicType(member.type_id, allow_type_arguments)) return false;
                    return true;
                },
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

        pub fn resolveMember(self: @This(), reference: structures.NameReference, name: []const u8, span: structures.SourceSpan) !?structures.NameReference {
            return self.resolveMemberWithOperands(reference, name, span, null);
        }

        pub fn resolveMemberWithOperands(self: @This(), reference: structures.NameReference, name: []const u8, span: structures.SourceSpan, operands: ?usize) !?structures.NameReference {
            switch (reference) {
                .namespace => |namespace| return try self.moduleMember(namespace, name, span),
                .declaration => |item| {
                    if (try self.isGenericStruct(item.item)) {
                        const source = (try itemSource(self.ctx, item.item)) orelse return null;
                        const site = semantic.parameterizedStructSite(&source.parsed, source.resolved.declaration) orelse return null;
                        const namespace = (try self.ctx.get(TypeNamespace, .{ .generated = .{ .owner = item, .node_offset = site } })).* orelse return error.Unavailable;
                        if (try self.namespaceReference(namespace, item.specialization, item.environment, name, span, operands)) |member| return member;
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
                const namespace = (try self.ctx.get(TypeNamespace, association.query_key)).* orelse return error.Unavailable;
                if (try self.namespaceReference(namespace, association.specialization, association.environment, name, span, operands)) |member| return member;
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
            const target_value = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (try self.staticItem(instance)) orelse return .missing,
                .namespace, .overloaded_function => return .missing,
            };
            const target = try self.lookupCompileTimeValue(target_value);
            if (target != .type) return .missing;
            // A static-source converter needs a concrete value for specialization;
            // its unspecialized declaration cannot be a first-class function.
            if (!try self.facts().isRuntimeCapable(source_type) and try self.collectionLiteralType(source_type) == null) return .missing;
            const candidates = try self.conversionCandidates(source_type, target.type, null);
            var selected: ?structures.InstanceId = null;
            for (candidates) |candidate| {
                // Widening into a target variant does not declare a converter to
                // that variant. Likewise, lookup synthesizes no identity adapter.
                if (candidate.target_type != target.type) continue;
                if (selected != null) return .{ .ambiguous = target.type };
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

        fn namespaceReference(self: @This(), namespace: structures.ModuleScope, specialization: ?structures.CompileTimeValueTupleId, environment: ?structures.CompileTimeBindingsId, spelling: []const u8, span: structures.SourceSpan, operands: ?usize) !?structures.NameReference {
            const first_name = structures.Name.fromText(spelling, 1);
            const second_name = structures.Name.fromText(spelling, 2);
            if (structures.Name.order(first_name, second_name) == .eq) {
                return try self.declarationReference(.{ .item = (try self.visibleTypeMember(namespace, first_name, span)) orelse return null, .specialization = specialization, .environment = environment });
            }
            const first = namespace.resolveName(first_name);
            const second = namespace.resolveName(second_name);
            if (first == null and second == null) return null;
            if (operands) |count| {
                var selected: ?structures.ModuleScope.Entry = null;
                for ([_]?structures.ModuleScope.Entry{ first, second }) |optional| {
                    const entry = optional orelse continue;
                    if (entry.kind == .overload)
                        return try self.declarationReference(.{ .item = (try self.visibleTypeMember(namespace, entry.name, span)).?, .specialization = specialization, .environment = environment });
                    const shape = (try self.functionShape(entry.item_id)) orelse return error.Unavailable;
                    if (count != entry.name.operation.operandCount() and count != shape.parameters.len) continue;
                    if (selected != null) {
                        try rejectImport(self.ctx, .{ .file_id = self.file_id.?, .span = span }, .ambiguous_operation_reference);
                        return error.Unavailable;
                    }
                    selected = entry;
                }
                const entry = selected orelse return null;
                return try self.declarationReference(.{ .item = (try self.visibleTypeMember(namespace, entry.name, span)).?, .specialization = specialization, .environment = environment });
            }
            if (first != null and second != null) return .{ .overloaded_function = try self.ctx.intern(FunctionOverloads, .{ .candidates = &.{
                .{ .item = first.?.item_id, .specialization = specialization, .environment = environment },
                .{ .item = second.?.item_id, .specialization = specialization, .environment = environment },
            } }) };
            const entry = first orelse second.?;
            return try self.declarationReference(.{ .item = (try self.visibleTypeMember(namespace, entry.name, span)).?, .specialization = specialization, .environment = environment });
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
            const importer = (try self.ctx.input(FileModule, self.file_id.?)).*;
            const exported = (try resolveModuleExport(self.ctx, importer, namespace.module, name, origin, &visited)) orelse return error.Unavailable;
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
                    break :identity .fromStruct((try self.ctx.lookupInterned(Types, type_id.interned().?)).structure);
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
            const supplied = if (instance.specialization) |tuple| (try self.ctx.lookupInterned(CompileTimeValueTuples, tuple)).values.len else 0;
            if (supplied != arity.total()) return null;
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

fn lookupVariantMembers(ctx: anytype, type_id: structures.TypeId) !?[]const structures.TypeId {
    if (type_id.isPrimitive()) return null;
    const interned_id = type_id.interned() orelse unreachable;
    const data = (try ctx.lookupInternedAs(Types, interned_id)) orelse return null;
    return switch (data.*) {
        .variant => |variant| variant.members,
        .reference, .callable, .structure, .array, .tuple => null,
    };
}

fn lookupCallable(ctx: anytype, type_id: structures.TypeId) !?structures.CallableType {
    if (type_id.isPrimitive()) return null;
    const interned_id = type_id.interned() orelse unreachable;
    const data = (try ctx.lookupInternedAs(Types, interned_id)) orelse return null;
    return switch (data.*) {
        .reference, .variant, .structure, .array, .tuple => null,
        .callable => |callable| callable,
    };
}

fn lookupArrayType(ctx: anytype, type_id: structures.TypeId) !?structures.ArrayType {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
    return switch (data.*) {
        .array => |array| array,
        .reference, .variant, .callable, .structure, .tuple => null,
    };
}

pub const RuntimeCapable = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?bool;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        std.debug.assert(!type_id.isPrimitive());
        return (TypeFacts(@TypeOf(ctx)){ .ctx = ctx }).runtimeCapableUncached(type_id);
    }
};

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
        if (try storageCursorAccessType(ctx, type_id) != null) return .{ .byte_size = 8, .byte_alignment = 8 };
        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
        switch (data.*) {
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

pub const VariantLayout = struct {
    pub const profile_category: profiling.Category = .type_facts;
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

pub const TupleDefinition = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        const members = (try facts.tupleMembers(type_id)) orelse return null;
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
};

pub const StructLayout = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?structures.StructLayout;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
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
};

pub const ArgumentPassing = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?structures.ArgumentPassing;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        return facts.argumentPassingUncached(type_id);
    }
};

pub const BorrowShape = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?struct { contains: bool, stores: bool };

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
        _ = (try facts.ownershipCapabilities(type_id)) orelse return null;
        var visited: std.ArrayList(structures.TypeId) = .empty;
        defer visited.deinit(ctx.allocator());
        const contains = try facts.containsBorrowAt(type_id, &visited, false);
        visited.clearRetainingCapacity();
        const stores = try facts.containsBorrowAt(type_id, &visited, true);
        return .{ .contains = contains, .stores = stores };
    }
};

pub const OwnershipCapabilities = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.TypeId;
    pub const Output = ?structures.OwnershipCapabilities;

    pub fn run(ctx: anytype, type_id: Input) anyerror!Output {
        if (type_id.isPrimitive()) return trivialOwnership();

        const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse return null;
        return switch (data.*) {
            .callable, .reference => trivialOwnership(),
            .variant => |variant| variantOwnership(ctx, variant.members),
            .structure => |identity| structOwnership(ctx, identity),
            .array => |array| arrayOwnership(ctx, array),
            .tuple => |tuple| tupleOwnership(ctx, tuple),
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
        fields.needs_custom_move = fields.needs_custom_move or child.needs_custom_move;
        fields.needs_custom_copy = fields.needs_custom_copy or child.needs_custom_copy;
        fields.needs_automatic_drop = fields.needs_automatic_drop or child.needs_automatic_drop;
        fields.requires_explicit_drop = fields.requires_explicit_drop or child.requires_explicit_drop;
    }

    fn arrayOwnership(ctx: anytype, array: structures.ArrayType) !?structures.OwnershipCapabilities {
        var fields = trivialOwnership();
        if (array.length != 0) includeOwnership(&fields, (try ctx.get(OwnershipCapabilities, array.element_type)).* orelse return null);
        return fields;
    }

    fn variantOwnership(ctx: anytype, members: []const structures.TypeId) !?structures.OwnershipCapabilities {
        var fields = trivialOwnership();
        for (members) |member| includeOwnership(&fields, (try ctx.get(OwnershipCapabilities, member)).* orelse return null);
        fields.needs_custom_move = fields.move != .none and fields.needs_custom_move;
        fields.needs_custom_copy = fields.copy != .none and fields.needs_custom_copy;
        if (fields.move != .none) fields.move = .fieldwise;
        if (fields.copy != .none) fields.copy = .fieldwise;
        return fields;
    }

    fn tupleOwnership(ctx: anytype, tuple: structures.TupleType) !?structures.OwnershipCapabilities {
        var fields = trivialOwnership();
        for (tuple.members) |member| {
            if (member.kind == .reference) continue;
            includeOwnership(&fields, (try ctx.get(OwnershipCapabilities, member.type_id)).* orelse return null);
        }
        return fields;
    }

    fn structOwnership(ctx: anytype, identity: structures.StructIdentity) !?structures.OwnershipCapabilities {
        var visited: StructVisits = .empty;
        defer visited.deinit(ctx.allocator());
        if (!try validateStructContainment(ctx, identity, &visited)) return null;
        const definition = (try getStructDefinition(ctx, identity)) orelse return null;

        var fields = trivialOwnership();
        for (definition.fields) |field| {
            if (field.kind == .owned) includeOwnership(&fields, (try ctx.get(OwnershipCapabilities, field.type_id)).* orelse return null);
        }

        const move: structures.MoveCapability = if (definition.ownership.move) |property| blk: {
            if ((property.capability == .trivial and fields.move != .trivial) or
                (property.capability == .fieldwise and fields.move == .none))
            {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_move else .fieldwise_move);
                return null;
            }
            if (property.capability == .custom and fields.move == .none) {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, .custom_move);
                return null;
            }
            break :blk property.capability;
        } else if (fields.move != .none) .fieldwise else .none;
        const copy: structures.CopyCapability = if (definition.ownership.copy) |property| blk: {
            if ((property.capability == .trivial and fields.copy != .trivial) or
                (property.capability == .fieldwise and fields.copy == .none))
            {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, if (property.capability == .trivial) .trivial_copy else .fieldwise_copy);
                return null;
            }
            break :blk property.capability;
        } else .none;
        const drop: structures.DropCapability = if (definition.ownership.drop) |property| blk: {
            if (property.capability == .trivial and fields.drop != .trivial) {
                try emitIncompatibleOwnershipProperty(ctx, identity, property.span, .trivial_drop);
                return null;
            }
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
    if (type_id.isPrimitive()) return true;
    const data = (try ctx.lookupInternedAs(Types, type_id.interned().?)) orelse unreachable;
    return switch (data.*) {
        .callable, .reference => true,
        .array => |array| validateContainedType(ctx, array.element_type, file_id, span, visited),
        .variant => |variant| blk: {
            for (variant.members) |member| {
                if (!try validateContainedType(ctx, member, file_id, span, visited)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            for (tuple.members) |member| {
                if (member.kind == .owned and !try validateContainedType(ctx, member.type_id, file_id, span, visited)) break :blk false;
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
    pub const profile_category: profiling.Category = .declarations;
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
                    const primitive = if (owner == null) std.meta.stringToEnum(structures.TypeId, segment) else null;
                    owner = try ctx.intern(ItemLocations, .{
                        .origin = .{ .module = module },
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
    pub const profile_category: profiling.Category = .declarations;
    pub const disk_boundary = true;
    pub const Input = structures.ModuleId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, module: Input) anyerror!Output {
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
};

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

pub const ConverterHeads = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = structures.ItemId;
    pub const Output = ?struct { source: ConverterHead, target: ConverterHead };

    pub fn run(ctx: anytype, item: Input) !Output {
        const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
        const declaration = try analysis.declarationContext(.{ .item = item }, &.{});
        const source = semantic.converterIndexSource(&declaration.parsed, declaration.source, declaration.resolved.declaration);
        const target = semantic.functionReturnTypeNode(&declaration.parsed, declaration.resolved.declaration) orelse return null;
        return .{
            .source = if (source) |annotation| try converterAnnotationHead(ctx, declaration, annotation, true) else .any,
            .target = try converterAnnotationHead(ctx, declaration, target, false),
        };
    }
};

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
pub const ConverterBucket = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Input = struct { module: structures.ModuleId, source: ConverterHead, target: ConverterHead, requester: structures.ModuleId };
    pub const Output = ?[]const structures.ItemId;
    pub const eqlOutput = value_operations.Owned(Output).eql;

    pub fn run(ctx: anytype, key: Input) !Output {
        const entries = (try ctx.get(ModuleConverterIndex, key.module)).* orelse return null;
        var lower: usize = 0;
        var upper = entries.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (entries[middle].orderKey(key.source, key.target) == .lt) lower = middle + 1 else upper = middle;
        }
        var items: std.ArrayList(structures.ItemId) = .empty;
        for (entries[lower..]) |entry| {
            if (entry.orderKey(key.source, key.target) != .eq) break;
            if (entry.is_public or key.module == key.requester) try items.append(ctx.allocator(), entry.item);
        }
        return try items.toOwnedSlice(ctx.allocator());
    }
};

fn conversionTypeHead(ctx: anytype, type_id: structures.TypeId) !ConverterHead {
    if (type_id.isPrimitive()) return .{ .primitive = type_id };
    const data = (try ctx.lookupInterned(Types, type_id.interned().?)).*;
    return switch (data) {
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

pub const ConversionCandidates = struct {
    pub const profile_category: profiling.Category = .conversion_matching;
    pub const disk_boundary = true;
    pub const Input = struct { source: ConversionSource, target: structures.TypeId, requester: structures.ModuleId };
    pub const Output = ?[]const structures.ConversionCandidate;
    pub const eqlOutput = value_operations.Owned(Output).eql;

    pub fn run(ctx: anytype, key: Input) anyerror!Output {
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
};

pub const TextType = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Name = enum { String, StaticString, StringView };
    pub const Input = Name;
    pub const Output = ?structures.TypeId;

    pub fn run(ctx: anytype, name: Input) anyerror!Output {
        const registered = (try standardFile(ctx, .text)) orelse return null;
        const module = try ctx.intern(ModulePaths, .{ .path = standard_library.File.text.modulePath() });
        const scope = (try ctx.get(ModuleDeclarations, module)).* orelse return null;
        const item = scope.resolveStatic(@tagName(name)) orelse return null;
        const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
        std.debug.assert(resolved.file_id == registered);
        const type_id = try internStructType(ctx, item);
        if (name == .StaticString and try staticStringBytesType(ctx, type_id) == null) return null;
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
pub const ConverterMatch = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = struct { item: structures.ItemId, source: ConversionSource, target: structures.TypeId };
    pub const Output = union(enum) { mismatch, candidate: structures.ConversionCandidate };

    pub fn run(ctx: anytype, key: Input) anyerror!Output {
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
            const collection = (try analysis.collectionLiteralType(signature.parameters[0].type_id)) orelse return .mismatch;
            if (collection.length != count) return .mismatch;
        } else if (signature.parameters.len != 0 and !try semantic.canWidenTo(analysis, source_type.?, signature.parameters[0].type_id)) return .mismatch;
        const static_source = source_value != null and !try analysis.facts().isRuntimeCapable(source_type.?);
        if (signature.parameters.len != @as(usize, if (static_source) 0 else 1) or signature.is_fallible or
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
};

pub const BuildModuleScope = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const disk_boundary = true;
    pub const Input = structures.FileId;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
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
};

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

pub const CollectFileImports = struct {
    pub const profile_category: profiling.Category = .declarations;
    pub const Input = structures.FileId;
    pub const Output = ?structures.ImportDeclarations;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const parsed = (try ctx.get(ParseFile, file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, file_id)).*;
        return try semantic.collectImports(ctx.allocator(), &parsed, source);
    }
};

pub const ResolveFileImports = struct {
    pub const profile_category: profiling.Category = .declarations;
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
    pub const profile_category: profiling.Category = .declarations;
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
            if (entry.is_public and !std.mem.startsWith(u8, entry.name.text(), "$converter")) try names.put(entry.name.text(), {});
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
                const owner_location = try ctx.lookupInterned(ItemLocations, owner);
                if (owner_location.kind == .top_level_entry) {
                    std.debug.assert(owner_location.origin == .entry);
                    if (owner_location.origin.entry != entry.location.file_id) return rejectItem(ctx, entry.location, .invalid_namespace_owner);
                    continue;
                }
                if (owner_location.kind == .primitive) {
                    if (entry.location.file_id != (try standardFile(ctx, .prelude)))
                        return rejectItem(ctx, entry.location, .invalid_namespace_owner);
                    continue;
                }
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
    pub const profile_category: profiling.Category = .declarations;
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
        if (loc.kind != .function) return null;
        const item_source = (try itemSource(ctx, item)) orelse return null;
        if (!semantic.isExternalFunction(&item_source.parsed, item_source.resolved.declaration)) return null;
        const module = switch (loc.origin) {
            .module => |module_id| module_id,
            .entry => return null,
        };
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
        const path = (try ctx.lookupInterned(ModulePaths, module)).path;
        if (!std.mem.eql(u8, path, file.modulePath())) return null;
        const registered = (try standardFile(ctx, file)) orelse return null;
        return if (registered == item_source.resolved.file_id) symbol else null;
    }
};

pub const FunctionShape = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionShape;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .function) return null;
        const item_source = (try itemSource(ctx, item_id)) orelse return null;
        const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
        if (semantic.isExternalFunction(&item_source.parsed, item_source.resolved.declaration) and (try ctx.get(ExternalSymbol, item_id)).* == null) {
            try ctx.emit(structures.Diagnostic, .{
                .file_id = item_source.resolved.file_id,
                .span = nodeSpan(&item_source.parsed, @fromBackingInt(@intCast(item_source.resolved.declaration))),
                .kind = .unsupported_external_declaration,
            });
            return null;
        }
        return availableSemanticValue(ctx, item_source.resolved.file_id, .{ .item = item_id }, semantic.analyzeFunctionShape(&item_source.parsed, source, item_source.resolved.declaration, ctx.allocator()));
    }
};

pub const IndependentConverterTypes = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = structures.ItemId;
    pub const Output = semantic.IndependentConverterTypes;

    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        const analysis: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx };
        const declaration = try analysis.declarationContext(.{ .item = item }, &.{});
        return semantic.analyzeIndependentConverterTypes(&declaration.parsed, declaration.source, declaration.resolved.declaration, declaration.analysis, ctx.allocator());
    }
};

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
    const arguments = if (instance.specialization) |tuple| (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
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

pub const FunctionInstanceSignature = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const disk_boundary = true;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        return validatedFunctionSignature(ctx, instance);
    }
};

pub const FunctionCandidateSignature = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, instance.item);
        if (loc.kind != .function) return null;
        const item_source = (try itemSource(ctx, instance.item)) orelse return null;
        const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
        const specialization = if (instance.specialization) |tuple| (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values else &.{};
        const arity = (try ctx.get(SpecializationArity, instance.item)).* orelse return null;
        // Instances can outlive the source shape that created them.
        if (specialization.len != arity.total()) return null;
        const shape = (try ctx.get(FunctionShape, instance.item)).* orelse return null;
        const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = item_source.resolved.file_id, .instance = instance };
        var signature = (try availableSemanticValue(ctx, item_source.resolved.file_id, instance, semantic.analyzeShapedFunctionSignature(&item_source.parsed, source, item_source.resolved.declaration, specialization[arity.inherited..], shape, analysis_context, ctx.allocator()))) orelse return null;
        var transferred = false;
        defer if (!transferred) signature.deinit(ctx.allocator());
        if (!try validOperationSignature(analysis_context, instance.item, signature)) {
            try ctx.emit(structures.Diagnostic, .{ .file_id = item_source.resolved.file_id, .span = nodeSpan(&item_source.parsed, @fromBackingInt(item_source.resolved.declaration)), .kind = .invalid_operation_signature, .instance = instance });
            return null;
        }
        transferred = true;
        return signature;
    }
};

pub const FunctionSignature = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const disk_boundary = true;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.FunctionSignature;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        return validatedFunctionSignature(ctx, .{ .item = item_id });
    }
};

pub const FunctionConstraints = struct {
    pub const profile_category: profiling.Category = .signatures;
    pub const Input = structures.InstanceId;
    pub const Output = ?struct { failed_condition: ?structures.Node.Index = null };

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        _ = (try ctx.get(FunctionCandidateSignature, instance)).* orelse return null; // Validate the instance's header before its constraints.
        const declaration = (try itemSource(ctx, instance.item)) orelse return null;
        const source = (try ctx.input(SourceText, declaration.resolved.file_id)).*;
        const types: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = declaration.resolved.file_id, .instance = instance };
        return evaluateWhereConditions(ctx, instance, declaration.resolved, &declaration.parsed, source, types);
    }
};

fn validatedFunctionSignature(ctx: anytype, instance: structures.InstanceId) !?structures.FunctionSignature {
    const header = (try ctx.get(FunctionCandidateSignature, instance)).* orelse return null;
    const source = (try itemSource(ctx, instance.item)) orelse return null;
    const types: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = source.resolved.file_id, .instance = instance };
    const signature = try value_operations.Owned(structures.FunctionSignature).clone(ctx.allocator(), header);
    return validateDemandedSignature(ctx, instance, source.resolved, &source.parsed, types, signature);
}

fn lookupFunctionSignature(ctx: anytype, instance: structures.InstanceId) !?structures.FunctionSignature {
    return if (instance.specialization != null or instance.environment != null)
        (try ctx.get(FunctionInstanceSignature, instance)).*
    else
        (try ctx.get(FunctionSignature, instance.item)).*;
}

fn validateDemandedSignature(
    ctx: anytype,
    instance: structures.InstanceId,
    resolved: structures.ResolvedItem,
    parsed: *const structures.Ast,
    analysis_context: anytype,
    result: structures.FunctionSignature,
) !?structures.FunctionSignature {
    var signature = result;
    var transferred = false;
    defer if (!transferred) signature.deinit(ctx.allocator());
    if (semantic.functionWhereConditions(parsed, resolved.declaration).len != 0) {
        const constraints = (try ctx.get(FunctionConstraints, instance)).* orelse return null;
        if (constraints.failed_condition) |condition| {
            try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, condition), .kind = .where_condition_failed, .instance = instance });
            return null;
        }
    }
    const validated = try validateExternalSignature(ctx, instance, resolved.file_id, parsed, resolved.declaration, signature) orelse return null;
    const library_issue = intrinsics.signatureIssue(analysis_context.facts(), try analysis_context.callBehavior(instance.item), validated) catch |err| switch (err) {
        error.Unavailable => return null,
        else => return err,
    };
    if (library_issue) |kind| {
        try ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = nodeSpan(parsed, @fromBackingInt(@intCast(resolved.declaration))), .kind = kind, .instance = instance });
        return null;
    }
    transferred = true;
    return validated;
}

fn validOperationSignature(types: anytype, item: structures.ItemId, signature: structures.FunctionSignature) !bool {
    const location = try types.ctx.lookupInterned(ItemLocations, item);
    if (location.name != .operation) return true;
    return validOperationShape(types, location.owner, location.name.operation, signature);
}

fn validOperationShape(types: anytype, owner: ?structures.ItemId, operation: structures.Operation, signature: structures.FunctionSignature) !bool {
    if (owner == null or signature.parameters.len == 0) return false;
    const association = (try types.typeNamespace(signature.parameters[0].type_id)) orelse return false;
    if (association.query_key.owner() != owner.?) return false;
    return intrinsics.validOperationShape(operation, signature);
}

fn evaluateWhereConditions(
    ctx: anytype,
    instance: structures.InstanceId,
    resolved: structures.ResolvedItem,
    parsed: *const structures.Ast,
    source: []const u8,
    analysis_context: anytype,
) !FunctionConstraints.Output {
    for (semantic.functionWhereConditions(parsed, resolved.declaration)) |condition| {
        var unresolved = (try availableSemanticValue(ctx, resolved.file_id, instance, semantic.buildUnresolvedBody(parsed, source, .{ .where_condition = condition }, analysis_context, ctx.allocator()))) orelse return null;
        defer unresolved.deinit(ctx.allocator());
        var body = (try typing.resolveAndTypeBody(ctx, instance, resolved.file_id, &.{}, .unit, true, .{ .publish_instruction_spans = true, .allow_type_values = true }, analysis_context, unresolved)) orelse return null;
        defer body.deinit(ctx.allocator());
        var arguments: [0]comptime_interpreter.Value = .{};
        var heap: comptime_interpreter.Heap = .init(ctx.allocator());
        defer heap.deinit();
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = instance, .heap = &heap };
        switch (try comptime_interpreter.execute(&body, &arguments, &executor, ctx.allocator())) {
            .returned => {},
            .failure => return .{ .failed_condition = condition },
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

fn validateExternalSignature(ctx: anytype, instance: structures.InstanceId, file_id: structures.FileId, parsed: *const structures.Ast, declaration: u32, signature: structures.FunctionSignature) !?structures.FunctionSignature {
    if (!semantic.isExternalFunction(parsed, declaration)) return signature;
    const item = instance.item;
    const symbol = (try ctx.get(ExternalSymbol, item)).* orelse return null;
    const valid = try intrinsics.validExternalSignature((TypeFacts(@TypeOf(ctx)){ .ctx = ctx }), symbol, signature);
    if (valid) return switch (symbol) {
        .copy_value, .move_value, .array_filled => validateOwnershipSignature(ctx, symbol, signature, file_id, nodeSpan(parsed, @fromBackingInt(@intCast(declaration)))),
        else => signature,
    };
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = nodeSpan(parsed, @fromBackingInt(@intCast(declaration))),
        .instance = instance,
        .kind = .invalid_external_signature,
    });
    return null;
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
    if (!intrinsics.validHostStorage(definition)) return null;
    return try internStructType(ctx, storage_item);
}

const StandardMemoryInstance = struct {
    generated: structures.GeneratedStructIdentity,
    declarations: structures.ModuleScope,
    arguments: []const structures.CompileTimeValueId,
    element_type: structures.TypeId,
};

fn standardMemoryInstance(ctx: anytype, type_id: structures.TypeId, structure: standard_library.Structure) !?StandardMemoryInstance {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return null;
    const generated = switch (data.*) {
        .structure => |identity| switch (identity) {
            .generated => |value| value,
            .declared => return null,
        },
        .reference, .variant, .callable, .array, .tuple => return null,
    };
    const location = try ctx.lookupInterned(ItemLocations, generated.owner.item);
    if (location.owner != null or !std.mem.eql(u8, location.name.text(), structure.declarationName())) return null;
    const file: standard_library.File = if (structure == .collection_literal) .array else .memory_allocation;
    const registered = (try standardFile(ctx, file)) orelse return null;
    const memory_module = try ctx.intern(ModulePaths, .{ .path = file.modulePath() });
    const declarations = (try ctx.get(ModuleDeclarations, memory_module)).* orelse return null;
    const item = declarations.resolveFunction(structure.declarationName()) orelse return null;
    if (generated.owner.item != item) return null;
    const resolved = (try ctx.get(ResolveItem, item)).* orelse return null;
    if (resolved.file_id != registered) return null;
    const tuple = generated.owner.specialization orelse return null;
    const arguments = (try ctx.lookupInterned(CompileTimeValueTuples, tuple)).values;
    if (arguments.len != @as(usize, if (structure == .collection_literal) 2 else 1)) return null;
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
    const storage_type = (try hostStorageType(ctx, instance.declarations)) orelse return null;
    if (!intrinsics.validAllocation(definition, storage_type)) return null;
    return element_type;
}

fn boxElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const instance = (try standardMemoryInstance(ctx, type_id, .Box)) orelse return null;
    const element_type = instance.element_type;
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (!intrinsics.validBox(definition) or
        (try allocationElementType(ctx, definition.fields[0].type_id)) != element_type)
    {
        return null;
    }
    return element_type;
}

fn borrowElementType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const interned = type_id.interned() orelse return null;
    const data = (try ctx.lookupInternedAs(Types, interned)) orelse return error.Unavailable;
    return if (data.* == .reference) data.reference else null;
}

fn spanAccessType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const instance = (try standardMemoryInstance(ctx, type_id, .Span)) orelse return null;
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (!try intrinsics.validSpan((TypeFacts(@TypeOf(ctx)){ .ctx = ctx }), definition, instance.element_type)) return null;
    return instance.element_type;
}

fn staticStringBytesType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
    const definition = (try facts.structDefinition(type_id)) orelse return null;
    if (!try intrinsics.validStaticString(facts, definition)) return null;
    return definition.fields[0].type_id;
}

fn storageCursorAccessType(ctx: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const instance = (try standardMemoryInstance(ctx, type_id, .StorageCursor)) orelse return null;
    const definition = (try ctx.get(GeneratedStructDefinition, instance.generated)).* orelse return null;
    if (!intrinsics.validStorageCursor(definition)) return null;
    return instance.element_type;
}

pub const ResolveStatic = struct {
    pub const profile_category: profiling.Category = .comptime_execution;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.CompileTimeValueId;
    pub fn run(ctx: anytype, item: Input) anyerror!Output {
        return (try ctx.get(ResolveStaticInstance, .{ .item = item })).*;
    }
};

pub const ResolveStaticInstance = struct {
    pub const profile_category: profiling.Category = .comptime_execution;
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
        const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = instance };
        const plan = (try availableSemanticValue(ctx, resolved.file_id, instance, semantic.analyzeStaticDeclaration(&parsed, source, resolved.declaration, analysis_context, ctx.allocator()))) orelse return null;
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
            if (try lookupVariantMembers(ctx, expected_type)) |members| {
                const active_type = if (typed_runtime.value == .variant) typed_runtime.value.variant.member_type else typed_runtime.type_id;
                const payload = if (typed_runtime.value == .variant) typed_runtime.value.variant.payload else value_id;
                const tag = (try semantic.widenedVariantTag(analysis_context, active_type, members)) orelse unreachable;
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
    pub const profile_category: profiling.Category = .body_overhead;
    pub const Input = structures.CompileTimeSite;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, site: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, site.owner.item);
        if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry and loc.kind != .overload) return null;
        const item_source = (try itemSource(ctx, site.owner.item)) orelse return null;
        if (site.node.index() >= item_source.parsed.nodes.len) return null;
        // Static arguments inside an initializer are independent demanded
        // thunks, so a static-owned site is not limited to the initializer root.
        const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
        const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = item_source.resolved.file_id,
            .instance = site.owner,
            .public_annotation = site.public_annotation,
            .static_bindings = if (site.bindings) |environment| (try ctx.lookupInterned(CompileTimeBindings, environment)).bindings else &.{},
        };
        const root: semantic.BodySource = if (site.condition) .{ .where_condition = site.node } else .{ .comptime_expression = site.node };
        var unresolved = (try availableSemanticValue(ctx, item_source.resolved.file_id, site.owner, semantic.buildUnresolvedBody(&item_source.parsed, source, root, analysis_context, ctx.allocator()))) orelse return null;
        defer unresolved.deinit(ctx.allocator());
        return typing.resolveAndTypeBody(
            ctx,
            site.owner,
            item_source.resolved.file_id,
            &.{},
            .unit,
            true,
            .{ .infer_return_type = true, .publish_instruction_spans = true, .allow_type_values = true, .expected_result_type = site.expected_type },
            analysis_context,
            unresolved,
        );
    }
};

/// Traverse once and snapshot each item before its carrier is cleaned or the
/// producer is polled again. Only canonical items cross the query boundary.
pub const ExecuteStaticIteration = struct {
    pub const profile_category: profiling.Category = .comptime_execution;
    pub const Input = structures.CompileTimeSite;
    pub const Output = ?structures.CompileTimeValueTupleId;

    pub fn run(ctx: anytype, site: Input) anyerror!Output {
        const item_source = (try itemSource(ctx, site.owner.item)) orelse return null;
        if (site.node.index() >= item_source.parsed.nodes.len) return null;
        if (item_source.parsed.nodes[site.node.index()].tag != .collection_for) return null;
        const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
        const types: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .instance = site.owner, .file_id = item_source.resolved.file_id, .static_bindings = if (site.bindings) |environment| (try ctx.lookupInterned(CompileTimeBindings, environment)).bindings else &.{} };
        var unresolved = (try availableSemanticValue(ctx, item_source.resolved.file_id, site.owner, semantic.buildUnresolvedBody(&item_source.parsed, source, .{ .static_iteration = site.node }, types, ctx.allocator()))) orelse return null;
        defer unresolved.deinit(ctx.allocator());
        var body = (try typing.resolveAndTypeBody(ctx, site.owner, item_source.resolved.file_id, &.{}, .unit, true, .{ .allow_type_values = true, .publish_instruction_spans = true }, types, unresolved)) orelse return null;
        defer body.deinit(ctx.allocator());
        var heap: comptime_interpreter.Heap = .init(ctx.allocator());
        defer heap.deinit();
        var values: std.ArrayList(structures.CompileTimeValueId) = .empty;
        defer values.deinit(ctx.allocator());
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = site.owner, .heap = &heap, .static_items = &values };
        var arguments: [0]comptime_interpreter.Value = .{};
        const result = try comptime_interpreter.execute(&body, &arguments, &executor, ctx.allocator());
        switch (result) {
            .returned => return try ctx.intern(CompileTimeValueTuples, .{ .values = values.items }),
            .failure => {
                _ = try reportComptimeOutcome(ctx, site, .failure);
                return null;
            },
            .exit => |status| {
                _ = try reportComptimeOutcome(ctx, site, .{ .exit = status });
                return null;
            },
            .execution_error => |issue| {
                try emitComptimeExecutionIssue(ctx, site.owner, site.node, issue);
                return null;
            },
            .reported_error, .unavailable => return null,
        }
    }
};

pub const ExecuteComptimeThunk = struct {
    pub const profile_category: profiling.Category = .comptime_execution;
    pub const Input = structures.CompileTimeSite;
    pub const Output = ?structures.CompileTimeOutcome;

    pub fn run(ctx: anytype, site: Input) anyerror!Output {
        if (!site.condition and (site.expected_type == null or site.expected_type == .type)) {
            const declaration = (try itemSource(ctx, site.owner.item)) orelse return null;
            if (site.node.index() >= declaration.parsed.nodes.len) return null;
            const source = (try ctx.input(SourceText, declaration.resolved.file_id)).*;
            const types: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = declaration.resolved.file_id, .instance = site.owner, .public_annotation = site.public_annotation, .static_bindings = if (site.bindings) |environment| (try ctx.lookupInterned(CompileTimeBindings, environment)).bindings else &.{} };
            const prepared = (try availableSemanticValue(ctx, declaration.resolved.file_id, site.owner, semantic.analyzeStaticTypeCall(&declaration.parsed, source, site.node, types, ctx.allocator()))) orelse return null;
            if (prepared) |instance| {
                const result = (try ctx.get(ExecuteComptimeCall, .{ .instance = instance, .arguments = try ctx.intern(CompileTimeValueTuples, .{ .values = &.{} }) })).* orelse return null;
                switch (result) {
                    .execution_error => return null,
                    .completed => |completed| return reportComptimeOutcome(ctx, site, completed.outcome),
                }
            }
        }
        const body = (try ctx.get(AnalyzeComptimeThunk, site)).* orelse return null;
        var heap: comptime_interpreter.Heap = .init(ctx.allocator());
        defer heap.deinit();
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = site.owner, .heap = &heap };
        var arguments: [0]comptime_interpreter.Value = .{};
        const result = try comptime_interpreter.execute(&body, &arguments, &executor, ctx.allocator());
        return switch (result) {
            .returned => |value| .{ .returned = try internInterpretedValue(ctx, body.return_type, value) },
            .failure => reportComptimeOutcome(ctx, site, .failure),
            .exit => |status| reportComptimeOutcome(ctx, site, .{ .exit = status }),
            .execution_error => |execution_error| blk: {
                try emitComptimeExecutionIssue(ctx, site.owner, site.node, execution_error);
                break :blk null;
            },
            .reported_error => null,
            .unavailable => null,
        };
    }
};

fn reportComptimeOutcome(ctx: anytype, site: structures.CompileTimeSite, outcome: structures.CompileTimeOutcome) !ExecuteComptimeThunk.Output {
    switch (outcome) {
        .returned => {},
        .failure => {
            if (site.condition) return outcome;
            const declaration = (try itemSource(ctx, site.owner.item)) orelse return null;
            try ctx.emit(structures.Diagnostic, .{ .file_id = declaration.resolved.file_id, .span = nodeSpan(&declaration.parsed, site.node), .kind = .compile_time_unhandled_failure });
        },
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

pub const ExecuteComptimeCall = struct {
    pub const profile_category: profiling.Category = .comptime_execution;
    pub const Input = structures.CompileTimeCallKey;
    pub const Output = ?structures.CompileTimeCallOutcome;

    pub fn run(ctx: anytype, key: Input) anyerror!Output {
        const signature = (try lookupFunctionSignature(ctx, key.instance)) orelse return null;
        const argument_tuple = try ctx.lookupInterned(CompileTimeValueTuples, key.arguments);
        if (argument_tuple.values.len != signature.parameters.len) return null;

        const arguments = try ctx.allocator().alloc(comptime_interpreter.Value, argument_tuple.values.len);
        defer ctx.allocator().free(arguments);
        var has_mut_arguments = false;
        for (argument_tuple.values, signature.parameters, arguments) |value_id, parameter, *argument| {
            has_mut_arguments = has_mut_arguments or parameter.mode == .mut or parameter.mode == .ref;
            const value = (try ctx.lookupInterned(CompileTimeValues, value_id)).*;
            const runtime = switch (value) {
                .type => return null,
                .runtime => |runtime| runtime,
            };
            if (runtime.type_id != parameter.type_id) return null;
            argument.* = .{ .runtime = runtime.value };
        }

        var heap: comptime_interpreter.Heap = .init(ctx.allocator());
        defer heap.deinit();
        var executor: ComptimeCallExecutor(@TypeOf(ctx)) = .{ .ctx = ctx, .owner = key.instance, .heap = &heap };
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
            .failure => structures.CompileTimeOutcome.failure,
            .exit => |status| structures.CompileTimeOutcome{ .exit = status },
            .execution_error => |execution_error| {
                try emitComptimeExecutionIssue(ctx, key.instance, null, execution_error);
                return .execution_error;
            },
            .reported_error => return .execution_error,
            .unavailable => null,
        } orelse return null;

        if (!has_mut_arguments or outcome == .exit) return .{ .completed = .{ .outcome = outcome, .arguments = key.arguments } };
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
            const facts: TypeFacts(Context) = .{ .ctx = self.ctx };
            if (signature.result_mode == .reference or try facts.mayContainStorage(signature.return_type)) return self.callTransient(instance, arguments, call_span, storage);
            for (signature.parameters) |parameter| {
                if ((parameter.mode == .mut or parameter.mode == .ref) and try facts.mayContainStorage(parameter.type_id)) return self.callTransient(instance, arguments, call_span, storage);
            }
            return self.call(instance, arguments, call_span);
        }

        pub fn call(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan) anyerror!comptime_interpreter.Result {
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            var has_mut_arguments = false;

            const value_ids = try self.ctx.allocator().alloc(structures.CompileTimeValueId, arguments.len);
            defer self.ctx.allocator().free(value_ids);
            for (arguments, signature.parameters, value_ids) |argument, parameter, *value_id| {
                std.debug.assert(argument == .runtime);
                has_mut_arguments = has_mut_arguments or parameter.mode == .mut or parameter.mode == .ref;
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
            if (count != 1) {
                const mismatch: structures.Diagnostic.TypeMismatch = .{ .expected = target_type, .found = source_type };
                try self.ctx.emit(structures.Diagnostic, .{ .file_id = resolved.file_id, .span = span, .instance = self.owner, .kind = if (count == 0) .{ .local_type_mismatch = mismatch } else .{ .ambiguous_conversion = mismatch } });
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

        fn convertStaticString(self: *@This(), analysis: AnalysisContext(Context), data: structures.ByteStringId, target_type: structures.TypeId, span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const static_string = try analysis.staticStringType();
            var arguments = [_]comptime_interpreter.Value{.{ .runtime = try self.staticString(.{ .type_id = static_string, .data = data }) }};
            if (static_string == target_type) return .{ .returned = arguments[0] };
            if (try semantic.canWidenTo(analysis, static_string, target_type)) return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, static_string, arguments[0], self) };
            const candidates = try analysis.conversionCandidates(static_string, target_type, null);
            if (candidates.len != 1 or candidates[0].source_mode != .imm) {
                const mismatch: structures.Diagnostic.TypeMismatch = .{ .expected = target_type, .found = .string_literal };
                try self.ctx.emit(structures.Diagnostic, .{ .file_id = analysis.file_id.?, .span = span, .instance = self.owner, .kind = if (candidates.len == 0) .{ .local_type_mismatch = mismatch } else .{ .ambiguous_conversion = mismatch } });
                return .reported_error;
            }
            const result = try self.callInStorage(candidates[0].instance, &arguments, span, storage);
            if (result != .returned or candidates[0].target_type == target_type) return result;
            return .{ .returned = try comptime_interpreter.storedVariantValue(target_type, candidates[0].target_type, result.returned, self) };
        }

        fn captureStaticItem(self: *@This(), type_id: structures.TypeId, value: comptime_interpreter.Value, span: ?structures.SourceSpan) !comptime_interpreter.Result {
            const items = self.static_items orelse return .{ .execution_error = .{ .reason = .unsupported_operation, .span = span } };
            const result = try comptime_interpreter.publish(.{ .returned = value }, &.{}, &.{}, self, self.ctx.allocator());
            switch (result) {
                .returned => |item| {
                    try items.append(self.ctx.allocator(), try internInterpretedValue(self.ctx, type_id, item));
                    return .{ .returned = .{ .runtime = .unit } };
                },
                else => return result,
            }
        }

        fn callTransient(self: *@This(), instance: structures.InstanceId, arguments: []comptime_interpreter.Value, call_span: ?structures.SourceSpan, storage: std.mem.Allocator) anyerror!comptime_interpreter.Result {
            const signature = (try lookupFunctionSignature(self.ctx, instance)) orelse return .unavailable;
            std.debug.assert(arguments.len == signature.parameters.len);
            const external = (try self.ctx.get(ExternalSymbol, instance.item)).*;
            if (external) |symbol| {
                if (intrinsics.effect(symbol) == .io) return .{ .execution_error = .{ .reason = .unsupported_operation, .span = call_span } };
                switch (symbol) {
                    .static_iteration_item => return self.captureStaticItem(signature.parameters[0].type_id, arguments[0], call_span),
                    .primitive_operation, .copy_value, .move_value, .array_filled, .array_from, .array_borrow, .borrow, .unsafe_borrow, .unsafe_take, .unsafe_take_box, .unsafe_destroy, .unsafe_destroy_box, .literal_byte, .byte_int, .initialize_collection, .initialize_collection_element, .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => {},
                    .unsafe_initialize => {},
                    .allocate, .allocate_host_storage => return self.allocateStorage(symbol, signature.return_type, arguments, storage),
                    .deallocate, .deallocate_host_storage, .deallocate_box => {
                        comptime_interpreter.releaseAllocation(arguments[0]);
                        return .{ .returned = .{ .runtime = .unit } };
                    },
                    .allocation_count => return .{ .returned = .{ .runtime = .{ .int = comptime_interpreter.allocationCount(arguments[0]) } } },
                    .unsafe_own_box => {
                        const field_type = (try self.structFieldType(signature.return_type, 0)) orelse return .unavailable;
                        return .{ .returned = try comptime_interpreter.ownAllocation(signature.return_type, field_type, arguments[0], storage) };
                    },
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
            const element_type = if (symbol == .allocate) (try allocationElementType(self.ctx, return_type)) orelse return .unavailable else structures.TypeId.byte;
            const layout = (try self.ctx.get(HostTypeLayout, element_type)).*;
            const count = comptime_interpreter.integerValue(arguments[0]);
            return .{ .returned = try self.heap.allocateValue(return_type, element_type, layout.byte_size, count, storage) orelse return .failure };
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
            const span_type = (try staticStringBytesType(self.ctx, constant.type_id)) orelse return error.Unavailable;
            const span = (try (TypeFacts(Context){ .ctx = self.ctx }).structDefinition(span_type)) orelse return error.Unavailable;
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
            return try facts.fieldStorageType(definition.fields[index]);
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
            .integer_overflow => .compile_time_integer_overflow,
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

pub const TypeNamespace = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = NamespaceIdentity;
    pub const Output = ?structures.ModuleScope;

    pub fn run(ctx: anytype, identity: Input) anyerror!Output {
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
        const module = switch (owner_loc.origin) {
            .module => |value| value,
            .entry => |file| (try ctx.input(FileModule, file)).*,
        };
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
                    const declaration = index.resolve(item_id) orelse unreachable;
                    const token = member_parsed.tokens[member_parsed.nodes[declaration].token_index];
                    try ctx.emit(structures.Diagnostic, .{
                        .file_id = file_id,
                        .span = .{ .start = token.loc.start, .end = token.loc.end },
                        .kind = if (reserved) .reserved_ownership_member else .duplicate_struct_member,
                    });
                    return null;
                }
                try appendScopeEntry(ctx, &entries, .{ .name = loc.name, .item_id = item_id, .kind = loc.kind, .is_public = item.is_public });
            }
        }
        return try finishScope(ctx, &entries);
    }
};

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

pub const StructDefinition = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const Input = structures.ItemId;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, item_id: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, item_id);
        if (loc.kind != .structure) return null;
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        // Validate the complete member scope, including qualified declarations.
        _ = (try ctx.get(TypeNamespace, .{ .declared = item_id })).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        const source = (try ctx.input(SourceText, resolved.file_id)).*;
        const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = resolved.file_id, .instance = .{ .item = item_id } };
        return availableSemanticValue(ctx, resolved.file_id, null, semantic.analyzeStructDefinition(&parsed, source, item_id, resolved.declaration, analysis_context, ctx.allocator()));
    }
};

pub const GeneratedStructDefinition = struct {
    pub const profile_category: profiling.Category = .query_other;
    pub const Input = structures.GeneratedStructIdentity;
    pub const Output = ?structures.StructDefinition;

    pub fn run(ctx: anytype, identity: Input) anyerror!Output {
        const loc = try ctx.lookupInterned(ItemLocations, identity.owner.item);
        if (loc.kind != .static and loc.kind != .function and loc.kind != .structure and loc.kind != .top_level_entry) return null;
        const item_source = (try itemSource(ctx, identity.owner.item)) orelse return null;
        const node_position = @as(i64, item_source.resolved.declaration) + @as(i64, identity.node_offset);
        const node_index = std.math.cast(u32, node_position) orelse return null;
        if (node_index >= item_source.parsed.nodes.len or item_source.parsed.nodes[node_index].tag != .@"struct") return null;
        const struct_node: structures.Node.Index = @fromBackingInt(@intCast(node_index));
        const source = (try ctx.input(SourceText, item_source.resolved.file_id)).*;
        const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = item_source.resolved.file_id,
            .instance = identity.owner,
        };
        return availableSemanticValue(ctx, item_source.resolved.file_id, identity.owner, semantic.analyzeGeneratedStructDefinition(&item_source.parsed, source, struct_node, identity, analysis_context, ctx.allocator()));
    }
};

fn getStructDefinition(ctx: anytype, identity: structures.StructIdentity) !?structures.StructDefinition {
    return switch (identity) {
        .declared => |item_id| (try ctx.get(StructDefinition, item_id)).*,
        .generated => |generated| (try ctx.get(GeneratedStructDefinition, generated)).*,
    };
}

/// Recursive reference summaries reach a fixed point within their call component.
/// Acyclic callees use independently cached contracts instead of joining each round.
const ReferenceInference = struct {
    const Entry = struct { instance: structures.InstanceId, contract: ?structures.ReferenceContract = .{} };
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    component: ?[]const structures.InstanceId = null,

    fn request(self: *ReferenceInference, ctx: anytype, instance: structures.InstanceId) !?structures.ReferenceContract {
        if (self.component) |component| {
            var recursive = false;
            for (component) |member| if (std.meta.eql(member, instance)) {
                recursive = true;
                break;
            };
            if (!recursive) return (try ctx.get(InferReferenceContract, instance)).*;
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

pub const InferReferenceContract = struct {
    pub const profile_category: profiling.Category = .type_facts;
    pub const disk_boundary = true;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.ReferenceContract;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        if (!try hasReferenceContractBody(ctx, instance)) return .{};
        const analyzed = ctx.get(AnalyzeFunctionInstance, instance) catch |err| switch (err) {
            error.QueryCycle => null,
            else => return err,
        };
        if (analyzed) |cached| {
            const body = cached.* orelse return null;
            return try value_operations.Owned(structures.ReferenceContract).clone(ctx.allocator(), body.reference_contract);
        }
        const component = (try referenceComponent(ctx, instance)) orelse return null;
        defer ctx.allocator().free(component);
        var inference: ReferenceInference = .{ .allocator = ctx.allocator(), .component = component };
        defer inference.deinit(ctx.allocator());
        _ = try inference.request(ctx, instance);
        const seed = (try ctx.get(ReferenceCallees, instance)).* orelse return null;
        var recursive = component.len > 1;
        for (seed.instances) |callee| if (std.meta.eql(callee, instance)) {
            recursive = true;
            break;
        };
        if (!recursive) {
            var unchanged = true;
            for (seed.instances) |callee| {
                const contract = (try ctx.get(InferReferenceContract, callee)).* orelse return null;
                if (!structures.ReferenceContract.equivalent(contract, .{})) unchanged = false;
            }
            if (unchanged) return try value_operations.Owned(structures.ReferenceContract).clone(ctx.allocator(), seed.initial_contract);
            return analyzeFunctionBody(ctx, true, instance, false, &inference);
        }
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
};

pub const AnalyzeFunctionInstance = struct {
    pub const profile_category: profiling.Category = .body_overhead;
    pub const disk_boundary = true;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        return analyzeFunctionBody(ctx, false, instance, false, null);
    }
};

pub const AnalyzeComptimeFunctionBody = struct {
    pub const profile_category: profiling.Category = .body_overhead;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.FunctionBodyAnalysis;

    pub fn run(ctx: anytype, instance: Input) anyerror!Output {
        return analyzeFunctionBody(ctx, false, instance, true, null);
    }
};

fn analyzeFunctionBody(ctx: anytype, comptime contract_only: bool, instance: structures.InstanceId, allow_type_values: bool, reference_inference: ?*ReferenceInference) !?if (contract_only) structures.ReferenceContract else structures.FunctionBodyAnalysis {
    const loc = try ctx.lookupInterned(ItemLocations, instance.item);
    if (loc.kind == .static or loc.kind == .structure) return null;
    if (loc.kind != .function) std.debug.assert(instance.specialization == null);
    var parameters: []const structures.CallableParameter = &.{};
    var return_type: structures.TypeId = .unit;
    var is_fallible = loc.kind == .top_level_entry;
    var result_mode: structures.ResultMode = .owned;
    if (loc.kind == .function) {
        const signature = (try lookupFunctionSignature(ctx, instance)) orelse return null;
        parameters = signature.parameters;
        return_type = signature.return_type;
        result_mode = signature.result_mode;
        is_fallible = signature.is_fallible;
    }
    if (!allow_type_values and return_type == .type) return null;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    if ((try ctx.get(BuildModuleScope, resolved.file_id)).* == null) return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    const builtin_body: ?typing.BuiltinBody = if ((try ctx.get(ExternalSymbol, instance.item)).*) |symbol| switch (symbol) {
        .primitive_operation => .{ .primitive_operation = loc.name.operation },
        .copy_value => .copy,
        .move_value => .move,
        .array_filled => .array_filled,
        .array_from => .array_from,
        .initialize_collection => .initialize_collection,
        .array_borrow => .array_borrow,
        .borrow => .box_borrow,
        .unsafe_own_box => .box_own,
        .unsafe_borrow => .allocation_borrow,
        .unsafe_take => .allocation_take,
        .unsafe_take_box => .box_take,
        .unsafe_destroy => .allocation_destroy,
        .unsafe_destroy_box => .box_destroy,
        .literal_byte => .literal_byte,
        .empty_cursor => .empty_cursor,
        .array_cursor, .allocation_cursor => .storage_cursor,
        .cursor_offset => .cursor_offset,
        .cursor_element => .cursor_element,
        .cursor_attenuate => .cursor_attenuate,
        .byte_int => .byte_to_int,
        .unsafe_initialize, .initialize_collection_element => .initialize_slot,
        else => null,
    } else null;
    if (loc.kind == .function and semantic.isExternalFunction(&parsed, resolved.declaration) and builtin_body == null) return null;
    const source = (try ctx.input(SourceText, resolved.file_id)).*;
    const analysis_context: AnalysisContext(@TypeOf(ctx)) = .{
        .ctx = ctx,
        .file_id = resolved.file_id,
        .instance = instance,
        .reference_inference = reference_inference,
    };
    var unresolved = (try availableSemanticValue(ctx, resolved.file_id, instance, semantic.buildUnresolvedBody(&parsed, source, switch (loc.kind) {
        .function => .{ .function = .{ .declaration = resolved.declaration, .parameters = parameters } },
        .top_level_entry => .{ .entry = resolved.declaration },
        .static, .structure, .primitive, .overload => unreachable,
    }, analysis_context, ctx.allocator()))) orelse return null;
    defer unresolved.deinit(ctx.allocator());
    var consuming_converter = if (builtin_body) |body| body == .array_from or body == .initialize_collection or body == .initialize_slot else false;
    if (loc.kind == .function and try analysis_context.inheritsInitializerFailure(instance)) consuming_converter = true;
    if (loc.kind == .function and parsed.nodes[parsed.nodes[resolved.declaration].data.node_node.b.index()].is_converter) {
        for (parameters) |parameter| if (parameter.mode == .init) {
            consuming_converter = true;
        };
    }
    const resolve = if (contract_only) typing.resolveAndInferReferenceContract else typing.resolveAndTypeBody;
    return resolve(
        ctx,
        instance,
        resolved.file_id,
        parameters,
        return_type,
        is_fallible,
        .{ .publish_instruction_spans = true, .allow_type_values = allow_type_values, .builtin_body = builtin_body, .consuming_converter = consuming_converter, .result_mode = result_mode, .infer_reference_contract = reference_inference != null },
        analysis_context,
        unresolved,
    );
}

pub const SelectEntry = struct {
    pub const profile_category: profiling.Category = .declarations;
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
    pub const profile_category: profiling.Category = .codegen;
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.CompiledFunction;

    pub fn run(ctx: anytype, instance_id: Input) anyerror!Output {
        if ((try ctx.get(ExternalSymbol, instance_id.item)).*) |symbol| {
            // Only publish code for a declaration with the implementation's signature.
            const signature = (try lookupFunctionSignature(ctx, instance_id)) orelse return null;
            return switch (symbol) {
                .static_iteration_item => null,
                .primitive_operation, .copy_value, .move_value, .array_filled, .array_from, .array_borrow, .borrow, .unsafe_own_box, .unsafe_borrow, .unsafe_take, .unsafe_take_box, .unsafe_destroy, .unsafe_destroy_box, .unsafe_initialize, .literal_byte, .byte_int, .initialize_collection, .initialize_collection_element, .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => try compileTypedFunction(ctx, instance_id),
                .io_read, .io_write => blk: {
                    const types: HostTypes(@TypeOf(ctx)) = .{ .ctx = ctx };
                    break :blk try codegen.compileExternalByteIo(symbol == .io_read, signature, types, ctx.allocator());
                },
                .exit => try codegen.compileExternalExit(ctx.allocator()),
                .panic_message => try codegen.compileExternalPanic(signature, HostTypes(@TypeOf(ctx)){ .ctx = ctx }, ctx.allocator()),
                .allocate_host_storage => try codegen.compileExternalAllocateHostStorage(ctx.allocator()),
                .deallocate_host_storage => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .allocate => blk: {
                    const element_type = (try allocationElementType(ctx, signature.return_type)) orelse unreachable;
                    const resolved = (try ctx.get(ResolveItem, instance_id.item)).* orelse return null;
                    const facts: TypeFacts(@TypeOf(ctx)) = .{ .ctx = ctx };
                    if (!try validateRuntimeType(ctx, facts, element_type, resolved.file_id, null, instance_id)) return null;
                    const layout = (try ctx.get(HostTypeLayout, element_type)).*;
                    break :blk try codegen.compileExternalAllocateHostTypedStorage(ctx.allocator(), layout);
                },
                .deallocate => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
                .allocation_count => blk: {
                    const layout = (try ctx.get(StructLayout, signature.parameters[0].type_id)).* orelse unreachable;
                    break :blk try codegen.compileExternalAllocationCount(ctx.allocator(), layout.field_offsets[1]);
                },
                .deallocate_box => try codegen.compileExternalDeallocateHostStorage(ctx.allocator()),
            };
        }
        return compileTypedFunction(ctx, instance_id);
    }
};

fn compileTypedFunction(ctx: anytype, instance: structures.InstanceId) !?structures.CompiledFunction {
    const body = (try ctx.get(AnalyzeFunctionInstance, instance)).* orelse return null;
    const resolved = (try ctx.get(ResolveItem, instance.item)).* orelse return null;
    if (!try validateRuntimeBody(ctx, &body, resolved.file_id, instance)) return null;
    const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
    var name: std.Io.Writer.Allocating = .init(ctx.allocator());
    defer name.deinit();
    try diagnostic_rendering.writeFunctionName(TypeFacts(@TypeOf(ctx)){ .ctx = ctx }, &name.writer, instance);
    const types: HostTypes(@TypeOf(ctx)) = .{ .ctx = ctx, .trace_source = .{
        .path = (try ctx.input(SourcePath, resolved.file_id)).*,
        .source = (try ctx.input(SourceText, resolved.file_id)).*,
        .line_starts = (try ctx.get(SourceLineStarts, resolved.file_id)).offsets,
        .name = name.writer.buffered(),
        .fallback_span = nodeSpan(&parsed, @fromBackingInt(@intCast(resolved.declaration))),
    } };
    return try codegen.compileFunction(&body, types, ctx.allocator());
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

pub const CollectReachableInstances = struct {
    pub const profile_category: profiling.Category = .query_other;
    pub const Input = structures.FileId;
    pub const Output = ?structures.ReachableInstances;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
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
                if (!result.found_existing) {
                    if (ctx.hasParallelWorkers()) _ = try ctx.spawn(CompileFunction, referenced);
                }
            }
        }

        return .{ .instances = try ctx.allocator().dupe(structures.InstanceId, instances.keys()) };
    }
};

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
                    if (item.loc.kind != .function or !std.mem.startsWith(u8, item.loc.name.text(), "$converter")) continue;
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
    pub const profile_category: profiling.Category = .query_other;
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
        \\static References = Array(Ref(int), 2)
        \\static EmptyReferences = Array(Ref(int), 0)
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
            try std.testing.expect(!len_signature.is_fallible);
            try std.testing.expectEqual(structures.TypeId.int, len_signature.return_type);
            for ([_][]const u8{"get"}) |name| {
                const member = (try analysis.typeNamespaceMember(type_id, name, .{ .start = 0, .end = 0 })).?;
                const signature = (try ctx.get(FunctionInstanceSignature, member)).*.?;
                try std.testing.expect(signature.is_fallible);
                try std.testing.expectEqual(structures.CallBehavior.ordinary, try analysis.callBehavior(member.item));
                try std.testing.expectEqual(@as(usize, 2), signature.parameters.len);
                try std.testing.expectEqual(structures.ParameterMode.ref, signature.parameters[0].mode);
                try std.testing.expectEqual(type_id, signature.parameters[0].type_id);
                try std.testing.expectEqual(structures.ParameterMode.imm, signature.parameters[1].mode);
                try std.testing.expectEqual(structures.TypeId.int, signature.parameters[1].type_id);
                try std.testing.expectEqual(structures.TypeId.int, signature.return_type);
                try std.testing.expectEqual(structures.ResultMode.reference, signature.result_mode);
            }
            for ([_]standard_library.External{ .array_filled, .array_borrow }) |symbol| {
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
