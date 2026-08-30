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
        keyword_false,
        keyword_func,
        keyword_for,
        keyword_if,
        keyword_is,
        keyword_mut,
        keyword_not,
        keyword_none,
        keyword_or,
        keyword_read,
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
        .{ "false", .keyword_false },
        .{ "func", .keyword_func },
        .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        .{ "is", .keyword_is },
        .{ "mut", .keyword_mut },
        .{ "not", .keyword_not },
        .{ "none", .keyword_none },
        .{ "or", .keyword_or },
        .{ "read", .keyword_read },
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
        @"and",
        @"or",
        not,
        neg,
        access,
        assign,
        block,
        bool_literal,
        call,
        call_arg_list_small,
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
        param,
        param_list_small,
        param_list,
        query_op,
        move_expr,
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
        type_list_small,
        type_list,
        type_variant_small,
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

    pub fn eql(a: Ast, b: Ast) bool {
        if (a.file_id != b.file_id) return false;
        if (a.tokens.len != b.tokens.len or a.nodes.len != b.nodes.len or a.node_refs.len != b.node_refs.len) return false;
        for (a.tokens, b.tokens) |left, right| {
            if (!std.meta.eql(left, right)) return false;
        }
        for (a.nodes, b.nodes) |left, right| {
            if (left.tag != right.tag or left.token_index != right.token_index) return false;
            switch (left.tag) {
                .return_nothing, .access, .bool_literal, .identifier, .none_literal, .number_literal, .type => {},
                .return_expr, .not, .neg, .query_op, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .struct_field, .struct_property, .struct_init_field => {
                    if (left.data.node != right.data.node) return false;
                },
                .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .call, .call_arg_list_small, .const_binding, .var_binding, .static_binding, .func, .param, .param_list_small, .signature, .type_func, .type_list_small, .type_variant_small, .@"if" => {
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
    top_level_entry,
};

/// Stable within a file across edits that do not rename the item, change its
/// kind, or reorder same-name duplicates. `ItemTree` and the item interner own
/// their respective copies of `name`.
pub const ItemLoc = struct {
    file_id: FileId,
    kind: ItemKind,
    name: []const u8,
    disambiguator: u32,

    pub fn eql(a: ItemLoc, b: ItemLoc) bool {
        return a.file_id == b.file_id and a.kind == b.kind and a.disambiguator == b.disambiguator and std.mem.eql(u8, a.name, b.name);
    }
};

pub const DiscoveredItem = struct {
    loc: ItemLoc,
    declaration: u32,
};

pub const ItemTree = struct {
    file_id: FileId,
    items: []DiscoveredItem,

    pub fn eql(a: ItemTree, b: ItemTree) bool {
        if (a.file_id != b.file_id or a.items.len != b.items.len) return false;
        for (a.items, b.items) |left, right| {
            if (!ItemLoc.eql(left.loc, right.loc) or left.declaration != right.declaration) return false;
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
    };

    pub fn resolve(self: ModuleScope, name: []const u8) ?ItemId {
        const index = std.sort.binarySearch(Entry, self.entries, name, struct {
            fn compare(target: []const u8, entry: Entry) std.math.Order {
                return std.mem.order(u8, target, entry.name);
            }
        }.compare) orelse return null;
        return self.entries[index].item_id;
    }

    pub fn eql(a: ModuleScope, b: ModuleScope) bool {
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |left, right| {
            if (left.item_id != right.item_id or !std.mem.eql(u8, left.name, right.name)) return false;
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

pub const Type = enum {
    int,
    unit,
};

pub const FunctionValueId = enum(u32) { _ };
pub const FunctionBlockId = enum(u32) { _ };

pub const FunctionValueRange = struct {
    start: u32,
    end: u32,
};

pub fn functionInstructionValue(argument_count: usize, instruction_index: usize) FunctionValueId {
    return @enumFromInt(argument_count + instruction_index);
}

pub const BinaryOperands = struct {
    lhs: FunctionValueId,
    rhs: FunctionValueId,
};

pub const PredicateOperation = enum {
    lti,
    gti,
    lei,
    gei,
    eqi,
    nei,
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
    return_value: FunctionValueId,
};

pub const FunctionBlock = struct {
    argument_start: u32 = 0,
    argument_end: u32 = 0,
    instruction_start: u32,
    instruction_end: u32,
    terminator: FunctionTerminator,
};

pub const FunctionSignature = struct {
    parameter_types: []const Type,
    return_type: Type,

    pub fn eql(a: FunctionSignature, b: FunctionSignature) bool {
        return a.return_type == b.return_type and std.mem.eql(Type, a.parameter_types, b.parameter_types);
    }

    pub fn deinit(self: *FunctionSignature, gpa: std.mem.Allocator) void {
        gpa.free(self.parameter_types);
        self.* = undefined;
    }
};

pub fn FunctionCall(comptime CallTarget: type) type {
    return struct {
        target: CallTarget,
        arguments: FunctionValueRange,
        return_type: Type,
    };
}

pub fn FunctionInstruction(comptime CallTarget: type) type {
    return union(enum) {
        consti: i32,
        call: FunctionCall(CallTarget),
        exit: FunctionValueId,
        negi: FunctionValueId,
        addi: BinaryOperands,
        subi: BinaryOperands,
        muli: BinaryOperands,
        divsi: BinaryOperands,
    };
}

/// Owned function control-flow graph. Block arguments, branch operands, call
/// operands, and instructions use flat arrays while each block owns its ranges
/// and terminator. CallTarget is the only representation difference between
/// semantic and per-instance IR.
pub fn FunctionIr(comptime CallTarget: type) type {
    return struct {
        block_argument_types: []Type,
        branch_arguments: []ValueId,
        call_arguments: []ValueId,
        instructions: []Instruction,
        blocks: []Block,
        entry: BlockId,

        pub const ValueId = FunctionValueId;
        pub const BlockId = FunctionBlockId;
        pub const Instruction = FunctionInstruction(CallTarget);
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
                !std.mem.eql(Type, a.block_argument_types, b.block_argument_types) or
                !std.mem.eql(ValueId, a.branch_arguments, b.branch_arguments) or
                !std.mem.eql(ValueId, a.call_arguments, b.call_arguments) or
                a.instructions.len != b.instructions.len or
                a.blocks.len != b.blocks.len) return false;
            for (a.instructions, b.instructions) |left, right| {
                if (!std.meta.eql(left, right)) return false;
            }
            for (a.blocks, b.blocks) |left, right| {
                if (!std.meta.eql(left, right)) return false;
            }
            return true;
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.block_argument_types);
            gpa.free(self.branch_arguments);
            gpa.free(self.call_arguments);
            gpa.free(self.instructions);
            gpa.free(self.blocks);
            self.* = undefined;
        }
    };
}

pub const FunctionBodyAnalysis = FunctionIr(ItemId);

/// Structural non-generic instance key. Future generic substitutions extend
/// this identity without changing declaration identity.
pub const InstanceId = struct {
    item: ItemId,
};

/// Owned per-instance SSA control-flow graph.
pub const SsaFunction = FunctionIr(InstanceId);

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
    message: []const u8,
    message_allocated: bool = false,

    pub fn eql(a: Diagnostic, b: Diagnostic) bool {
        return a.file_id == b.file_id and
            std.meta.eql(a.span, b.span) and
            std.mem.eql(u8, a.message, b.message);
    }

    pub fn clone(gpa: std.mem.Allocator, value: Diagnostic) std.mem.Allocator.Error!Diagnostic {
        return .{
            .file_id = value.file_id,
            .span = value.span,
            .message = try gpa.dupe(u8, value.message),
            .message_allocated = true,
        };
    }

    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        if (self.message_allocated) gpa.free(self.message);
        self.* = undefined;
    }
};
