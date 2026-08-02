const std = @import("std");
const structures = @import("structures.zig");
const ast = @import("ast_new.zig");
const codegen = @import("codegen_new.zig");
const semantic = @import("semantic.zig");
const ssa = @import("ssa.zig");

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
        return try semantic.discoverItems(ctx.allocator(), &ast_value, source);
    }
};

pub const ItemLocations = struct {
    pub const Value = structures.ItemLoc;
    pub const Id = structures.ItemId;

    pub fn hash(value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, value.file_id);
        std.hash.autoHash(&hasher, value.kind);
        hasher.update(value.name);
        std.hash.autoHash(&hasher, value.disambiguator);
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

pub const IndexItems = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.ItemIndex;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const discovered = try ctx.get(DiscoverItems, file_id);
        const tree = discovered.* orelse return null;
        var entries: std.AutoArrayHashMapUnmanaged(structures.ItemId, u32) = .empty;
        errdefer entries.deinit(ctx.allocator());
        try entries.ensureTotalCapacity(ctx.allocator(), tree.items.len);
        for (tree.items) |item| {
            const item_id = try ctx.intern(ItemLocations, item.loc);
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

        var has_duplicates = false;
        for (index.ids()) |item_id| {
            const loc = try ctx.lookupInterned(ItemLocations, item_id);
            std.debug.assert(loc.file_id == file_id);
            if (loc.kind != .function or loc.disambiguator == 0) continue;

            // Discovery assigns source-order ordinals per function name, so a
            // nonzero ordinal is always a later declaration of a duplicate.
            has_duplicates = true;
            // Record ParseFile directly because a diagnostic span can move
            // while the indexed identities and declarations remain equal.
            const parsed = (try ctx.get(ParseFile, file_id)).* orelse unreachable;
            std.debug.assert(parsed.file_id == file_id);
            const declaration = index.resolve(item_id) orelse unreachable;
            std.debug.assert(declaration < parsed.nodes.len);
            const node = parsed.nodes[declaration];
            std.debug.assert(node.tag == .comptime_binding);
            std.debug.assert(node.token_index < parsed.tokens.len);
            const token = parsed.tokens[node.token_index];
            try ctx.emit(structures.Diagnostic, .{
                .file_id = file_id,
                .span = .{ .start = token.loc.start, .end = token.loc.end },
                .message = "duplicate top-level function name",
            });
        }
        if (has_duplicates) return null;

        var entries: std.ArrayList(structures.ModuleScope.Entry) = .empty;
        defer {
            for (entries.items) |entry| ctx.allocator().free(entry.name);
            entries.deinit(ctx.allocator());
        }
        for (index.ids()) |item_id| {
            const loc = try ctx.lookupInterned(ItemLocations, item_id);
            if (loc.kind != .function) continue;
            std.debug.assert(loc.file_id == file_id);
            std.debug.assert(loc.disambiguator == 0);

            const name = try ctx.allocator().dupe(u8, loc.name);
            errdefer ctx.allocator().free(name);
            try entries.append(ctx.allocator(), .{ .name = name, .item_id = item_id });
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
        return switch (semantic.analyzeFunctionSignature(&parsed, source, resolved.declaration)) {
            .success => |signature| signature,
            .unsupported => |issue| blk: {
                try emitSemanticIssue(ctx, resolved.file_id, issue);
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
        if (loc.kind == .function) {
            // Body analysis is defined only for function headers supported by
            // FunctionSignature; its payload is not needed yet.
            if ((try ctx.get(FunctionSignature, item_id)).* == null) return null;
        }
        const resolved = (try ctx.get(ResolveItem, item_id)).* orelse return null;
        const parsed = (try ctx.get(ParseFile, resolved.file_id)).* orelse return null;
        return switch (loc.kind) {
            .function => blk: {
                const source = (try ctx.input(SourceText, resolved.file_id)).*;
                const result = semantic.analyzeFunctionBody(&parsed, source, resolved.declaration);
                break :blk switch (result) {
                    .success => |body| body,
                    .unsupported => |issue| result_blk: {
                        try emitSemanticIssue(ctx, resolved.file_id, issue);
                        break :result_blk null;
                    },
                };
            },
            .top_level_entry => switch (semantic.analyzeEntryBody(&parsed, resolved.declaration)) {
                .empty => .unit,
                .unsupported => |issue| blk: {
                    try emitSemanticIssue(ctx, resolved.file_id, issue);
                    break :blk null;
                },
                .direct_call => |name_span| blk: {
                    const source = (try ctx.input(SourceText, resolved.file_id)).*;
                    std.debug.assert(name_span.start <= name_span.end);
                    std.debug.assert(name_span.end <= source.len);
                    const scope = (try ctx.get(BuildModuleScope, resolved.file_id)).* orelse break :blk null;
                    const target = scope.resolve(source[name_span.start..name_span.end]) orelse {
                        try emitSemanticIssue(ctx, resolved.file_id, .{
                            .span = name_span,
                            .message = "unknown function",
                        });
                        break :blk null;
                    };
                    const signature = (try ctx.get(FunctionSignature, target)).* orelse break :blk null;
                    std.debug.assert(signature.parameter_count == 0);
                    std.debug.assert(signature.return_type == .int);
                    break :blk .{ .direct_call = target };
                },
            },
        };
    }
};

fn emitSemanticIssue(ctx: anytype, file_id: structures.FileId, issue: semantic.Issue) !void {
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = issue.span,
        .message = issue.message,
    });
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

pub const LowerToSSA = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.SsaFunction;

    pub fn run(ctx: anytype, instance_id: Input) anyerror!Output {
        const body = (try ctx.get(AnalyzeFunctionBody, instance_id.item)).* orelse return null;
        return try ssa.lowerFunction(body, ctx.allocator());
    }
};

pub const CompileFunction = struct {
    pub const Input = structures.InstanceId;
    pub const Output = ?structures.CompiledFunction;

    pub fn run(ctx: anytype, instance_id: Input) anyerror!Output {
        const lowered = (try ctx.get(LowerToSSA, instance_id)).* orelse return null;
        return try codegen.compileFunction(&lowered, ctx.allocator());
    }
};

pub const BuildExecutable = struct {
    pub const Input = structures.FileId;
    pub const Output = ?structures.Executable;

    pub fn run(ctx: anytype, file_id: Input) anyerror!Output {
        const entry_id = (try ctx.get(SelectEntry, file_id)).* orelse return null;
        const artifact = (try ctx.get(CompileFunction, .{ .item = entry_id })).* orelse return null;

        // CompileFunction currently emits only the one-call shape: matching
        // relocation/reference counts of 0 or 1.
        std.debug.assert(artifact.relocations.len == artifact.referenced_instances.len);
        std.debug.assert(artifact.relocations.len <= 1);

        var callee: ?structures.CompiledFunction = null;
        if (artifact.referenced_instances.len == 1) {
            callee = (try ctx.get(CompileFunction, artifact.referenced_instances[0])).* orelse return null;
        }

        return try codegen.buildExecutable(&artifact, if (callee) |*target| target else null, ctx.allocator());
    }
};
