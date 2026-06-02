const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const db = @import("db.zig");

pub const DiscoveredItem = struct {
    id: db.ItemId,
    name: []const u8,
    decl: ast.NodeIdx,
    body: ?db.BodyId,
};

pub const ItemTree = struct {
    source_id: db.SourceId,
    module_id: db.ModuleId,
    items: std.ArrayList(DiscoveredItem),

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }
};

pub const DiscoverMemo = db.Memo(ItemTree);

pub fn computeDiscover(
    source_id: db.SourceId,
    parse_memo: *const db.Memo(parser.ParsedAst),
    gpa: std.mem.Allocator,
) error{OutOfMemory}!DiscoverMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, parse_memo.diagnostics.items, 0);
    errdefer diagnostics_list.deinit(gpa);

    var value: ?ItemTree = null;
    if (parse_memo.value) |*parsed| {
        value = try discoverItems(source_id, &parsed.ast, gpa);
    }

    return db.makeMemo(ItemTree, value, diagnostics_list);
}

fn discoverItems(source_id: db.SourceId, parsed_ast: *const ast.Ast, gpa: std.mem.Allocator) error{OutOfMemory}!ItemTree {
    const module_id: db.ModuleId = .{ .package_id = 0, .source_id = source_id };
    var items = try std.ArrayList(DiscoveredItem).initCapacity(gpa, parsed_ast.decls.len + 1);
    errdefer items.deinit(gpa);

    for (parsed_ast.decls) |decl| {
        const node = parsed_ast.nodes[decl];
        const item_kind = itemKindForTag(node.tag) orelse continue;
        const name = parsed_ast.identOf(node.data0);
        const item_id: db.ItemId = .{
            .module = module_id,
            .kind = item_kind,
            .name_hash = stableNameHash(item_kind, name),
        };
        try items.append(gpa, .{
            .id = item_id,
            .name = name,
            .decl = decl,
            .body = bodyForDecl(parsed_ast, item_id, decl),
        });
    }

    if (parsed_ast.entry != std.math.maxInt(ast.NodeIdx) and parsed_ast.nodes[parsed_ast.entry].tag != .unit_lit) {
        const item_id: db.ItemId = .{
            .module = module_id,
            .kind = .top_level_entry,
            .name_hash = stableNameHash(.top_level_entry, "$entry"),
        };
        try items.append(gpa, .{
            .id = item_id,
            .name = "$entry",
            .decl = parsed_ast.entry,
            .body = .{ .owner = item_id, .kind = .top_level_entry },
        });
    }

    return .{
        .source_id = source_id,
        .module_id = module_id,
        .items = items,
    };
}

fn itemKindForTag(tag: ast.Tag) ?db.ItemKind {
    return switch (tag) {
        .comptime_fn => .function,
        .comptime_value_decl => .comptime_value,
        .comptime_struct => .comptime_struct,
        else => null,
    };
}

fn bodyForDecl(parsed_ast: *const ast.Ast, item_id: db.ItemId, decl: ast.NodeIdx) ?db.BodyId {
    return switch (parsed_ast.nodes[decl].tag) {
        .comptime_fn => .{ .owner = item_id, .kind = .function },
        .comptime_value_decl => .{ .owner = item_id, .kind = .comptime_value },
        else => null,
    };
}

fn stableNameHash(kind: db.ItemKind, name: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(@tagName(kind));
    hasher.update(":");
    hasher.update(name);
    return hasher.final();
}
