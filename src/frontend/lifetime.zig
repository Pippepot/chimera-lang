const std = @import("std");
const structures = @import("../structures.zig");
const control_flow = @import("../control_flow.zig");
const body_graph = @import("body_graph.zig");
pub const GenerationId = body_graph.GenerationId;
pub const BoundaryId = body_graph.BoundaryId;
pub const Generation = body_graph.Generation;
pub const LifetimeEffect = body_graph.LifetimeEffect;
const Effect = body_graph.Effect;
pub const OwnershipForward = body_graph.OwnershipForward;
pub const OwnershipEdge = body_graph.OwnershipEdge;
pub const CleanupLocation = body_graph.CleanupLocation;
pub const PlannedEnding = body_graph.PlannedEnding;
pub const Boundary = body_graph.Boundary;
pub const BuildInstruction = body_graph.BuildInstruction;
pub const BuildItem = body_graph.BuildItem;
pub const BuildBlock = body_graph.BuildBlock;

const GenerationBits = struct {
    fn wordCount(generation_count: usize) usize {
        return (generation_count + 63) / 64;
    }

    fn contains(bits: []const u64, generation: GenerationId) bool {
        const index = @backingInt(generation);
        return bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }

    fn insert(bits: []u64, generation: GenerationId) void {
        const index = @backingInt(generation);
        bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    }

    fn remove(bits: []u64, generation: GenerationId) void {
        const index = @backingInt(generation);
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
    gpa: std.mem.Allocator,
    generations: []const Generation,
    boundaries: []const Boundary,
    blocks: []const BuildBlock,
    block_argument_generations: []const ?GenerationId,
    ownership_forwards: []const OwnershipForward,
    ownership_edges: []const OwnershipEdge,
    control_flow: control_flow.Index,
    entry: structures.FunctionBlockId,
    reachable: []bool = &.{},
    dirty_blocks: []bool = &.{},
    available_in: []u64 = &.{},
    available_out: []u64 = &.{},
    live_in: []u64 = &.{},
    live_out: []u64 = &.{},
    scratch: []u64 = &.{},
    edge_scratch: []u64 = &.{},
    words_per_block: usize,
    cleanup_values: std.AutoHashMapUnmanaged(CleanupKey, structures.FunctionValueId) = .empty,
    cleanup_work: std.AutoArrayHashMapUnmanaged(CleanupKey, void) = .empty,

    const CleanupKey = struct { block: structures.FunctionBlockId, generation: GenerationId };

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
        const words_per_block = GenerationBits.wordCount(generations.len);
        const matrix_len = std.math.mul(usize, blocks.len, words_per_block) catch return error.AnalysisTooLarge;
        var solver: Solver = .{
            .gpa = gpa,
            .generations = generations,
            .boundaries = boundaries,
            .blocks = blocks,
            .block_argument_generations = block_argument_generations,
            .ownership_forwards = ownership_forwards,
            .ownership_edges = ownership_edges,
            .control_flow = try control_flow.Index.init(gpa, blocks.len, ownership_edges),
            .entry = entry,
            .words_per_block = words_per_block,
        };
        errdefer solver.deinit();
        solver.reachable = try gpa.alloc(bool, blocks.len);
        solver.dirty_blocks = try gpa.alloc(bool, blocks.len);
        solver.available_in = try gpa.alloc(u64, matrix_len);
        solver.available_out = try gpa.alloc(u64, matrix_len);
        solver.live_in = try gpa.alloc(u64, matrix_len);
        solver.live_out = try gpa.alloc(u64, matrix_len);
        solver.scratch = try gpa.alloc(u64, words_per_block);
        solver.edge_scratch = try gpa.alloc(u64, words_per_block);
        @memset(solver.reachable, false);
        @memset(solver.available_in, 0);
        @memset(solver.available_out, 0);
        @memset(solver.live_in, 0);
        @memset(solver.live_out, 0);
        return solver;
    }

    pub fn deinit(self: *Solver) void {
        self.control_flow.deinit(self.gpa);
        self.cleanup_values.deinit(self.gpa);
        self.cleanup_work.deinit(self.gpa);
        self.gpa.free(self.reachable);
        self.gpa.free(self.dirty_blocks);
        self.gpa.free(self.available_in);
        self.gpa.free(self.available_out);
        self.gpa.free(self.live_in);
        self.gpa.free(self.live_out);
        self.gpa.free(self.scratch);
        self.gpa.free(self.edge_scratch);
        self.* = undefined;
    }

    pub fn tableBytes(self: *const Solver) usize {
        return 4 * std.mem.sliceAsBytes(self.available_in).len + self.cleanup_values.count() * (@sizeOf(CleanupKey) + @sizeOf(structures.FunctionValueId));
    }

    pub fn solve(
        self: *Solver,
        endings: *std.ArrayList(PlannedEnding),
    ) !void {
        std.debug.assert(endings.items.len == 0);
        try self.computeReachability();
        self.control_flow.solve(self.ownership_edges, self.reachable, self.dirty_blocks, .{ .solver = self, .endings = null }, false, stepForward);
        self.control_flow.solve(self.ownership_edges, self.reachable, self.dirty_blocks, self, true, stepDemand);
        std.debug.assert(std.mem.allEqual(u64, self.blockSet(self.live_in, self.entry), 0));
        try self.planEndings(endings);
        self.validatePathComplete(endings.items);
    }

    fn computeReachability(self: *Solver) !void {
        std.debug.assert(@backingInt(self.entry) < self.blocks.len);
        var worklist: std.ArrayList(structures.FunctionBlockId) = .empty;
        defer worklist.deinit(self.gpa);
        self.reachable[@backingInt(self.entry)] = true;
        try worklist.append(self.gpa, self.entry);
        while (worklist.pop()) |block| {
            for (0..(self.blocks[@backingInt(block)].terminator orelse unreachable).successorCount()) |ordinal| {
                const edge = self.findEdge(block, @intCast(ordinal));
                const successor_index = @backingInt(edge.successor);
                std.debug.assert(successor_index < self.blocks.len);
                if (self.reachable[successor_index]) continue;
                self.reachable[successor_index] = true;
                try worklist.append(self.gpa, edge.successor);
            }
        }
    }

    fn stepDemand(self: *Solver, block_index: usize) bool {
        const block_id: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
        const block_value = self.blocks[block_index];
        @memset(self.scratch, 0);
        for (0..(block_value.terminator orelse unreachable).successorCount()) |ordinal| {
            const edge = self.findEdge(block_id, @intCast(ordinal));
            std.debug.assert(self.reachable[@backingInt(edge.successor)]);
            @memcpy(self.edge_scratch, self.blockSet(self.live_in, edge.successor));
            self.remapEdgeDemand(self.edge_scratch, edge, true);
            GenerationBits.intersectWith(self.edge_scratch, self.blockSet(self.available_out, block_id));
            GenerationBits.unionWith(self.scratch, self.edge_scratch);
        }
        @memcpy(self.blockSet(self.live_out, block_id), self.scratch);
        self.scanEffectsBackward(self.scratch, block_value.terminator_effects.items);
        var items = std.mem.reverseIterator(block_value.items.items);
        while (items.next()) |item| switch (item) {
            .instruction => {},
            .boundary => |boundary| self.scanEffectsBackward(self.scratch, self.boundaries[@backingInt(boundary)].effects.items),
        };
        return publishChanged(u64, self.blockSet(self.live_in, block_id), self.scratch);
    }

    fn stepForward(context: anytype, block_index: usize) bool {
        const self = context.solver;
        const block_value = self.blocks[block_index];
        const block_id: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
        @memset(self.scratch, 0);
        if (block_id != self.entry) {
            var incoming = self.control_flow.blocks[block_index].first_incoming;
            while (incoming) |edge_index| : (incoming = self.control_flow.previous_incoming[edge_index]) {
                const edge = &self.ownership_edges[edge_index];
                if (!self.reachable[@backingInt(edge.predecessor)]) continue;
                @memcpy(self.edge_scratch, self.blockSet(self.available_out, edge.predecessor));
                self.crossOpenEdge(self.edge_scratch, edge, context.endings, false);
                GenerationBits.unionWith(self.scratch, self.edge_scratch);
            }
        }
        @memcpy(self.blockSet(self.available_in, block_id), self.scratch);
        self.scanOpenBlock(self.scratch, block_value, context.endings, false);
        return publishChanged(u64, self.blockSet(self.available_out, block_id), self.scratch);
    }

    fn blockArgumentValue(self: *const Solver, block: BuildBlock, generation: GenerationId) ?structures.FunctionValueId {
        for (block.argument_start..block.argument_end) |argument| {
            if (self.block_argument_generations[argument] == generation) return @fromBackingInt(@intCast(argument));
        }
        return null;
    }

    fn cleanupValue(self: *Solver, block: structures.FunctionBlockId, generation: GenerationId) !structures.FunctionValueId {
        const key: CleanupKey = .{ .block = block, .generation = generation };
        if (self.cleanup_values.get(key)) |value| return value;
        self.cleanup_work.clearRetainingCapacity();
        try self.cleanup_work.put(self.gpa, key, {});
        var result: ?structures.FunctionValueId = null;
        var cursor: usize = 0;
        while (cursor < self.cleanup_work.count()) : (cursor += 1) {
            const current = self.cleanup_work.keys()[cursor];
            const block_value = self.blocks[@backingInt(current.block)];
            if (self.cleanup_values.get(current) orelse self.blockCleanupValue(block_value, current.generation)) |value| {
                if (result) |previous| std.debug.assert(previous == value);
                result = value;
                continue;
            }
            var incoming = self.control_flow.blocks[@backingInt(current.block)].first_incoming;
            while (incoming) |edge_index| : (incoming = self.control_flow.previous_incoming[edge_index]) {
                const edge = &self.ownership_edges[edge_index];
                if (!self.reachable[@backingInt(edge.predecessor)]) continue;
                const source = self.edgeSource(edge, current.generation) orelse continue;
                if (!GenerationBits.contains(self.blockSet(self.available_out, edge.predecessor), source)) continue;
                try self.cleanup_work.put(self.gpa, .{ .block = edge.predecessor, .generation = source }, {});
            }
        }
        const value = result orelse unreachable;
        for (self.cleanup_work.keys()) |visited| try self.cleanup_values.put(self.gpa, visited, value);
        return value;
    }

    fn blockCleanupValue(self: *const Solver, block: BuildBlock, generation: GenerationId) ?structures.FunctionValueId {
        if (effectCleanupValue(block.terminator_effects.items, generation)) |value| return value;
        var items = std.mem.reverseIterator(block.items.items);
        while (items.next()) |item| switch (item) {
            .instruction => {},
            .boundary => |boundary| if (effectCleanupValue(self.boundaries[@backingInt(boundary)].effects.items, generation)) |value| return value,
        };
        return self.blockArgumentValue(block, generation);
    }

    fn effectCleanupValue(effects: []const Effect, generation: GenerationId) ?structures.FunctionValueId {
        var reversed = std.mem.reverseIterator(effects);
        while (reversed.next()) |effect| switch (effect.operation orelse continue) {
            .define => |definition| if (definition.generation == generation) return definition.value,
            .update => |update| if (update.generation == generation) return update.cleanup_value,
            .consume => |consumed| std.debug.assert(consumed != generation),
            .use => {},
        };
        return null;
    }

    fn edgeSource(self: *const Solver, edge: *const OwnershipEdge, generation: GenerationId) ?GenerationId {
        var source = generation;
        var mappings = std.mem.reverseIterator(self.ownership_forwards[edge.mappings.start..edge.mappings.end]);
        while (mappings.next()) |mapping| {
            if (source == mapping.source) return null;
            if (source == mapping.destination) source = mapping.source orelse return null;
        }
        return source;
    }

    /// With planned endings, a source ended on the edge does not reach its destination.
    fn remapEdgeAvailability(self: *const Solver, available: []u64, edge: *const OwnershipEdge, endings: ?[]const PlannedEnding) void {
        const mappings = self.ownership_forwards[edge.mappings.start..edge.mappings.end];
        for (mappings) |mapping| {
            const source = mapping.source orelse {
                GenerationBits.remove(available, mapping.destination);
                continue;
            };
            const ended = if (endings) |planned| hasEnding(source, edgeLocation(edge), planned) else false;
            const source_available = GenerationBits.contains(available, source) and !ended;
            if (!ended) GenerationBits.remove(available, source);
            if (source_available) GenerationBits.insert(available, mapping.destination) else GenerationBits.remove(available, mapping.destination);
        }
    }

    fn scanEffectsForward(_: *const Solver, available: []u64, effects: []const Effect) void {
        for (effects) |effect| switch (effect.operation orelse continue) {
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
        for (mappings) |mapping| {
            if (mapping.source) |source| {
                if (GenerationBits.contains(demand, mapping.destination)) {
                    GenerationBits.remove(demand, mapping.destination);
                    GenerationBits.insert(demand, source);
                } else if (require_unused_sources) GenerationBits.insert(demand, source);
            } else GenerationBits.remove(demand, mapping.destination);
        }
    }

    fn planEndings(
        self: *Solver,
        endings: *std.ArrayList(PlannedEnding),
    ) !void {
        for (self.blocks, 0..) |block_value, block_index| {
            if (!self.reachable[block_index]) continue;
            const block_id: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
            const terminator = block_value.terminator orelse unreachable;
            try self.planEdges(block_id, terminator, endings);
            // Terminator effects end on every outgoing edge; boundary effects end at their boundary.
            var edge_locations: [2]CleanupLocation = undefined;
            for (0..terminator.successorCount()) |ordinal| edge_locations[ordinal] = edgeLocation(self.findEdge(block_id, @intCast(ordinal)));
            @memcpy(self.scratch, self.blockSet(self.live_out, block_id));
            try self.planEffectsBackward(self.scratch, block_value.terminator_effects.items, edge_locations[0..terminator.successorCount()], endings);
            var items = std.mem.reverseIterator(block_value.items.items);
            while (items.next()) |item| switch (item) {
                .instruction => {},
                .boundary => |boundary| try self.planEffectsBackward(self.scratch, self.boundaries[@backingInt(boundary)].effects.items, &.{.{ .boundary = boundary }}, endings),
            };
            std.debug.assert(std.mem.eql(u64, self.scratch, self.blockSet(self.live_in, block_id)));
        }
        self.finishEndings(endings);
    }

    fn planEdges(
        self: *Solver,
        predecessor: structures.FunctionBlockId,
        terminator: structures.FunctionTerminator,
        endings: *std.ArrayList(PlannedEnding),
    ) !void {
        const available = self.blockSet(self.available_out, predecessor);
        const demanded_on_some_edge = self.blockSet(self.live_out, predecessor);
        for (0..terminator.successorCount()) |ordinal| {
            const edge = self.findEdge(predecessor, @intCast(ordinal));
            @memcpy(self.edge_scratch, self.blockSet(self.live_in, edge.successor));
            self.remapEdgeDemand(self.edge_scratch, edge, false);
            GenerationBits.intersectWith(self.edge_scratch, available);
            for (available, demanded_on_some_edge, self.edge_scratch, 0..) |available_word, demanded_word, successor_word, word_index| {
                var ending_word = available_word & demanded_word & ~successor_word;
                while (ending_word != 0) {
                    const generation_index = word_index * 64 + @ctz(ending_word);
                    const generation: GenerationId = @fromBackingInt(@intCast(generation_index));
                    try self.recordEnding(endings, .{
                        .generation = generation,
                        .cleanup_value = try self.cleanupValue(predecessor, generation),
                        .location = edgeLocation(edge),
                    });
                    ending_word &= ending_word - 1;
                }
            }
        }
    }

    /// An undemanded effect ends its generation at each of `locations`.
    fn planEffectsBackward(
        self: *Solver,
        demand: []u64,
        effects: []const Effect,
        locations: []const CleanupLocation,
        endings: *std.ArrayList(PlannedEnding),
    ) !void {
        var reversed = std.mem.reverseIterator(effects);
        while (reversed.next()) |effect| switch (effect.operation orelse continue) {
            .define => |definition| {
                if (GenerationBits.contains(demand, definition.generation)) {
                    GenerationBits.remove(demand, definition.generation);
                } else for (locations) |location| {
                    try self.recordEnding(endings, .{ .generation = definition.generation, .cleanup_value = definition.value, .location = location });
                }
            },
            .use, .update => |use| {
                if (!GenerationBits.contains(demand, use.generation)) for (locations) |location| {
                    try self.recordEnding(endings, .{
                        .generation = use.generation,
                        .cleanup_value = use.cleanup_value,
                        .cleanup_condition = use.cleanup_condition,
                        .location = location,
                    });
                };
                GenerationBits.insert(demand, use.generation);
            },
            .consume => |generation| GenerationBits.insert(demand, generation),
        };
    }

    fn recordEnding(self: *Solver, endings: *std.ArrayList(PlannedEnding), ending: PlannedEnding) !void {
        var planned = ending;
        planned.cleanup_condition = ending.cleanup_condition orelse self.generations[@backingInt(ending.generation)].cleanup_condition;
        try endings.append(self.gpa, planned);
    }

    fn finishEndings(self: *const Solver, endings: *std.ArrayList(PlannedEnding)) void {
        std.mem.sort(PlannedEnding, endings.items, self.generations, struct {
            fn lessThan(generations: []const Generation, left: PlannedEnding, right: PlannedEnding) bool {
                return switch (compareLocations(left.location, right.location)) {
                    .lt => true,
                    .gt => false,
                    .eq => {
                        const left_generation = generations[@backingInt(left.generation)];
                        const right_generation = generations[@backingInt(right.generation)];
                        const left_start = generations[@backingInt(left_generation.lifetime_origin orelse left.generation)].start_order;
                        const right_start = generations[@backingInt(right_generation.lifetime_origin orelse right.generation)].start_order;
                        if (left_start != right_start) return left_start > right_start;
                        return left_generation.start_order > right_generation.start_order;
                    },
                };
            }
        }.lessThan);
        // Unique generation orders break ties between refinements of one owner.
        var unique_count: usize = 0;
        for (endings.items) |ending| {
            if (unique_count > 0) {
                const previous = endings.items[unique_count - 1];
                if (previous.generation == ending.generation and std.meta.eql(previous.location, ending.location)) {
                    if (!self.generations[@backingInt(ending.generation)].requires_explicit_drop) {
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

    fn compareLocations(left: CleanupLocation, right: CleanupLocation) std.math.Order {
        const tag_order = std.math.order(@backingInt(left), @backingInt(right));
        if (tag_order != .eq) return tag_order;
        return switch (left) {
            .boundary => |boundary| std.math.order(@backingInt(boundary), @backingInt(right.boundary)),
            .edge => |edge| std.math.order(@backingInt(edge.predecessor), @backingInt(right.edge.predecessor)).differ() orelse
                std.math.order(edge.successor_ordinal, right.edge.successor_ordinal),
        };
    }

    fn validatePathComplete(
        self: *Solver,
        endings: []const PlannedEnding,
    ) void {
        // This pass checks compiler invariants; source obligations were planned above.
        if (!std.debug.runtime_safety) return;
        @memset(self.available_in, 0);
        @memset(self.available_out, 0);
        self.control_flow.solve(self.ownership_edges, self.reachable, self.dirty_blocks, .{ .solver = self, .endings = endings }, false, stepForward);
        for (self.blocks, 0..) |block, block_index| {
            if (!self.reachable[block_index]) continue;
            switch (block.terminator orelse unreachable) {
                .return_unit, .return_value => {
                    std.debug.assert(std.mem.allEqual(u64, self.blockSet(self.available_out, @fromBackingInt(@intCast(block_index))), 0));
                },
                .branch, .predicate_branch, .diverge => {},
            }
        }
        self.validateEndingApplications(endings);
    }

    fn validateEndingApplications(
        self: *Solver,
        endings: []const PlannedEnding,
    ) void {
        for (self.blocks, 0..) |block_value, block_index| {
            if (!self.reachable[block_index]) continue;
            const block_id: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
            @memcpy(self.scratch, self.blockSet(self.available_in, block_id));
            self.scanOpenBlock(self.scratch, block_value, endings, true);
            for (0..(block_value.terminator orelse unreachable).successorCount()) |ordinal| {
                @memcpy(self.edge_scratch, self.scratch);
                self.crossOpenEdge(self.edge_scratch, self.findEdge(block_id, @intCast(ordinal)), endings, true);
            }
        }
    }

    /// Follows an edge's ownership mappings, then applies the endings planned on it.
    fn crossOpenEdge(self: *const Solver, open: []u64, edge: *const OwnershipEdge, endings: ?[]const PlannedEnding, validate_existing: bool) void {
        self.remapEdgeAvailability(open, edge, endings);
        if (endings) |planned| {
            self.applyEndings(open, edgeLocation(edge), planned, validate_existing);
        }
    }

    fn scanOpenBlock(self: *const Solver, open: []u64, block: BuildBlock, endings: ?[]const PlannedEnding, validate_existing: bool) void {
        for (block.items.items) |item| switch (item) {
            .instruction => {},
            .boundary => |boundary| {
                self.scanEffectsForward(open, self.boundaries[@backingInt(boundary)].effects.items);
                if (endings) |planned| self.applyEndings(open, .{ .boundary = boundary }, planned, validate_existing);
            },
        };
        self.scanEffectsForward(open, block.terminator_effects.items);
    }

    fn applyEndings(
        self: *const Solver,
        open: []u64,
        location: CleanupLocation,
        endings: []const PlannedEnding,
        validate_existing: bool,
    ) void {
        for (endingsAtLocation(location, endings)) |ending| {
            if (validate_existing and (ending.cleanup_condition == null or self.generations[@backingInt(ending.generation)].requires_explicit_drop))
                std.debug.assert(GenerationBits.contains(open, ending.generation));
            GenerationBits.remove(open, ending.generation);
        }
    }

    fn hasEnding(generation: GenerationId, location: CleanupLocation, endings: []const PlannedEnding) bool {
        for (endingsAtLocation(location, endings)) |ending| {
            if (ending.generation == generation) return true;
        }
        return false;
    }

    fn endingsAtLocation(location: CleanupLocation, endings: []const PlannedEnding) []const PlannedEnding {
        const start, const end = std.sort.equalRange(PlannedEnding, endings, location, struct {
            fn order(needle: CleanupLocation, ending: PlannedEnding) std.math.Order {
                return compareLocations(needle, ending.location);
            }
        }.order);
        return endings[start..end];
    }

    fn scanEffectsBackward(_: *const Solver, demand: []u64, effects: []const Effect) void {
        var reversed = std.mem.reverseIterator(effects);
        while (reversed.next()) |effect| switch (effect.operation orelse continue) {
            .define => |definition| GenerationBits.remove(demand, definition.generation),
            .use, .update => |use| GenerationBits.insert(demand, use.generation),
            .consume => |generation| GenerationBits.insert(demand, generation),
        };
    }

    fn findEdge(self: *const Solver, predecessor: structures.FunctionBlockId, successor_ordinal: u2) *const OwnershipEdge {
        const edge_index = self.control_flow.blocks[@backingInt(predecessor)].outgoing[successor_ordinal] orelse unreachable;
        return &self.ownership_edges[edge_index];
    }

    fn edgeLocation(edge: *const OwnershipEdge) CleanupLocation {
        return .{ .edge = .{ .predecessor = edge.predecessor, .successor_ordinal = edge.successor_ordinal } };
    }

    /// Replaces a published fact row and reports whether it changed.
    fn publishChanged(comptime Fact: type, published: []Fact, facts: []const Fact) bool {
        if (std.mem.eql(Fact, published, facts)) return false;
        @memcpy(published, facts);
        return true;
    }

    fn blockSet(self: *const Solver, matrix: []u64, block: structures.FunctionBlockId) []u64 {
        const start = @backingInt(block) * self.words_per_block;
        return matrix[start .. start + self.words_per_block];
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
    cleanups: []const PlannedEnding = &.{},
    abandonments: []const struct { generation: GenerationId, location: CleanupLocation } = &.{},
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
    var next_effect_id: u32 = 0;
    for (boundaries, boundary_effects) |*boundary, effects| {
        for (effects) |effect| {
            try boundary.effects.append(gpa, .{ .id = @fromBackingInt(next_effect_id), .operation = effect });
            next_effect_id += 1;
        }
    }

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
        for (description.boundaries) |boundary| try block.items.append(gpa, .{ .boundary = @fromBackingInt(@intCast(boundary)) });
        for (description.terminator_effects) |effect| {
            try block.terminator_effects.append(gpa, .{ .id = @fromBackingInt(next_effect_id), .operation = effect });
            next_effect_id += 1;
        }
    }

    var endings: std.ArrayList(PlannedEnding) = .empty;
    defer endings.deinit(gpa);
    var solver = try Solver.init(
        gpa,
        generations,
        boundaries,
        blocks,
        block_argument_generations,
        ownership_forwards,
        ownership_edges,
        @fromBackingInt(@intCast(0)),
    );
    defer solver.deinit();
    try solver.solve(&endings);
    var cleanup_index: usize = 0;
    var abandonment_index: usize = 0;
    for (endings.items) |ending| {
        if (generations[@backingInt(ending.generation)].requires_explicit_drop) {
            try std.testing.expect(abandonment_index < expected.abandonments.len);
            const expected_abandonment = expected.abandonments[abandonment_index];
            try std.testing.expectEqual(expected_abandonment.generation, ending.generation);
            try std.testing.expectEqualDeep(expected_abandonment.location, ending.location);
            abandonment_index += 1;
        } else {
            try std.testing.expect(cleanup_index < expected.cleanups.len);
            try std.testing.expectEqualDeep(expected.cleanups[cleanup_index], ending);
            cleanup_index += 1;
        }
    }
    try std.testing.expectEqual(expected.cleanups.len, cleanup_index);
    try std.testing.expectEqual(expected.abandonments.len, abandonment_index);
}

fn testSolverGeneration(start_order: u32, explicit: bool) Generation {
    return .{
        .type_id = .unit,
        .start_order = start_order,
        .span = .{ .start = start_order, .end = start_order + 1 },
        .requires_explicit_drop = explicit,
        .cleanup_fields = false,
    };
}

test "lifetime solver releases partially initialized storage on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 6 });
    try std.testing.expectError(error.OutOfMemory, Solver.init(
        failing.allocator(),
        &.{testSolverGeneration(0, false)},
        &.{},
        &.{.{ .argument_start = 0, .argument_end = 0, .terminator = .return_unit }},
        &.{},
        &.{},
        &.{},
        @fromBackingInt(0),
    ));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "lifetime solver plans straight-line last and zero uses" {
    const generations = [_]Generation{ testSolverGeneration(0, false), testSolverGeneration(1, false) };
    const boundaries = [_][]const LifetimeEffect{
        &.{
            .{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } },
            .{ .define = .{ .generation = @fromBackingInt(@intCast(1)), .value = @fromBackingInt(@intCast(11)) } },
        },
        &.{.{ .use = .{ .generation = @fromBackingInt(@intCast(1)), .cleanup_value = @fromBackingInt(@intCast(12)) } }},
    };
    const blocks = [_]TestSolverBlock{.{ .boundaries = &.{ 0, 1 }, .terminator = .return_unit }};
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &.{}, .{ .cleanups = &.{
        .{
            .generation = @fromBackingInt(@intCast(0)),
            .cleanup_value = @fromBackingInt(@intCast(10)),
            .location = .{ .boundary = @fromBackingInt(@intCast(0)) },
        },
        .{
            .generation = @fromBackingInt(@intCast(1)),
            .cleanup_value = @fromBackingInt(@intCast(12)),
            .location = .{ .boundary = @fromBackingInt(@intCast(1)) },
        },
    } });
}

test "lifetime solver distinguishes branch use and consume" {
    const generations = [_]Generation{testSolverGeneration(0, false)};
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } }},
        &.{.{ .use = .{
            .generation = @fromBackingInt(@intCast(0)),
            .cleanup_value = @fromBackingInt(@intCast(11)),
            .cleanup_condition = @fromBackingInt(@intCast(99)),
        } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @fromBackingInt(@intCast(0)), .rhs = @fromBackingInt(@intCast(1)) },
            .then_branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{1}, .terminator = .return_unit },
        .{ .terminator_effects = &.{.{ .consume = @fromBackingInt(@intCast(0)) }}, .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 1, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &edges, .{ .cleanups = &.{.{
        .generation = @fromBackingInt(@intCast(0)),
        .cleanup_value = @fromBackingInt(@intCast(11)),
        .cleanup_condition = @fromBackingInt(@intCast(99)),
        .location = .{ .boundary = @fromBackingInt(@intCast(1)) },
    }} });
}

test "lifetime solver follows ownership joins and releases every allocation failure" {
    if (!@import("test_options").allocation_failures) return testExpectOwnershipJoinPlan(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testExpectOwnershipJoinPlan, .{});
}

fn testExpectOwnershipJoinPlan(gpa: std.mem.Allocator) !void {
    const generations = [_]Generation{
        testSolverGeneration(0, false),
        testSolverGeneration(1, false),
        testSolverGeneration(2, false),
    };
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } }},
        &.{.{ .define = .{ .generation = @fromBackingInt(@intCast(1)), .value = @fromBackingInt(@intCast(11)) } }},
        &.{.{ .use = .{ .generation = @fromBackingInt(@intCast(2)), .cleanup_value = @fromBackingInt(@intCast(0)) } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @fromBackingInt(@intCast(1)), .rhs = @fromBackingInt(@intCast(2)) },
            .then_branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{0}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(3)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{1}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(3)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{2}, .terminator = .return_unit, .argument_start = 0, .argument_end = 1 },
    };
    const forwards = [_]OwnershipForward{
        .{ .source = @fromBackingInt(@intCast(0)), .destination = @fromBackingInt(@intCast(2)) },
        .{ .source = @fromBackingInt(@intCast(1)), .destination = @fromBackingInt(@intCast(2)) },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @fromBackingInt(@intCast(2)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(3)), .mappings = .{ .start = 1, .end = 2 } },
        .{ .predecessor = @fromBackingInt(@intCast(1)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(3)), .mappings = .{ .start = 0, .end = 1 } },
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 1, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(gpa, &generations, &boundaries, &blocks, &.{@fromBackingInt(@intCast(2))}, &forwards, &edges, .{ .cleanups = &.{.{
        .generation = @fromBackingInt(@intCast(2)),
        .cleanup_value = @fromBackingInt(@intCast(0)),
        .location = .{ .boundary = @fromBackingInt(@intCast(2)) },
    }} });
}

