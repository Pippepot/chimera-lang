const std = @import("std");
const structures = @import("../structures.zig");
const shape = @import("cleanup_shape.zig");

/// What destroying a value demands of its owner.
pub const Obligations = struct {
    automatic: bool = false,
    explicit: bool = false,

    pub fn any(self: Obligations) bool {
        return self.automatic or self.explicit;
    }

    fn include(self: *Obligations, child: Obligations) void {
        self.automatic = self.automatic or child.automatic;
        self.explicit = self.explicit or child.explicit;
    }
};

/// Checks and observable side effects do not by themselves change the contents
/// used to resolve a later reference read. Unknown service payloads may do so.
pub const Effects = struct {
    validation: bool = false,
    contents: bool = false,
    service_mutations: bool = false,
    context: structures.ContextEffects = .{},

    pub fn mayWriteContents(self: Effects) bool {
        return self.contents or self.service_mutations;
    }

    pub fn any(self: Effects) bool {
        return self.validation or self.mayWriteContents() or self.context.reads != 0 or self.context.writes != 0;
    }

    fn include(self: *Effects, child: Effects) void {
        self.validation = self.validation or child.validation;
        self.contents = self.contents or child.contents;
        self.service_mutations = self.service_mutations or child.service_mutations;
        self.context.include(child.context);
    }
};

pub const EffectsCache = std.AutoHashMapUnmanaged(*const Actions, Effects);

/// An immutable selection of destruction operations, shared by provenance
/// analysis, emission, and ownership obligations. Locations and invocation-time
/// origins remain separate. Hook contracts are queried only by consumers of effects.
pub const Actions = struct {
    type_id: structures.TypeId,
    operation: union(enum) {
        none,
        /// The type's custom drop hook.
        hook,
        /// A value that must be transferred or passed to a `deinit` parameter.
        explicit,
        array: struct { length: u32, element: *const Actions },
        parts: []const Part,
    },

    pub const Part = struct { step: structures.ReferencePathStep, actions: *const Actions };

    pub fn obligations(self: Actions) Obligations {
        switch (self.operation) {
            .none => return .{},
            .hook => return .{ .automatic = true },
            .explicit => return .{ .explicit = true },
            .array => |array| return if (array.length == 0) .{} else array.element.obligations(),
            .parts => |parts| {
                var result: Obligations = .{};
                for (parts) |part| result.include(part.actions.obligations());
                return result;
            },
        }
    }

    pub fn hookContract(analysis: anytype, type_id: structures.TypeId) anyerror!structures.ReferenceContract {
        const definition = (try analysis.facts().structDefinition(type_id)).?;
        return (try analysis.functionReferenceContract(definition.ownership.drop.?.hook.?)) orelse error.Unavailable;
    }

    pub fn effects(self: *const Actions, allocator: std.mem.Allocator, analysis: anytype, cache: *EffectsCache) anyerror!Effects {
        if (cache.get(self)) |cached| return cached;
        var result: Effects = .{};
        switch (self.operation) {
            .none, .explicit => {},
            .hook => result = try hookEffects(analysis, self.type_id),
            .array => |array| if (array.length != 0) {
                result = try array.element.effects(allocator, analysis, cache);
            },
            .parts => |parts| {
                for (parts) |part| result.include(try part.actions.effects(allocator, analysis, cache));
            },
        }
        try cache.put(allocator, self, result);
        return result;
    }
};

fn hookEffects(analysis: anytype, type_id: structures.TypeId) !Effects {
    const references = try Actions.hookContract(analysis, type_id);
    var result: Effects = .{
        .validation = references.requirements.len != 0 or references.exclusions.len != 0,
        .service_mutations = references.service_mutations.len != 0,
        .context = references.context_effects,
    };
    for (references.requirements) |requirement| {
        if (requirement.kind != .contents) continue;
        const written_type = requirement.written_type orelse continue;
        if (try analysis.facts().canStoreBorrow(written_type)) result.contents = true;
    }
    return result;
}

pub const Cache = std.AutoHashMapUnmanaged(structures.TypeId, *const Actions);

pub fn build(allocator: std.mem.Allocator, analysis: anytype, cache: *Cache, type_id: structures.TypeId, selections: []const shape.Selection, missing: []const []const structures.ReferencePathStep, fields_only: bool) anyerror!*const Actions {
    const whole = !fields_only and selections.len == 0 and missing.len == 0;
    if (whole) if (cache.get(type_id)) |cached| return cached;
    const result = try allocator.create(Actions);
    result.* = .{ .type_id = type_id, .operation = .none };
    const capabilities = (try analysis.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
    if ((!fields_only or (capabilities.drop == .custom and try analysis.facts().callable(type_id) != null)) and capabilities.drop != .fieldwise) {
        if (capabilities.drop == .custom) {
            result.operation = .hook;
        } else if (capabilities.requires_explicit_drop) result.operation = .explicit;
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
