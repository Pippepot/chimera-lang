const std = @import("std");

// Shared compiler structures.
//
// This file is the low-level data boundary used across compiler stages. Keep it
// independent from parser/query/analyzer/codegen modules so shared result types
// can be imported without creating compiler dependency cycles.

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Location = struct { start: u32, end: u32 };

    pub const Tag = enum {
        invalid,
        eof,
        indent,
        dedent,
        identifier,

        equal,
        equal_angle_bracket_right,
        plus,
        minus,
        asterisk,
        slash,
        percent,
        caret,
        pipe,
        ampersand,
        angle_bracket_left,
        angle_bracket_angle_bracket_left,
        angle_bracket_left_angle_bracket_right,
        angle_bracket_right,
        angle_bracket_angle_bracket_right,

        equal_equal,
        plus_equal,
        minus_equal,
        asterisk_equal,
        slash_equal,
        percent_equal,
        caret_equal,
        pipe_equal,
        ampersand_equal,
        angle_bracket_left_equal,
        angle_bracket_angle_bracket_left_equal,
        angle_bracket_right_equal,
        angle_bracket_angle_bracket_right_equal,

        l_brace,
        r_brace,
        l_paren,
        r_paren,
        l_bracket,
        r_bracket,
        question_mark,
        arrow,
        tilde,
        period,
        comma,
        colon,
        semicolon,
        char_literal,
        string_literal,
        number_literal,
        ellipsis2,
        ellipsis3,

        keyword_and,
        keyword_as,
        keyword_break,
        keyword_comptime,
        keyword_const,
        keyword_continue,
        keyword_deinit,
        keyword_init,
        keyword_else,
        keyword_extern,
        keyword_fallible,
        keyword_false,
        keyword_func,
        keyword_for,
        keyword_if,
        keyword_is,
        keyword_loop,
        keyword_mut,
        keyword_not,
        keyword_none,
        keyword_or,
        keyword_imm,
        keyword_return,
        keyword_sizeof,
        keyword_static,
        keyword_struct,
        keyword_test,
        keyword_true,
        keyword_var,
        keyword_where,
        keyword_import,
        keyword_pub,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "and", .keyword_and },
        .{ "as", .keyword_as },
        .{ "break", .keyword_break },
        .{ "comptime", .keyword_comptime },
        .{ "const", .keyword_const },
        .{ "continue", .keyword_continue },
        .{ "deinit", .keyword_deinit },
        .{ "init", .keyword_init },
        .{ "else", .keyword_else },
        .{ "extern", .keyword_extern },
        .{ "fallible", .keyword_fallible },
        .{ "false", .keyword_false },
        .{ "func", .keyword_func },
        .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        .{ "is", .keyword_is },
        .{ "loop", .keyword_loop },
        .{ "mut", .keyword_mut },
        .{ "not", .keyword_not },
        .{ "none", .keyword_none },
        .{ "or", .keyword_or },
        .{ "imm", .keyword_imm },
        .{ "return", .keyword_return },
        .{ "sizeof", .keyword_sizeof },
        .{ "static", .keyword_static },
        .{ "struct", .keyword_struct },
        .{ "test", .keyword_test },
        .{ "true", .keyword_true },
        .{ "var", .keyword_var },
        .{ "where", .keyword_where },
        .{ "import", .keyword_import },
        .{ "pub", .keyword_pub },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }
};

pub const Node = struct {
    tag: Tag,
    token_index: u32,
    data: Data,

    pub const Index = enum(u32) {
        null = 0,
        _,

        pub fn unwrap(self: @This()) ?Index {
            return if (self == .null) null else self;
        }

        pub fn index(self: @This()) u32 {
            return @intFromEnum(self);
        }
    };

    pub const Tag = enum(u8) {
        add,
        sub,
        mul,
        div,
        eq,
        ne,
        lt,
        gt,
        le,
        ge,
        is,
        as,
        @"if",
        if_else,
        loop,
        @"and",
        @"or",
        not,
        neg,
        access,
        implicit_static,
        assign,
        add_assign,
        sub_assign,
        mul_assign,
        div_assign,
        block,
        bool_literal,
        call,
        call_arg_list,
        const_binding,
        var_binding,
        borrow_binding,
        borrow_mut_binding,
        static_binding,
        namespace_declaration,
        comptime_expr,
        field_access,
        deref,
        func,
        identifier,
        none_literal,
        number_literal,
        unit_literal,
        param,
        param_list,
        query_op,
        move_expr,
        break_nothing,
        break_expr,
        continue_expr,
        return_nothing,
        return_expr,
        signature,
        return_origins,
        where_clauses,
        sizeof_expr,
        @"struct",
        struct_field,
        struct_property,
        struct_init,
        struct_init_field,
        type,
        implicit_type,
        type_func,
        type_list,
        type_variant,
        import,
        selective_import,
        @"pub",
        _,
    };

    pub const Data = union {
        none: void,
        node: Index,
        node_node: struct {
            a: Index,
            b: Index,
        },
        signature: struct {
            parameters: Index,
            return_type: Index,
            where_clauses: Index,
        },
        ref: struct {
            start: u32,
            end: u32,
        },
    };
};

pub const Ast = struct {
    file_id: FileId,
    tokens: []Token,
    nodes: []Node,
    node_refs: []Node.Index,

    pub fn nodeList(self: Ast, index: Node.Index) []const Node.Index {
        const node = self.nodes[(index.unwrap() orelse return &.{}).index()];
        switch (node.tag) {
            .param_list, .type_variant, .type_list, .call_arg_list, .where_clauses => {},
            else => unreachable,
        }
        return self.node_refs[node.data.ref.start..node.data.ref.end];
    }

    pub fn eql(a: Ast, b: Ast) bool {
        if (a.file_id != b.file_id) return false;
        if (a.tokens.len != b.tokens.len or a.nodes.len != b.nodes.len or a.node_refs.len != b.node_refs.len) return false;
        for (a.tokens, b.tokens) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.nodes, b.nodes) |left, right| {
            if (left.tag != right.tag or left.token_index != right.token_index) return false;
            switch (left.tag) {
                .break_nothing, .continue_expr, .return_nothing, .access, .implicit_static, .bool_literal, .identifier, .none_literal, .number_literal, .unit_literal, .type, .implicit_type => {},
                .break_expr, .return_expr, .loop, .not, .neg, .query_op, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .deref, .struct_field, .struct_property, .struct_init_field, .@"pub" => {
                    if (left.data.node != right.data.node) return false;
                },
                .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .call, .const_binding, .var_binding, .borrow_binding, .borrow_mut_binding, .static_binding, .namespace_declaration, .func, .param, .return_origins, .type_func, .@"if" => {
                    if (left.data.node_node.a != right.data.node_node.a or left.data.node_node.b != right.data.node_node.b) return false;
                },
                .signature => if (!std.meta.eql(left.data.signature, right.data.signature)) return false,
                .block, .call_arg_list, .param_list, .type_list, .type_variant, .where_clauses, .if_else, .@"struct", .struct_init, .import, .selective_import => {
                    if (left.data.ref.start != right.data.ref.start or left.data.ref.end != right.data.ref.end) return false;
                },
                else => return false,
            }
        }
        return std.mem.eql(Node.Index, a.node_refs, b.node_refs);
    }

    pub fn deinit(self: *Ast, gpa: std.mem.Allocator) void {
        gpa.free(self.tokens);
        gpa.free(self.nodes);
        gpa.free(self.node_refs);
        self.* = undefined;
    }
};

