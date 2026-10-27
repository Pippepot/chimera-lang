const std = @import("std");
const structures = @import("../structures.zig");

/// Restrictions on stored alternatives, relative to the unchanged owner layout.
/// Empty paths describe a variant owner; other paths describe nested variants.
pub const Selection = struct {
    path: []const structures.ReferencePathStep,
    members: []const structures.TypeId,
};

pub fn samePath(left: []const structures.ReferencePathStep, right: []const structures.ReferencePathStep) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

pub fn membersAt(selections: []const Selection, path: []const structures.ReferencePathStep) ?[]const structures.TypeId {
    for (selections) |selection| if (samePath(selection.path, path)) return selection.members;
    return null;
}

pub fn withMembers(allocator: std.mem.Allocator, selections: []const Selection, path: []const structures.ReferencePathStep, members: []const structures.TypeId) ![]const Selection {
    if (membersAt(selections, path)) |current| if (std.mem.eql(structures.TypeId, current, members)) return selections;
    var result: std.ArrayList(Selection) = .empty;
    for (selections) |selection| {
        if (!samePath(selection.path, path)) try result.append(allocator, selection);
    }
    try result.append(allocator, .{ .path = try allocator.dupe(structures.ReferencePathStep, path), .members = members });
    return result.toOwnedSlice(allocator);
}

pub fn children(allocator: std.mem.Allocator, selections: []const Selection, step: structures.ReferencePathStep) ![]const Selection {
    var result: std.ArrayList(Selection) = .empty;
    for (selections) |selection| {
        if (selection.path.len != 0 and std.meta.eql(selection.path[0], step))
            try result.append(allocator, .{ .path = selection.path[1..], .members = selection.members });
    }
    return result.toOwnedSlice(allocator);
}

pub fn typeAt(context: anytype, root: structures.TypeId, path: []const structures.ReferencePathStep) !?structures.TypeId {
    var current = root;
    for (path) |step| switch (step) {
        .field => |index| {
            const definition = (try context.structDefinition(current)) orelse return null;
            if (index >= definition.fields.len) return null;
            const field = definition.fields[index];
            if (field.kind == .reference) return null;
            current = field.type_id;
        },
        .variant => |member| {
            if (current != member) {
                const members = (try context.facts().variantMembers(current)) orelse return null;
                if (std.mem.indexOfScalar(structures.TypeId, members, member) == null) return null;
            }
            const specification = try context.facts().memberSpec(member);
            if (specification.kind == .reference) return null;
            current = specification.type_id;
        },
        else => return null,
    };
    return current;
}

pub fn requiresExplicit(allocator: std.mem.Allocator, context: anytype, type_id: structures.TypeId, selections: []const Selection, missing: []const []const structures.ReferencePathStep, fields_only: bool) anyerror!bool {
    const capabilities = (try context.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
    if (!fields_only and (capabilities.drop != .fieldwise or (selections.len == 0 and missing.len == 0))) return capabilities.requires_explicit_drop;
    if (try context.facts().variantMembers(type_id)) |all| {
        for (membersAt(selections, &.{}) orelse all) |member| {
            const specification = try context.facts().memberSpec(member);
            if (specification.kind == .reference) continue;
            const nested = try children(allocator, selections, .{ .variant = member });
            var nested_missing: std.ArrayList([]const structures.ReferencePathStep) = .empty;
            for (missing) |path| if (path.len != 0 and path[0] == .variant and path[0].variant == member)
                try nested_missing.append(allocator, path[1..]);
            if (try requiresExplicit(allocator, context, specification.type_id, nested, nested_missing.items, false)) return true;
        }
        return false;
    }
    const definition = (try context.structDefinition(type_id)) orelse return capabilities.requires_explicit_drop;
    fields: for (definition.fields, 0..) |field, index| {
        if (field.kind == .reference) continue;
        var nested_missing: std.ArrayList([]const structures.ReferencePathStep) = .empty;
        for (missing) |path| {
            std.debug.assert(path.len != 0);
            if (path[0] != .field or path[0].field != index) continue;
            if (path.len == 1) continue :fields;
            try nested_missing.append(allocator, path[1..]);
        }
        const nested = try children(allocator, selections, .{ .field = @intCast(index) });
        if (try requiresExplicit(allocator, context, field.type_id, nested, nested_missing.items, false)) return true;
    }
    return false;
}