test "lifetime solver reaches a fixed point across continue and break" {
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @fromBackingInt(@intCast(1)), .rhs = @fromBackingInt(@intCast(2)) },
            .then_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @fromBackingInt(@intCast(3)), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .boundaries = &.{1}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(1)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(1)), .successor_ordinal = 1, .successor = @fromBackingInt(@intCast(3)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(2)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 0 } },
    };
    for ([_]usize{ 1, 65, 130 }) |count| {
        var generations: [130]Generation = undefined;
        var definitions: [130]LifetimeEffect = undefined;
        var uses: [130]LifetimeEffect = undefined;
        var cleanups: [130]PlannedEnding = undefined;
        for (0..count) |index| {
            const generation: GenerationId = @fromBackingInt(@intCast(index));
            const value: structures.FunctionValueId = @fromBackingInt(@intCast(index + 10));
            generations[index] = testSolverGeneration(@intCast(index), false);
            definitions[index] = .{ .define = .{ .generation = generation, .value = value } };
            uses[index] = .{ .use = .{ .generation = generation, .cleanup_value = @fromBackingInt(@intCast(index + 1000)) } };
            cleanups[count - 1 - index] = .{
                .generation = generation,
                .cleanup_value = value,
                .location = .{ .edge = .{ .predecessor = @fromBackingInt(1), .successor_ordinal = 1 } },
            };
        }
        const boundaries = [_][]const LifetimeEffect{ definitions[0..count], uses[0..count] };
        try testExpectLifetimePlan(std.testing.allocator, generations[0..count], &boundaries, &blocks, &.{}, &.{}, &edges, .{ .cleanups = cleanups[0..count] });
    }
}

