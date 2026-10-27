const std = @import("std");
const value_operations = @import("value.zig");

// Shared compiler structures.
//
// This file is the low-level data boundary used across compiler stages. Keep it
// independent from parser/query/analyzer/codegen modules so shared result types
// can be imported without creating compiler dependency cycles.

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Location = struct { start: u32, end: u32 };

    const definitions = .{
        .invalid = null,
        .eof = null,
        .indent = null,
        .dedent = null,
        .identifier = null,

        .equal = "=",
        .equal_angle_bracket_right = "=>",
        .plus = "+",
        .minus = "-",
        .asterisk = "*",
        .slash = "/",
        .percent = "%",
        .caret = "^",
        .pipe = "|",
        .ampersand = "&",
        .angle_bracket_left = "<",
        .angle_bracket_angle_bracket_left = "<<",
        .angle_bracket_left_angle_bracket_right = "<>",
        .angle_bracket_right = ">",
        .angle_bracket_angle_bracket_right = ">>",

        .equal_equal = "==",
        .plus_equal = "+=",
        .minus_equal = "-=",
        .asterisk_equal = "*=",
        .slash_equal = "/=",
        .percent_equal = "%=",
        .caret_equal = "^=",
        .pipe_equal = "|=",
        .ampersand_equal = "&=",
        .angle_bracket_left_equal = "<=",
        .angle_bracket_angle_bracket_left_equal = "<<=",
        .angle_bracket_right_equal = ">=",
        .angle_bracket_angle_bracket_right_equal = ">>=",

        .l_brace = "{",
        .r_brace = "}",
        .l_paren = "(",
        .r_paren = ")",
        .l_bracket = "[",
        .r_bracket = "]",
        .question_mark = "?",
        .arrow = "->",
        .tilde = "~",
        .period = ".",
        .comma = ",",
        .colon = ":",
        .semicolon = ";",
        .char_literal = null,
        .string_literal = null,
        .number_literal = null,
        .ellipsis2 = "..",
        .ellipsis3 = "...",

        .keyword_and = null,
        .keyword_as = null,
        .keyword_break = null,
        .keyword_comptime = null,
        .keyword_const = null,
        .keyword_converter = null,
        .keyword_continue = null,
        .keyword_deinit = null,
        .keyword_init = null,
        .keyword_else = null,
        .keyword_extern = null,
        .keyword_false = null,
        .keyword_func = null,
        .keyword_for = null,
        .keyword_if = null,
        .keyword_in = null,
        .keyword_is = null,
        .keyword_loop = null,
        .keyword_match = null,
        .keyword_mut = null,
        .keyword_ref = null,
        .keyword_not = null,
        .keyword_none = null,
        .keyword_or = null,
        .keyword_overload = null,
        .keyword_panic = null,
        .keyword_imm = null,
        .keyword_return = null,
        .keyword_sizeof = null,
        .keyword_static = null,
        .keyword_struct = null,
        .keyword_test = null,
        .keyword_true = null,
        .keyword_var = null,
        .keyword_where = null,
        .keyword_import = null,
        .keyword_pub = null,
    };

    pub const Tag = std.meta.FieldEnum(@TypeOf(definitions));

    pub const keywords = std.StaticStringMap(Tag).initComptime(blk: {
        var entries: []const struct { []const u8, Tag } = &.{};
        for (std.enums.values(Tag)) |tag| {
            if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) entries = entries ++ .{.{ @tagName(tag)["keyword_".len..], tag }};
        }
        break :blk entries;
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const punctuation = std.StaticStringMap(Tag).initComptime(blk: {
        var entries: []const struct { []const u8, Tag } = &.{};
        for (@typeInfo(@TypeOf(definitions)).@"struct".field_names) |name| {
            const token_text: ?[]const u8 = @field(definitions, name);
            if (token_text) |text| entries = entries ++ .{.{ text, @field(Tag, name) }};
        }
        break :blk entries;
    });

    pub fn spelling(tag: Tag) ?[]const u8 {
        inline for (.{ punctuation, keywords }) |spellings| {
            for (spellings.keys(), spellings.values()) |text, candidate| if (candidate == tag) return text;
        }
        return null;
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
        rem,
        eq,
        ne,
        lt,
        gt,
        le,
        ge,
        is,
        as,
        membership,
        range,
        range_inclusive,
        @"if",
        if_else,
        loop,
        for_loop,
        @"and",
        @"or",
        not,
        neg,
        assign,
        add_assign,
        sub_assign,
        mul_assign,
        div_assign,
        rem_assign,
        block,
        bool_literal,
        call,
        call_arg_list,
        const_binding,
        var_binding,
        ref_binding,
        static_binding,
        destructure_binding,
        binding_annotation,
        binding_else,
        binding_tuple,
        binding_sequence,
        namespace_declaration,
        comptime_expr,
        field_access,
        index_access,
        func,
        overload,
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
        panic_expr,
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
        type_tuple,
        reference_type,
        import,
        selective_import,
        @"pub",
        collection_literal,
        collection_spread,
        collection_for,
        collection_if,
        tuple_literal,
        match_expr,
        match_arm,
        match_guard,
        match_tuple,
        from_end,
        _,
    };

    pub const Data = union {
        none: void,
        node: Index,
        node_node: struct {
            a: Index,
            b: Index,
        },
        parameter: struct {
            access: ?Token.Tag = null,
            annotation: Index = .null,
        },
        field: struct {
            type_annotation: Index,
            kind: MemberKind,
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
            .break_nothing, .continue_expr, .return_nothing, .bool_literal, .identifier, .none_literal, .number_literal, .string_literal, .unit_literal, .type, .implicit_type => .none,
            .break_expr, .return_expr, .panic_expr, .loop, .not, .neg, .from_end, .reference_type, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .struct_property, .struct_init_field, .@"pub", .collection_spread => .node,
            .add, .sub, .mul, .div, .rem, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .membership, .range, .range_inclusive, .@"and", .@"or", .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .rem_assign, .call, .index_access, .const_binding, .var_binding, .ref_binding, .static_binding, .namespace_declaration, .destructure_binding, .binding_annotation, .binding_else, .func, .type_func, .@"if", .collection_if, .match_arm, .match_guard => .node_node,
            .param => .parameter,
            .struct_field => .field,
            .signature => .signature,
            .block, .for_loop, .collection_for, .call_arg_list, .param_list, .type_list, .type_variant, .type_tuple, .where_clauses, .if_else, .@"struct", .struct_init, .collection_literal, .tuple_literal, .binding_tuple, .binding_sequence, .import, .selective_import, .overload, .match_expr, .match_tuple => .ref,
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
            .parameter => .{ .fixed = .{ self.data.parameter.annotation, .null, .null } },
            .field => .{ .fixed = .{ self.data.field.type_annotation, .null, .null } },
            .signature => .{ .fixed = .{ self.data.signature.parameters, self.data.signature.return_type, self.data.signature.where_clauses } },
            .ref => .{ .list = node_refs[self.data.ref.start..self.data.ref.end] },
        };
    }
};

