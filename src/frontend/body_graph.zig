const std = @import("std");
const structures = @import("../structures.zig");

pub const GenerationId = enum(u32) { _ };
pub const BoundaryId = enum(u32) { _ };
pub const EffectId = enum(u32) { _ };

pub const Generation = struct {
    type_id: structures.TypeId,
    start_order: u32,
    span: structures.SourceSpan,
    requires_explicit_drop: bool,
    cleanup_fields: bool,
    cleanup_condition: ?structures.FunctionValueId = null,
    missing_fields: []const []const u32 = &.{},
};

pub const LifetimeEffect = union(enum) {
    define: struct { generation: GenerationId, value: structures.FunctionValueId },
    use: Use,
    update: Use,
    consume: GenerationId,

    const Use = struct {
        generation: GenerationId,
        cleanup_value: structures.FunctionValueId,
        cleanup_condition: ?structures.FunctionValueId = null,
    };
};

pub const OwnershipForward = union(enum) {
    forward: struct { source: GenerationId, destination: GenerationId },
    produce: GenerationId,
    unowned: GenerationId,
};

pub const OwnershipEdge = struct {
    predecessor: structures.FunctionBlockId,
    successor_ordinal: u2,
    successor: structures.FunctionBlockId,
    mappings: structures.FunctionValueRange,
};

pub const CleanupLocation = union(enum) {
    boundary: BoundaryId,
    edge: struct { predecessor: structures.FunctionBlockId, successor_ordinal: u2 },
    block_entry: structures.FunctionBlockId,
};

pub const PlannedEnding = struct {
    generation: GenerationId,
    cleanup_value: structures.FunctionValueId,
    cleanup_condition: ?structures.FunctionValueId = null,
    location: CleanupLocation,
};

pub const Effect = struct {
    id: EffectId,
    operation: ?LifetimeEffect = null,
};

pub const Boundary = struct {
    span: structures.SourceSpan,
    effects: std.ArrayList(Effect) = .empty,
};

pub const BuildInstruction = struct {
    id: u31,
    operation: structures.FunctionInstruction,
    span: structures.SourceSpan,
};

pub const BuildItem = union(enum) { instruction: BuildInstruction, boundary: BoundaryId };

pub const BuildBlock = struct {
    argument_start: u32,
    argument_end: u32,
    items: std.ArrayList(BuildItem) = .empty,
    terminator_effects: std.ArrayList(Effect) = .empty,
    reference_effect: ?EffectId = null,
    layout_index: ?u32 = null,
    terminator: ?structures.FunctionTerminator = null,
    terminator_span: ?structures.SourceSpan = null,
};