test "lifetime solver propagates through reordered blocks and ignores unreachable predecessors" {
    const generations = [_]Generation{
        testSolverGeneration(0, false),
        testSolverGeneration(1, false),
        testSolverGeneration(2, false),
    };
    const boundaries = [_][]const LifetimeEffect{
        &.{.{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } }},
        &.{.{ .use = .{ .generation = @fromBackingInt(@intCast(1)), .cleanup_value = @fromBackingInt(@intCast(0)) } }},
        &.{.{ .define = .{ .generation = @fromBackingInt(@intCast(2)), .value = @fromBackingInt(@intCast(20)) } }},
    };
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(4)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{1}, .terminator = .return_unit, .argument_start = 0, .argument_end = 1 },
        .{ .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .boundaries = &.{2}, .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } } } },
        .{ .terminator = .{ .branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } } } },
    };
    const forwards = [_]OwnershipForward{.{
        .source = @fromBackingInt(@intCast(0)),
        .destination = @fromBackingInt(@intCast(1)),
    }};
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(4)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(2)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 1 } },
        .{ .predecessor = @fromBackingInt(@intCast(3)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(4)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{@fromBackingInt(@intCast(1))}, &forwards, &edges, .{ .cleanups = &.{.{
        .generation = @fromBackingInt(@intCast(1)),
        .cleanup_value = @fromBackingInt(@intCast(0)),
        .location = .{ .boundary = @fromBackingInt(@intCast(1)) },
    }} });
}