pub const Ast = struct {
    file_id: FileId,
    tokens: []const Token = &.{},
    nodes: []const Node = &.{},
    node_refs: []const Node.Index = &.{},

    pub fn nodeList(self: Ast, index: Node.Index) []const Node.Index {
        const node = self.nodes[(index.unwrap() orelse return &.{}).index()];
        std.debug.assert(node.dataTag() == .ref);
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
                inline else => |tag| if (!std.meta.eql(@field(left.data, @tagName(tag)), @field(right.data, @tagName(tag)))) return false,
            }
        }
        return std.mem.eql(Node.Index, a.node_refs, b.node_refs);
    }

    pub const deinit = value_operations.Owned(@This()).deinit;
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

pub const TypeComponents = struct {
    shape: union(enum) {
        empty,
        array: ArrayType,
        structure: *const StructDefinition,
        tuple: TupleType,
        variant: []const TypeId,
    } = .empty,
    index: usize = 0,

    pub const Component = struct {
        type_id: TypeId,
        kind: MemberKind = .owned,
        step: ReferencePathStep,
        count: u32 = 1,
    };

    pub inline fn next(self: *TypeComponents) ?Component {
        const count = switch (self.shape) {
            .empty => 0,
            .array => 1,
            .structure => |definition| definition.fields.len,
            .tuple => |tuple| tuple.members.len,
            .variant => |members| members.len,
        };
        if (self.index == count) return null;
        const index = self.index;
        self.index += 1;
        return switch (self.shape) {
            .empty => unreachable,
            .array => |array| .{ .type_id = array.element_type, .step = .element, .count = array.length },
            .structure => |definition| .{ .type_id = definition.fields[index].type_id, .kind = definition.fields[index].kind, .step = .{ .field = @intCast(index) } },
            .tuple => |tuple| .{ .type_id = tuple.members[index].type_id, .kind = tuple.members[index].kind, .step = .{ .field = @intCast(index) } },
            .variant => |members| .{ .type_id = members[index], .step = .{ .variant = members[index] } },
        };
    }
};

pub const OwnershipMember = enum { copy, move };

