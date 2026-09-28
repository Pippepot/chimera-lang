const std = @import("std");
const structures = @import("../structures.zig");
pub const GenerationId = enum(u32) { _ };
pub const BoundaryId = enum(u32) { _ };

pub const Generation = struct {
    type_id: structures.TypeId,
    start_order: u32,
    span: structures.SourceSpan,
    requires_explicit_drop: bool,
    can_deinit: bool,
    cleanup_condition: ?structures.FunctionValueId = null,
    missing_fields: []const []const u32 = &.{},
};

pub const LifetimeEffect = union(enum) {
    define: struct {
        generation: GenerationId,
        value: structures.FunctionValueId,
    },
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
    forward: struct {
        source: GenerationId,
        destination: GenerationId,
    },
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
    edge: struct {
        predecessor: structures.FunctionBlockId,
        successor_ordinal: u2,
    },
    block_entry: structures.FunctionBlockId,
};

pub const PlannedCleanup = struct {
    generation: GenerationId,
    cleanup_value: structures.FunctionValueId,
    cleanup_condition: ?structures.FunctionValueId = null,
    location: CleanupLocation,
};

pub const ExplicitAbandonment = struct {
    generation: GenerationId,
    location: CleanupLocation,
};

pub const Boundary = struct {
    span: structures.SourceSpan,
    effects: std.ArrayList(LifetimeEffect) = .empty,
};

pub const BuildInstruction = struct {
    id: u31,
    operation: structures.FunctionInstruction,
    span: structures.SourceSpan,
};

pub const BuildItem = union(enum) {
    instruction: BuildInstruction,
    boundary: BoundaryId,
};

pub const BuildBlock = struct {
    argument_start: u32,
    argument_end: u32,
    items: std.ArrayList(BuildItem) = .empty,
    terminator_effects: std.ArrayList(LifetimeEffect) = .empty,
    layout_index: ?u32 = null,
    terminator: ?structures.FunctionTerminator = null,
    terminator_span: ?structures.SourceSpan = null,
};