pub const Executable = struct {
    bytes: []const u8,

    pub fn eql(a: Executable, b: Executable) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }

    pub fn deinit(self: *Executable, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

pub const FileId = u64;

pub const ModuleId = enum(u32) { _ };

pub const ModulePath = struct {
    path: []const u8,
};

pub const ItemId = enum(u32) { _ };

pub const OwnershipMember = enum { copy, move };

pub const ItemKind = enum {
    function,
    structure,
    static,
    top_level_entry,
};

/// Interned identities contain no replaceable source locations.
pub const ItemLoc = struct {
    origin: union(enum) { module: ModuleId, entry: FileId },
    owner: ?ItemId = null,
    source_site: ?i64 = null,
    is_hook: bool = false,
    kind: ItemKind,
    name: []const u8,

    pub fn eql(a: ItemLoc, b: ItemLoc) bool {
        return std.meta.eql(a.origin, b.origin) and a.owner == b.owner and
            a.source_site == b.source_site and a.is_hook == b.is_hook and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
    }
};

pub const DiscoveredItem = struct {
    loc: ItemLoc,
    declaration: u32,
    parent: ?u32 = null,
    qualified_owner: ?[]const u8 = null,
    is_public: bool = false,
};

pub const ItemTree = struct {
    file_id: FileId,
    items: []DiscoveredItem,

    pub fn eql(a: ItemTree, b: ItemTree) bool {
        if (a.file_id != b.file_id or a.items.len != b.items.len) return false;
        for (a.items, b.items) |left, right| {
            if (!ItemLoc.eql(left.loc, right.loc) or left.declaration != right.declaration or left.parent != right.parent or
                !optionalStringEql(left.qualified_owner, right.qualified_owner) or left.is_public != right.is_public) return false;
        }
        return true;
    }

    pub fn deinit(self: *ItemTree, gpa: std.mem.Allocator) void {
        for (self.items) |item| {
            gpa.free(item.loc.name);
            if (item.qualified_owner) |owner| gpa.free(owner);
        }
        gpa.free(self.items);
        self.* = undefined;
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const ItemIndex = struct {
    file_id: FileId,
    entries: std.AutoArrayHashMapUnmanaged(ItemId, u32),

    pub fn ids(self: ItemIndex) []const ItemId {
        return self.entries.keys();
    }

    pub fn count(self: ItemIndex) usize {
        return self.entries.count();
    }

    pub fn resolve(self: ItemIndex, item_id: ItemId) ?u32 {
        return self.entries.get(item_id);
    }

    pub fn eql(a: ItemIndex, b: ItemIndex) bool {
        return a.file_id == b.file_id and
            std.mem.eql(ItemId, a.entries.keys(), b.entries.keys()) and
            std.mem.eql(u32, a.entries.values(), b.entries.values());
    }

    pub fn deinit(self: *ItemIndex, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }
};

pub const ModuleScope = struct {
    entries: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        item_id: ItemId,
        kind: ItemKind,
        is_public: bool = false,
    };

    pub fn resolve(self: ModuleScope, name: []const u8) ?ItemId {
        return (self.resolveEntry(name) orelse return null).item_id;
    }

    pub fn resolveFunction(self: ModuleScope, name: []const u8) ?ItemId {
        const entry = self.resolveEntry(name) orelse return null;
        return if (entry.kind == .function) entry.item_id else null;
    }

    pub fn resolveStatic(self: ModuleScope, name: []const u8) ?ItemId {
        const entry = self.resolveEntry(name) orelse return null;
        return if (entry.kind == .static or entry.kind == .structure) entry.item_id else null;
    }

    pub fn resolveEntry(self: ModuleScope, name: []const u8) ?Entry {
        const index = std.sort.binarySearch(Entry, self.entries, name, struct {
            fn compare(target: []const u8, entry: Entry) std.math.Order {
                return std.mem.order(u8, target, entry.name);
            }
        }.compare) orelse return null;
        return self.entries[index];
    }

    pub fn eql(a: ModuleScope, b: ModuleScope) bool {
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |left, right| {
            if (left.item_id != right.item_id or left.kind != right.kind or left.is_public != right.is_public or !std.mem.eql(u8, left.name, right.name)) return false;
        }
        return true;
    }

    pub fn deinit(self: *ModuleScope, gpa: std.mem.Allocator) void {
        for (self.entries) |entry| gpa.free(entry.name);
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub const ModuleItemIndex = struct {
    entries: []Entry,

    pub const Entry = struct { item: ItemId, location: ResolvedItem };

    pub fn resolve(self: ModuleItemIndex, item: ItemId) ?ResolvedItem {
        const index = std.sort.binarySearch(Entry, self.entries, item, struct {
            fn compare(target: ItemId, entry: Entry) std.math.Order {
                return std.math.order(@intFromEnum(target), @intFromEnum(entry.item));
            }
        }.compare) orelse return null;
        return self.entries[index].location;
    }

    pub fn eql(a: ModuleItemIndex, b: ModuleItemIndex) bool {
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |left, right| if (!std.meta.eql(left, right)) return false;
        return true;
    }

    pub fn deinit(self: *ModuleItemIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub const ImportName = struct {
    spelling: []const u8,
    span: SourceSpan,

    pub fn eql(a: ImportName, b: ImportName) bool {
        return std.mem.eql(u8, a.spelling, b.spelling) and std.meta.eql(a.span, b.span);
    }
};

/// Collected syntax owns every spelling; null and empty selections are distinct.
pub const ImportDeclaration = struct {
    path: ImportName,
    alias: ?ImportName,
    selective: ?[]Selection,
    is_public: bool,

    pub const Selection = struct { original: ImportName, bound: ImportName };

    pub fn deinit(self: *ImportDeclaration, gpa: std.mem.Allocator) void {
        gpa.free(self.path.spelling);
        if (self.alias) |alias| gpa.free(alias.spelling);
        if (self.selective) |items| {
            for (items) |item| {
                gpa.free(item.original.spelling);
                gpa.free(item.bound.spelling);
            }
            gpa.free(items);
        }
        self.* = undefined;
    }

    pub fn eql(a: ImportDeclaration, b: ImportDeclaration) bool {
        if (!ImportName.eql(a.path, b.path) or a.is_public != b.is_public) return false;
        if ((a.alias == null) != (b.alias == null)) return false;
        if (a.alias) |alias| if (!ImportName.eql(alias, b.alias.?)) return false;
        if ((a.selective == null) != (b.selective == null)) return false;
        if (a.selective) |items| {
            if (items.len != b.selective.?.len) return false;
            for (items, b.selective.?) |left, right| {
                if (!ImportName.eql(left.original, right.original) or !ImportName.eql(left.bound, right.bound)) return false;
            }
        }
        return true;
    }
};

pub const ImportDeclarations = struct {
    entries: []ImportDeclaration,

    pub fn eql(a: ImportDeclarations, b: ImportDeclarations) bool {
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |left, right| if (!ImportDeclaration.eql(left, right)) return false;
        return true;
    }

    pub fn deinit(self: *ImportDeclarations, gpa: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(gpa);
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub const NamespaceBinding = struct { module: ModuleId, members_visible: bool = true };

pub const NameReference = union(enum) {
    namespace: NamespaceBinding,
    declaration: InstanceId,
    constant: CompileTimeValueId,
};

pub const ImportTarget = union(enum) {
    namespace: NamespaceBinding,
    declaration: ItemId,
};

pub const FileImport = struct {
    name: []const u8,
    target: ImportTarget,
    reexport: bool,
};

pub const FileImports = struct {
    // Full unaliased paths permit child navigation; prefix bindings alone do not.
    modules: []ModuleId,
    imports: []FileImport,

    pub fn eql(a: FileImports, b: FileImports) bool {
        if (!std.mem.eql(ModuleId, a.modules, b.modules)) return false;
        if (a.imports.len != b.imports.len) return false;
        for (a.imports, b.imports) |left, right| {
            if (!std.mem.eql(u8, left.name, right.name) or left.reexport != right.reexport or !std.meta.eql(left.target, right.target)) return false;
        }
        return true;
    }

    pub fn deinit(self: *FileImports, gpa: std.mem.Allocator) void {
        for (self.imports) |binding| gpa.free(binding.name);
        gpa.free(self.imports);
        gpa.free(self.modules);
        self.* = undefined;
    }
};

pub const ResolvedItem = struct {
    file_id: FileId,
    declaration: u32,
};

pub const CompileTimeValue = union(enum) {
    type: TypeId,
    runtime: Runtime,

    pub const Runtime = struct {
        type_id: TypeId,
        value: RuntimeValue,
    };

    pub const RuntimeValue = union(enum) {
        int: i32,
        byte: u8,
        bool: bool,
        unit,
        none,
        function_ref: FunctionReference,
        structure: CompileTimeValueTupleId,
        variant: struct {
            member_type: TypeId,
            payload: CompileTimeValueId,
        },

        pub fn scalarTypeId(self: @This()) ?TypeId {
            return switch (self) {
                .int => .int,
                .byte => .byte,
                .bool => .bool,
                .unit => .unit,
                .none => .none,
                .function_ref => |reference| reference.type_id,
                .structure, .variant => null,
            };
        }
    };
};

/// Session-stable identity of one canonical compile-time value.
pub const CompileTimeValueId = enum(u32) { _ };

/// Session-stable identity of one ordered tuple of canonical compile-time
/// values. Specializations and interpreted calls share this representation.
pub const CompileTimeValueTupleId = enum(u32) { _ };

pub const CompileTimeValueTuple = struct {
    values: []const CompileTimeValueId,
};

/// Result of evaluating one typed compile-time thunk. A returned value is
/// canonical before it crosses the query boundary; failure and compiler
/// control remain execution outcomes rather than value kinds.
pub const CompileTimeOutcome = union(enum) {
    returned: CompileTimeValueId,
    failure,
    exit: i32,
};

/// Result of one memoized interpreted call. Updated ordinary arguments are
/// canonicalized separately so mutable copy-back uses the same query result.
pub const CompileTimeCallOutcome = union(enum) {
    completed: struct {
        outcome: CompileTimeOutcome,
        arguments: CompileTimeValueTupleId,
    },
    execution_error,
};

/// Uncatchable control requested by compile-time execution and handled by the
/// embedding compiler driver rather than rendered as a source diagnostic.
pub const CompilerControl = union(enum) {
    exit: i32,
};

/// Database interner index carried inside a non-primitive TypeId. The remaining
/// TypeId bit distinguishes interned identities from reserved primitive IDs.
pub const InternedTypeId = enum(u31) { _ };

pub const TypeId = enum(u32) {
    int,
    byte,
    bool,
    unit,
    none,
    never,
    type,
    _,

    const interned_mask: u32 = 1 << 31;

    pub fn fromInterned(interned_id: InternedTypeId) TypeId {
        return @enumFromInt(interned_mask | @intFromEnum(interned_id));
    }

    pub fn interned(self: TypeId) ?InternedTypeId {
        const raw = @intFromEnum(self);
        if (raw & interned_mask == 0) return null;
        return @enumFromInt(@as(u31, @truncate(raw)));
    }

    pub fn isPrimitive(self: TypeId) bool {
        return self == .int or self == .bool or self == .unit or self == .none or self == .never or self == .type or self == .byte;
    }
};

pub const VariantType = struct {
    members: []const TypeId,
};

pub const ParameterMode = enum {
    imm,
    static,
    mut,
    @"var",
    deinit,
    init,
};

pub const CallableParameter = struct {
    mode: ParameterMode,
    type_id: TypeId,
};

fn callableParametersEql(a: []const CallableParameter, b: []const CallableParameter) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.mode != right.mode or left.type_id != right.type_id) return false;
    }
    return true;
}

pub const CallableType = struct {
    parameters: []const CallableParameter,
    return_type: TypeId,
    is_fallible: bool,
    return_origins: ?[]const u32 = null,

    pub fn parametersEql(a: CallableType, b: CallableType) bool {
        return callableParametersEql(a.parameters, b.parameters);
    }

    pub fn eql(a: CallableType, b: CallableType) bool {
        return a.return_type == b.return_type and
            a.is_fallible == b.is_fallible and
            (if (a.return_origins) |origins|
                if (b.return_origins) |other| std.mem.eql(u32, origins, other) else false
            else
                b.return_origins == null) and
            a.parametersEql(b);
    }

    pub fn deinit(self: *CallableType, gpa: std.mem.Allocator) void {
        gpa.free(self.parameters);
        if (self.return_origins) |origins| gpa.free(origins);
        self.* = undefined;
    }
};

pub const GeneratedStructIdentity = struct {
    owner: InstanceId,
    node_offset: i64,
};

pub const StructIdentity = union(enum) {
    declared: ItemId,
    generated: GeneratedStructIdentity,
};

pub const TypeData = union(enum) {
    variant: VariantType,
    callable: CallableType,
    structure: StructIdentity,
};

pub const InternVariantResult = union(enum) {
    type_id: TypeId,
    duplicate: TypeId,
};

/// Byte size and alignment in one layout domain. Byte size includes the padding
/// needed for an element stride; the current layout queries resolve the host ABI.
pub const TypeLayout = struct {
    byte_size: u32,
    byte_alignment: u32,
};

pub const ArgumentPassing = enum { direct, indirect };

pub const VariantLayout = struct {
    layout: TypeLayout,
    payload_offset: u32,
};

pub const StructField = struct {
    name: []const u8,
    type_id: TypeId,
    span: SourceSpan,
};

pub const StructDefinition = struct {
    fields: []StructField,
    ownership: StructOwnershipProperties = .{},
    accessible_fields: bool = true,

    pub const ResolvedField = struct {
        index: u32,
        type_id: TypeId,
    };

    pub fn resolveField(self: StructDefinition, name: []const u8) ?ResolvedField {
        for (self.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return .{
                .index = @intCast(index),
                .type_id = field.type_id,
            };
        }
        return null;
    }

    pub fn eql(a: StructDefinition, b: StructDefinition) bool {
        if (a.fields.len != b.fields.len or !std.meta.eql(a.ownership, b.ownership) or a.accessible_fields != b.accessible_fields) return false;
        for (a.fields, b.fields) |left, right| {
            if (left.type_id != right.type_id or
                !std.meta.eql(left.span, right.span) or
                !std.mem.eql(u8, left.name, right.name)) return false;
        }
        return true;
    }

    pub fn deinit(self: *StructDefinition, gpa: std.mem.Allocator) void {
        for (self.fields) |field| gpa.free(field.name);
        gpa.free(self.fields);
        self.* = undefined;
    }
};

pub const StructOwnershipProperties = struct {
    move: ?Property(MoveCapability) = null,
    copy: ?Property(CopyCapability) = null,
    drop: ?Property(DropCapability) = null,

    pub fn Property(comptime Capability: type) type {
        return struct {
            capability: Capability,
            hook: ?InstanceId = null,
            span: SourceSpan,
        };
    }
};

pub const StructLayout = struct {
    layout: TypeLayout,
    field_offsets: []u32,

    pub fn eql(a: StructLayout, b: StructLayout) bool {
        return std.meta.eql(a.layout, b.layout) and std.mem.eql(u32, a.field_offsets, b.field_offsets);
    }

    pub fn deinit(self: *StructLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.field_offsets);
        self.* = undefined;
    }
};

pub const MoveCapability = enum {
    trivial,
    fieldwise,
    custom,
    none,
};

pub const CopyCapability = enum {
    trivial,
    fieldwise,
    custom,
    none,
};

pub const DropCapability = enum {
    trivial,
    fieldwise,
    custom,
    explicit,
};

pub const OwnershipCapabilities = struct {
    move: MoveCapability,
    copy: CopyCapability,
    drop: DropCapability,
    needs_custom_move: bool = false,
    needs_custom_copy: bool = false,
    needs_automatic_drop: bool = false,
    requires_explicit_drop: bool = false,

    pub fn isDirectlyMovable(self: OwnershipCapabilities) bool {
        return self.move != .none and !self.needs_custom_move;
    }
};

pub const FunctionValueId = enum(u32) { _ };
pub const FunctionBlockId = enum(u32) { _ };

pub const FunctionValueRange = struct {
    start: u32,
    end: u32,
};

pub const invalid_variant_tag = std.math.maxInt(u32);

pub fn functionInstructionValue(argument_count: usize, instruction_index: usize) FunctionValueId {
    return @enumFromInt(argument_count + instruction_index);
}

pub const BinaryOperands = struct {
    lhs: FunctionValueId,
    rhs: FunctionValueId,
};

pub const FunctionValueUse = struct {
    value: FunctionValueId,
    coerce_to: ?TypeId = null,
    variant_tag_mapping: ?FunctionValueRange = null,
};

pub const FunctionCallArgument = union(enum) {
    prepared: FunctionValueUse,
    deinit: FunctionValueId,
    initializer: FunctionValueId,

    pub fn valueUse(self: @This()) FunctionValueUse {
        return switch (self) {
            .prepared => |use| use,
            .deinit, .initializer => |source| .{ .value = source },
        };
    }

    pub fn valueId(self: @This()) FunctionValueId {
        return self.valueUse().value;
    }

    pub fn operand(self: *@This()) *FunctionValueId {
        return switch (self.*) {
            .prepared => |*use| &use.value,
            .deinit, .initializer => |*source| source,
        };
    }
};

pub const PredicateOperation = enum {
    lti,
    gti,
    lei,
    gei,
    eqi,
    nei,
    eqb,
    neb,
    eqt,
    net,
};

pub const FunctionBranch = struct {
    target: FunctionBlockId,
    arguments: FunctionValueRange,
};

pub const CallOutcome = enum(u8) { failure = 0, success = 1, lexical_exit = 2 };

pub const FunctionTerminator = union(enum) {
    branch: FunctionBranch,
    predicate_branch: struct {
        operation: PredicateOperation,
        operands: BinaryOperands,
        then_branch: FunctionBranch,
        else_branch: FunctionBranch,
    },
    fallible_call: struct {
        call: FunctionCall,
        success: FunctionBlockId,
        failure: ?FunctionBlockId,
        lexical_exit: ?FunctionBlockId = null,
    },
    continuation_branch: struct {
        token: FunctionValueId,
        target: FunctionValueId,
        match: FunctionBlockId,
        mismatch: FunctionBlockId,
    },
    return_unit,
    return_value: FunctionValueUse,
    return_failure,
    return_lexical: FunctionValueId,
    diverge,

    pub fn operands(self: *FunctionTerminator) [2]?*FunctionValueId {
        return switch (self.*) {
            .predicate_branch => |*branch| .{ &branch.operands.lhs, &branch.operands.rhs },
            .fallible_call => |*fallible| fallible.call.operands(),
            .continuation_branch => |*branch| .{ &branch.token, &branch.target },
            .return_lexical => |*token| .{ token, null },
            .return_value => |*use| .{ &use.value, null },
            .branch, .return_unit, .return_failure, .diverge => .{ null, null },
        };
    }

    pub fn successors(self: *FunctionTerminator) [3]?*FunctionBlockId {
        return switch (self.*) {
            .branch => |*branch| .{ &branch.target, null, null },
            .predicate_branch => |*branch| .{ &branch.then_branch.target, &branch.else_branch.target, null },
            .fallible_call => |*call| callSuccessors(call),
            .continuation_branch => |*branch| .{ &branch.match, &branch.mismatch, null },
            .return_unit, .return_value, .return_failure, .return_lexical, .diverge => .{ null, null, null },
        };
    }

    pub fn successorCount(self: FunctionTerminator) u2 {
        var terminator = self;
        const targets = terminator.successors();
        return @as(u2, @intFromBool(targets[0] != null)) + @intFromBool(targets[1] != null) + @intFromBool(targets[2] != null);
    }

    fn callSuccessors(call: *@FieldType(FunctionTerminator, "fallible_call")) [3]?*FunctionBlockId {
        var targets: [3]?*FunctionBlockId = .{ null, null, null };
        var count: usize = 0;
        if (call.call.return_type != .never) {
            targets[count] = &call.success;
            count += 1;
        }
        if (call.failure) |*failure| {
            targets[count] = failure;
            count += 1;
        }
        if (call.lexical_exit) |*lexical| targets[count] = lexical;
        return targets;
    }
};

pub const FunctionBlock = struct {
    argument_start: u32 = 0,
    argument_end: u32 = 0,
    instruction_start: u32,
    instruction_end: u32,
    terminator: FunctionTerminator,
};

pub const ValueRepresentation = enum { value, storage, initializer, continuation };

pub const FunctionBlockArgument = struct {
    type_id: TypeId,
    /// Pending construction and selected storage are independent of T's layout
    /// and movement capabilities.
    representation: ValueRepresentation = .value,
};

/// Function-signature query outputs own `parameters`; interned callable types
/// clone the same value shape into session-stable storage.
pub const FunctionSignature = CallableType;

pub const CallBehavior = enum {
    ordinary,
    box_new,
    box_value,
    box_borrow,
    box_borrow_mut,
    local_borrow,
    allocation_element_borrow,
    reference_read,
    reference_write,
    reference_attenuate,
    box_destroy,
    allocation_destroy,
    allocation_read,
    buffer_new,
    buffer_append,
    buffer_reserve,
};

pub const FunctionParameterShape = struct {
    mode: ParameterMode,
    is_meta_type: bool,
};

/// Declaration-level parameter modes. Unlike `FunctionSignature`, this keeps
/// static parameters and does not require dependent runtime types to have been
/// substituted yet.
pub const FunctionShape = struct {
    returns_type: bool = false,
    parameters: []const FunctionParameterShape,

    pub fn eql(a: FunctionShape, b: FunctionShape) bool {
        if (a.returns_type != b.returns_type) return false;
        if (a.parameters.len != b.parameters.len) return false;
        for (a.parameters, b.parameters) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        return true;
    }

    pub fn deinit(self: *FunctionShape, gpa: std.mem.Allocator) void {
        gpa.free(self.parameters);
        self.* = undefined;
    }
};

pub const FunctionCall = struct {
    target: union(enum) { direct: InstanceId, indirect: FunctionValueId, initializer: FunctionValueId },
    arguments: FunctionValueRange,
    return_type: TypeId,
    destination: ?FunctionValueId = null,

    pub fn hasInitializer(self: @This(), arguments: []const FunctionCallArgument) bool {
        if (self.target == .initializer) return true;
        for (arguments[self.arguments.start..self.arguments.end]) |argument| if (argument == .initializer) return true;
        return false;
    }

    pub fn usesInitializer(self: @This(), initializer: ?FunctionValueId, arguments: []const FunctionCallArgument) bool {
        const value = initializer orelse return false;
        if (self.target == .initializer and self.target.initializer == value) return true;
        for (arguments[self.arguments.start..self.arguments.end]) |argument| {
            if (argument == .initializer and argument.initializer == value) return true;
        }
        return false;
    }

    pub fn operands(self: *FunctionCall) [2]?*FunctionValueId {
        return .{
            switch (self.target) {
                .indirect => &self.target.indirect,
                .initializer => &self.target.initializer,
                .direct => null,
            },
            if (self.destination) |*destination| destination else null,
        };
    }
};

pub const FunctionReference = struct {
    target: ItemId,
    specialization: ?CompileTimeValueTupleId = null,
    type_id: TypeId,

    pub fn instance(self: FunctionReference) InstanceId {
        return .{ .item = self.target, .specialization = self.specialization };
    }
};

pub const VariantOperation = struct {
    operand: FunctionValueId,
    target_type: TypeId,
    tag_mapping: ?FunctionValueRange = null,
    destination: ?FunctionValueId = null,
};

pub const StructFieldValue = struct {
    field_index: u32,
    value: FunctionValueId,
};

pub const StructOperation = struct {
    fields: FunctionValueRange,
    type_id: TypeId,
};

pub const StorageProjection = struct {
    owner: FunctionValueId,
    type_id: TypeId,
    projection: union(enum) { box_element, field: u32, variant },
};

pub const AllocationElement = struct {
    allocation: FunctionValueId,
    index: FunctionValueId,
    type_id: TypeId,
};

pub const BorrowOperation = struct {
    source: FunctionValueId,
    type_id: TypeId,
};

pub const BorrowAddressOperation = struct {
    source: FunctionValueId,
    type_id: TypeId,
    fields: FunctionValueRange = .{ .start = 0, .end = 0 },
    base_is_reference: bool = false,
};

pub const BorrowWriteOperation = struct {
    reference: FunctionValueId,
    value: FunctionValueId,
    type_id: TypeId,
};

pub const ValueCopy = struct {
    source: FunctionValueId,
    type_id: TypeId,
    destination: ?FunctionValueId = null,
};

pub const FieldAccessOperation = struct {
    operand: FunctionValueId,
    field_index: u32,
    field_type: TypeId,
};

pub const FieldUpdateOperation = struct {
    operand: FunctionValueId,
    value: FunctionValueId,
    field_index: u32,
    type_id: TypeId,
};

pub const MutParameterWrite = struct {
    parameter_index: u32,
    value: FunctionValueId,
    type_id: TypeId,
};

pub const CallMutArgument = struct {
    arguments: FunctionValueRange,
    return_type: TypeId,
    argument_index: u32,
    type_id: TypeId,
    destination: ?FunctionValueId = null,
};

pub const FunctionInstruction = union(enum) {
    const_int: i32,
    const_byte: u8,
    const_bool: bool,
    const_type: TypeId,
    const_unit,
    const_none,
    function_ref: FunctionReference,
    continuation_ref: ?FunctionValueId,
    continuation_storage: struct { token: FunctionValueId, type_id: TypeId },
    continuation_select: struct { token: FunctionValueId, storage: FunctionValueId },
    initializer_ref: struct { region: u32, captures: FunctionValueRange, type_id: TypeId },
    variant_tag: FunctionValueId,
    variant_coerce: VariantOperation,
    variant_extract: VariantOperation,
    callable_coerce: VariantOperation,
    struct_init: StructOperation,
    local_storage: TypeId,
    result_storage: TypeId,
    storage_projection: StorageProjection,
    allocation_element: AllocationElement,
    borrow_box: BorrowOperation,
    borrow_address: BorrowAddressOperation,
    borrow_read: BorrowOperation,
    borrow_write: BorrowWriteOperation,
    value_copy: ValueCopy,
    field_access: FieldAccessOperation,
    field_update: FieldUpdateOperation,
    mut_parameter_write: MutParameterWrite,
    call_mut_argument: CallMutArgument,
    call: FunctionCall,
    negi: FunctionValueId,
    addi: BinaryOperands,
    subi: BinaryOperands,
    muli: BinaryOperands,
    divsi: BinaryOperands,

    pub fn operands(self: *FunctionInstruction) [2]?*FunctionValueId {
        return switch (self.*) {
            .const_int, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .initializer_ref, .struct_init, .local_storage, .result_storage => .{ null, null },
            .continuation_ref => |*destination| .{ if (destination.*) |*value| value else null, null },
            .continuation_storage => |*operation| .{ &operation.token, null },
            .continuation_select => |*operation| .{ &operation.token, &operation.storage },
            .variant_tag, .negi => |*operand| .{ operand, null },
            .variant_coerce, .variant_extract, .callable_coerce => |*operation| .{ &operation.operand, if (operation.destination) |*destination| destination else null },
            .storage_projection => |*operation| .{ &operation.owner, null },
            .allocation_element => |*operation| .{ &operation.allocation, &operation.index },
            .borrow_box, .borrow_read => |*operation| .{ &operation.source, null },
            .borrow_address => |*operation| .{ &operation.source, null },
            .borrow_write => |*operation| .{ &operation.reference, &operation.value },
            .value_copy => |*operation| .{ &operation.source, if (operation.destination) |*destination| destination else null },
            .call_mut_argument => |*operation| .{ if (operation.destination) |*destination| destination else null, null },
            .field_access => |*operation| .{ &operation.operand, null },
            .field_update => |*operation| .{ &operation.operand, &operation.value },
            .mut_parameter_write => |*operation| .{ &operation.value, null },
            .call => |*call| call.operands(),
            .addi, .subi, .muli, .divsi => |*binary| .{ &binary.lhs, &binary.rhs },
        };
    }

    pub fn resultType(self: FunctionInstruction) TypeId {
        return switch (self) {
            .const_int, .variant_tag, .negi, .addi, .subi, .muli, .divsi => .int,
            .const_byte => .byte,
            .const_bool => .bool,
            .const_type => .type,
            .const_unit, .continuation_ref, .continuation_select => .unit,
            .continuation_storage => |operation| operation.type_id,
            .const_none => .none,
            .function_ref => |reference| reference.type_id,
            .initializer_ref => |reference| reference.type_id,
            .variant_coerce, .variant_extract, .callable_coerce => |operation| if (operation.destination == null) operation.target_type else .unit,
            .struct_init => |operation| operation.type_id,
            .local_storage, .result_storage => |type_id| type_id,
            .storage_projection => |operation| operation.type_id,
            .allocation_element => |operation| operation.type_id,
            .borrow_box, .borrow_read => |operation| operation.type_id,
            .borrow_address => |operation| operation.type_id,
            .borrow_write => .unit,
            .value_copy => |operation| if (operation.destination == null) operation.type_id else .unit,
            .field_access => |operation| operation.field_type,
            .field_update => |operation| operation.type_id,
            .mut_parameter_write => .unit,
            .call_mut_argument => |operation| if (operation.destination == null) operation.type_id else .unit,
            .call => |call| if (call.destination == null) call.return_type else .unit,
        };
    }
};

/// Owned function control-flow graph. Block arguments, branch operands, call
/// operands, and instructions use flat arrays while each block owns its ranges
/// and terminator. Calls retain declaration identities until code emission.
pub const FunctionBodyAnalysis = struct {
    return_type: TypeId,
    /// Includes private initializer outcomes; source declarations retain their
    /// own fallibility in CallableType.
    is_fallible: bool = false,
    /// Region entry arguments are addresses supplied by its private environment.
    is_initializer_region: bool = false,
    initializer_regions: []FunctionBodyAnalysis = &.{},
    initializer_captures: []FunctionValueId = &.{},
    parameter_modes: []ParameterMode,
    block_arguments: []FunctionBlockArgument,
    variant_coercion_tags: []const u32 = &.{},
    struct_field_values: []StructFieldValue = &.{},
    borrow_fields: []u32 = &.{},
    branch_arguments: []FunctionValueUse,
    call_arguments: []FunctionCallArgument,
    instructions: []Instruction,
    instruction_spans: []SourceSpan = &.{},
    terminator_spans: []SourceSpan = &.{},
    blocks: []Block,
    entry: BlockId,

    pub const ValueId = FunctionValueId;
    pub const BlockId = FunctionBlockId;
    pub const Instruction = FunctionInstruction;
    pub const Terminator = FunctionTerminator;
    pub const Block = FunctionBlock;

    pub fn instructionValue(self: @This(), instruction_index: usize) ValueId {
        std.debug.assert(instruction_index < self.instructions.len);
        return functionInstructionValue(self.block_arguments.len, instruction_index);
    }

    pub fn valueType(self: @This(), value: ValueId) TypeId {
        const index = @intFromEnum(value);
        std.debug.assert(index < self.valueCount());
        return if (index < self.block_arguments.len) self.block_arguments[index].type_id else self.instructions[index - self.block_arguments.len].resultType();
    }

    pub fn valueCount(self: @This()) usize {
        return self.block_arguments.len + self.instructions.len;
    }

    pub fn eql(a: @This(), b: @This()) bool {
        if (a.entry != b.entry or
            a.return_type != b.return_type or
            a.is_fallible != b.is_fallible or
            a.is_initializer_region != b.is_initializer_region or
            a.initializer_regions.len != b.initializer_regions.len or
            !std.mem.eql(FunctionValueId, a.initializer_captures, b.initializer_captures) or
            !std.mem.eql(ParameterMode, a.parameter_modes, b.parameter_modes) or
            a.block_arguments.len != b.block_arguments.len or
            !std.mem.eql(u32, a.variant_coercion_tags, b.variant_coercion_tags) or
            a.struct_field_values.len != b.struct_field_values.len or
            !std.mem.eql(u32, a.borrow_fields, b.borrow_fields) or
            !valueUsesEql(a.branch_arguments, b.branch_arguments) or
            !callArgumentsEql(a.call_arguments, b.call_arguments) or
            a.instructions.len != b.instructions.len or
            !sourceSpansEql(a.instruction_spans, b.instruction_spans) or
            !sourceSpansEql(a.terminator_spans, b.terminator_spans) or
            a.blocks.len != b.blocks.len) return false;
        for (a.block_arguments, b.block_arguments) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.initializer_regions, b.initializer_regions) |left, right| {
            if (!eql(left, right)) return false;
        }
        for (a.struct_field_values, b.struct_field_values) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.instructions, b.instructions) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.blocks, b.blocks) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        return true;
    }

    fn valueUsesEql(left: []const FunctionValueUse, right: []const FunctionValueUse) bool {
        if (left.len != right.len) return false;
        for (left, right) |left_use, right_use| {
            if (!std.meta.eql(left_use, right_use)) return false;
        }
        return true;
    }

    fn callArgumentsEql(left: []const FunctionCallArgument, right: []const FunctionCallArgument) bool {
        if (left.len != right.len) return false;
        for (left, right) |left_argument, right_argument| {
            if (!std.meta.eql(left_argument, right_argument)) return false;
        }
        return true;
    }

    fn sourceSpansEql(left: []const SourceSpan, right: []const SourceSpan) bool {
        if (left.len != right.len) return false;
        for (left, right) |left_span, right_span| {
            if (!std.meta.eql(left_span, right_span)) return false;
        }
        return true;
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.parameter_modes);
        gpa.free(self.block_arguments);
        gpa.free(self.variant_coercion_tags);
        gpa.free(self.struct_field_values);
        gpa.free(self.borrow_fields);
        gpa.free(self.branch_arguments);
        gpa.free(self.call_arguments);
        for (self.initializer_regions) |*region| region.deinit(gpa);
        gpa.free(self.initializer_regions);
        gpa.free(self.initializer_captures);
        gpa.free(self.instructions);
        gpa.free(self.instruction_spans);
        gpa.free(self.terminator_spans);
        gpa.free(self.blocks);
        self.* = undefined;
    }
};

