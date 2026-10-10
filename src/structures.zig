const std = @import("std");
const value_operations = @import("value.zig");

// Shared compiler structures.
//
// This file is the low-level data boundary used across compiler stages. Keep it
// independent from parser/query/analyzer/codegen modules so shared result types
// can be imported without creating compiler dependency cycles.

/// Compare slice contents using fieldwise equality, ignoring struct padding.
/// Elements with owned slices still need their own content comparison.
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
        keyword_converter,
        keyword_continue,
        keyword_deinit,
        keyword_init,
        keyword_else,
        keyword_extern,
        keyword_fail,
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
        .{ "converter", .keyword_converter },
        .{ "continue", .keyword_continue },
        .{ "deinit", .keyword_deinit },
        .{ "init", .keyword_init },
        .{ "else", .keyword_else },
        .{ "extern", .keyword_extern },
        .{ "fail", .keyword_fail },
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
    is_static_struct: bool = false,
    is_converter: bool = false,

    pub const Index = enum(u32) {
        null = 0,
        _,

        pub fn unwrap(self: @This()) ?Index {
            return if (self == .null) null else self;
        }

        pub fn index(self: @This()) u32 {
            return @backingInt(self);
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
        index_access,
        func,
        identifier,
        none_literal,
        number_literal,
        string_literal,
        unit_literal,
        param,
        param_list,
        move_expr,
        break_nothing,
        break_expr,
        continue_expr,
        return_nothing,
        return_expr,
        fail_expr,
        signature,
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
        collection_literal,
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

    pub fn dataTag(self: Node) ?std.meta.FieldEnum(Data) {
        return switch (self.tag) {
            .break_nothing, .continue_expr, .return_nothing, .fail_expr, .access, .implicit_static, .bool_literal, .identifier, .none_literal, .number_literal, .string_literal, .unit_literal, .type, .implicit_type => .none,
            .break_expr, .return_expr, .loop, .not, .neg, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .deref, .struct_field, .struct_property, .struct_init_field, .@"pub" => .node,
            .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .call, .index_access, .const_binding, .var_binding, .borrow_binding, .borrow_mut_binding, .static_binding, .namespace_declaration, .func, .param, .type_func, .@"if" => .node_node,
            .signature => .signature,
            .block, .call_arg_list, .param_list, .type_list, .type_variant, .where_clauses, .if_else, .@"struct", .struct_init, .collection_literal, .import, .selective_import => .ref,
            else => null,
        };
    }

    pub const Children = union(enum) {
        fixed: [3]Index,
        list: []const Index,

        pub fn slice(self: *const Children) []const Index {
            return switch (self.*) {
                .fixed => |*nodes| nodes,
                .list => |nodes| nodes,
            };
        }
    };

    pub fn children(self: Node, node_refs: []const Index) Children {
        return switch (self.dataTag() orelse return .{ .list = &.{} }) {
            .none => .{ .list = &.{} },
            .node => .{ .fixed = .{ self.data.node, .null, .null } },
            .node_node => .{ .fixed = .{ self.data.node_node.a, self.data.node_node.b, .null } },
            .signature => .{ .fixed = .{ self.data.signature.parameters, self.data.signature.return_type, self.data.signature.where_clauses } },
            .ref => .{ .list = node_refs[self.data.ref.start..self.data.ref.end] },
        };
    }
};

pub const Ast = struct {
    file_id: FileId,
    tokens: []Token,
    nodes: []Node,
    node_refs: []Node.Index,

    pub fn nodeList(self: Ast, index: Node.Index) []const Node.Index {
        const node = self.nodes[(index.unwrap() orelse return &.{}).index()];
        switch (node.tag) {
            .param_list, .type_variant, .type_list, .call_arg_list, .where_clauses, .collection_literal => {},
            else => unreachable,
        }
        return self.node_refs[node.data.ref.start..node.data.ref.end];
    }

    pub fn tokenSpan(self: *const Ast, token_index: u32) SourceSpan {
        const token = self.tokens[token_index];
        var end = token.loc.end;
        if (token.tag == .l_bracket and self.tokens[token_index + 1].tag == .r_bracket) {
            end = self.tokens[token_index + 1].loc.end;
            if (self.tokens[token_index + 2].tag == .equal) end = self.tokens[token_index + 2].loc.end;
        }
        return .{ .start = token.loc.start, .end = end };
    }

    pub fn eql(a: Ast, b: Ast) bool {
        if (a.file_id != b.file_id) return false;
        if (a.tokens.len != b.tokens.len or a.nodes.len != b.nodes.len or a.node_refs.len != b.node_refs.len) return false;
        if (!value_operations.equal([]const Token, a.tokens, b.tokens)) return false;
        for (a.nodes, b.nodes) |left, right| {
            if (left.tag != right.tag or left.token_index != right.token_index or left.is_static_struct != right.is_static_struct or left.is_converter != right.is_converter) return false;
            switch (left.dataTag() orelse return false) {
                .none => {},
                .node => if (left.data.node != right.data.node) return false,
                .node_node => if (!std.meta.eql(left.data.node_node, right.data.node_node)) return false,
                .signature => if (!std.meta.eql(left.data.signature, right.data.signature)) return false,
                .ref => if (!std.meta.eql(left.data.ref, right.data.ref)) return false,
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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const FileId = u64;

pub const ModuleId = enum(u32) { _ };

pub const ModulePath = struct {
    path: []const u8,
};

pub const ItemId = enum(u32) { _ };

pub const OwnershipMember = enum { copy, move };

pub const Operation = enum {
    @"+",
    @"-",
    @"*",
    @"/",
    unary_minus,
    @"==",
    @"<>",
    @"<",
    @">",
    @"<=",
    @">=",
    not,
    @"[]",
    @"[]=",

    pub fn fromName(name: []const u8, operands: ?usize) ?Operation {
        var fallback: ?Operation = null;
        inline for (std.enums.values(Operation)) |operation| {
            if (std.mem.eql(u8, name, operation.spelling())) {
                if (operands == operation.operandCount()) return operation;
                if (fallback == null) fallback = operation;
            }
        }
        return fallback;
    }

    pub fn spelling(self: Operation) []const u8 {
        return if (self == .unary_minus) "-" else @tagName(self);
    }

    pub fn operandCount(self: Operation) usize {
        return switch (self) {
            .unary_minus, .not => 1,
            .@"[]=" => 3,
            else => 2,
        };
    }

    pub fn isIndexer(self: Operation) bool {
        return self == .@"[]" or self == .@"[]=";
    }

    pub fn returnsBool(self: Operation) bool {
        return switch (self) {
            .@"==", .@"<>", .@"<", .@">", .@"<=", .@">=", .not => true,
            else => false,
        };
    }

    pub fn supportsPrimitive(self: Operation, receiver: TypeId) bool {
        return switch (receiver) {
            .int => !self.isIndexer() and self != .not,
            .bool => self == .@"==" or self == .@"<>" or self == .not,
            else => false,
        };
    }
};

pub const Name = union(enum) {
    identifier: []const u8,
    operation: Operation,

    pub fn fromText(spelling: []const u8, operands: ?usize) Name {
        if (Operation.fromName(spelling, operands)) |operation| return .{ .operation = operation };
        return .{ .identifier = spelling };
    }

    pub fn text(self: Name) []const u8 {
        return switch (self) {
            .identifier => |identifier| identifier,
            .operation => |operation| operation.spelling(),
        };
    }

    pub fn order(left: Name, right: Name) std.math.Order {
        const spelling = std.mem.order(u8, left.text(), right.text());
        if (spelling != .eq) return spelling;
        if (left == .operation and right == .operation)
            return std.math.order(left.operation.operandCount(), right.operation.operandCount());
        return spelling;
    }

    pub const Context = struct {
        pub fn hash(_: Context, name: Name) u64 {
            return value_operations.Owned(Name).hash(name);
        }
        pub fn eql(_: Context, left: Name, right: Name) bool {
            return value_operations.Owned(Name).eql(left, right);
        }
    };
    pub const Set = std.HashMap(Name, void, Context, std.hash_map.default_max_load_percentage);
    pub fn clone(self: Name, allocator: std.mem.Allocator) !Name {
        return value_operations.Owned(Name).clone(allocator, self);
    }
    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const ItemKind = enum {
    function,
    structure,
    static,
    top_level_entry,
    primitive,
};

pub const ConversionCandidate = struct {
    instance: InstanceId,
    target_type: TypeId,
    source_mode: ParameterMode,
};

/// Interned identities contain no replaceable source locations.
pub const ItemLoc = struct {
    origin: union(enum) { module: ModuleId, entry: FileId },
    owner: ?ItemId = null,
    source_site: ?i64 = null,
    is_hook: bool = false,
    kind: ItemKind,
    name: Name,

    pub const eql = value_operations.Owned(@This()).eql;
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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

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
        name: Name,
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
        return self.resolveName(.fromText(name, null));
    }

    pub fn resolveName(self: ModuleScope, name: Name) ?Entry {
        const index = std.sort.binarySearch(Entry, self.entries, name, struct {
            fn compare(target: Name, entry: Entry) std.math.Order {
                return Name.order(target, entry.name);
            }
        }.compare) orelse return null;
        return self.entries[index];
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const ModuleItemIndex = struct {
    entries: []Entry,

    pub const Entry = struct { item: ItemId, location: ResolvedItem };

    pub fn resolve(self: ModuleItemIndex, item: ItemId) ?ResolvedItem {
        const index = std.sort.binarySearch(Entry, self.entries, item, struct {
            fn compare(target: ItemId, entry: Entry) std.math.Order {
                return std.math.order(@backingInt(target), @backingInt(entry.item));
            }
        }.compare) orelse return null;
        return self.entries[index].location;
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const ImportName = struct {
    spelling: []const u8,
    span: SourceSpan,

    pub const eql = value_operations.Owned(@This()).eql;
};

/// Collected syntax owns every spelling; null and empty selections are distinct.
pub const ImportDeclaration = struct {
    path: ImportName,
    alias: ?ImportName,
    selective: ?[]Selection,
    is_public: bool,

    pub const Selection = struct { original: ImportName, bound: ImportName };

    pub const deinit = value_operations.Owned(@This()).deinit;

    pub const eql = value_operations.Owned(@This()).eql;
};

pub const ImportDeclarations = struct {
    entries: []ImportDeclaration,

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const NamespaceBinding = struct { module: ModuleId, members_visible: bool = true };

pub const NameReference = union(enum) {
    namespace: NamespaceBinding,
    declaration: InstanceId,
    overloaded_function: [2]InstanceId,
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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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
        int_literal: i64,
        string_literal: ByteStringId,
        static_data: ByteStringId,
        byte_pointer: StaticBytePointer,
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
                .int_literal => .int_literal,
                .string_literal => .string_literal,
                .static_data => .static_data,
                .byte_pointer => .byte_pointer,
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

/// Canonical immutable bytes, owned by the database rather than source or frames.
pub const ByteStringId = enum(u32) { _ };
pub const ByteString = struct { bytes: []const u8 };
pub const StaticBytePointer = struct { data: ByteStringId, offset: u32 = 0 };

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
    int_literal,
    string_literal,
    static_data,
    byte_pointer,
    _,

    const interned_mask: u32 = 1 << 31;

    pub fn fromInterned(interned_id: InternedTypeId) TypeId {
        return @fromBackingInt(@intCast(interned_mask | @backingInt(interned_id)));
    }

    pub fn interned(self: TypeId) ?InternedTypeId {
        const raw = @backingInt(self);
        if (raw & interned_mask == 0) return null;
        return @fromBackingInt(@intCast(@as(u31, @truncate(raw))));
    }

    pub fn isPrimitive(self: TypeId) bool {
        return self == .int or self == .bool or self == .unit or self == .none or self == .never or self == .type or self == .byte or self == .int_literal or self == .string_literal or self == .static_data or self == .byte_pointer;
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

pub const CallableType = struct {
    parameters: []const CallableParameter,
    return_type: TypeId,
    is_fallible: bool,

    pub fn parametersEql(a: CallableType, b: CallableType) bool {
        return value_operations.equal([]const CallableParameter, a.parameters, b.parameters);
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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
    array: ArrayType,
};

pub const ArrayType = struct {
    element_type: TypeId,
    length: u32,
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
    is_public: bool = false,
};

pub const StructDefinition = struct {
    fields: []StructField,
    ownership: StructOwnershipProperties = .{},
    is_static: bool = false,

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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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
    return @fromBackingInt(@intCast(argument_count + instruction_index));
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

pub const CallOutcome = enum(u8) { failure = 0, success = 1 };

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
    },
    return_unit,
    return_value: FunctionValueUse,
    return_failure,
    diverge,

    pub fn operands(self: *FunctionTerminator) [2]?*FunctionValueId {
        return switch (self.*) {
            .predicate_branch => |*branch| .{ &branch.operands.lhs, &branch.operands.rhs },
            .fallible_call => |*fallible| fallible.call.operands(),
            .return_value => |*use| .{ &use.value, null },
            .branch, .return_unit, .return_failure, .diverge => .{ null, null },
        };
    }

    pub fn successors(self: *FunctionTerminator) [2]?*FunctionBlockId {
        return switch (self.*) {
            .branch => |*branch| .{ &branch.target, null },
            .predicate_branch => |*branch| .{ &branch.then_branch.target, &branch.else_branch.target },
            .fallible_call => |*call| callSuccessors(call),
            .return_unit, .return_value, .return_failure, .diverge => .{ null, null },
        };
    }

    pub fn successorCount(self: FunctionTerminator) u2 {
        var terminator = self;
        const targets = terminator.successors();
        return @as(u2, @intFromBool(targets[0] != null)) + @intFromBool(targets[1] != null);
    }

    fn callSuccessors(call: *@FieldType(FunctionTerminator, "fallible_call")) [2]?*FunctionBlockId {
        var targets: [2]?*FunctionBlockId = .{ null, null };
        var count: usize = 0;
        if (call.call.return_type != .never) {
            targets[count] = &call.success;
            count += 1;
        }
        if (call.failure) |*failure| {
            targets[count] = failure;
        }
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

pub const ValueRepresentation = enum { value, storage, initializer };

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

/// Declaration-level callable facts. Unlike `FunctionSignature`, this keeps
/// static parameters and does not require dependent runtime types to have been
/// substituted yet.
pub const FunctionShape = struct {
    returns_type: bool = false,
    is_fallible: bool = false,
    parameters: []const FunctionParameterShape,

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const FunctionCall = struct {
    target: union(enum) { direct: InstanceId, indirect: FunctionValueId, initializer: FunctionValueId },
    arguments: FunctionValueRange,
    return_type: TypeId,
    destination: ?FunctionValueId = null,

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

pub const StorageProjection = struct {
    owner: FunctionValueId,
    type_id: TypeId,
    projection: union(enum) { box_element, field: u32, variant, allocation_array },
};

pub const AllocationElement = struct {
    allocation: FunctionValueId,
    index: FunctionValueId,
    type_id: TypeId,
};

pub const ArrayElement = struct {
    array: FunctionValueId,
    index: FunctionValueId,
    type_id: TypeId,
};

pub const BorrowOperation = struct {
    source: FunctionValueId,
    type_id: TypeId,
};

pub const BorrowProjection = union(enum) { field: u32, variant: TypeId };

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
    const_int_literal: i64,
    const_string_literal: ByteStringId,
    const_data: ByteStringId,
    const_byte_pointer: StaticBytePointer,
    byte_pointer: FunctionValueId,
    byte_offset: BinaryOperands,
    byte_read: BinaryOperands,
    byte_to_int: FunctionValueId,
    const_byte: u8,
    const_bool: bool,
    const_type: TypeId,
    const_unit,
    const_none,
    function_ref: FunctionReference,
    initializer_ref: struct { region: u32, captures: FunctionValueRange, type_id: TypeId },
    variant_tag: FunctionValueId,
    variant_coerce: VariantOperation,
    variant_extract: VariantOperation,
    callable_coerce: VariantOperation,
    local_storage: TypeId,
    result_storage: TypeId,
    storage_projection: StorageProjection,
    allocation_element: AllocationElement,
    array_element: ArrayElement,
    borrow_box: BorrowOperation,
    borrow_address: BorrowAddressOperation,
    borrow_read: BorrowOperation,
    borrow_write: BorrowWriteOperation,
    value_copy: ValueCopy,
    field_access: FieldAccessOperation,
    mut_parameter_write: MutParameterWrite,
    call_mut_argument: CallMutArgument,
    call: FunctionCall,
    static_conversion: struct { operand: FunctionValueId, type_id: TypeId, destination: ?FunctionValueId = null },
    negi: FunctionValueId,
    addi: BinaryOperands,
    subi: BinaryOperands,
    muli: BinaryOperands,
    divsi: BinaryOperands,

    pub fn operands(self: *FunctionInstruction) [2]?*FunctionValueId {
        return switch (self.*) {
            .const_int, .const_int_literal, .const_string_literal, .const_data, .const_byte_pointer, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .initializer_ref, .local_storage, .result_storage => .{ null, null },
            .variant_tag, .negi, .byte_pointer, .byte_to_int => |*operand| .{ operand, null },
            .variant_coerce, .variant_extract, .callable_coerce => |*operation| .{ &operation.operand, if (operation.destination) |*destination| destination else null },
            .storage_projection => |*operation| .{ &operation.owner, null },
            .allocation_element => |*operation| .{ &operation.allocation, &operation.index },
            .array_element => |*operation| .{ &operation.array, &operation.index },
            .borrow_box, .borrow_read => |*operation| .{ &operation.source, null },
            .borrow_address => |*operation| .{ &operation.source, null },
            .borrow_write => |*operation| .{ &operation.reference, &operation.value },
            .value_copy => |*operation| .{ &operation.source, if (operation.destination) |*destination| destination else null },
            .call_mut_argument => |*operation| .{ if (operation.destination) |*destination| destination else null, null },
            .field_access => |*operation| .{ &operation.operand, null },
            .mut_parameter_write => |*operation| .{ &operation.value, null },
            .call => |*call| call.operands(),
            .static_conversion => |*conversion| .{ &conversion.operand, if (conversion.destination) |*destination| destination else null },
            .addi, .subi, .muli, .divsi, .byte_offset, .byte_read => |*binary| .{ &binary.lhs, &binary.rhs },
        };
    }

    pub fn resultType(self: FunctionInstruction) TypeId {
        return switch (self) {
            .const_int, .variant_tag, .negi, .addi, .subi, .muli, .divsi, .byte_to_int => .int,
            .const_int_literal => .int_literal,
            .const_string_literal => .string_literal,
            .const_data => .static_data,
            .const_byte_pointer, .byte_pointer, .byte_offset => .byte_pointer,
            .byte_read => .byte,
            .const_byte => .byte,
            .const_bool => .bool,
            .const_type => .type,
            .const_unit => .unit,
            .const_none => .none,
            .function_ref => |reference| reference.type_id,
            .initializer_ref => |reference| reference.type_id,
            .variant_coerce, .variant_extract, .callable_coerce => |operation| if (operation.destination == null) operation.target_type else .unit,
            .local_storage, .result_storage => |type_id| type_id,
            .storage_projection => |operation| operation.type_id,
            .allocation_element => |operation| operation.type_id,
            .array_element => |operation| operation.type_id,
            .borrow_box, .borrow_read => |operation| operation.type_id,
            .borrow_address => |operation| operation.type_id,
            .borrow_write => .unit,
            .value_copy => |operation| if (operation.destination == null) operation.type_id else .unit,
            .field_access => |operation| operation.field_type,
            .mut_parameter_write => .unit,
            .call_mut_argument => |operation| if (operation.destination == null) operation.type_id else .unit,
            .call => |call| if (call.destination == null) call.return_type else .unit,
            .static_conversion => |conversion| if (conversion.destination == null) conversion.type_id else .unit,
        };
    }
};

/// Owned function control-flow graph. Block arguments, branch operands, call
/// operands, and instructions use flat arrays while each block owns its ranges
/// and terminator. Calls retain declaration identities until code emission.
pub const FunctionBodyAnalysis = struct {
    return_type: TypeId,
    /// ABI failure permission; init regions and consuming converters may inherit failure.
    is_fallible: bool = false,
    /// Region entry arguments are addresses supplied by its private environment.
    is_initializer_region: bool = false,
    initializer_regions: []FunctionBodyAnalysis = &.{},
    initializer_captures: []FunctionValueId = &.{},
    parameter_modes: []ParameterMode,
    block_arguments: []FunctionBlockArgument,
    variant_coercion_tags: []const u32 = &.{},
    borrow_fields: []BorrowProjection = &.{},
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
        const index = @backingInt(value);
        std.debug.assert(index < self.valueCount());
        return if (index < self.block_arguments.len) self.block_arguments[index].type_id else self.instructions[index - self.block_arguments.len].resultType();
    }

    pub fn valueCount(self: @This()) usize {
        return self.block_arguments.len + self.instructions.len;
    }

    /// Visits stored operands in this body, including side tables and destinations.
    /// Parameter targets and nested regions have independent identities.
    pub fn visitValueReferences(self: @This(), context: anytype, comptime visit: anytype) void {
        for (self.instructions) |*instruction| for (instruction.operands()) |operand| {
            if (operand) |value| visit(context, value);
        };
        for (self.blocks) |*block| for (block.terminator.operands()) |operand| {
            if (operand) |value| visit(context, value);
        };
        for (self.call_arguments) |*argument| visit(context, argument.operand());
        for (self.branch_arguments) |*argument| visit(context, &argument.value);
        for (self.initializer_captures) |*capture| visit(context, capture);
    }

    pub fn hasFailureExit(self: @This()) bool {
        for (self.blocks) |block| if (block.terminator == .return_failure) return true;
        return false;
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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
    public_annotation: bool = false,
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

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const CompiledFunction = struct {
    /// Owned, nonempty machine code implementing the callable ABI.
    code: []const u8,
    /// Nonzero power-of-two alignment required for the loaded code address.
    required_alignment: u32,
    relocations: []const Relocation,
    referenced_instances: []const InstanceId,
    constant_data: []const ByteString = &.{},
    requires_sigpipe_ignore: bool = false,

    pub const ReferenceId = enum(u32) { _ };

    pub const RelocationKind = enum {
        call_relative_32,
        address_absolute_64,
    };

    pub const Relocation = struct {
        /// Byte offset of the field to patch. Relative displacements are based
        /// at the end of that field; the reference selects a function or data.
        offset: u32,
        kind: RelocationKind,
        reference: union(enum) { function: ReferenceId, data: u32 },
        addend: i64,
    };

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
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
        compile_time_escaping_storage,
        compile_time_call_trace,
        unsupported_external_declaration,
        invalid_external_signature,
        invalid_operation_signature,
        ambiguous_operation_reference,
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
        compile_time_only_type: TypeId,
        ambiguous_conversion: TypeMismatch,
        invalid_converter,
        invalid_converter_owner,
        value_used_as_type,
        type_factory_requires_call,
        generic_struct_requires_specialization,
        function_annotation_not_supported,
        parameter_mode_not_supported,
        initializer_not_consumed,
        initializer_already_consumed,
        initializer_requires_construction,
        initializer_consumed_in_loop,
        initializer_exit_outside_boundary,
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
        private_struct_field: TypeId,
        public_field_private_type,
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
        invalid_string_escape,
        invalid_string_utf8,
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
        fallible_call_requires_marker,
        fallible_call_not_fallible,
        missing_return_value: TypeId,
        return_type_mismatch: TypeMismatch,
        unknown_function,
        call_argument_count_mismatch: struct { expected: u32, found: u32 },
        call_argument_type_mismatch: TypeMismatch,
    };
};