const GenerationBits = struct {
    fn wordCount(generation_count: usize) usize {
        return (generation_count + 63) / 64;
    }

    fn clear(bits: []u64) void {
        @memset(bits, 0);
    }

    fn copy(destination: []u64, source: []const u64) void {
        std.debug.assert(destination.len == source.len);
        @memcpy(destination, source);
    }

    fn contains(bits: []const u64, generation: GenerationId) bool {
        const index = @intFromEnum(generation);
        return bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }

    fn insert(bits: []u64, generation: GenerationId) void {
        const index = @intFromEnum(generation);
        bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    }

    fn remove(bits: []u64, generation: GenerationId) void {
        const index = @intFromEnum(generation);
        bits[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
    }

    fn unionWith(destination: []u64, source: []const u64) void {
        std.debug.assert(destination.len == source.len);
        for (destination, source) |*word, source_word| word.* |= source_word;
    }

    fn intersectWith(destination: []u64, source: []const u64) void {
        std.debug.assert(destination.len == source.len);
        for (destination, source) |*word, source_word| word.* &= source_word;
    }
};

pub const Solver = struct {
    const BlockEdges = struct {
        outgoing: [2]?usize = .{ null, null },
        first_incoming: ?usize = null,
    };

    gpa: std.mem.Allocator,
    generations: []const Generation,
    boundaries: []const Boundary,
    blocks: []const BuildBlock,
    block_argument_generations: []const ?GenerationId,
    ownership_forwards: []const OwnershipForward,
    ownership_edges: []const OwnershipEdge,
    block_edges: []BlockEdges,
    previous_incoming: []?usize,
    entry: structures.FunctionBlockId,
    reachable: []bool,
    available_in: []u64,
    available_out: []u64,
    representations_in: []?structures.FunctionValueId,
    representations_out: []?structures.FunctionValueId,
    live_in: []u64,
    live_out: []u64,
    scratch: []u64,
    edge_scratch: []u64,
    representation_scratch: []?structures.FunctionValueId,
    edge_representation_scratch: []?structures.FunctionValueId,
    words_per_block: usize,

    pub fn init(
        gpa: std.mem.Allocator,
        generations: []const Generation,
        boundaries: []const Boundary,
        blocks: []const BuildBlock,
        block_argument_generations: []const ?GenerationId,
        ownership_forwards: []const OwnershipForward,
        ownership_edges: []const OwnershipEdge,
        entry: structures.FunctionBlockId,
    ) !Solver {
        const block_edges = try gpa.alloc(BlockEdges, blocks.len);
        errdefer gpa.free(block_edges);
        @memset(block_edges, .{});
        const previous_incoming = try gpa.alloc(?usize, ownership_edges.len);
        errdefer gpa.free(previous_incoming);
        for (ownership_edges, 0..) |edge, edge_index| {
            const predecessor = &block_edges[@intFromEnum(edge.predecessor)];
            std.debug.assert(predecessor.outgoing[edge.successor_ordinal] == null);
            predecessor.outgoing[edge.successor_ordinal] = edge_index;
            const successor = &block_edges[@intFromEnum(edge.successor)];
            previous_incoming[edge_index] = successor.first_incoming;
            successor.first_incoming = edge_index;
        }
        const words_per_block = GenerationBits.wordCount(generations.len);
        const matrix_len = std.math.mul(usize, blocks.len, words_per_block) catch return error.AnalysisTooLarge;
        const reachable = try gpa.alloc(bool, blocks.len);
        errdefer gpa.free(reachable);
        const available_in = try gpa.alloc(u64, matrix_len);
        errdefer gpa.free(available_in);
        const available_out = try gpa.alloc(u64, matrix_len);
        errdefer gpa.free(available_out);
        const representation_len = std.math.mul(usize, blocks.len, generations.len) catch return error.AnalysisTooLarge;
        const representations_in = try gpa.alloc(?structures.FunctionValueId, representation_len);
        errdefer gpa.free(representations_in);
        const representations_out = try gpa.alloc(?structures.FunctionValueId, representation_len);
        errdefer gpa.free(representations_out);
        const live_in = try gpa.alloc(u64, matrix_len);
        errdefer gpa.free(live_in);
        const live_out = try gpa.alloc(u64, matrix_len);
        errdefer gpa.free(live_out);
        const scratch = try gpa.alloc(u64, words_per_block);
        errdefer gpa.free(scratch);
        const edge_scratch = try gpa.alloc(u64, words_per_block);
        errdefer gpa.free(edge_scratch);
        const representation_scratch = try gpa.alloc(?structures.FunctionValueId, generations.len);
        errdefer gpa.free(representation_scratch);
        const edge_representation_scratch = try gpa.alloc(?structures.FunctionValueId, generations.len);
        errdefer gpa.free(edge_representation_scratch);
        @memset(reachable, false);
        @memset(available_in, 0);
        @memset(available_out, 0);
        @memset(representations_in, null);
        @memset(representations_out, null);
        @memset(live_in, 0);
        @memset(live_out, 0);
        return .{
            .gpa = gpa,
            .generations = generations,
            .boundaries = boundaries,
            .blocks = blocks,
            .block_argument_generations = block_argument_generations,
            .ownership_forwards = ownership_forwards,
            .ownership_edges = ownership_edges,
            .block_edges = block_edges,
            .previous_incoming = previous_incoming,
            .entry = entry,
            .reachable = reachable,
            .available_in = available_in,
            .available_out = available_out,
            .representations_in = representations_in,
            .representations_out = representations_out,
            .live_in = live_in,
            .live_out = live_out,
            .scratch = scratch,
            .edge_scratch = edge_scratch,
            .representation_scratch = representation_scratch,
            .edge_representation_scratch = edge_representation_scratch,
            .words_per_block = words_per_block,
        };
    }

    pub fn deinit(self: *Solver) void {
        self.gpa.free(self.block_edges);
        self.gpa.free(self.previous_incoming);
        self.gpa.free(self.reachable);
        self.gpa.free(self.available_in);
        self.gpa.free(self.available_out);
        self.gpa.free(self.representations_in);
        self.gpa.free(self.representations_out);
        self.gpa.free(self.live_in);
        self.gpa.free(self.live_out);
        self.gpa.free(self.scratch);
        self.gpa.free(self.edge_scratch);
        self.gpa.free(self.representation_scratch);
        self.gpa.free(self.edge_representation_scratch);
        self.* = undefined;
    }

    pub fn solve(
        self: *Solver,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
    ) !void {
        std.debug.assert(planned_cleanups.items.len == 0);
        std.debug.assert(explicit_abandonments.items.len == 0);
        try self.computeReachability();
        self.solveAvailability();
        self.solveRepresentations();
        self.solveDemand();
        const entry_demand = self.blockSet(self.live_in, self.entry);
        for (entry_demand) |word| std.debug.assert(word == 0);
        try self.planEndings(planned_cleanups, explicit_abandonments);
        self.validatePathComplete(planned_cleanups.items, explicit_abandonments.items);
    }

    fn computeReachability(self: *Solver) !void {
        std.debug.assert(@intFromEnum(self.entry) < self.blocks.len);
        var worklist: std.ArrayList(structures.FunctionBlockId) = .empty;
        defer worklist.deinit(self.gpa);
        self.reachable[@intFromEnum(self.entry)] = true;
        try worklist.append(self.gpa, self.entry);
        while (worklist.pop()) |block| {
            const terminator = self.blocks[@intFromEnum(block)].terminator orelse unreachable;
            const successor_count = terminator.successorCount();
            for (0..successor_count) |ordinal| {
                const edge = self.findEdge(block, @intCast(ordinal));
                const successor_index = @intFromEnum(edge.successor);
                std.debug.assert(successor_index < self.blocks.len);
                if (self.reachable[successor_index]) continue;
                self.reachable[successor_index] = true;
                try worklist.append(self.gpa, edge.successor);
            }
        }
    }

    fn solveDemand(self: *Solver) void {
        var changed = true;
        while (changed) {
            changed = false;
            var block_index = self.blocks.len;
            while (block_index > 0) {
                block_index -= 1;
                if (!self.reachable[block_index]) continue;
                const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
                const block_value = self.blocks[block_index];
                GenerationBits.clear(self.scratch);
                const terminator = block_value.terminator orelse unreachable;
                for (0..terminator.successorCount()) |ordinal| {
                    const edge = self.findEdge(block_id, @intCast(ordinal));
                    std.debug.assert(self.reachable[@intFromEnum(edge.successor)]);
                    GenerationBits.copy(self.edge_scratch, self.blockSet(self.live_in, edge.successor));
                    self.remapEdgeDemand(self.edge_scratch, edge, true);
                    GenerationBits.intersectWith(self.edge_scratch, self.blockSet(self.available_out, block_id));
                    GenerationBits.unionWith(self.scratch, self.edge_scratch);
                }
                if (!std.mem.eql(u64, self.blockSet(self.live_out, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.live_out, block_id), self.scratch);
                    changed = true;
                }
                self.scanEffectsBackward(self.scratch, block_value.terminator_effects.items);
                var item_index = block_value.items.items.len;
                while (item_index > 0) {
                    item_index -= 1;
                    switch (block_value.items.items[item_index]) {
                        .instruction => {},
                        .boundary => |boundary| self.scanEffectsBackward(
                            self.scratch,
                            self.boundaries[@intFromEnum(boundary)].effects.items,
                        ),
                    }
                }
                if (!std.mem.eql(u64, self.blockSet(self.live_in, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.live_in, block_id), self.scratch);
                    changed = true;
                }
            }
        }
    }

    fn solveAvailability(self: *Solver) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.blocks, 0..) |block_value, block_index| {
                if (!self.reachable[block_index]) continue;
                const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
                GenerationBits.clear(self.scratch);
                if (block_id != self.entry) {
                    var incoming = self.block_edges[block_index].first_incoming;
                    while (incoming) |edge_index| : (incoming = self.previous_incoming[edge_index]) {
                        const edge = &self.ownership_edges[edge_index];
                        if (!self.reachable[@intFromEnum(edge.predecessor)]) continue;
                        GenerationBits.copy(self.edge_scratch, self.blockSet(self.available_out, edge.predecessor));
                        self.remapEdgeAvailability(self.edge_scratch, edge);
                        GenerationBits.unionWith(self.scratch, self.edge_scratch);
                    }
                }
                if (!std.mem.eql(u64, self.blockSet(self.available_in, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.available_in, block_id), self.scratch);
                    changed = true;
                }
                for (block_value.items.items) |item| switch (item) {
                    .instruction => {},
                    .boundary => |boundary| self.scanEffectsForward(
                        self.scratch,
                        self.boundaries[@intFromEnum(boundary)].effects.items,
                    ),
                };
                self.scanEffectsForward(self.scratch, block_value.terminator_effects.items);
                if (!std.mem.eql(u64, self.blockSet(self.available_out, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.available_out, block_id), self.scratch);
                    changed = true;
                }
            }
        }
    }

    fn solveRepresentations(self: *Solver) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.blocks, 0..) |block_value, block_index| {
                if (!self.reachable[block_index]) continue;
                const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
                @memset(self.representation_scratch, null);
                if (block_id != self.entry) {
                    var incoming = self.block_edges[block_index].first_incoming;
                    while (incoming) |edge_index| : (incoming = self.previous_incoming[edge_index]) {
                        const edge = &self.ownership_edges[edge_index];
                        if (!self.reachable[@intFromEnum(edge.predecessor)]) continue;
                        @memcpy(self.edge_representation_scratch, self.blockRepresentations(self.representations_out, edge.predecessor));
                        self.remapEdgeRepresentations(self.edge_representation_scratch, edge);
                        GenerationBits.copy(self.edge_scratch, self.blockSet(self.available_out, edge.predecessor));
                        self.remapEdgeAvailability(self.edge_scratch, edge);
                        for (self.edge_representation_scratch, 0..) |representation, generation_index| {
                            if (!GenerationBits.contains(self.edge_scratch, @enumFromInt(generation_index))) continue;
                            const value = representation orelse continue;
                            if (self.representation_scratch[generation_index]) |existing| {
                                if (self.blockArgumentValue(block_value, @enumFromInt(generation_index)) == null) {
                                    std.debug.assert(existing == value);
                                }
                            } else {
                                self.representation_scratch[generation_index] = value;
                            }
                        }
                    }
                }
                for (block_value.argument_start..block_value.argument_end) |argument| {
                    const generation = self.block_argument_generations[argument] orelse continue;
                    self.representation_scratch[@intFromEnum(generation)] = @enumFromInt(argument);
                }
                if (!std.mem.eql(?structures.FunctionValueId, self.blockRepresentations(self.representations_in, block_id), self.representation_scratch)) {
                    @memcpy(self.blockRepresentations(self.representations_in, block_id), self.representation_scratch);
                    changed = true;
                }
                for (block_value.items.items) |item| switch (item) {
                    .instruction => {},
                    .boundary => |boundary| self.scanRepresentationsForward(
                        self.representation_scratch,
                        self.boundaries[@intFromEnum(boundary)].effects.items,
                    ),
                };
                self.scanRepresentationsForward(self.representation_scratch, block_value.terminator_effects.items);
                if (!std.mem.eql(?structures.FunctionValueId, self.blockRepresentations(self.representations_out, block_id), self.representation_scratch)) {
                    @memcpy(self.blockRepresentations(self.representations_out, block_id), self.representation_scratch);
                    changed = true;
                }
            }
        }
        for (self.blocks, 0..) |_, block_index| {
            if (!self.reachable[block_index]) continue;
            const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
            for (self.generations, 0..) |_, generation_index| {
                const generation: GenerationId = @enumFromInt(generation_index);
                if (GenerationBits.contains(self.blockSet(self.available_in, block_id), generation)) {
                    std.debug.assert(self.blockRepresentations(self.representations_in, block_id)[generation_index] != null);
                }
                if (GenerationBits.contains(self.blockSet(self.available_out, block_id), generation)) {
                    std.debug.assert(self.blockRepresentations(self.representations_out, block_id)[generation_index] != null);
                }
            }
        }
        for (self.ownership_edges) |edge| {
            if (!self.reachable[@intFromEnum(edge.predecessor)]) continue;
            const available = self.blockSet(self.available_out, edge.predecessor);
            const representations = self.blockRepresentations(self.representations_out, edge.predecessor);
            for (self.ownership_forwards[edge.mappings.start..edge.mappings.end]) |mapping| switch (mapping) {
                .forward => |forward| {
                    if (GenerationBits.contains(available, forward.source)) {
                        std.debug.assert(representations[@intFromEnum(forward.source)] != null);
                    }
                },
                .produce => |destination| {
                    std.debug.assert(self.blockArgumentValue(self.blocks[@intFromEnum(edge.successor)], destination) != null);
                },
                .unowned => {},
            };
        }
    }

    fn scanRepresentationsForward(_: *const Solver, representations: []?structures.FunctionValueId, effects: []const LifetimeEffect) void {
        for (effects) |effect| switch (effect) {
            .define => |definition| representations[@intFromEnum(definition.generation)] = definition.value,
            .use => {},
            .update => |update| representations[@intFromEnum(update.generation)] = update.cleanup_value,
            .consume => |generation| representations[@intFromEnum(generation)] = null,
        };
    }

    fn remapEdgeRepresentations(self: *const Solver, representations: []?structures.FunctionValueId, edge: *const OwnershipEdge) void {
        const mappings = self.ownership_forwards[edge.mappings.start..edge.mappings.end];
        for (mappings) |mapping| switch (mapping) {
            .forward => |forward| {
                const source = &representations[@intFromEnum(forward.source)];
                representations[@intFromEnum(forward.destination)] = source.*;
                source.* = null;
            },
            .produce => |destination| {
                const block = self.blocks[@intFromEnum(edge.successor)];
                representations[@intFromEnum(destination)] = self.blockArgumentValue(block, destination) orelse unreachable;
            },
            .unowned => |destination| representations[@intFromEnum(destination)] = null,
        };
    }

    fn blockArgumentValue(self: *const Solver, block: BuildBlock, generation: GenerationId) ?structures.FunctionValueId {
        for (block.argument_start..block.argument_end) |argument| {
            if (self.block_argument_generations[argument] == generation) return @enumFromInt(argument);
        }
        return null;
    }

    fn remapEdgeAvailability(self: *const Solver, available: []u64, edge: *const OwnershipEdge) void {
        const mappings = self.ownership_forwards[edge.mappings.start..edge.mappings.end];
        for (mappings) |mapping| switch (mapping) {
            .forward => |forward| {
                const source_available = GenerationBits.contains(available, forward.source);
                GenerationBits.remove(available, forward.source);
                if (source_available) GenerationBits.insert(available, forward.destination) else GenerationBits.remove(available, forward.destination);
            },
            .produce => |destination| GenerationBits.insert(available, destination),
            .unowned => |destination| GenerationBits.remove(available, destination),
        };
    }

    fn scanEffectsForward(_: *const Solver, available: []u64, effects: []const LifetimeEffect) void {
        for (effects) |effect| switch (effect) {
            .define => |definition| GenerationBits.insert(available, definition.generation),
            .use, .update => {},
            .consume => |generation| GenerationBits.remove(available, generation),
        };
    }

    fn remapEdgeDemand(
        self: *const Solver,
        demand: []u64,
        edge: *const OwnershipEdge,
        require_unused_sources: bool,
    ) void {
        const mappings = self.ownership_forwards[edge.mappings.start..edge.mappings.end];
        for (mappings) |mapping| switch (mapping) {
            .forward => |forward| {
                if (GenerationBits.contains(demand, forward.destination)) {
                    GenerationBits.remove(demand, forward.destination);
                    GenerationBits.insert(demand, forward.source);
                } else if (require_unused_sources) {
                    GenerationBits.insert(demand, forward.source);
                }
            },
            .produce, .unowned => |destination| GenerationBits.remove(demand, destination),
        };
    }

    fn planEndings(
        self: *Solver,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
    ) !void {
        for (self.blocks, 0..) |block_value, block_index| {
            if (!self.reachable[block_index]) continue;
            const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
            try self.planEdges(block_id, block_value.terminator orelse unreachable, planned_cleanups, explicit_abandonments);
            GenerationBits.copy(self.scratch, self.blockSet(self.live_out, block_id));
            try self.planEffectsBackward(
                self.scratch,
                block_value.terminator_effects.items,
                null,
                block_id,
                block_value.terminator orelse unreachable,
                planned_cleanups,
                explicit_abandonments,
            );
            var item_index = block_value.items.items.len;
            while (item_index > 0) {
                item_index -= 1;
                switch (block_value.items.items[item_index]) {
                    .instruction => {},
                    .boundary => |boundary| try self.planEffectsBackward(
                        self.scratch,
                        self.boundaries[@intFromEnum(boundary)].effects.items,
                        boundary,
                        block_id,
                        block_value.terminator orelse unreachable,
                        planned_cleanups,
                        explicit_abandonments,
                    ),
                }
            }
            std.debug.assert(std.mem.eql(u64, self.scratch, self.blockSet(self.live_in, block_id)));
        }
        self.finishEndings(planned_cleanups, explicit_abandonments);
    }

    fn planEdges(
        self: *Solver,
        predecessor: structures.FunctionBlockId,
        terminator: structures.FunctionTerminator,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
    ) !void {
        const available = self.blockSet(self.available_out, predecessor);
        const demanded_on_some_edge = self.blockSet(self.live_out, predecessor);
        const representations = self.blockRepresentations(self.representations_out, predecessor);
        for (0..terminator.successorCount()) |ordinal| {
            const successor_ordinal: u2 = @intCast(ordinal);
            const edge = self.findEdge(predecessor, successor_ordinal);
            GenerationBits.copy(self.edge_scratch, self.blockSet(self.live_in, edge.successor));
            self.remapEdgeDemand(self.edge_scratch, edge, false);
            GenerationBits.intersectWith(self.edge_scratch, available);
            const location: CleanupLocation = .{ .edge = .{
                .predecessor = predecessor,
                .successor_ordinal = successor_ordinal,
            } };
            for (self.generations, 0..) |_, generation_index| {
                const generation: GenerationId = @enumFromInt(generation_index);
                if (!GenerationBits.contains(available, generation) or
                    !GenerationBits.contains(demanded_on_some_edge, generation) or
                    GenerationBits.contains(self.edge_scratch, generation)) continue;
                try self.recordEnding(
                    planned_cleanups,
                    explicit_abandonments,
                    generation,
                    representations[generation_index] orelse unreachable,
                    null,
                    location,
                );
            }
            for (self.ownership_forwards[edge.mappings.start..edge.mappings.end]) |mapping| switch (mapping) {
                .produce => |destination| {
                    if (GenerationBits.contains(self.blockSet(self.live_in, edge.successor), destination)) continue;
                    try self.recordEnding(
                        planned_cleanups,
                        explicit_abandonments,
                        destination,
                        self.blockRepresentations(self.representations_in, edge.successor)[@intFromEnum(destination)] orelse unreachable,
                        null,
                        .{ .block_entry = edge.successor },
                    );
                },
                .forward, .unowned => {},
            };
        }
    }

    fn planEffectsBackward(
        self: *Solver,
        demand: []u64,
        effects: []const LifetimeEffect,
        boundary: ?BoundaryId,
        block: structures.FunctionBlockId,
        terminator: structures.FunctionTerminator,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
    ) !void {
        var effect_index = effects.len;
        while (effect_index > 0) {
            effect_index -= 1;
            switch (effects[effect_index]) {
                .define => |definition| {
                    if (GenerationBits.contains(demand, definition.generation)) {
                        GenerationBits.remove(demand, definition.generation);
                    } else {
                        try self.recordAfterEffect(
                            planned_cleanups,
                            explicit_abandonments,
                            definition.generation,
                            definition.value,
                            null,
                            boundary,
                            block,
                            terminator,
                        );
                    }
                },
                .use, .update => |use| {
                    if (!GenerationBits.contains(demand, use.generation)) {
                        try self.recordAfterEffect(
                            planned_cleanups,
                            explicit_abandonments,
                            use.generation,
                            use.cleanup_value,
                            use.cleanup_condition,
                            boundary,
                            block,
                            terminator,
                        );
                    }
                    GenerationBits.insert(demand, use.generation);
                },
                .consume => |generation| GenerationBits.insert(demand, generation),
            }
        }
    }

    fn recordAfterEffect(
        self: *Solver,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
        generation: GenerationId,
        cleanup_value: structures.FunctionValueId,
        cleanup_condition: ?structures.FunctionValueId,
        boundary: ?BoundaryId,
        block: structures.FunctionBlockId,
        terminator: structures.FunctionTerminator,
    ) !void {
        if (boundary) |boundary_id| {
            try self.recordEnding(
                planned_cleanups,
                explicit_abandonments,
                generation,
                cleanup_value,
                cleanup_condition,
                .{ .boundary = boundary_id },
            );
            return;
        }
        for (0..terminator.successorCount()) |ordinal| {
            try self.recordEnding(
                planned_cleanups,
                explicit_abandonments,
                generation,
                cleanup_value,
                cleanup_condition,
                .{ .edge = .{ .predecessor = block, .successor_ordinal = @intCast(ordinal) } },
            );
        }
    }

    fn recordEnding(
        self: *Solver,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
        generation: GenerationId,
        cleanup_value: structures.FunctionValueId,
        cleanup_condition: ?structures.FunctionValueId,
        location: CleanupLocation,
    ) !void {
        const generation_data = self.generations[@intFromEnum(generation)];
        const effective_condition = cleanup_condition orelse generation_data.cleanup_condition;
        if (!generation_data.requires_explicit_drop or generation_data.can_deinit) {
            try planned_cleanups.append(self.gpa, .{
                .generation = generation,
                .cleanup_value = cleanup_value,
                .cleanup_condition = effective_condition,
                .location = location,
            });
            return;
        }
        std.debug.assert(generation_data.requires_explicit_drop);
        try explicit_abandonments.append(self.gpa, .{ .generation = generation, .location = location });
    }

    fn finishEndings(
        self: *const Solver,
        planned_cleanups: *std.ArrayList(PlannedCleanup),
        explicit_abandonments: *std.ArrayList(ExplicitAbandonment),
    ) void {
        inline for (.{ planned_cleanups, explicit_abandonments }) |endings| {
            const Ending = @TypeOf(endings.items[0]);
            std.mem.sort(Ending, endings.items, self.generations, struct {
                fn lessThan(generations: []const Generation, left: Ending, right: Ending) bool {
                    const location_order = compareLocations(left.location, right.location);
                    if (location_order != 0) return location_order < 0;
                    return generations[@intFromEnum(left.generation)].start_order > generations[@intFromEnum(right.generation)].start_order;
                }
            }.lessThan);
            // Start orders are unique, so repeated generation/location pairs are adjacent.
            var unique_count: usize = 0;
            for (endings.items) |ending| {
                if (unique_count > 0) {
                    const previous = endings.items[unique_count - 1];
                    if (previous.generation == ending.generation and std.meta.eql(previous.location, ending.location)) {
                        if (Ending == PlannedCleanup) {
                            std.debug.assert(previous.cleanup_value == ending.cleanup_value);
                            std.debug.assert(previous.cleanup_condition == ending.cleanup_condition);
                        }
                        continue;
                    }
                }
                endings.items[unique_count] = ending;
                unique_count += 1;
            }
            endings.shrinkRetainingCapacity(unique_count);
        }
    }

    fn compareLocations(left: CleanupLocation, right: CleanupLocation) i2 {
        const left_tag = @intFromEnum(left);
        const right_tag = @intFromEnum(right);
        if (left_tag != right_tag) return compareU32(left_tag, right_tag);
        return switch (left) {
            .boundary => |left_boundary| compareU32(@intFromEnum(left_boundary), @intFromEnum(right.boundary)),
            .edge => |left_edge| {
                const right_edge = right.edge;
                const block_order = compareU32(@intFromEnum(left_edge.predecessor), @intFromEnum(right_edge.predecessor));
                if (block_order != 0) return block_order;
                return compareU32(left_edge.successor_ordinal, right_edge.successor_ordinal);
            },
            .block_entry => |left_block| compareU32(@intFromEnum(left_block), @intFromEnum(right.block_entry)),
        };
    }

    fn compareU32(left: u32, right: u32) i2 {
        return if (left < right) -1 else if (left > right) 1 else 0;
    }

    fn validatePathComplete(
        self: *Solver,
        planned_cleanups: []const PlannedCleanup,
        explicit_abandonments: []const ExplicitAbandonment,
    ) void {
        // This pass checks compiler invariants; source obligations were planned above.
        if (!std.debug.runtime_safety) return;
        @memset(self.live_in, 0);
        @memset(self.live_out, 0);
        var changed = true;
        while (changed) {
            changed = false;
            for (self.blocks, 0..) |block_value, block_index| {
                if (!self.reachable[block_index]) continue;
                const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
                GenerationBits.clear(self.scratch);
                if (block_id != self.entry) {
                    var incoming = self.block_edges[block_index].first_incoming;
                    while (incoming) |edge_index| : (incoming = self.previous_incoming[edge_index]) {
                        const edge = &self.ownership_edges[edge_index];
                        if (!self.reachable[@intFromEnum(edge.predecessor)]) continue;
                        GenerationBits.copy(self.edge_scratch, self.blockSet(self.live_out, edge.predecessor));
                        self.remapOpenEdge(self.edge_scratch, edge, planned_cleanups, explicit_abandonments);
                        self.applyEndings(
                            self.edge_scratch,
                            .{ .edge = .{ .predecessor = edge.predecessor, .successor_ordinal = edge.successor_ordinal } },
                            planned_cleanups,
                            explicit_abandonments,
                            false,
                        );
                        self.applyEndings(
                            self.edge_scratch,
                            .{ .block_entry = block_id },
                            planned_cleanups,
                            explicit_abandonments,
                            false,
                        );
                        GenerationBits.unionWith(self.scratch, self.edge_scratch);
                    }
                }
                if (!std.mem.eql(u64, self.blockSet(self.live_in, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.live_in, block_id), self.scratch);
                    changed = true;
                }
                for (block_value.items.items) |item| switch (item) {
                    .instruction => {},
                    .boundary => |boundary| {
                        self.scanEffectsForward(self.scratch, self.boundaries[@intFromEnum(boundary)].effects.items);
                        self.applyEndings(
                            self.scratch,
                            .{ .boundary = boundary },
                            planned_cleanups,
                            explicit_abandonments,
                            false,
                        );
                    },
                };
                self.scanEffectsForward(self.scratch, block_value.terminator_effects.items);
                if (!std.mem.eql(u64, self.blockSet(self.live_out, block_id), self.scratch)) {
                    GenerationBits.copy(self.blockSet(self.live_out, block_id), self.scratch);
                    changed = true;
                }
            }
        }
        for (self.blocks, 0..) |block, block_index| {
            if (!self.reachable[block_index]) continue;
            switch (block.terminator orelse unreachable) {
                .return_unit, .return_value, .return_failure => {
                    const open = self.blockSet(self.live_out, @enumFromInt(block_index));
                    for (open) |word| std.debug.assert(word == 0);
                },
                .branch, .predicate_branch, .fallible_call, .diverge => {},
            }
        }
        self.validateEndingApplications(planned_cleanups, explicit_abandonments);
    }

    fn validateEndingApplications(
        self: *Solver,
        planned_cleanups: []const PlannedCleanup,
        explicit_abandonments: []const ExplicitAbandonment,
    ) void {
        for (self.blocks, 0..) |block_value, block_index| {
            if (!self.reachable[block_index]) continue;
            const block_id: structures.FunctionBlockId = @enumFromInt(block_index);
            GenerationBits.copy(self.scratch, self.blockSet(self.live_in, block_id));
            for (block_value.items.items) |item| switch (item) {
                .instruction => {},
                .boundary => |boundary| {
                    self.scanEffectsForward(self.scratch, self.boundaries[@intFromEnum(boundary)].effects.items);
                    self.applyEndings(
                        self.scratch,
                        .{ .boundary = boundary },
                        planned_cleanups,
                        explicit_abandonments,
                        true,
                    );
                },
            };
            self.scanEffectsForward(self.scratch, block_value.terminator_effects.items);
            for (0..(block_value.terminator orelse unreachable).successorCount()) |ordinal| {
                const edge = self.findEdge(block_id, @intCast(ordinal));
                GenerationBits.copy(self.edge_scratch, self.scratch);
                self.remapOpenEdge(self.edge_scratch, edge, planned_cleanups, explicit_abandonments);
                self.applyEndings(
                    self.edge_scratch,
                    .{ .edge = .{ .predecessor = block_id, .successor_ordinal = @intCast(ordinal) } },
                    planned_cleanups,
                    explicit_abandonments,
                    true,
                );
                self.applyEndings(
                    self.edge_scratch,
                    .{ .block_entry = edge.successor },
                    planned_cleanups,
                    explicit_abandonments,
                    true,
                );
            }
        }
    }

    fn remapOpenEdge(
        self: *const Solver,
        open: []u64,
        edge: *const OwnershipEdge,
        planned_cleanups: []const PlannedCleanup,
        explicit_abandonments: []const ExplicitAbandonment,
    ) void {
        const location: CleanupLocation = .{ .edge = .{
            .predecessor = edge.predecessor,
            .successor_ordinal = edge.successor_ordinal,
        } };
        for (self.ownership_forwards[edge.mappings.start..edge.mappings.end]) |mapping| switch (mapping) {
            .forward => |forward| {
                if (hasEnding(forward.source, location, planned_cleanups, explicit_abandonments)) {
                    GenerationBits.remove(open, forward.destination);
                    continue;
                }
                const source_open = GenerationBits.contains(open, forward.source);
                GenerationBits.remove(open, forward.source);
                if (source_open) GenerationBits.insert(open, forward.destination) else GenerationBits.remove(open, forward.destination);
            },
            .produce => |destination| GenerationBits.insert(open, destination),
            .unowned => |destination| GenerationBits.remove(open, destination),
        };
    }

    fn applyEndings(
        _: *const Solver,
        open: []u64,
        location: CleanupLocation,
        planned_cleanups: []const PlannedCleanup,
        explicit_abandonments: []const ExplicitAbandonment,
        validate_existing: bool,
    ) void {
        for (planned_cleanups) |cleanup| {
            if (!std.meta.eql(cleanup.location, location)) continue;
            if (validate_existing and cleanup.cleanup_condition == null) {
                std.debug.assert(GenerationBits.contains(open, cleanup.generation));
            }
            GenerationBits.remove(open, cleanup.generation);
        }
        for (explicit_abandonments) |abandonment| {
            if (!std.meta.eql(abandonment.location, location)) continue;
            if (validate_existing) std.debug.assert(GenerationBits.contains(open, abandonment.generation));
            GenerationBits.remove(open, abandonment.generation);
        }
    }

    fn hasEnding(
        generation: GenerationId,
        location: CleanupLocation,
        planned_cleanups: []const PlannedCleanup,
        explicit_abandonments: []const ExplicitAbandonment,
    ) bool {
        for (planned_cleanups) |cleanup| {
            if (cleanup.generation == generation and std.meta.eql(cleanup.location, location)) return true;
        }
        for (explicit_abandonments) |abandonment| {
            if (abandonment.generation == generation and std.meta.eql(abandonment.location, location)) return true;
        }
        return false;
    }

    fn scanEffectsBackward(_: *const Solver, demand: []u64, effects: []const LifetimeEffect) void {
        var effect_index = effects.len;
        while (effect_index > 0) {
            effect_index -= 1;
            switch (effects[effect_index]) {
                .define => |definition| GenerationBits.remove(demand, definition.generation),
                .use, .update => |use| GenerationBits.insert(demand, use.generation),
                .consume => |generation| GenerationBits.insert(demand, generation),
            }
        }
    }

    fn findEdge(self: *const Solver, predecessor: structures.FunctionBlockId, successor_ordinal: u2) *const OwnershipEdge {
        const edge_index = self.block_edges[@intFromEnum(predecessor)].outgoing[successor_ordinal] orelse unreachable;
        return &self.ownership_edges[edge_index];
    }

    fn blockSet(self: *const Solver, matrix: []u64, block: structures.FunctionBlockId) []u64 {
        const start = @intFromEnum(block) * self.words_per_block;
        return matrix[start .. start + self.words_per_block];
    }

    fn blockRepresentations(
        self: *const Solver,
        matrix: []?structures.FunctionValueId,
        block: structures.FunctionBlockId,
    ) []?structures.FunctionValueId {
        const start = @intFromEnum(block) * self.generations.len;
        return matrix[start .. start + self.generations.len];
    }
};