/// Callable-instance key. Static argument tuples are interned separately so
/// query keys remain small and pointer-free.
pub const InstanceId = struct {
    item: ItemId,
    specialization: ?CompileTimeValueTupleId = null,
};

/// Pointer-free identity of a source expression evaluated at compile time. The
/// owning instance supplies its static environment; the node identifies the
/// expression in the current parsed source. Runtime lexical captures are not
/// part of a site identity and are rejected semantically.
pub const CompileTimeSite = struct {
    owner: InstanceId,
    node: Node.Index,
    expected_type: ?TypeId = null,
};

/// Identity of one concrete compile-time function invocation. Ordinary
/// parameters are supplied in `arguments`; static parameters are already part
/// of `instance.specialization`.
pub const CompileTimeCallKey = struct {
    instance: InstanceId,
    arguments: CompileTimeValueTupleId,
};

/// Owned deterministic breadth-first order of instances reachable from an entry.
/// The slice is nonempty and stores the entry first.
pub const ReachableInstances = struct {
    instances: []const InstanceId,

    pub fn eql(a: ReachableInstances, b: ReachableInstances) bool {
        if (a.instances.len != b.instances.len) return false;
        for (a.instances, b.instances) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        return true;
    }

    pub fn deinit(self: *ReachableInstances, gpa: std.mem.Allocator) void {
        gpa.free(self.instances);
        self.* = undefined;
    }
};

