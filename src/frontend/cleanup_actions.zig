const std = @import("std");
const structures = @import("../structures.zig");
const shape = @import("cleanup_shape.zig");

/// An immutable selection of destruction operations, shared by provenance
/// analysis and emission. Locations and invocation-time origins remain separate.
pub const Actions = struct {
    type_id: structures.TypeId,
    operation: union(enum) {
        none,
        drop: ?structures.ReferenceContract,
        array: struct { length: u32, element: *const Actions },
        parts: []const Part,
    },

    pub const Part = struct { step: structures.ReferencePathStep, actions: *const Actions };

    pub fn hasReferenceEffects(self: Actions) bool {
        switch (self.operation) {
            .none => return false,
            .drop => |contract| {
                const references = contract orelse return false;
                if (references.requirements.len != 0 or references.service_mutations.len != 0) return true;
                for (references.origins) |origin| if (origin.output_parameter != null or origin.output_contextual != null) return true;
                return false;
            },
            .array => |array| return array.length != 0 and array.element.hasReferenceEffects(),
            .parts => |parts| {
                for (parts) |part| if (part.actions.hasReferenceEffects()) return true;
                return false;
            },
        }
    }
};

pub const Cache = std.AutoHashMapUnmanaged(structures.TypeId, *const Actions);

pub fn build(allocator: std.mem.Allocator, analysis: anytype, cache: *Cache, type_id: structures.TypeId, selections: []const shape.Selection, missing: []const []const structures.ReferencePathStep, fields_only: bool) anyerror!*const Actions {
    const whole = !fields_only and selections.len == 0 and missing.len == 0;
    if (whole) if (cache.get(type_id)) |cached| return cached;
    const result = try allocator.create(Actions);
    result.* = .{ .type_id = type_id, .operation = .none };
    const capabilities = (try analysis.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
    if ((!fields_only or (capabilities.drop == .custom and try analysis.facts().callable(type_id) != null)) and capabilities.drop != .fieldwise) {
        if (capabilities.drop == .custom) {
            const definition = (try analysis.facts().structDefinition(type_id)).?;
            result.operation = .{ .drop = (try analysis.functionReferenceContract(definition.ownership.drop.?.hook.?)) orelse return error.Unavailable };
        } else if (capabilities.requires_explicit_drop) result.operation = .{ .drop = null };
    } else if (capabilities.needs_automatic_drop or capabilities.requires_explicit_drop) {
        result.operation = try children(allocator, analysis, cache, type_id, selections, missing);
    }
    if (whole) try cache.put(allocator, type_id, result);
    return result;
}

fn children(allocator: std.mem.Allocator, analysis: anytype, cache: *Cache, type_id: structures.TypeId, selections: []const shape.Selection, missing: []const []const structures.ReferencePathStep) anyerror!@FieldType(Actions, "operation") {
    if (try analysis.facts().arrayType(type_id)) |array| {
        if (array.length == 0) return .none;
        if (selections.len == 0 and missing.len == 0)
            return .{ .array = .{ .length = array.length, .element = try build(allocator, analysis, cache, array.element_type, &.{}, &.{}, false) } };
        var parts: std.ArrayList(Actions.Part) = .empty;
        var index = array.length;
        while (index != 0) {
            index -= 1;
            const offset = std.math.cast(i32, index) orelse return error.AnalysisTooLarge;
            try appendPart(allocator, analysis, cache, &parts, array.element_type, .{ .element_at = .{ .offset = offset } }, selections, missing);
        }
        return .{ .parts = parts.items };
    }
    var parts: std.ArrayList(Actions.Part) = .empty;
    if (try analysis.facts().variantMembers(type_id)) |members| {
        for (shape.membersAt(selections, &.{}) orelse members) |member| {
            const specification = try analysis.facts().memberSpec(member);
            if (specification.kind == .reference) {
                const skipped = try allocator.create(Actions);
                skipped.* = .{ .type_id = member, .operation = .none };
                try parts.append(allocator, .{ .step = .{ .variant = member }, .actions = skipped });
            } else try appendPart(allocator, analysis, cache, &parts, member, .{ .variant = member }, selections, missing);
        }
    } else {
        var components = try analysis.facts().components(type_id);
        while (components.next()) |component| {
            if (component.kind == .reference or component.count == 0) continue;
            try appendPart(allocator, analysis, cache, &parts, component.type_id, component.step, selections, missing);
        }
        std.mem.reverse(Actions.Part, parts.items);
    }
    return .{ .parts = parts.items };
}

fn appendPart(allocator: std.mem.Allocator, analysis: anytype, cache: *Cache, parts: *std.ArrayList(Actions.Part), type_id: structures.TypeId, step: structures.ReferencePathStep, selections: []const shape.Selection, missing: []const []const structures.ReferencePathStep) !void {
    const remaining = (try shape.missingChildren(allocator, missing, step)) orelse return;
    const selected = try shape.children(allocator, selections, step);
    try parts.append(allocator, .{ .step = step, .actions = try build(allocator, analysis, cache, type_id, selected, remaining, false) });
}