const TestSolverBlock = struct {
    boundaries: []const u32 = &.{},
    terminator_effects: []const LifetimeEffect = &.{},
    terminator: structures.FunctionTerminator,
    argument_start: u32 = 0,
    argument_end: u32 = 0,
};

const TestSolverExpected = struct {
    cleanups: []const PlannedCleanup = &.{},
    abandonments: []const ExplicitAbandonment = &.{},
};

fn testExpectLifetimePlan(
    gpa: std.mem.Allocator,
    generations: []const Generation,
    boundary_effects: []const []const LifetimeEffect,
    block_descriptions: []const TestSolverBlock,
    block_argument_generations: []const ?GenerationId,
    ownership_forwards: []const OwnershipForward,
    ownership_edges: []const OwnershipEdge,
    expected: TestSolverExpected,
) !void {
    const boundaries = try gpa.alloc(Boundary, boundary_effects.len);
    defer gpa.free(boundaries);
    @memset(boundaries, .{ .span = .{ .start = 0, .end = 0 } });
    defer for (boundaries) |*boundary| boundary.effects.deinit(gpa);
    for (boundaries, boundary_effects) |*boundary, effects| try boundary.effects.appendSlice(gpa, effects);

    const blocks = try gpa.alloc(BuildBlock, block_descriptions.len);
    defer gpa.free(blocks);
    for (blocks, block_descriptions, 0..) |*block, description, index| {
        block.* = .{
            .argument_start = description.argument_start,
            .argument_end = description.argument_end,
            // Publication order must not affect lifetime analysis.
            .layout_index = @intCast(block_descriptions.len - 1 - index),
            .terminator = description.terminator,
        };
    }
    defer for (blocks) |*block| {
        block.items.deinit(gpa);
        block.terminator_effects.deinit(gpa);
    };
    for (blocks, block_descriptions) |*block, description| {
        for (description.boundaries) |boundary| try block.items.append(gpa, .{ .boundary = @enumFromInt(boundary) });
        try block.terminator_effects.appendSlice(gpa, description.terminator_effects);
    }

    var planned_cleanups: std.ArrayList(PlannedCleanup) = .empty;
    defer planned_cleanups.deinit(gpa);
    var explicit_abandonments: std.ArrayList(ExplicitAbandonment) = .empty;
    defer explicit_abandonments.deinit(gpa);
    var solver = try Solver.init(
        gpa,
        generations,
        boundaries,
        blocks,
        block_argument_generations,
        ownership_forwards,
        ownership_edges,
        @enumFromInt(0),
    );
    defer solver.deinit();
    try solver.solve(&planned_cleanups, &explicit_abandonments);
    try std.testing.expectEqual(expected.cleanups.len, planned_cleanups.items.len);
    for (expected.cleanups, planned_cleanups.items) |expected_cleanup, actual| {
        try std.testing.expect(std.meta.eql(expected_cleanup, actual));
    }
    try std.testing.expectEqual(expected.abandonments.len, explicit_abandonments.items.len);
    for (expected.abandonments, explicit_abandonments.items) |expected_abandonment, actual| {
        try std.testing.expect(std.meta.eql(expected_abandonment, actual));
    }
}