test "lifetime solver handles terminal consumes divergence and branch production" {
    const consumed_generation = [_]Generation{testSolverGeneration(0, false)};
    const consumed_boundaries = [_][]const LifetimeEffect{&.{.{ .define = .{
        .generation = @fromBackingInt(@intCast(0)),
        .value = @fromBackingInt(@intCast(10)),
    } }}};
    const consumed_blocks = [_]TestSolverBlock{.{
        .boundaries = &.{0},
        .terminator_effects = &.{.{ .consume = @fromBackingInt(@intCast(0)) }},
        .terminator = .return_unit,
    }};
    try testExpectLifetimePlan(std.testing.allocator, &consumed_generation, &consumed_boundaries, &consumed_blocks, &.{}, &.{}, &.{}, .{});

    const diverging_boundaries = [_][]const LifetimeEffect{&.{
        .{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } },
        .{ .use = .{ .generation = @fromBackingInt(@intCast(0)), .cleanup_value = @fromBackingInt(@intCast(10)) } },
    }};
    const diverging_blocks = [_]TestSolverBlock{.{
        .terminator_effects = diverging_boundaries[0],
        .terminator = .diverge,
    }};
    try testExpectLifetimePlan(std.testing.allocator, &consumed_generation, &.{}, &diverging_blocks, &.{}, &.{}, &.{}, .{});
}