pub const Operation = enum {
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
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

    /// Operations are named by their spelling; unary minus is spelled `-` with one operand.
    pub fn fromName(name: []const u8, operands: ?usize) ?Operation {
        const operation = std.meta.stringToEnum(Operation, name) orelse return null;
        if (operation == .unary_minus) return null;
        if (operation == .@"-" and operands == 1) return .unary_minus;
        return operation;
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

    pub fn isPredicate(self: Operation) bool {
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
    converter: struct { file_id: FileId, ordinal: u32 },

    pub fn fromText(spelling: []const u8, operands: ?usize) Name {
        if (Operation.fromName(spelling, operands)) |operation| return .{ .operation = operation };
        return .{ .identifier = spelling };
    }

    pub fn text(self: Name) []const u8 {
        return switch (self) {
            .identifier => |identifier| identifier,
            .operation => |operation| operation.spelling(),
            .converter => "$converter",
        };
    }

    pub fn order(left: Name, right: Name) std.math.Order {
        const spelling = std.mem.order(u8, left.text(), right.text());
        if (spelling != .eq) return spelling;
        if (left == .operation and right == .operation)
            return std.math.order(left.operation.operandCount(), right.operation.operandCount());
        if (left == .converter and right == .converter) {
            const file = std.math.order(left.converter.file_id, right.converter.file_id);
            if (file != .eq) return file;
            return std.math.order(left.converter.ordinal, right.converter.ordinal);
        }
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
    overload,
    structure,
    static,
    top_level_entry,
    primitive,
};

pub const ConversionCandidate = struct {
    instance: InstanceId,
    input_type: TypeId,
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
    items: []const DiscoveredItem,

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
        is_converter: bool = false,
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
    entries: []const Entry,

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
    selective: ?[]const Selection,
    is_public: bool,

    pub const Selection = struct { original: ImportName, bound: ImportName };

    pub const deinit = value_operations.Owned(@This()).deinit;

    pub const eql = value_operations.Owned(@This()).eql;
};

pub const ImportDeclarations = struct {
    entries: []const ImportDeclaration,

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const NamespaceBinding = struct { module: ModuleId, members_visible: bool = true };

pub const NameReference = union(enum) {
    namespace: NamespaceBinding,
    declaration: InstanceId,
    overloaded_function: FunctionOverloadId,
    constant: CompileTimeValueId,
};

pub const FunctionOverloadId = enum(u32) { _ };

pub const FunctionOverloadSet = struct {
    candidates: []const InstanceId,
    declaration: ?InstanceId = null,

    pub const eql = value_operations.Owned(@This()).eql;
    pub const deinit = value_operations.Owned(@This()).deinit;
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
    modules: []const ModuleId,
    imports: []const FileImport,

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
        storage_cursor: StaticStorageCursor,
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
                // Primitive values are named after their types.
                inline .int, .int_literal, .string_literal, .byte, .bool, .unit, .none => |_, tag| @field(TypeId, @tagName(tag)),
                inline .storage_cursor, .function_ref => |typed| typed.type_id,
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
pub const StaticStorageCursor = struct { type_id: TypeId, data: ?ByteStringId = null, offset: u32 = 0 };
pub const StaticStringConstant = struct { type_id: TypeId, data: ByteStringId };

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

/// Uncatchable process exit requested by compile-time execution and handled by
/// the embedding compiler driver rather than rendered as a source diagnostic.
pub const CompilerControl = struct {
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
        return @backingInt(self) <= @backingInt(TypeId.string_literal);
    }
};

pub const VariantType = struct {
    members: []const TypeId,
};

pub const ParameterMode = enum {
    imm,
    ref,
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

pub const ResultMode = enum { owned, reference };

pub const MemberKind = enum { owned, reference };

pub const MemberSpec = struct {
    type_id: TypeId,
    kind: MemberKind = .owned,
};

pub const CallableType = struct {
    parameters: []const CallableParameter,
    return_type: TypeId,
    result_mode: ResultMode = .owned,

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
    /// Nonowning address used by typed IR. Source references have logical type T.
    reference: TypeId,
    variant: VariantType,
    callable: CallableType,
    structure: StructIdentity,
    array: ArrayType,
    tuple: TupleType,
};

pub const TupleType = struct {
    members: []const MemberSpec,
};

/// Logical result of consuming an init carrier. A projection describes a
/// construction-only wrapper's reference shape, not runtime wrapper storage.
pub const InitializerConstruction = struct {
    type_id: TypeId,
    projection: ?u32 = null,
    optional_allocation: bool = false,
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
    kind: MemberKind = .owned,
    type_id: TypeId,
    span: SourceSpan,
    is_public: bool = false,
};

pub const StructDefinition = struct {
    fields: []const StructField,
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
    field_offsets: []const u32,

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
    borrowed: FunctionValueId,
    initializer: FunctionValueId,

    pub fn valueUse(self: @This()) FunctionValueUse {
        return switch (self) {
            .prepared => |use| use,
            .deinit, .borrowed, .initializer => |source| .{ .value = source },
        };
    }

    pub fn valueId(self: @This()) FunctionValueId {
        return self.valueUse().value;
    }

    pub fn operand(self: anytype) OperandPointer(@TypeOf(self)) {
        return switch (self.*) {
            .prepared => |*use| &use.value,
            .deinit, .borrowed, .initializer => |*source| source,
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

    pub fn negated(self: PredicateOperation) PredicateOperation {
        return switch (self) {
            .lti => .gei,
            .gti => .lei,
            .lei => .gti,
            .gei => .lti,
            .eqi => .nei,
            .nei => .eqi,
            .eqb => .neb,
            .neb => .eqb,
            .eqt => .net,
            .net => .eqt,
        };
    }

    pub fn holds(self: PredicateOperation, order: std.math.Order) bool {
        return switch (self) {
            .lti => order == .lt,
            .gti => order == .gt,
            .lei => order != .gt,
            .gei => order != .lt,
            .eqi, .eqb, .eqt => order == .eq,
            .nei, .neb, .net => order != .eq,
        };
    }
};

pub const FunctionBranch = struct {
    target: FunctionBlockId,
    arguments: FunctionValueRange,
};

pub const FunctionTerminator = union(enum) {
    branch: FunctionBranch,
    predicate_branch: struct {
        operation: PredicateOperation,
        operands: BinaryOperands,
        then_branch: FunctionBranch,
        else_branch: FunctionBranch,
    },
    return_unit,
    return_value: FunctionValueUse,
    diverge,

    pub fn operands(self: anytype) [2]?OperandPointer(@TypeOf(self)) {
        return switch (self.*) {
            .predicate_branch => |*branch| .{ &branch.operands.lhs, &branch.operands.rhs },
            .return_value => |*use| .{ &use.value, null },
            .branch, .return_unit, .diverge => .{ null, null },
        };
    }

    pub fn branches(self: *FunctionTerminator) [2]?*FunctionBranch {
        return switch (self.*) {
            .branch => |*branch| .{ branch, null },
            .predicate_branch => |*branch| .{ &branch.then_branch, &branch.else_branch },
            .return_unit, .return_value, .diverge => .{ null, null },
        };
    }

    pub fn successors(self: *FunctionTerminator) [2]?*FunctionBlockId {
        return switch (self.*) {
            .branch => |*branch| .{ &branch.target, null },
            .predicate_branch => |*branch| .{ &branch.then_branch.target, &branch.else_branch.target },
            .return_unit, .return_value, .diverge => .{ null, null },
        };
    }

    pub fn successorCount(self: FunctionTerminator) u2 {
        var terminator = self;
        const targets = terminator.successors();
        return @as(u2, @intFromBool(targets[0] != null)) + @intFromBool(targets[1] != null);
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
    list_append,
    list_reserve,
    list_remove,
    list_consume,
    collection_append_bounded,
    collection_append_growing,
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
    parameters: []const FunctionParameterShape,
    static_names: []const []const u8 = &.{},

    pub fn specializationArgument(self: FunctionShape, arguments: []const CompileTimeValueId, name: []const u8) ?CompileTimeValueId {
        std.debug.assert(arguments.len <= self.static_names.len);
        for (self.static_names[0..arguments.len], arguments) |parameter_name, argument| {
            if (std.mem.eql(u8, parameter_name, name)) return argument;
        }
        return null;
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const FunctionCall = struct {
    target: union(enum) { direct: InstanceId, indirect: FunctionValueId, initializer: FunctionValueId },
    arguments: FunctionValueRange,
    return_type: TypeId,
    destination: ?FunctionValueId = null,

    pub fn operands(self: anytype) [2]?OperandPointer(@TypeOf(self)) {
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
    environment: ?CompileTimeBindingsId = null,
    type_id: TypeId,

    pub fn instance(self: FunctionReference) InstanceId {
        return .{ .item = self.target, .specialization = self.specialization, .environment = self.environment };
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

pub const CursorElement = struct {
    cursor: FunctionValueId,
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

pub const CompareOperation = struct {
    operation: PredicateOperation,
    operands: BinaryOperands,
};

pub const SelectOperation = struct {
    condition: FunctionValueId,
    then_value: FunctionValueId,
    else_value: FunctionValueId,
    type_id: TypeId,
};

pub const FillOperation = struct {
    first: FunctionValueId,
    count: FunctionValueId,
    value: FunctionValueId,
    type_id: TypeId,
};

pub const MoveOperation = struct {
    destination: FunctionValueId,
    source: FunctionValueId,
    count: FunctionValueId,
    type_id: TypeId,
    backward: bool,
};

pub const AggregateOperation = struct {
    fields: FunctionValueRange,
    type_id: TypeId,
};

pub const InitializerCaptureWrite = struct {
    parameter_index: u32,
    value: FunctionValueId,
    type_id: TypeId,
};

pub const FunctionInstruction = union(enum) {
    const_int: i32,
    const_int_literal: i64,
    const_string_literal: ByteStringId,
    const_static_string: StaticStringConstant,
    const_storage_cursor: StaticStorageCursor,
    storage_cursor: BorrowOperation,
    cursor_offset: CursorElement,
    cursor_element: CursorElement,
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
    initializer_capture_write: InitializerCaptureWrite,
    call: FunctionCall,
    static_conversion: struct { operand: FunctionValueId, type_id: TypeId, destination: ?FunctionValueId = null },
    negi: FunctionValueId,
    addi: BinaryOperands,
    subi: BinaryOperands,
    muli: BinaryOperands,
    divsi: BinaryOperands,
    compare: CompareOperation,
    select: SelectOperation,
    aggregate: AggregateOperation,
    fill: FillOperation,
    move: MoveOperation,

    pub fn operands(self: anytype) [3]?OperandPointer(@TypeOf(self)) {
        return switch (self.*) {
            .const_int, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .initializer_ref, .local_storage, .result_storage, .aggregate => .{ null, null, null },
            .variant_tag, .negi, .byte_to_int => |*operand| .{ operand, null, null },
            inline .variant_coerce, .variant_extract, .static_conversion => |*operation| .{ &operation.operand, if (operation.destination) |*destination| destination else null, null },
            .storage_projection => |*operation| .{ &operation.owner, null, null },
            .allocation_element => |*operation| .{ &operation.allocation, &operation.index, null },
            .array_element => |*operation| .{ &operation.array, &operation.index, null },
            inline .borrow_box, .borrow_read, .storage_cursor, .borrow_address => |*operation| .{ &operation.source, null, null },
            .cursor_offset, .cursor_element => |*operation| .{ &operation.cursor, &operation.index, null },
            .borrow_write => |*operation| .{ &operation.reference, &operation.value, null },
            .value_copy => |*operation| .{ &operation.source, if (operation.destination) |*destination| destination else null, null },
            .field_access => |*operation| .{ &operation.operand, null, null },
            .initializer_capture_write => |*operation| .{ &operation.value, null, null },
            .call => |*call| call.operands() ++ .{null},
            .addi, .subi, .muli, .divsi => |*binary| .{ &binary.lhs, &binary.rhs, null },
            .compare => |*operation| .{ &operation.operands.lhs, &operation.operands.rhs, null },
            .select => |*operation| .{ &operation.condition, &operation.then_value, &operation.else_value },
            .fill => |*operation| .{ &operation.first, &operation.count, &operation.value },
            .move => |*operation| .{ &operation.destination, &operation.source, &operation.count },
        };
    }

    pub fn integerResult(self: FunctionInstruction, lhs: i32, rhs: i32) ?i32 {
        return switch (self) {
            .addi => lhs +% rhs,
            .subi => lhs -% rhs,
            .muli => lhs *% rhs,
            .divsi => if (rhs == 0) null else if (rhs == -1) -%lhs else @divTrunc(lhs, rhs),
            else => unreachable,
        };
    }

    pub fn resultType(self: FunctionInstruction) TypeId {
        return switch (self) {
            // Each primitive constant is named after the type of its value.
            inline .const_int, .const_int_literal, .const_string_literal, .const_byte, .const_bool, .const_type, .const_unit, .const_none => |_, tag| @field(TypeId, @tagName(tag)["const_".len..]),
            .variant_tag, .negi, .addi, .subi, .muli, .divsi, .byte_to_int => .int,
            .borrow_write, .initializer_capture_write, .fill, .move => .unit,
            .compare => .bool,
            inline .select, .aggregate => |operation| operation.type_id,
            .local_storage, .result_storage => |type_id| type_id,
            .field_access => |operation| operation.field_type,
            inline .const_static_string, .const_storage_cursor, .storage_cursor, .cursor_offset, .cursor_element, .function_ref, .initializer_ref, .storage_projection, .allocation_element, .array_element, .borrow_box, .borrow_read, .borrow_address => |operation| operation.type_id,
            // Results written to a destination leave only unit in their own value.
            .variant_coerce, .variant_extract => |operation| if (operation.destination == null) operation.target_type else .unit,
            inline .value_copy, .static_conversion => |operation| if (operation.destination == null) operation.type_id else .unit,
            .call => |call| if (call.destination == null) call.return_type else .unit,
        };
    }
};

/// Paths describe references inside logical values, independently of the
/// address projections consumed by code generation.
/// A slot selector can be constant or affine in one immutable integer argument.
/// Unresolved runtime selectors widen to `element`, never to a guessed slot.
pub const ReferenceIndex = struct {
    parameter: ?u32 = null,
    offset: i32 = 0,
};

pub const ReferencePathStep = union(enum) {
    field: u32,
    variant: TypeId,
    element,
    element_at: ReferenceIndex,
    without_element: ?ReferenceIndex,
    without_field: u32,
    without_variant: TypeId,
    target,
    referent,
    descendants,

    pub fn isElement(step: @This()) bool {
        return step == .element or step == .element_at;
    }

    pub fn isExclusion(step: @This()) bool {
        return step == .without_element or step == .without_field or step == .without_variant;
    }

    pub fn indexSelector(step: @This()) ?ReferenceIndex {
        switch (step) {
            .element_at => |index| return index,
            .without_element => |index| return index,
            else => return null,
        }
    }

    pub fn matches(a: @This(), b: @This()) bool {
        if (a.isElement() and b.isElement()) return a.overlaps(b);
        return value_operations.equal(@This(), a, b);
    }

    pub fn overlaps(a: @This(), b: @This()) bool {
        if (a.isElement() and b.isElement()) {
            if (a == .element or b == .element) return true;
            const first = a.element_at;
            const second = b.element_at;
            if (first.parameter != second.parameter) return true;
            return first.offset == second.offset;
        }
        if (a.isExclusion() or b.isExclusion()) return true;
        return value_operations.equal(@This(), a, b);
    }
};

pub const ReferenceSourceKind = enum { place, contents };

pub const ReferenceOriginContract = struct {
    output_parameter: ?u32 = null,
    parameter: ?u32,
    kind: ReferenceSourceKind,
    source_path: FunctionValueRange,
    result_path: FunctionValueRange,
    readonly: bool,
    storage_depth: u32 = 0,
    recursive_storage: bool = false,
    variant_guard: bool = false,
    stable: bool = false,
    after_write: bool = false,
    reads_contents: bool = false,
    readonly_owned: ?TypeId = null,
};

pub const ReferenceRequirement = struct {
    parameter: u32,
    kind: ReferenceSourceKind,
    path: FunctionValueRange,
    written_type: ?TypeId = null,
    ends_lifetime: bool = false,
    storage_depth: u32 = 0,
    recursive_storage: bool = false,
};

pub const ReferenceExclusion = struct {
    reference: ReferenceOriginContract,
    invalidation: ReferenceOriginContract,
};

pub const ReferenceContract = struct {
    origins: []const ReferenceOriginContract = &.{},
    requirements: []const ReferenceRequirement = &.{},
    exclusions: []const ReferenceExclusion = &.{},
    paths: []const ReferencePathStep = &.{},

    pub const eql = value_operations.Owned(@This()).eql;
    pub const deinit = value_operations.Owned(@This()).deinit;

    /// Inference joins sets of dependencies; their discovery order is irrelevant.
    pub fn equivalent(left: @This(), right: @This()) bool {
        inline for (.{ "origins", "requirements", "exclusions" }, .{ sameOrigin, sameRequirement, sameExclusion }) |name, same| {
            const first = @field(left, name);
            const second = @field(right, name);
            if (first.len != second.len) return false;
            for (first) |entry| {
                for (second) |candidate| {
                    if (same(left, entry, right, candidate)) break;
                } else return false;
            }
        }
        return true;
    }

    pub fn sameExclusion(left: @This(), a: ReferenceExclusion, right: @This(), b: ReferenceExclusion) bool {
        return sameOrigin(left, a.reference, right, b.reference) and sameOrigin(left, a.invalidation, right, b.invalidation);
    }

    pub fn sameOrigin(left: @This(), a: ReferenceOriginContract, right: @This(), b: ReferenceOriginContract) bool {
        return a.output_parameter == b.output_parameter and a.parameter == b.parameter and a.kind == b.kind and a.readonly == b.readonly and a.readonly_owned == b.readonly_owned and
            a.storage_depth == b.storage_depth and a.recursive_storage == b.recursive_storage and a.variant_guard == b.variant_guard and a.stable == b.stable and a.after_write == b.after_write and a.reads_contents == b.reads_contents and
            samePath(left, a.source_path, right, b.source_path) and samePath(left, a.result_path, right, b.result_path);
    }

    pub fn sameRequirement(left: @This(), a: ReferenceRequirement, right: @This(), b: ReferenceRequirement) bool {
        return a.parameter == b.parameter and a.kind == b.kind and a.written_type == b.written_type and
            a.storage_depth == b.storage_depth and a.recursive_storage == b.recursive_storage and a.ends_lifetime == b.ends_lifetime and samePath(left, a.path, right, b.path);
    }

    pub fn samePath(left: @This(), a: FunctionValueRange, right: @This(), b: FunctionValueRange) bool {
        return value_operations.equal([]const ReferencePathStep, left.paths[a.start..a.end], right.paths[b.start..b.end]);
    }
};

pub const InlineFrameId = enum(u32) { root = std.math.maxInt(u32), _ };

pub const InlineFrame = struct {
    instance: InstanceId,
    call_span: SourceSpan,
    parent: InlineFrameId,
};

pub const FunctionBodyAnalysis = struct {
    reference_contract: ReferenceContract = .{},
    return_type: TypeId,
    /// ABI failure permission; init regions and consuming converters may inherit failure.
    /// Region entry arguments are addresses supplied by its private environment.
    is_initializer_region: bool = false,
    initializer_regions: []const FunctionBodyAnalysis = &.{},
    initializer_captures: []const FunctionValueId = &.{},
    parameter_modes: []const ParameterMode = &.{},
    block_arguments: []const FunctionBlockArgument = &.{},
    variant_coercion_tags: []const u32 = &.{},
    borrow_fields: []const BorrowProjection = &.{},
    branch_arguments: []const FunctionValueUse = &.{},
    call_arguments: []const FunctionCallArgument = &.{},
    aggregate_fields: []const FunctionValueId = &.{},
    instructions: []const Instruction = &.{},
    instruction_spans: []const SourceSpan = &.{},
    terminator_spans: []const SourceSpan = &.{},
    root_instance: ?InstanceId = null,
    inline_frames: []const InlineFrame = &.{},
    instruction_frames: []const InlineFrameId = &.{},
    terminator_frames: []const InlineFrameId = &.{},
    blocks: []const Block = &.{},
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
        visitFunctionValueReferences(self, context, visit);
    }

    pub const eql = value_operations.Owned(@This()).eql;

    pub const deinit = value_operations.Owned(@This()).deinit;
};

pub const FunctionBodyFinalization = struct {
    instructions: []FunctionInstruction,
    blocks: []FunctionBlock,
    call_arguments: []FunctionCallArgument,
    branch_arguments: []FunctionValueUse,
    initializer_captures: []FunctionValueId,
    aggregate_fields: []FunctionValueId = &.{},

    pub fn visitValueReferences(self: @This(), context: anytype, comptime visit: anytype) void {
        visitFunctionValueReferences(self, context, visit);
    }
};

fn OperandPointer(comptime Pointer: type) type {
    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const FunctionValueId else *FunctionValueId;
}

fn visitFunctionValueReferences(view: anytype, context: anytype, comptime visit: anytype) void {
    for (view.instructions) |*instruction| for (instruction.operands()) |operand| {
        if (operand) |value| visit(context, value);
    };
    for (view.blocks) |*block| for (block.terminator.operands()) |operand| {
        if (operand) |value| visit(context, value);
    };
    for (view.call_arguments) |*argument| visit(context, argument.operand());
    for (view.branch_arguments) |*argument| visit(context, &argument.value);
    for (view.initializer_captures) |*capture| visit(context, capture);
    for (view.aggregate_fields) |*field| visit(context, field);
}

/// Callable-instance key. Static argument tuples are interned separately so
/// query keys remain small and pointer-free.
pub const InstanceId = struct {
    item: ItemId,
    specialization: ?CompileTimeValueTupleId = null,
    environment: ?CompileTimeBindingsId = null,

    pub fn hash(self: InstanceId) u64 {
        var identity: u64 = @backingInt(self.item);
        if (self.specialization) |specialization|
            identity ^= std.hash.int(@as(u64, @backingInt(specialization)) + 1);
        if (self.environment) |environment|
            identity ^= std.math.rotl(u64, std.hash.int(@as(u64, @backingInt(environment)) + 1), 32);
        return std.hash.int(identity);
    }
};

pub const CompileTimeBindingsId = enum(u32) { _ };
pub const CompileTimeBindings = struct { bindings: []const StaticBinding };

pub const StaticBinding = struct {
    name: []const u8,
    /// Null records an unavailable runtime lexical name, without its data.
    value: ?CompileTimeValueId,
};

/// Owned identity of a source expression and its lexical static bindings.
/// Runtime lexical captures are rejected semantically.
pub const CompileTimeSite = struct {
    owner: InstanceId,
    node: Node.Index,
    expected_type: ?TypeId = null,
    public_annotation: bool = false,
    bindings: ?CompileTimeBindingsId = null,
    condition: bool = false,
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
    code: []const u8 = &.{},
    /// Nonzero power-of-two alignment required for the loaded code address.
    required_alignment: u32,
    relocations: []const Relocation = &.{},
    referenced_instances: []const InstanceId = &.{},
    constant_data: []const ByteString = &.{},
    requires_sigpipe_ignore: bool = false,
    /// Return addresses and caller frame sizes; consumed only on panic.
    trace_sites: []const TraceSite = &.{},
    /// The linker supplies the shared trace reporter to this runtime entrypoint.
    panic_trace_offset: ?u32 = null,

    pub const TraceSite = struct {
        return_offset: u32,
        stack_size: u32,
        label: []const u8,
    };

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
    pub fn eql(a: Diagnostic, b: Diagnostic) bool {
        return value_operations.equal(Diagnostic, a, b);
    }

    pub const Note = struct {
        span: SourceSpan,
        kind: enum { type_proof, proof_invalidated },
    };
    file_id: FileId,
    span: ?SourceSpan,
    kind: Kind,
    instance: ?InstanceId = null,
    notes: []const Note = &.{},

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

    pub const Message = struct {
        text: []const u8,
        source_label: bool = false,
    };

    fn kindFromDefinitions(comptime schema: anytype) type {
        @setEvalBranchQuota(10_000);
        const names = @typeInfo(@TypeOf(schema)).@"struct".field_names;
        var payloads: [names.len]type = undefined;
        for (names, 0..) |name, index| {
            const definition = @field(schema, name);
            payloads[index] = if (@TypeOf(definition) == type) definition else void;
        }
        return @Union(.auto, std.meta.FieldEnum(@TypeOf(schema)), names, &payloads, &@splat(.{}));
    }

    pub const Kind = kindFromDefinitions(definitions);

    pub fn message(comptime tag: std.meta.Tag(Kind)) Message {
        const definition = @field(definitions, @tagName(tag));
        if (@TypeOf(definition) == type) @compileError("missing custom renderer for diagnostic " ++ @tagName(tag));
        if (@TypeOf(definition) == Message) return definition;
        return .{ .text = definition };
    }

    const definitions = .{
        .expected_token = struct {
            expected: Token.Tag,
            found: Token.Tag,
        },
        .invalid_expression = Token.Tag,
        .unsupported_syntax = Token.Tag,
        .binding_else_must_exit = "a binding mismatch handler must exit its scope",
        .refutable_binding_requires_else = "this binding can mismatch; use an if binding or an explicit else handler",
        .unexpected_indented_block = "unexpected indented block; the previous expression does not introduce a block",
        .match_capture_must_be_immutable = "a match capture is immutable; use a bare name or `ref`, not `var`",
        .match_requires_arm = "a match requires at least one arm",
        .match_redundant_arm = "this match arm is fully covered by preceding arms",
        .match_not_exhaustive = TypeId,
        .match_pattern_incompatible = TypeMismatch,
        .match_literal_ambiguous = TypeId,
        .match_range_ambiguous = TypeId,
        .match_range_empty = "range pattern contains no values",
        .match_range_bound_not_integer = "range pattern bounds must be compile-time integers",
        .match_tuple_capture_type_ambiguous = "a tuple capture must have the same element type in every matching tuple alternative; use separate type arms",
        .match_tuple_pattern_incompatible = "no alternative of the matched value has a tuple shape compatible with this pattern",
        .match_guard_invalidates_subject = "a match condition cannot consume, mutate, or invalidate the retained subject or its captures",
        .indented_block_after_inline_body = "indented block cannot follow an inline function body; `->` starts the body, and the return type goes before it",
        .duplicate_top_level_declaration = Message{ .text = "top-level name is already declared", .source_label = true },
        .declaration_cycle = Message{ .text = "declaration depends on itself", .source_label = true },
        .static_initializer_not_supported = "this static initializer is not supported yet",
        .compile_time_call_cycle = "compile-time call recursively depends on the same function and arguments",
        .compile_time_division_by_zero = "division by zero during compile-time execution",
        .compile_time_unsupported_operation = "operation is not supported during compile-time execution",
        .compile_time_escaping_storage = "evaluation-owned storage cannot escape compile-time execution",
        .compile_time_panic = ByteStringId,
        .compile_time_call_trace = "called at compile time from here",
        .unsupported_external_declaration = "external function has no compiler-provided implementation",
        .invalid_external_signature = "external function signature does not match its compiler-provided implementation",
        .invalid_operation_signature = "operation function must match its exact compiler-specified signature",
        .invalid_membership_signature = "membership requires contains to borrow its receiver and tested value with imm and return bool",
        .ambiguous_operation_reference = "operator reference requires an unambiguous operand count or a function-type annotation",
        .empty_overload = "an overload declaration requires at least one function",
        .invalid_overload_candidate = "overload alternatives must name function declarations",
        .duplicate_overload_candidate = "function is already included in this overload set",
        .no_matching_overload = ?TypeId,
        .ambiguous_overload = "multiple overloads match; name an implementation explicitly",
        .overload_requires_callable_context = "an overload reference requires a function-type annotation",
        .struct_member_not_supported = "struct bodies support fields, namespace declarations, and `move`, `copy`, or `drop` properties",
        .duplicate_struct_member = Message{ .text = "struct member is already declared", .source_label = true },
        .reserved_ownership_member = Message{ .text = "`copy` and `move` are reserved for ownership capabilities", .source_label = true },
        .duplicate_struct_property = Message{ .text = "struct ownership property is already declared", .source_label = true },
        .unknown_struct_property = void,
        .invalid_struct_property_value = InvalidStructPropertyValue,
        .struct_ownership_hook_signature_mismatch = TypeMismatch,
        .struct_ownership_property_incompatible_with_fields = IncompatibleStructOwnershipProperty,
        .struct_field_type_not_supported = "this struct field type is not supported yet",
        .recursive_struct_containment = Message{ .text = "struct recursively contains itself by value through field", .source_label = true },
        .static_initializer_type_mismatch = TypeMismatch,
        .type_value_used_as_runtime_value = Message{ .text = "expected a value, found a type", .source_label = true },
        .compile_time_only_type = TypeId,
        .ambiguous_conversion = TypeMismatch,
        .ambiguous_variant_member = TypeMismatch,
        .tuple_context_not_tuple = "tuple expression requires a tuple type in this context",
        .destructure_requires_tuple = "tuple binding requires a tuple value",
        .destructure_requires_sequence = "sequence binding requires an Array, List, or Span value",
        .destructure_length_mismatch = struct { expected: u32, found: u32 },
        .tuple_member_count_mismatch = struct { expected: u32, found: u32 },
        .invalid_converter = "converter must have one immutable runtime source, one compile-time-only static source, or one deferred collection source",
        .invalid_converter_owner = "converter must be declared in the defining module of its source or target type",
        .value_used_as_type = Message{ .text = "expected a type, found a value", .source_label = true },
        .reference_projection_requires_member = "a reference condition must select one variant member or retain the full target type",
        .type_factory_requires_call = Message{ .text = "call this type-producing function to obtain a type", .source_label = true },
        .generic_struct_requires_specialization = void,
        .function_annotation_not_supported = "type annotations on function bindings are not supported yet",
        .parameter_mode_not_supported = "this parameter access mode is not supported yet",
        .initializer_already_consumed = "this init parameter has already been constructed or forwarded on a possible path",
        .initializer_requires_construction = "an init parameter can only be constructed into owned storage or forwarded to init",
        .initializer_consumed_in_loop = "a loop backedge cannot change an init parameter's pending state",
        .initializer_exit_outside_boundary = "return, break, and continue cannot exit a deferred initializer",
        .initializer_capture_conflict = "this write or consumption conflicts with a pending initializer capture",
        .static_parameter_requires_specialization = "a function with static parameters must be called with compile-time arguments",
        .static_argument_cannot_be_inferred = "cannot infer every static argument from the runtime argument types",
        .static_argument_inference_conflict = "runtime argument types infer conflicting values for a static parameter",
        .static_argument_not_supported = "this static argument is not supported yet",
        .comptime_runtime_capture = "compile-time expressions cannot capture runtime locals",
        .static_argument_type_mismatch = "static argument does not match the parameter type",
        .where_condition_failed = "function specialization does not satisfy this where condition",
        .duplicate_parameter = Message{ .text = "parameter name is already declared", .source_label = true },
        .parameter_type_missing = "parameter is missing its type; write it as `name: Type`",
        .parameter_type_not_supported = "this parameter type is not supported yet",
        .return_type_not_supported = "this return type is not supported yet",
        .top_level_return = "cannot return from top-level code",
        .break_outside_loop = "break is only allowed inside a loop",
        .continue_outside_loop = "continue is only allowed inside a loop",
        .import_outside_top_level = "import is only allowed at the top level",
        .misplaced_pub = "pub is only allowed on top-level static, function, struct, and import declarations",
        .namespace_used_as_value = "a module namespace is not a value",
        .unknown_namespace_member = Message{ .text = "unknown struct namespace member", .source_label = true },
        .missing_operation = struct { receiver: TypeId, operation: Operation },
        .invalid_namespace_owner = "qualified declaration owner must be a declared struct in the same module or a primitive in the registered standard prelude",
        .unknown_module = Message{ .text = "unknown module", .source_label = true },
        .unknown_imported_name = Message{ .text = "unknown imported name", .source_label = true },
        .private_access = Message{ .text = "declaration is not public", .source_label = true },
        .import_conflict = Message{ .text = "imported name is already declared", .source_label = true },
        .nested_declaration_not_supported = "nested declarations are not supported yet; move this declaration to the top level",
        .ownership_transfer_requires_place = "`^` can only transfer a local binding or one of its fields",
        .ownership_transfer_requires_owned_place = "cannot transfer this borrowed value; ownership remains with the caller",
        .partial_field_transfer_not_supported = "cannot transfer or join these fields independently under the current ownership rules",
        .explicit_drop_field_cannot_be_implicitly_ended = "cannot implicitly end an explicit-drop field; transfer or dispose of it on every path",
        .field_not_restored_before_mut_return = "a `mut` argument must have every transferred field restored before returning",
        .ownership_transfer_requires_owning_context = "remove `^`: this use borrows the value instead of taking ownership",
        .mutable_argument_requires_place = "argument to a `mut` parameter must be a writable place: a mutable local, borrowed result, or reference field with writable access",
        .mutable_argument_requires_mutable_place = "argument to a `mut` parameter must be a writable place: a mutable local, borrowed result, or reference field with writable access",
        .overlapping_mutable_arguments = "this `mut` argument accesses the same value as another argument in the call",
        .use_after_transfer = "cannot use this value after it was transferred with `^`",
        .possibly_transferred = "cannot use this value because it may already have been transferred with `^`",
        .replaced_value_used = "cannot use this value while it is replaced in its own storage; its type cannot move directly, so read or transfer it before the replacement",
        .consumed_storage_in_use = "cannot overwrite storage retained by a pending `deinit` argument; replace it after the call completes",
        .borrow_outlives_source = "borrow cannot outlive the value or storage it references",
        .borrow_requires_place = "borrowing a value's storage requires a named local or parameter, or one of its fields",
        .mutable_borrow_requires_writable_place = "a writable reference requires a mutable place or writable Ref",
        .reference_not_writable = "cannot modify a readonly reference",
        .transferred_value_not_restored_before_loop_backedge = "transferred value must be reassigned before the next loop iteration",
        .type_not_movable = TypeId,
        .relocation_requires_direct_move = TypeId,
        .type_not_copyable = TypeNotCopyable,
        .list_requires_automatic_drop = TypeId,
        .list_requires_direct_move = TypeId,
        .list_iteration_item_conflicts_with_end = TypeId,
        .borrow_write_requires_automatic_drop = TypeId,
        .borrow_write_requires_direct_move = TypeId,
        .box_requires_automatic_drop = TypeId,
        .box_extraction_requires_direct_move = TypeId,
        .value_requires_explicit_drop = TypeId,
        .expression_not_supported = "this expression is not supported yet",
        .invalid_collection_sequence = "collection_sequence must contain one owned List value matching its element type",
        .collection_requires_static_count = "Array construction requires a statically known element count; use List for runtime-sized results",
        .collection_size_out_of_range = "collection element count exceeds the supported range",
        .static_iteration_binding_mode = "static for bindings must be bare or const value bindings",
        .struct_initializer_not_struct = TypeId,
        .unknown_struct_field = Message{ .text = "unknown struct field", .source_label = true },
        .duplicate_struct_initializer_field = Message{ .text = "struct field is initialized more than once", .source_label = true },
        .missing_struct_initializer_field = struct { type_id: TypeId, field_index: u32 },
        .struct_initializer_field_type_mismatch = TypeMismatch,
        .field_access_not_struct = TypeId,
        .private_struct_field = TypeId,
        .public_field_private_type = "a public field's type cannot name a private declaration",
        .unknown_field = Message{ .text = "unknown struct field", .source_label = true },
        .duplicate_local_binding = Message{ .text = "binding is already declared in this scope", .source_label = true },
        .local_type_not_supported = "this local binding type is not supported yet",
        .float_type_not_supported = "the `float` type is not supported yet",
        .unknown_type = Message{ .text = "unknown type", .source_label = true },
        .unknown_value = Message{ .text = "unknown value", .source_label = true },
        .assignment_to_immutable = Message{ .text = "cannot assign to immutable binding", .source_label = true },
        .assignment_type_mismatch = TypeMismatch,
        .integer_literal_not_decimal = "integer literal must use decimal notation",
        .float_literal_not_supported = "float literals are not supported yet",
        .integer_literal_out_of_range = "integer literal is outside the supported i32 range",
        .invalid_string_escape = "invalid string escape",
        .invalid_string_utf8 = "string literal is not valid UTF-8",
        .condition_not_bool = TypeId,
        .inspection_type_not_supported = "this inspection type is not supported yet",
        .iterator_result_requires_end = TypeMismatch,
        .loop_invalidates_type_proof = "this loop can repeat after invalidating a type proof used in its body; test the type inside the loop",
        .condition_binding_must_be_immutable = "an `if` binding must use `const`, not `var`",
        .value_not_callable = Message{ .text = "value is not callable", .source_label = true },
        .duplicate_variant_member_type = "variant contains the same member type more than once",
        .local_type_mismatch = TypeMismatch,
        .comparison_operand_not_int = TypeId,
        .equality_operand_not_supported = TypeId,
        .equality_operand_type_mismatch = TypeMismatch,
        .missing_return_value = TypeId,
        .return_type_mismatch = TypeMismatch,
        .unknown_function = Message{ .text = "unknown function", .source_label = true },
        .call_argument_count_mismatch = struct { expected: u32, found: u32 },
        .call_argument_type_mismatch = TypeMismatch,
    };
};