fn testSolverGeneration(start_order: u32, explicit: bool) Generation {
    return .{
        .type_id = .unit,
        .start_order = start_order,
        .span = .{ .start = start_order, .end = start_order + 1 },
        .requires_explicit_drop = explicit,
        .can_deinit = false,
    };
}

test "lifetime solver plans straight-line last and zero uses" {
    const generations = [_]Generation{ testSolverGeneration(0, false), testSolverGeneration(1, false) };
    const boundaries = [_][]const LifetimeEffect{
        &.{
            .{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } },
            .{ .define = .{ .generation = @enumFromInt(1), .value = @enumFromInt(11) } },
        },
        &.{.{ .use = .{ .generation = @enumFromInt(1), .cleanup_value = @enumFromInt(12) } }},
    };
    const blocks = [_]TestSolverBlock{.{ .boundaries = &.{ 0, 1 }, .terminator = .return_unit }};
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &.{}, .{ .cleanups = &.{
        .{
            .generation = @enumFromInt(0),
            .cleanup_value = @enumFromInt(10),
            .location = .{ .boundary = @enumFromInt(0) },
        },
        .{
            .generation = @enumFromInt(1),
            .cleanup_value = @enumFromInt(12),
            .location = .{ .boundary = @enumFromInt(1) },
        },
    } });
}