test "lifetime solver reports explicit abandonment on only one branch" {
    const generations = [_]Generation{testSolverGeneration(0, true)};
    const boundaries = [_][]const LifetimeEffect{&.{.{ .define = .{
        .generation = @fromBackingInt(@intCast(0)),
        .value = @fromBackingInt(@intCast(10)),
    } }}};
    const blocks = [_]TestSolverBlock{
        .{ .boundaries = &.{0}, .terminator = .{ .predicate_branch = .{
            .operation = .eqb,
            .operands = .{ .lhs = @fromBackingInt(@intCast(1)), .rhs = @fromBackingInt(@intCast(2)) },
            .then_branch = .{ .target = @fromBackingInt(@intCast(1)), .arguments = .{ .start = 0, .end = 0 } },
            .else_branch = .{ .target = @fromBackingInt(@intCast(2)), .arguments = .{ .start = 0, .end = 0 } },
        } } },
        .{ .terminator_effects = &.{.{ .consume = @fromBackingInt(@intCast(0)) }}, .terminator = .return_unit },
        .{ .terminator = .return_unit },
    };
    const edges = [_]OwnershipEdge{
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0, .successor = @fromBackingInt(@intCast(1)), .mappings = .{ .start = 0, .end = 0 } },
        .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 1, .successor = @fromBackingInt(@intCast(2)), .mappings = .{ .start = 0, .end = 0 } },
    };
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &edges, .{ .abandonments = &.{.{
        .generation = @fromBackingInt(@intCast(0)),
        .location = .{ .edge = .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 1 } },
    }} });
}

