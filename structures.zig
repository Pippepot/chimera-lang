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
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "and", .keyword_and },
        .{ "as", .keyword_as },
        .{ "break", .keyword_break },
        .{ "comptime", .keyword_comptime },
        .{ "const", .keyword_const },
        .{ "continue", .keyword_continue },
        .{ "deinit", .keyword_deinit },
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
        static_binding,
        comptime_expr,
        field_access,
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
        sizeof_expr,
        @"struct",
        struct_field,
        struct_property,
        struct_init,
        struct_init_field,
        type,
        type_func,
        type_list,
        type_variant,
        _,
    };

    pub const Data = union {
        none: void,
        node: Index,
        node_node: struct {
            a: Index,
            b: Index,
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
            .param_list, .type_variant, .type_list, .call_arg_list => {},
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
                .break_nothing, .continue_expr, .return_nothing, .access, .bool_literal, .identifier, .none_literal, .number_literal, .unit_literal, .type => {},
                .break_expr, .return_expr, .loop, .not, .neg, .query_op, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .struct_field, .struct_property, .struct_init_field => {
                    if (left.data.node != right.data.node) return false;
                },
                .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .call, .const_binding, .var_binding, .static_binding, .func, .param, .signature, .type_func, .@"if" => {
                    if (left.data.node_node.a != right.data.node_node.a or left.data.node_node.b != right.data.node_node.b) return false;
                },
                .block, .call_arg_list, .param_list, .type_list, .type_variant, .if_else, .@"struct", .struct_init => {
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

pub const ItemId = enum(u32) { _ };

pub const ItemKind = enum {
    function,
    structure,
    static,
    top_level_entry,
};

/// Stable within an owner across edits that do not rename the item or change
/// its kind. Top-level items have no owner. `ItemTree` and the item interner own
/// their respective copies of `name`.
pub const ItemLoc = struct {
    file_id: FileId,
    owner: ?ItemId = null,
    kind: ItemKind,
    name: []const u8,

    pub fn eql(a: ItemLoc, b: ItemLoc) bool {
        return a.file_id == b.file_id and a.owner == b.owner and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
    }
};

pub const DiscoveredItem = struct {
    loc: ItemLoc,
    declaration: u32,
    parent: ?u32 = null,
};

pub const ItemTree = struct {
    file_id: FileId,
    items: []DiscoveredItem,

    pub fn eql(a: ItemTree, b: ItemTree) bool {
        if (a.file_id != b.file_id or a.items.len != b.items.len) return false;
        for (a.items, b.items) |left, right| {
            if (!ItemLoc.eql(left.loc, right.loc) or left.declaration != right.declaration or left.parent != right.parent) return false;
        }
        return true;
    }

    pub fn deinit(self: *ItemTree, gpa: std.mem.Allocator) void {
        for (self.items) |item| gpa.free(item.loc.name);
        gpa.free(self.items);
        self.* = undefined;
    }
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
        name: []const u8,
        item_id: ItemId,
        kind: ItemKind,
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

    fn resolveEntry(self: ModuleScope, name: []const u8) ?Entry {
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
            if (left.item_id != right.item_id or left.kind != right.kind or !std.mem.eql(u8, left.name, right.name)) return false;
        }
        return true;
    }

    pub fn deinit(self: *ModuleScope, gpa: std.mem.Allocator) void {
        for (self.entries) |entry| gpa.free(entry.name);
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub const ResolvedItem = struct {
    file_id: FileId,
    declaration: u32,
};

pub const CompileTimeValue = union(enum) {
    type: TypeId,
    runtime: struct {
        type_id: TypeId,
        value: RuntimeValue,
    },

    pub const RuntimeValue = union(enum) {
        int: i32,
        bool: bool,
        unit,
        none,
        function_ref: FunctionReference,

        pub fn typeId(self: @This()) TypeId {
            return switch (self) {
                .int => .int,
                .bool => .bool,
                .unit => .unit,
                .none => .none,
                .function_ref => |reference| reference.type_id,
            };
        }
    };
};

/// Database interner index carried inside a non-primitive TypeId. The remaining
/// TypeId bit distinguishes interned identities from reserved primitive IDs.
pub const InternedTypeId = enum(u31) { _ };

pub const TypeId = enum(u32) {
    int,
    bool,
    unit,
    none,
    never,
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
        return self == .int or self == .bool or self == .unit or self == .none or self == .never;
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

    pub fn parametersEql(a: CallableType, b: CallableType) bool {
        return callableParametersEql(a.parameters, b.parameters);
    }

    pub fn eql(a: CallableType, b: CallableType) bool {
        return a.return_type == b.return_type and
            a.is_fallible == b.is_fallible and
            a.parametersEql(b);
    }

    pub fn deinit(self: *CallableType, gpa: std.mem.Allocator) void {
        gpa.free(self.parameters);
        self.* = undefined;
    }
};

pub const TypeData = union(enum) {
    variant: VariantType,
    callable: CallableType,
    structure: ItemId,
};

pub const InternVariantResult = union(enum) {
    type_id: TypeId,
    duplicate: TypeId,
};

/// Representation facts shared by every runtime type. Type-specific metadata,
/// such as field or payload offsets, belongs to that representation's query.
pub const TypeLayout = struct {
    byte_size: u32,
    byte_alignment: u32,
};

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
        if (a.fields.len != b.fields.len or !std.meta.eql(a.ownership, b.ownership)) return false;
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
            hook: ?ItemId = null,
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
    contains_custom_copy: bool = false,
    needs_automatic_drop: bool = false,
    requires_explicit_drop: bool = false,
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

pub const PredicateOperation = enum {
    lti,
    gti,
    lei,
    gei,
    eqi,
    nei,
    eqb,
    neb,
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
    fallible_call: struct {
        call: FunctionCall,
        success: FunctionBlockId,
        failure: FunctionBlockId,
    },
    fallible_indirect_call: struct {
        call: IndirectFunctionCall,
        success: FunctionBlockId,
        failure: FunctionBlockId,
    },
    return_unit,
    return_value: FunctionValueUse,
    return_failure,
    diverge,
};

pub const FunctionBlock = struct {
    argument_start: u32 = 0,
    argument_end: u32 = 0,
    instruction_start: u32,
    instruction_end: u32,
    terminator: FunctionTerminator,
};

/// Function-signature query outputs own `parameters`; interned callable types
/// clone the same value shape into session-stable storage.
pub const FunctionSignature = CallableType;

pub const FunctionCall = struct {
    target: ItemId,
    arguments: FunctionValueRange,
    return_type: TypeId,
};

pub const IndirectFunctionCall = struct {
    target: FunctionValueId,
    arguments: FunctionValueRange,
    return_type: TypeId,
};

pub const FunctionReference = struct {
    target: ItemId,
    type_id: TypeId,
};

pub const VariantOperation = struct {
    operand: FunctionValueId,
    target_type: TypeId,
    tag_mapping: ?FunctionValueRange = null,
};

pub const StructFieldValue = struct {
    field_index: u32,
    value: FunctionValueId,
};

pub const StructOperation = struct {
    fields: FunctionValueRange,
    type_id: TypeId,
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
};

pub const FunctionInstruction = union(enum) {
    consti: i32,
    constb: bool,
    const_unit,
    const_none,
    function_ref: FunctionReference,
    variant_tag: FunctionValueId,
    variant_coerce: VariantOperation,
    variant_extract: VariantOperation,
    callable_coerce: VariantOperation,
    struct_init: StructOperation,
    field_access: FieldAccessOperation,
    field_update: FieldUpdateOperation,
    mut_parameter_write: MutParameterWrite,
    call_mut_argument: CallMutArgument,
    call: FunctionCall,
    indirect_call: IndirectFunctionCall,
    exit: FunctionValueId,
    negi: FunctionValueId,
    addi: BinaryOperands,
    subi: BinaryOperands,
    muli: BinaryOperands,
    divsi: BinaryOperands,

    pub fn resultType(self: FunctionInstruction) TypeId {
        return switch (self) {
            .consti, .variant_tag, .negi, .addi, .subi, .muli, .divsi => .int,
            .constb => .bool,
            .const_unit => .unit,
            .const_none => .none,
            .exit => .never,
            .function_ref => |reference| reference.type_id,
            .variant_coerce, .variant_extract, .callable_coerce => |operation| operation.target_type,
            .struct_init => |operation| operation.type_id,
            .field_access => |operation| operation.field_type,
            .field_update => |operation| operation.type_id,
            .mut_parameter_write => .unit,
            .call_mut_argument => |operation| operation.type_id,
            .call => |call| call.return_type,
            .indirect_call => |call| call.return_type,
        };
    }
};

/// Owned function control-flow graph. Block arguments, branch operands, call
/// operands, and instructions use flat arrays while each block owns its ranges
/// and terminator. Calls retain declaration identities until code emission.
pub const FunctionBodyAnalysis = struct {
    return_type: TypeId,
    is_fallible: bool = false,
    block_argument_types: []TypeId,
    variant_coercion_tags: []const u32 = &.{},
    struct_field_values: []StructFieldValue = &.{},
    branch_arguments: []FunctionValueUse,
    call_arguments: []FunctionValueUse,
    instructions: []Instruction,
    blocks: []Block,
    entry: BlockId,

    pub const ValueId = FunctionValueId;
    pub const BlockId = FunctionBlockId;
    pub const Instruction = FunctionInstruction;
    pub const Terminator = FunctionTerminator;
    pub const Block = FunctionBlock;

    pub fn instructionValue(self: @This(), instruction_index: usize) ValueId {
        std.debug.assert(instruction_index < self.instructions.len);
        return functionInstructionValue(self.block_argument_types.len, instruction_index);
    }

    pub fn valueCount(self: @This()) usize {
        return self.block_argument_types.len + self.instructions.len;
    }

    pub fn eql(a: @This(), b: @This()) bool {
        if (a.entry != b.entry or
            a.return_type != b.return_type or
            a.is_fallible != b.is_fallible or
            !std.mem.eql(TypeId, a.block_argument_types, b.block_argument_types) or
            !std.mem.eql(u32, a.variant_coercion_tags, b.variant_coercion_tags) or
            a.struct_field_values.len != b.struct_field_values.len or
            !valueUsesEql(a.branch_arguments, b.branch_arguments) or
            !valueUsesEql(a.call_arguments, b.call_arguments) or
            a.instructions.len != b.instructions.len or
            a.blocks.len != b.blocks.len) return false;
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

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.block_argument_types);
        gpa.free(self.variant_coercion_tags);
        gpa.free(self.struct_field_values);
        gpa.free(self.branch_arguments);
        gpa.free(self.call_arguments);
        gpa.free(self.instructions);
        gpa.free(self.blocks);
        self.* = undefined;
    }
};

/// Structural non-generic instance key. Future generic substitutions extend
/// this identity without changing declaration identity.
pub const InstanceId = struct {
    item: ItemId,
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
        trivial_copy,
        fieldwise_copy,
        trivial_drop,
    };

    pub const MissingStructInitializerField = struct {
        name_span: SourceSpan,
    };

    pub const Kind = union(enum) {
        expected_token: struct {
            expected: Token.Tag,
            found: Token.Tag,
        },
        invalid_expression: Token.Tag,
        duplicate_top_level_declaration,
        declaration_cycle,
        static_initializer_not_supported,
        struct_member_not_supported,
        duplicate_struct_field,
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
        function_annotation_not_supported,
        parameter_mode_not_supported,
        duplicate_parameter,
        parameter_type_missing,
        parameter_type_not_supported,
        return_type_not_supported,
        top_level_return,
        break_outside_loop,
        continue_outside_loop,
        nested_declaration_not_supported,
        ownership_transfer_requires_place,
        ownership_transfer_requires_owned_place,
        ownership_transfer_requires_owning_context,
        mutable_argument_requires_place,
        mutable_argument_requires_mutable_place,
        overlapping_mutable_arguments,
        use_after_transfer,
        possibly_transferred,
        transferred_value_not_restored_before_loop_backedge,
        type_not_movable: TypeId,
        type_not_copyable: TypeNotCopyable,
        value_requires_explicit_drop: TypeId,
        expression_not_supported,
        struct_initializer_not_struct: TypeId,
        unknown_struct_field,
        duplicate_struct_initializer_field,
        missing_struct_initializer_field: MissingStructInitializerField,
        struct_initializer_field_type_mismatch: TypeMismatch,
        field_access_not_struct: TypeId,
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