pub const CompiledFunction = struct {
    /// Owned, nonempty machine code implementing the callable ABI.
    code: []const u8,
    /// Nonzero power-of-two alignment required for the loaded code address.
    required_alignment: u32,
    relocations: []const Relocation,
    referenced_instances: []const InstanceId,

    pub const ReferenceId = enum(u32) { _ };

    pub const RelocationKind = enum {
        call_relative_32,
        address_absolute_64,
    };

    pub const Relocation = struct {
        /// Byte offset of the field to patch. Relative displacements are based
        /// at the end of that field; `reference` indexes referenced_instances.
        offset: u32,
        kind: RelocationKind,
        reference: ReferenceId,
        addend: i64,
    };

    pub fn eql(a: CompiledFunction, b: CompiledFunction) bool {
        if (a.required_alignment != b.required_alignment or
            !std.mem.eql(u8, a.code, b.code) or
            a.relocations.len != b.relocations.len or
            a.referenced_instances.len != b.referenced_instances.len)
        {
            return false;
        }
        for (a.relocations, b.relocations) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.referenced_instances, b.referenced_instances) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        return true;
    }

    pub fn deinit(self: *CompiledFunction, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        gpa.free(self.relocations);
        gpa.free(self.referenced_instances);
        self.* = undefined;
    }
};

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub const Diagnostic = struct {
    file_id: FileId,
    span: ?SourceSpan,
    kind: Kind,

    pub const TypeMismatch = struct {
        expected: TypeId,
        found: TypeId,
    };

    pub const TypeNotCopyable = struct {
        type_id: TypeId,
        is_movable: bool,
    };

    pub const InvalidStructPropertyValue = enum {
        move,
        copy,
        drop,
    };

    pub const IncompatibleStructOwnershipProperty = enum {
        trivial_move,
        fieldwise_move,
        custom_move,
        trivial_copy,
        fieldwise_copy,
        trivial_drop,
    };

    pub const MissingStructInitializerField = struct {
        type_id: TypeId,
        field_index: u32,
    };

    pub const Kind = union(enum) {
        expected_token: struct {
            expected: Token.Tag,
            found: Token.Tag,
        },
        invalid_expression: Token.Tag,
        unexpected_indented_block,
        indented_block_after_inline_body,
        duplicate_top_level_declaration,
        declaration_cycle,
        static_initializer_not_supported,
        compile_time_call_cycle,
        compile_time_unhandled_failure,
        compile_time_division_by_zero,
        compile_time_integer_overflow,
        compile_time_unsupported_operation,
        compile_time_call_trace,
        unsupported_external_declaration,
        invalid_external_signature,
        struct_member_not_supported,
        duplicate_struct_member,
        reserved_ownership_member,
        duplicate_struct_property,
        unknown_struct_property,
        invalid_struct_property_value: InvalidStructPropertyValue,
        struct_ownership_hook_signature_mismatch: TypeMismatch,
        struct_ownership_property_incompatible_with_fields: IncompatibleStructOwnershipProperty,
        struct_field_type_not_supported,
        recursive_struct_containment,
        static_initializer_type_mismatch: TypeMismatch,
        type_value_used_as_runtime_value,
        value_used_as_type,
        type_factory_requires_call,
        generic_struct_requires_specialization,
        function_annotation_not_supported,
        parameter_mode_not_supported,
        initializer_not_consumed,
        initializer_already_consumed,
        initializer_requires_construction,
        initializer_consumed_in_loop,
        initializer_capture_not_supported,
        initializer_escape_not_supported,
        initializer_capture_conflict,
        static_parameter_requires_specialization,
        static_argument_cannot_be_inferred,
        static_argument_inference_conflict,
        static_argument_not_supported,
        comptime_runtime_capture,
        static_argument_type_mismatch,
        where_condition_failed,
        duplicate_parameter,
        parameter_type_missing,
        parameter_type_not_supported,
        return_type_not_supported,
        top_level_return,
        break_outside_loop,
        continue_outside_loop,
        import_outside_top_level,
        misplaced_pub,
        namespace_used_as_value,
        unknown_namespace_member,
        invalid_namespace_owner,
        unknown_module,
        unknown_imported_name,
        private_access,
        import_conflict,
        nested_declaration_not_supported,
        ownership_transfer_requires_place,
        ownership_transfer_requires_owned_place,
        partial_field_transfer_not_supported,
        explicit_drop_field_cannot_be_implicitly_ended,
        field_not_restored_before_mut_return,
        ownership_transfer_requires_owning_context,
        mutable_argument_requires_place,
        mutable_argument_requires_mutable_place,
        overlapping_mutable_arguments,
        use_after_transfer,
        possibly_transferred,
        replaced_value_used,
        consumed_storage_in_use,
        borrow_outlives_source,
        invalid_return_origin,
        return_origin_not_declared,
        borrow_requires_place,
        mutable_borrow_requires_writable_place,
        dereference_requires_ref: TypeId,
        reference_not_writable,
        transferred_value_not_restored_before_loop_backedge,
        type_not_movable: TypeId,
        relocation_requires_direct_move: TypeId,
        type_not_copyable: TypeNotCopyable,
        buffer_cannot_store_borrow_element: TypeId,
        buffer_requires_automatic_drop: TypeId,
        buffer_requires_direct_move: TypeId,
        borrow_write_cannot_store_borrow: TypeId,
        borrow_write_requires_automatic_drop: TypeId,
        borrow_write_requires_direct_move: TypeId,
        box_requires_automatic_drop: TypeId,
        box_extraction_requires_direct_move: TypeId,
        value_requires_explicit_drop: TypeId,
        expression_not_supported,
        struct_initializer_not_struct: TypeId,
        unknown_struct_field,
        duplicate_struct_initializer_field,
        missing_struct_initializer_field: MissingStructInitializerField,
        struct_initializer_field_type_mismatch: TypeMismatch,
        field_access_not_struct: TypeId,
        opaque_struct_access: TypeId,
        unknown_field,
        duplicate_local_binding,
        local_type_not_supported,
        float_type_not_supported,
        unknown_type,
        unknown_value,
        assignment_target_not_local,
        assignment_to_immutable,
        assignment_type_mismatch: TypeMismatch,
        integer_literal_not_decimal,
        float_literal_not_supported,
        integer_literal_out_of_range,
        fallible_condition_not_supported,
        if_condition_not_fallible,
        inspection_type_not_supported,
        variant_inspection_operand_not_variant: TypeId,
        condition_binding_must_be_immutable,
        value_not_callable,
        duplicate_variant_member_type,
        local_type_mismatch: TypeMismatch,
        negation_operand_not_int: TypeId,
        arithmetic_operand_not_int: TypeId,
        comparison_operand_not_int: TypeId,
        equality_operand_not_supported: TypeId,
        equality_operand_type_mismatch: TypeMismatch,
        fallible_expression_outside_fallible_function,
        missing_return_value: TypeId,
        return_type_mismatch: TypeMismatch,
        unknown_function,
        call_argument_count_mismatch: struct { expected: u32, found: u32 },
        call_argument_type_mismatch: TypeMismatch,
    };
};