test "lifetime solver reverses simultaneous generation start order" {
    const generations = [_]Generation{ testSolverGeneration(0, false), testSolverGeneration(1, false) };
    const boundaries = [_][]const LifetimeEffect{
        &.{
            .{ .define = .{ .generation = @fromBackingInt(@intCast(0)), .value = @fromBackingInt(@intCast(10)) } },
            .{ .define = .{ .generation = @fromBackingInt(@intCast(1)), .value = @fromBackingInt(@intCast(11)) } },
        },
        &.{
            .{ .use = .{ .generation = @fromBackingInt(@intCast(0)), .cleanup_value = @fromBackingInt(@intCast(10)) } },
            .{ .use = .{ .generation = @fromBackingInt(@intCast(1)), .cleanup_value = @fromBackingInt(@intCast(11)) } },
        },
    };
    const blocks = [_]TestSolverBlock{.{ .boundaries = &.{ 0, 1 }, .terminator = .return_unit }};
    try testExpectLifetimePlan(std.testing.allocator, &generations, &boundaries, &blocks, &.{}, &.{}, &.{}, .{ .cleanups = &.{
        .{
            .generation = @fromBackingInt(@intCast(1)),
            .cleanup_value = @fromBackingInt(@intCast(11)),
            .location = .{ .boundary = @fromBackingInt(@intCast(1)) },
        },
        .{
            .generation = @fromBackingInt(@intCast(0)),
            .cleanup_value = @fromBackingInt(@intCast(10)),
            .location = .{ .boundary = @fromBackingInt(@intCast(1)) },
        },
    } });
}