test "lifetime solver distinguishes branch use and consume" {
    const generations = [_]Generation{testSolverGeneration(0, false)};
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } }},
        &.{.{ .use = .{
            .generation = @enumFromInt(0),
            .cleanup_value = @enumFromInt(11),
            .cleanup_condition = @enumFromInt(99),
        } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @enumFromInt(0), .rhs = @enumFromInt(1) },
            .then_branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @enumFromInt(2), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{1}, .terminator = .return_unit },
        .{ .terminator_effects = &.{.{ .consume = @enumFromInt(0) }}, .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1, .successor = @enumFromInt(2), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &edges, .{ .cleanups = &.{.{
        .generation = @enumFromInt(0),
        .cleanup_value = @enumFromInt(11),
        .cleanup_condition = @enumFromInt(99),
        .location = .{ .boundary = @enumFromInt(1) },
    }} });
}

test "lifetime solver follows ownership joins and releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testExpectOwnershipJoinPlan, .{});
}

fn testExpectOwnershipJoinPlan(gpa: std.mem.Allocator) !void {
    const generations = [_]Generation{
        testSolverGeneration(0, false),
        testSolverGeneration(1, false),
        testSolverGeneration(2, false),
    };
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } }},
        &.{.{ .define = .{ .generation = @enumFromInt(1), .value = @enumFromInt(11) } }},
        &.{.{ .use = .{ .generation = @enumFromInt(2), .cleanup_value = @enumFromInt(0) } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @enumFromInt(1), .rhs = @enumFromInt(2) },
            .then_branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @enumFromInt(2), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{0}, .terminator = .{ .branch = .{ .target = @enumFromInt(3), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{1}, .terminator = .{ .branch = .{ .target = @enumFromInt(3), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{2}, .terminator = .return_unit, .argument_start = 0, .argument_end = 1 },
    };
    const forwards = [_]OwnershipForward{
        .{ .forward = .{ .source = @enumFromInt(0), .destination = @enumFromInt(2) } },
        .{ .forward = .{ .source = @enumFromInt(1), .destination = @enumFromInt(2) } },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @enumFromInt(2), .successor_ordinal = 0, .successor = @enumFromInt(3), .mappings = .{ .start = 1, .end = 2 } },
        .{ .predecessor = @enumFromInt(1), .successor_ordinal = 0, .successor = @enumFromInt(3), .mappings = .{ .start = 0, .end = 1 } },
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1, .successor = @enumFromInt(2), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(gpa, &generations, &boundaries, &blocks, &.{@enumFromInt(2)}, &forwards, &edges, .{ .cleanups = &.{.{
        .generation = @enumFromInt(2),
        .cleanup_value = @enumFromInt(0),
        .location = .{ .boundary = @enumFromInt(2) },
    }} });
}

test "lifetime solver reaches a fixed point across continue and break" {
    const generations = [_]Generation{testSolverGeneration(0, false)};
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } }},
        &.{.{ .use = .{ .generation = @enumFromInt(0), .cleanup_value = @enumFromInt(11) } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @enumFromInt(1), .rhs = @enumFromInt(2) },
            .then_branch = .{ .target = @enumFromInt(2), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @enumFromInt(3), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{1}, .terminator = .{ .branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(1), .successor_ordinal = 0, .successor = @enumFromInt(2), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(1), .successor_ordinal = 1, .successor = @enumFromInt(3), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(2), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &edges, .{ .cleanups = &.{.{
        .generation = @enumFromInt(0),
        .cleanup_value = @enumFromInt(10),
        .location = .{ .edge = .{ .predecessor = @enumFromInt(1), .successor_ordinal = 1 } },
    }} });
}

test "lifetime solver handles terminal consumes divergence and fallible production" {
    const consumed_generation = [_]Generation{testSolverGeneration(0, false)};
    const consumed_boundaries = [_][]const LifetimeEffect{&.{.{ .define = .{
        .generation = @enumFromInt(0),
        .value = @enumFromInt(10),
    } }}};
    const consumed_blocks = [_]TestSolverBlock{.{
        .boundaries = &.{0},
        .terminator_effects = &.{.{ .consume = @enumFromInt(0) }},
        .terminator = .return_failure,
    }};
    try testExpectLifetimePlan(std.testing.allocator, &consumed_generation, &consumed_boundaries, &consumed_blocks, &.{}, &.{}, &.{}, .{});

    const diverging_boundaries = [_][]const LifetimeEffect{&.{
        .{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } },
        .{ .use = .{ .generation = @enumFromInt(0), .cleanup_value = @enumFromInt(10) } },
    }};
    const diverging_blocks = [_]TestSolverBlock{.{
        .terminator_effects = diverging_boundaries[0],
        .terminator = .diverge,
    }};
    try testExpectLifetimePlan(std.testing.allocator, &consumed_generation, &.{}, &diverging_blocks, &.{}, &.{}, &.{}, .{});

    const produced_blocks = [_]TestSolverBlock{
        .{ .terminator = .{ .fallible_call = .{
            .call = .{ .target = .{ .direct = .{ .item = @enumFromInt(0) } }, .arguments = .{ .start = 0, .end = 0 }, .return_type = .unit },
            .success = @enumFromInt(1),
            .failure = @enumFromInt(2),
        } } },
        .{ .terminator = .return_unit, .argument_start = 0, .argument_end = 1 },
        .{ .terminator = .return_failure, .argument_start = 1, .argument_end = 1 },
    };
    const produced_forwards = [_]OwnershipForward{.{ .produce = @enumFromInt(0) }};
    const produced_edges = [_]OwnershipEdge{
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 1 } },
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1, .successor = @enumFromInt(2), .mappings = .{ .start = 1, .end = 1 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &consumed_generation, &.{}, &produced_blocks, &.{@enumFromInt(0)}, &produced_forwards, &produced_edges, .{ .cleanups = &.{.{
        .generation = @enumFromInt(0),
        .cleanup_value = @enumFromInt(0),
        .location = .{ .block_entry = @enumFromInt(1) },
    }} });
}