test "lifetime endings deduplicate requests while preserving order locations and conditions" {
    if (!@import("test_options").allocation_failures) return testEndingDeduplication(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testEndingDeduplication, .{});
}

fn testEndingDeduplication(gpa: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |explicit| {
        var generations = [_]Generation{ testSolverGeneration(1, explicit), testSolverGeneration(0, explicit) };
        generations[0].cleanup_condition = @fromBackingInt(@intCast(99));
        // Exercise plan finalization directly, including requests from separate planning sites.
        var solver = try Solver.init(gpa, &generations, &.{}, &.{}, &.{}, &.{}, &.{}, @fromBackingInt(@intCast(0)));
        defer solver.deinit();
        var endings: std.ArrayList(PlannedEnding) = .empty;
        defer endings.deinit(gpa);
        const expected = [_]struct { generation: GenerationId, location: CleanupLocation }{
            .{ .generation = @fromBackingInt(@intCast(0)), .location = .{ .boundary = @fromBackingInt(@intCast(0)) } },
            .{ .generation = @fromBackingInt(@intCast(1)), .location = .{ .boundary = @fromBackingInt(@intCast(0)) } },
            .{ .generation = @fromBackingInt(@intCast(0)), .location = .{ .boundary = @fromBackingInt(@intCast(1)) } },
            .{ .generation = @fromBackingInt(@intCast(0)), .location = .{ .edge = .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 0 } } },
            .{ .generation = @fromBackingInt(@intCast(0)), .location = .{ .edge = .{ .predecessor = @fromBackingInt(@intCast(0)), .successor_ordinal = 1 } } },
            .{ .generation = @fromBackingInt(@intCast(0)), .location = .{ .edge = .{ .predecessor = @fromBackingInt(1), .successor_ordinal = 0 } } },
        };
        for ([_]usize{ 4, 1, 3, 0, 4, 5, 2, 5, 1, 0, 2, 3 }) |index| {
            const ending = expected[index];
            try solver.recordEnding(&endings, .{
                .generation = ending.generation,
                .cleanup_value = @fromBackingInt(@intCast(10 + @backingInt(ending.generation))),
                .location = ending.location,
            });
        }
        solver.finishEndings(&endings);
        try std.testing.expectEqual(expected.len, endings.items.len);
        for (expected, endings.items) |ending, actual| {
            try std.testing.expectEqualDeep(PlannedEnding{
                .generation = ending.generation,
                .cleanup_value = @fromBackingInt(@intCast(10 + @backingInt(ending.generation))),
                .cleanup_condition = generations[@backingInt(ending.generation)].cleanup_condition,
                .location = ending.location,
            }, actual);
            const matches = Solver.endingsAtLocation(ending.location, endings.items);
            var match_count: usize = 0;
            var expected_open: u64 = 3;
            for (endings.items) |candidate| {
                if (!std.meta.eql(candidate.location, ending.location)) continue;
                try std.testing.expect(match_count < matches.len);
                try std.testing.expectEqualDeep(candidate, matches[match_count]);
                match_count += 1;
                expected_open &= ~(@as(u64, 1) << @intCast(@backingInt(candidate.generation)));
            }
            try std.testing.expectEqual(match_count, matches.len);
            var open = [_]u64{3};
            solver.applyEndings(&open, ending.location, endings.items, true);
            try std.testing.expectEqual(expected_open, open[0]);
            for (0..generations.len) |generation_index| {
                const generation: GenerationId = @fromBackingInt(@intCast(generation_index));
                try std.testing.expectEqual(!GenerationBits.contains(&open, generation), Solver.hasEnding(generation, ending.location, endings.items));
            }
        }
        const absent_locations = [_]CleanupLocation{
            .{ .boundary = @fromBackingInt(2) },
            .{ .edge = .{ .predecessor = @fromBackingInt(2), .successor_ordinal = 0 } },
            .{ .boundary = @fromBackingInt(3) },
            .{ .boundary = @fromBackingInt(4) },
        };
        for (absent_locations) |location| {
            try std.testing.expectEqual(0, Solver.endingsAtLocation(location, endings.items).len);
            try std.testing.expect(!Solver.hasEnding(@fromBackingInt(0), location, endings.items));
            var open = [_]u64{3};
            solver.applyEndings(&open, location, endings.items, true);
            try std.testing.expectEqual(3, open[0]);
        }
        try std.testing.expectEqual(0, Solver.endingsAtLocation(expected[0].location, &.{}).len);
        try std.testing.expectEqual(0, Solver.endingsAtLocation(expected[0].location, endings.items[2..]).len);
    }
}