test "lifetime solver reports explicit abandonment on only one branch" {
    const generations = [_]Generation{testSolverGeneration(0, true)};
    const boundaries = [_][]const LifetimeEffect{&.{.{ .define = .{
        .generation = @enumFromInt(0),
        .value = @enumFromInt(10),
    } }}};
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @enumFromInt(1), .rhs = @enumFromInt(2) },
            .then_branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @enumFromInt(2), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .terminator_effects = &.{.{ .consume = @enumFromInt(0) }}, .terminator = .return_unit },
        .{ .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0, .successor = @enumFromInt(1), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1, .successor = @enumFromInt(2), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &edges, .{ .abandonments = &.{.{
        .generation = @enumFromInt(0),
        .location = .{ .edge = .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1 } },
    }} });
}

test "lifetime solver reverses simultaneous generation start order" {
    const generations = [_]Generation{ testSolverGeneration(0, false), testSolverGeneration(1, false) };
    const boundaries = [_][]const LifetimeEffect{
        &.{
            .{ .define = .{ .generation = @enumFromInt(0), .value = @enumFromInt(10) } },
            .{ .define = .{ .generation = @enumFromInt(1), .value = @enumFromInt(11) } },
        },
        &.{
            .{ .use = .{ .generation = @enumFromInt(0), .cleanup_value = @enumFromInt(10) } },
            .{ .use = .{ .generation = @enumFromInt(1), .cleanup_value = @enumFromInt(11) } },
        },
    };
    const blocks = [_]TestSolverBlock{.{ .boundaries = &.{ 0, 1 }, .terminator = .return_unit }};
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &.{}, .{ .cleanups = &.{
        .{
            .generation = @enumFromInt(1),
            .cleanup_value = @enumFromInt(11),
            .location = .{ .boundary = @enumFromInt(1) },
        },
        .{
            .generation = @enumFromInt(0),
            .cleanup_value = @enumFromInt(10),
            .location = .{ .boundary = @enumFromInt(1) },
        },
    } });
}

test "lifetime endings deduplicate requests while preserving order locations and conditions" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testEndingDeduplication, .{});
}

fn testEndingDeduplication(gpa: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |explicit| {
        var generations = [_]Generation{ testSolverGeneration(1, explicit), testSolverGeneration(0, explicit) };
        generations[0].cleanup_condition = @enumFromInt(99);
        // Exercise plan finalization directly, including requests from separate planning sites.
        var solver = try Solver.init(gpa, &generations, &.{}, &.{}, &.{}, &.{}, &.{}, @enumFromInt(0));
        defer solver.deinit();
        var cleanups: std.ArrayList(PlannedCleanup) = .empty;
        defer cleanups.deinit(gpa);
        var abandonments: std.ArrayList(ExplicitAbandonment) = .empty;
        defer abandonments.deinit(gpa);
        const expected = [_]struct { generation: GenerationId, location: CleanupLocation }{
            .{ .generation = @enumFromInt(0), .location = .{ .boundary = @enumFromInt(0) } },
            .{ .generation = @enumFromInt(1), .location = .{ .boundary = @enumFromInt(0) } },
            .{ .generation = @enumFromInt(0), .location = .{ .boundary = @enumFromInt(1) } },
            .{ .generation = @enumFromInt(0), .location = .{ .edge = .{ .predecessor = @enumFromInt(0), .successor_ordinal = 0 } } },
            .{ .generation = @enumFromInt(0), .location = .{ .edge = .{ .predecessor = @enumFromInt(0), .successor_ordinal = 1 } } },
            .{ .generation = @enumFromInt(0), .location = .{ .block_entry = @enumFromInt(1) } },
        };
        for ([_]usize{ 4, 1, 3, 0, 4, 5, 2, 5, 1, 0, 2, 3 }) |index| {
            const ending = expected[index];
            try solver.recordEnding(
                &cleanups,
                &abandonments,
                ending.generation,
                @enumFromInt(10 + @intFromEnum(ending.generation)),
                null,
                ending.location,
            );
        }
        solver.finishEndings(&cleanups, &abandonments);
        try std.testing.expectEqual(if (explicit) @as(usize, 0) else expected.len, cleanups.items.len);
        try std.testing.expectEqual(if (explicit) expected.len else @as(usize, 0), abandonments.items.len);
        for (expected, 0..) |ending, index| {
            if (explicit) {
                try std.testing.expectEqualDeep(ExplicitAbandonment{
                    .generation = ending.generation,
                    .location = ending.location,
                }, abandonments.items[index]);
            } else {
                try std.testing.expectEqualDeep(PlannedCleanup{
                    .generation = ending.generation,
                    .cleanup_value = @enumFromInt(10 + @intFromEnum(ending.generation)),
                    .cleanup_condition = generations[@intFromEnum(ending.generation)].cleanup_condition,
                    .location = ending.location,
                }, cleanups.items[index]);
            }
        }
    }
}
