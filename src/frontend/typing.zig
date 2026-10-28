const std = @import("std");
const standard_library = @import("standard_library");
const value_operations = @import("../value.zig");
const structures = @import("../structures.zig");
const semantic = @import("semantic.zig");
const lifetime = @import("lifetime.zig");
const body_graph = @import("body_graph.zig");
const origin_storage = @import("reference_origins.zig");
const flow_snapshot = @import("flow_snapshot.zig");
const flow_types = @import("flow_types.zig");
const cleanup_shape = @import("cleanup_shape.zig");
const control_flow = @import("../control_flow.zig");
const profiling = @import("../profiling.zig");

const GenerationId = body_graph.GenerationId;
const BoundaryId = body_graph.BoundaryId;
const EffectId = body_graph.EffectId;
const Generation = body_graph.Generation;
const LifetimeEffect = body_graph.LifetimeEffect;
const OwnershipForward = body_graph.OwnershipForward;
const OwnershipEdge = body_graph.OwnershipEdge;
const PlannedEnding = body_graph.PlannedEnding;
const Boundary = body_graph.Boundary;
const BuildInstruction = body_graph.BuildInstruction;
const BuildItem = body_graph.BuildItem;
const BuildBlock = body_graph.BuildBlock;
const CleanupLocation = body_graph.CleanupLocation;
const LifetimeSolver = lifetime.Solver;

pub const BodyOptions = struct {
    infer_return_type: bool = false,
    publish_instruction_spans: bool = false,
    allow_type_values: bool = false,
    expected_result_type: ?structures.TypeId = null,
    measurements: ?*BodyMeasurements = null,
    builtin_body: ?BuiltinBody = null,
    result_mode: structures.ResultMode = .owned,
    infer_reference_contract: bool = false,
    widen_reference_indices: bool = false,
};

/// Resolved standard declaration identity, with the spelling of a primitive operation.
pub const BuiltinBody = struct {
    symbol: standard_library.External,
    operation: ?structures.Operation = null,
};

pub const BodyMeasurements = struct {
    snapshots: usize = 0,
    snapshot_bytes: usize = 0,
    flow_fact_bytes: usize = 0,
    flow_place_bytes: usize = 0,
    flow_predicate_bytes: usize = 0,
    inference_key_bytes: usize = 0,
    blocks: usize = 0,
    generations: usize = 0,
    lifetime_table_bytes: usize = 0,
    overload_argument_discoveries: usize = 0,
    unevaluated_type_visits: usize = 0,
    type_only_regions: usize = 0,
    region_capture_buffer_growths: usize = 0,
    initializer_capture_values: usize = 0,
    inference_capture_values: usize = 0,
};

pub fn emitSemanticIssue(ctx: anytype, file_id: structures.FileId, issue: semantic.Issue) !void {
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = issue.span, .kind = issue.kind });
}

pub fn referenceReplacementIssue(types: anytype, element_type: structures.TypeId) !?structures.Diagnostic.Kind {
    const capabilities = (try types.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
    if (capabilities.requires_explicit_drop) return .{ .borrow_write_requires_automatic_drop = element_type };
    if (!capabilities.isDirectlyMovable())
        return .{ .borrow_write_requires_direct_move = element_type };
    return null;
}

pub fn resolveAndTypeBody(
    ctx: anytype,
    instance: structures.InstanceId,
    file_id: structures.FileId,
    parameters: []const structures.CallableParameter,
    return_type: structures.TypeId,
    options: BodyOptions,
    analysis_context: anytype,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    const body = (try resolveBody(false, ctx, instance, file_id, parameters, return_type, options, analysis_context, unresolved)) orelse return null;
    return try value_operations.Owned(structures.FunctionBodyAnalysis).clone(ctx.allocator(), body);
}

/// Returns a workspace body view for query publication, or an owned reference contract.
pub fn resolveBody(
    comptime contract_only: bool,
    ctx: anytype,
    instance: structures.InstanceId,
    file_id: structures.FileId,
    parameters: []const structures.CallableParameter,
    return_type: structures.TypeId,
    options: BodyOptions,
    analysis_context: anytype,
    unresolved: semantic.UnresolvedBody,
) !?if (contract_only) structures.ReferenceContract else structures.FunctionBodyAnalysis {
    if (options.measurements) |measurements| measurements.* = .{};
    var builder: BodyBuilder(@TypeOf(ctx), @TypeOf(analysis_context)) = .{
        .gpa = ctx.allocator(),
        .ctx = ctx,
        .analysis_context = analysis_context,
        .instance = instance,
        .file_id = file_id,
        .unresolved = unresolved,
        .return_type = if (options.result_mode == .reference) try analysis_context.facts().referenceType(return_type) else return_type,
        .options = options,
    };
    {
        var phase: profiling.Scope = .{};
        phase.beginCurrent(.body_typing);
        defer phase.end();
        builder.build(parameters) catch |err| switch (err) {
            error.SourceRejected, error.Unavailable => return null,
            else => return err,
        };
    }
    const result = (if (contract_only) builder.finishReferenceAnalysis() else builder.finishAnalysis(options.measurements, null)) catch |err| switch (err) {
        error.SourceRejected, error.Unavailable => return null,
        else => return err,
    };
    return if (contract_only) try value_operations.Owned(structures.ReferenceContract).clone(ctx.allocator(), result) else result;
}

/// All construction data and nested regions borrow one analysis workspace.
/// Finished graphs remain views until publication or an owned temporary copy.
fn BodyBuilder(comptime Context: type, comptime AnalysisServices: type) type {
    return struct {
        const Self = @This();
        const ReferenceProjection = struct {
            step: structures.ReferencePathStep,
            next: ?u32,
        };
        const PlaceReferenceMetadata = struct {
            storage_depth: u32,
            stable: bool,
            after_write: bool,
            state: ?StateId = null,
        };
        const ReferenceTransform = struct {
            operation: union(enum) {
                prefix: @FieldType(ReferenceProjection, "step"),
                select: @FieldType(ReferenceProjection, "step"),
                exclude: @FieldType(ReferenceProjection, "step"),
                source_path: structures.ReferencePathStep,
                place: PlaceReferenceMetadata,
                readonly,
                readonly_owned: structures.TypeId,
                widen,
                read: struct { state: StateId, instruction: u31 },
                relocate_read: struct { from: u31, to: u31 },
                refresh_written: StateId,
                refresh: struct { root: semantic.UnresolvedBody.LocalId, previous: BindingIdentity, replacement: BindingIdentity, storage_replacement: ?BindingIdentity = null, preserved_storage_depth: u32 = std.math.maxInt(u32) },
            },
            previous: ?u32,
        };
        const ReferenceOrigin = struct {
            // A copied parameter's inline storage belongs to this call; its
            // allocated descendants still belong to the caller.
            frame_type: ?structures.TypeId = null,
            generation: ?GenerationId = null,
            cleanup_value: ?structures.FunctionValueId = null,
            root: ?semantic.UnresolvedBody.LocalId = null,
            binding_identity: BindingIdentity = .unknown,
            parameter: ?u32 = null,
            source_kind: structures.ReferenceSourceKind = .contents,
            source_path: ?u32 = null,
            storage_depth: u32 = 0,
            loop: ?u32 = null,
            projection: ?u32 = null,
            readonly: bool = false,
            readonly_owned: ?structures.TypeId = null,
            variant_guard: bool = false,
            after_write: bool = false,
            stable: bool = false,
            permanent: bool = false,
            read: ?u31 = null,
            deferred_capture: bool = false,
            initializer_owner: ?structures.FunctionValueId = null,
            // Proof identity for a fixed reference whose backing path is imprecise.
            flow_handle: ?FlowHandle = null,
            transform: ?u32 = null,
            next: ?u32 = null,
        };
        const BindingIdentity = union(enum) { unknown, fixed: u32, join: u32 };
        const ReferenceRefresh = union(enum) { value: *?u32, slots: *?u32 };
        const ReferenceEffectSite = union(enum) { instruction: u31, terminator: EffectId };
        const ReferenceEffects = struct { writes: ?u32 = null, storage_invalidations: ?u32 = null };
        const ReferenceExclusion = struct { reference: ?u32, invalidation: ?u32, span: structures.SourceSpan, match_testing: bool = false };
        const MatchTestingScope = struct { parent: ?*MatchTestingScope, origins: ?u32 = null, locals: std.ArrayList(semantic.UnresolvedBody.LocalId) = .empty };
        const ReferenceWrite = struct {
            origins: ?u32,
            written_type: structures.TypeId,
            ends_lifetime: bool = false,
        };
        const BindingJoin = struct {
            slot: ?u32 = null,
            kind: enum { contents, storage, variant } = .contents,
            initial: BindingIdentity,
            alternatives: std.ArrayList(BindingIdentity) = .empty,
            complete: bool = false,
        };
        const ResolvedBindingIdentity = struct {
            value: ?u32 = null,
            conflicting: bool = false,
            incomplete: bool = false,
        };
        const FlowHandle = enum(u64) { _ };
        const FlowOrigin = struct {
            scope: u32 = 0,
            handle: ?FlowHandle = null,
            root: ?semantic.UnresolvedBody.LocalId = null,
            parameter: ?u32 = null,
            generation: ?GenerationId = null,
            cleanup_value: ?structures.FunctionValueId = null,
            path: ?u32 = null,
        };
        const FlowPlace = struct { type_id: structures.TypeId, origins: []const u32 };
        const FlowProjection = struct { step: structures.ReferencePathStep, parent: ?u32, depth: u32 };
        const FlowData = struct {
            origins: std.AutoArrayHashMapUnmanaged(FlowOrigin, void) = .empty,
            places: std.ArrayList(FlowPlace) = .empty,
            indices: std.StringHashMapUnmanaged(u32) = .empty,
            paths: std.AutoArrayHashMapUnmanaged(FlowProjection, void) = .empty,
            facts: flow_types.Store = .{},
            predicates: std.ArrayList(struct { matched: flow_types.State, unmatched: flow_types.State }) = .empty,
            next_scope: u32 = 1,
        };
        const LoopReferenceOrigins = struct {
            slot: u32,
            origins: ?u32,
            read_checkpoint: ?u31 = null,
            complete: bool = false,
        };
        const Value = struct {
            id: structures.FunctionValueId,
            type_id: structures.TypeId,
            writable: bool = true,
            predicate: ?u32 = null,
            place_reference: ?structures.FunctionValueId = null,
            place_origins: ?u32 = null,
            flow_origins: ?u32 = null,
            owned_generation: ?GenerationId = null,
            borrowed_generation: ?GenerationId = null,
            borrowed_cleanup_value: ?structures.FunctionValueId = null,
            // `borrow_condition` is true on paths where ownership still belongs
            // to `borrowed_type`; `borrow_root` is the youngest possible local
            // source and therefore the first lexical lifetime that can end.
            borrowed_type: ?structures.TypeId = null,
            borrow_condition: ?structures.FunctionValueId = null,
            borrow_root: ?semantic.UnresolvedBody.LocalId = null,
            reference_origins: ?u32 = null,
            local_reference: ?LocalReference = null,
            stable_reference_root: ?semantic.UnresolvedBody.LocalId = null,
            binding_identity: BindingIdentity = .unknown,
            storage_identity: ?BindingIdentity = null,
            variant_identity: ?BindingIdentity = null,
            materialize_on_copy: bool = false,
            explicit_transfer: bool = false,
            initializer_parameter: ?u32 = null,
            consumption_completion: ?structures.FunctionValueId = null,
            pending_consumption_owners: ?u32 = null,
            // Consuming an existing place keeps its address across result joins.
            preserves_storage: bool = false,
            representation: structures.ValueRepresentation = .value,
        };
        const CallTarget = union(enum) {
            direct: structures.InstanceId,
            inferred: structures.InstanceId,
            indirect: Value,
        };
        const InitAvailability = enum { absent, pending, consumed, maybe_consumed };
        const ReplacementTarget = union(enum) { local: semantic.UnresolvedBody.LocalId, reference: Value };
        const InitializerTypeKey = struct { expression: semantic.UnresolvedBody.ValueId, expected: ?structures.TypeId, initializer_boundary: bool, flow_state: usize };
        const InitializerTypes = std.AutoHashMapUnmanaged(InitializerTypeKey, structures.TypeId);
        const CaptureTransfer = struct { local: semantic.UnresolvedBody.LocalId, parameter: u32, field: ?usize = null };
        const PendingConsumptionOwner = struct {
            generation: ?GenerationId,
            cleanup_value: structures.FunctionValueId,
            local: semantic.UnresolvedBody.LocalId,
            field: ?usize,
            next: ?u32 = null,
        };
        const InitializerTransfer = struct {
            initializer: structures.FunctionValueId,
            local: semantic.UnresolvedBody.LocalId,
            owner: Value,
            call_availability: Availability,
            field: ?usize = null,
        };
        const InitializerWrite = struct {
            initializer: structures.FunctionValueId,
            local: semantic.UnresolvedBody.LocalId,
            origins: ?u32,
        };
        const InitializerReferenceWrite = struct { initializer: structures.FunctionValueId, reference: Value };
        const Availability = enum { unbound, available, transferred, maybe_transferred, replacing };

        fn unavailableUse(availability: Availability) structures.Diagnostic.Kind {
            return switch (availability) {
                .transferred => .use_after_transfer,
                .maybe_transferred => .possibly_transferred,
                .replacing => .replaced_value_used,
                .unbound, .available => unreachable,
            };
        }
        const FieldPlace = struct {
            local: semantic.UnresolvedBody.LocalId,
            fields: []const semantic.UnresolvedBody.FieldName,
            moves_owner: bool = false,
        };
        const StateValues = flow_snapshot.Buffer(?Value, null);
        const StateAvailability = flow_snapshot.Buffer(Availability, .unbound);
        const StateFields = flow_snapshot.Buffer(Availability, .available);
        const StateInitializers = flow_snapshot.Buffer(InitAvailability, .absent);
        const StateConsumptions = flow_snapshot.Buffer(bool, false);
        fn stateValue(values: StateValues, index: usize) ?*const Value {
            return if (values.getPtr(index).*) |*entry| entry else null;
        }
        const State = struct {
            values: StateValues = .{},
            availability: StateAvailability = .{},
            field_availability: StateFields = .{},
            initializers: StateInitializers = .{},
            completed_consumptions: StateConsumptions = .{},
            refinements: flow_types.State = .{},

            fn snapshot(self: State) State {
                var result = self;
                inline for (@typeInfo(State).@"struct".field_names) |name| {
                    @field(result, name) = @field(self, name).snapshot();
                }
                return result;
            }

            fn joinFlow(self: *State, allocator: std.mem.Allocator, other: State) !void {
                try self.availability.merge(allocator, other.availability, joinAvailability);
                try self.field_availability.merge(allocator, other.field_availability, joinAvailability);
                try self.initializers.merge(allocator, other.initializers, struct {
                    fn combine(left: InitAvailability, right: InitAvailability) InitAvailability {
                        return if (left == right) left else .maybe_consumed;
                    }
                }.combine);
                try self.completed_consumptions.merge(allocator, other.completed_consumptions, struct {
                    fn combine(left: bool, right: bool) bool {
                        return left and right;
                    }
                }.combine);
            }
        };
        const Expression = semantic.UnresolvedBody.Expression;
        const StateId = enum(u32) { _ };
        const PendingReferenceUseLocation = EffectId;
        const EffectLocation = union(enum) {
            boundary: struct { id: BoundaryId, effect_index: usize },
            terminator: struct { id: structures.FunctionBlockId, effect_index: usize },
        };
        const ReferenceUseKind = enum { access, retention };
        const PendingReferenceUse = struct {
            kind: ReferenceUseKind,
            origins: u32,
            state: StateId,
            span: structures.SourceSpan,
            location: PendingReferenceUseLocation,
        };
        const ReferenceUse = struct {
            origins: u32,
            span: structures.SourceSpan,
            location: PendingReferenceUseLocation,
            match_testing: bool = false,
        };
        const PendingReferenceInvalidation = struct {
            origins: u32,
            known: ?u32,
            span: structures.SourceSpan,
        };
        const PendingReferenceReturn = struct { origins: u32, span: structures.SourceSpan };
        const PendingExtraction = struct {
            binding: semantic.UnresolvedBody.Capture,
            operand: Value,
            target_type: structures.TypeId,
        };
        const FlowExit = struct {
            block: structures.FunctionBlockId,
            state: StateId,
            reference_origins: ?u32 = null,
            constructed: ?Value = null,
        };
        const ConditionFlow = struct {
            matched: ?FlowExit,
            unmatched: ?FlowExit,
            diverged: ?Value = null,
        };
        const PatternScope = struct {
            baseline: StateAvailability,
            exits: std.ArrayList(FlowExit) = .empty,
        };
        const LoopContext = struct {
            body: semantic.UnresolvedBody.BlockId,
            header: structures.FunctionBlockId,
            baseline: StateId,
            result: ResultRequest,
            refinements: flow_types.State,
            proofs: std.AutoHashMapUnmanaged(u32, void) = .empty,
        };
        const LoopBackedge = struct {
            block: structures.FunctionBlockId,
            state: StateId,
        };
        const PlaceField = struct {
            index: u32,
            type_id: structures.TypeId,
            kind: structures.MemberKind = .owned,
            name: []const u8,
        };
        const OwnedPlace = struct {
            local: semantic.UnresolvedBody.LocalId,
            fields: structures.FunctionValueRange,
        };
        const LocalReference = struct { local: semantic.UnresolvedBody.LocalId, projections: structures.FunctionValueRange };
        const ArgumentRoot = union(enum) { local: semantic.UnresolvedBody.LocalId, reference: Value };
        const ArgumentPlace = struct { root: ArgumentRoot, fields: structures.FunctionValueRange };
        const SourcePlaceRoot = union(enum) { local: semantic.UnresolvedBody.LocalId, parameter: semantic.UnresolvedBody.ValueId, reference: semantic.UnresolvedBody.ValueUse };
        const BorrowPlace = struct {
            root: union(enum) {
                local: semantic.UnresolvedBody.LocalId,
                parameter: semantic.UnresolvedBody.ValueId,
                reference: Value,
            },
            fields: structures.FunctionValueRange,
        };
        const PendingMutArgument = struct {
            // A call publishes one mutation event on both result edges.
            result_identity: BindingIdentity,
            place: ArgumentPlace,
            argument_index: u32,
            reference_origins: ?u32 = null,
            return_origin: bool = false,
            writes_storage: bool = true,
        };
        const PendingReferenceOutput = struct { reference: Value, origins: ?u32 };

        const CallOriginSource = struct {
            type_id: structures.TypeId,
            contained: ?u32,
            storage: ?u32 = null,
            value: ?structures.FunctionValueId = null,
        };
        const PendingMutableAliasCheck = struct {
            origins: ?u32,
            local: ?semantic.UnresolvedBody.LocalId,
            place_origins: ?u32,
            span: structures.SourceSpan,
        };
        const OwnershipForwardHint = struct {
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            source: ?GenerationId,
            destination: GenerationId,
        };
        const GenerationOnlyJoin = struct {
            slot: u32,
            destination: GenerationId,
        };
        const GenerationOrigin = enum { none, define, phi };
        const LocalMetadata = struct { mutable: bool = false, reference: bool = false, can_deinit: bool = false, mut_parameter: ?u32 = null };

        ctx: Context,
        gpa: std.mem.Allocator,
        analysis_context: AnalysisServices,
        instance: structures.InstanceId,
        file_id: structures.FileId,
        unresolved: semantic.UnresolvedBody,
        return_type: structures.TypeId,
        pattern_scope: ?*PatternScope = null,

        options: BodyOptions = .{},
        type_check_only: bool = false,
        values: flow_snapshot.Buffer(?Value, null) = .{},
        state: State = .{},
        initializer_regions: std.ArrayList(structures.FunctionBodyAnalysis) = .empty,
        initializer_captures: std.ArrayList(structures.FunctionValueId) = .empty,
        initializer_types: InitializerTypes = .empty,
        // Region contexts borrow their root's type discovery cache. Executable
        // preparation still checks ownership and effects in each context.
        shared_initializer_types: ?*InitializerTypes = null,
        is_initializer_region: bool = false,
        collection_emission: ?*CollectionEmission = null,
        optional_collection_allocation: bool = false,
        captured_locals: []?u32 = &.{},
        initializer_writes: std.ArrayList(InitializerWrite) = .empty,
        initializer_reference_writes: std.ArrayList(InitializerReferenceWrite) = .empty,
        initializer_write_checks: std.ArrayList(struct {
            origins: ?u32,
            owners: []Value,
            locals: []semantic.UnresolvedBody.LocalId,
            span: structures.SourceSpan,
        }) = .empty,
        capture_reference_writes: std.ArrayList(Value) = .empty,
        returned_reference_origins: ?u32 = null,
        capture_output_origins: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,
        capture_transfers: std.ArrayList(CaptureTransfer) = .empty,
        initializer_transfers: std.ArrayList(InitializerTransfer) = .empty,
        pending_consumption_owners: std.ArrayList(PendingConsumptionOwner) = .empty,
        ordinary_completion_states: std.ArrayList(StateId) = .empty,
        locals: std.MultiArrayList(LocalMetadata).Slice = .empty,
        field_places: []FieldPlace = &.{},
        states: std.ArrayList(State) = .empty,
        block_arguments: std.ArrayList(structures.FunctionBlockArgument) = .empty,
        parameter_modes: std.ArrayList(structures.ParameterMode) = .empty,
        block_argument_generations: std.ArrayList(?GenerationId) = .empty,
        variant_coercion_tags: std.ArrayList(u32) = .empty,
        borrow_fields: std.ArrayList(structures.BorrowProjection) = .empty,
        reference_storage: origin_storage.Store(ReferenceOrigin, ReferenceProjection, ReferenceTransform) = .{},
        flow: ?*FlowData = null,
        flow_parent: ?*Self = null,
        flow_captures: []const Value = &.{},
        flow_scope: u32 = 0,
        reference_writes: std.ArrayList(ReferenceWrite) = .empty,
        binding_joins: std.ArrayList(BindingJoin) = .empty,
        binding_versions: std.ArrayList(?union(enum) { alias: BindingIdentity, write: struct { previous: BindingIdentity, preserved_storage_depth: u32 } }) = .empty,
        loop_reference_origins: std.ArrayList(LoopReferenceOrigins) = .empty,
        loop_backedges: std.ArrayList(LoopBackedge) = .empty,
        pending_reference_uses: std.ArrayList(PendingReferenceUse) = .empty,
        reference_uses: std.ArrayList(ReferenceUse) = .empty,
        cleanup_origins: std.AutoHashMapUnmanaged(structures.FunctionValueId, u32) = .empty,
        cleanup_captures: std.ArrayList(CleanupCapture) = .empty,
        reference_effects: std.AutoHashMapUnmanaged(ReferenceEffectSite, ReferenceEffects) = .empty,
        next_effect_id: u32 = 0,
        effect_locations: []?EffectLocation = &.{},
        reference_exclusions: std.ArrayList(ReferenceExclusion) = .empty,
        pending_reference_invalidations: std.ArrayList(PendingReferenceInvalidation) = .empty,
        pending_mutable_alias_checks: std.ArrayList(PendingMutableAliasCheck) = .empty,
        pending_reference_returns: std.ArrayList(PendingReferenceReturn) = .empty,
        call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
        mut_argument_fields: std.ArrayList(PlaceField) = .empty,
        pending_mut_arguments: std.ArrayList(PendingMutArgument) = .empty,
        pending_reference_outputs: std.ArrayList(PendingReferenceOutput) = .empty,
        writable_call_references: std.ArrayList(Value) = .empty,
        pending_consumed_arguments: std.ArrayList(Value) = .empty,
        pending_initializer_owners: std.ArrayList(Value) = .empty,
        initializer_owners: std.ArrayList(struct { initializer: structures.FunctionValueId, owner: Value }) = .empty,
        pending_initializer_locals: std.ArrayList(semantic.UnresolvedBody.LocalId) = .empty,
        match_testing_scope: ?*MatchTestingScope = null,
        replacement_targets: std.ArrayList(ReplacementTarget) = .empty,
        pending_deinit_places: std.ArrayList(OwnedPlace) = .empty,
        pending_deinit_fields: std.ArrayList(PlaceField) = .empty,
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        branch_argument_generations: std.ArrayList(?GenerationId) = .empty,
        generations: std.ArrayList(Generation) = .empty,
        ownership_forwards: std.ArrayList(OwnershipForward) = .empty,
        ownership_edges: std.ArrayList(OwnershipEdge) = .empty,
        ownership_forward_hints: std.ArrayList(OwnershipForwardHint) = .empty,
        planned_endings: std.ArrayList(PlannedEnding) = .empty,
        boundaries: std.ArrayList(Boundary) = .empty,
        blocks: std.ArrayList(BuildBlock) = .empty,
        loop_stack: std.ArrayList(LoopContext) = .empty,
        loop_breaks: std.ArrayList(FlowExit) = .empty,
        current_block: ?structures.FunctionBlockId = null,
        current_boundary: ?BoundaryId = null,
        instruction_count: u32 = 0,
        block_layout_count: u32 = 0,

        const CleanupCapture = struct {
            block: structures.FunctionBlockId,
            position: union(enum) {
                entry,
                instruction: u31,
                boundary: BoundaryId,
            },
            origins: ?u32,
            previous: ?u32,
        };

        const PreparedCleanup = struct {
            plan: PlannedEnding,
            origins: ?u32,
        };

        fn init(self: *Self, parameters: []const structures.CallableParameter) !void {
            std.debug.assert(parameters.len == self.unresolved.parameter_count);
            std.debug.assert(parameters.len == self.unresolved.parameter_spans.len);
            self.values = @TypeOf(self.values).init(parameters.len + self.unresolved.expressions.len);
            self.state.initializers = @TypeOf(self.state.initializers).init(parameters.len);
            self.state.values = @TypeOf(self.state.values).init(self.unresolved.local_count);
            var locals: std.MultiArrayList(LocalMetadata) = .empty;
            try locals.ensureTotalCapacity(self.gpa, self.unresolved.local_count);
            for (0..self.unresolved.local_count) |_| locals.appendAssumeCapacity(.{});
            self.locals = locals.slice();
            self.state.availability = @TypeOf(self.state.availability).init(self.unresolved.local_count);
            self.field_places = try self.collectFieldPlaces();
            self.state.field_availability = @TypeOf(self.state.field_availability).init(self.field_places.len);
            self.state.completed_consumptions = @TypeOf(self.state.completed_consumptions).init(self.state.values.len + self.field_places.len);
            try self.block_arguments.ensureUnusedCapacity(self.gpa, parameters.len);
            try self.parameter_modes.ensureUnusedCapacity(self.gpa, parameters.len);
            try self.block_argument_generations.ensureUnusedCapacity(self.gpa, parameters.len);
            const root_span = self.unresolved.blocks[@backingInt(self.unresolved.root_block)].span;
            var parameter_local: usize = 0;
            for (parameters, 0..) |parameter, index| {
                var entry_value: Value = .{ .id = @fromBackingInt(@intCast(index)), .type_id = parameter.type_id };
                if (parameter.mode == .@"var" or parameter.mode == .deinit) {
                    entry_value.owned_generation = try self.allocateGeneration(parameter.type_id, self.unresolved.parameter_spans[index], parameter.mode == .deinit);
                }
                const stores_borrow = try self.analysis_context.facts().canStoreBorrow(parameter.type_id);
                switch (parameter.mode) {
                    .init => {
                        try self.values.set(self.gpa, index, .{ .id = entry_value.id, .type_id = entry_value.type_id, .initializer_parameter = @intCast(index), .reference_origins = if (stores_borrow) try self.addReferenceOrigin(null, .{ .parameter = @intCast(index) }) else null });
                        try self.state.initializers.set(self.gpa, index, .pending);
                    },
                    .imm => {
                        try self.values.set(self.gpa, index, .{
                            .id = entry_value.id,
                            .type_id = entry_value.type_id,
                            .writable = false,
                            .borrowed_type = entry_value.type_id,
                            .reference_origins = try self.addReferenceOrigin(null, .{ .parameter = @intCast(index), .source_kind = if (stores_borrow) .contents else .place }),
                            .place_origins = if (stores_borrow) try self.parameterPlaceOrigins(@intCast(index), entry_value) else null,
                        });
                    },
                    .ref, .mut, .@"var", .deinit => {
                        if (stores_borrow) entry_value.reference_origins = try self.addReferenceOrigin(null, .{ .parameter = @intCast(index) });
                        entry_value.binding_identity = try self.newBindingIdentity();
                        if (parameter.mode != .@"var") entry_value.representation = .storage;
                        try self.state.values.set(self.gpa, parameter_local, entry_value);
                        self.locals.items(.mutable)[parameter_local] = true;
                        self.locals.items(.can_deinit)[parameter_local] = parameter.mode == .deinit;
                        if (parameter.mode == .ref or parameter.mode == .mut) self.locals.items(.mut_parameter)[parameter_local] = @intCast(index);
                        try self.state.availability.set(self.gpa, parameter_local, .available);
                        parameter_local += 1;
                    },
                    .static => unreachable,
                }
                self.block_arguments.appendAssumeCapacity(.{ .type_id = parameter.type_id, .representation = switch (parameter.mode) {
                    .init => .initializer,
                    .ref, .mut, .deinit => .storage,
                    else => .value,
                } });
                self.parameter_modes.appendAssumeCapacity(parameter.mode);
                self.block_argument_generations.appendAssumeCapacity(entry_value.owned_generation);
            }
            const entry = try self.newBlock(0, @intCast(parameters.len));
            self.enterBlock(entry);
            // A region receives already established values through
            // captures. Rebuilding static parameter values here would create
            // unused owned objects and repeat their cleanup effects.
            if (!self.is_initializer_region) for (0..self.unresolved.static_expression_count) |static_index| {
                _ = try self.value(@fromBackingInt(@intCast(parameters.len + static_index)));
            };
            const parameter_boundary = try self.newBoundary(root_span);
            for (0..self.state.values.len) |local| {
                const parameter_value = self.state.values.get(local) orelse continue;
                if (parameter_value.owned_generation) |generation| {
                    try self.rememberCleanupOrigins(parameter_value);
                    _ = try self.appendEffectAt(parameter_boundary, .{ .define = .{
                        .generation = generation,
                        .value = parameter_value.id,
                    } });
                }
            }
            try self.closeBoundary(parameter_boundary);
        }

        fn collectFieldPlaces(self: *Self) ![]FieldPlace {
            var places: std.ArrayList(FieldPlace) = .empty;
            var path: std.ArrayList(semantic.UnresolvedBody.FieldName) = .empty;

            for (self.unresolved.expressions, 0..) |expression, index| {
                path.clearRetainingCapacity();
                const local = switch (expression.operation) {
                    .field_access, .field_transfer => switch ((try self.appendSourcePlaceFields(false, @fromBackingInt(@intCast(self.unresolved.parameter_count + index)), &path)) orelse continue) {
                        .local => |local| local,
                        .parameter, .reference => continue,
                    },
                    .assignment => |target| blk: {
                        if (target.fields.start == target.fields.end) continue;
                        try path.appendSlice(self.gpa, self.unresolved.assignment_fields[target.fields.start..target.fields.end]);
                        break :blk target.target;
                    },
                    else => continue,
                };
                const duplicate = for (places.items) |place| {
                    if (place.local == local and samePlacePath(place.fields, path.items)) break true;
                } else false;
                if (duplicate) continue;
                try places.ensureUnusedCapacity(self.gpa, 1);
                places.appendAssumeCapacity(.{ .local = local, .fields = try path.toOwnedSlice(self.gpa) });
            }
            return places.toOwnedSlice(self.gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try self.ctx.emit(structures.Diagnostic, .{ .file_id = self.file_id, .span = span, .kind = kind, .instance = self.instance });
            return error.SourceRejected;
        }

        fn rejectRead(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind, expression: semantic.UnresolvedBody.ValueId) anyerror {
            if (try self.readPlaceValue(expression)) |source| if (try self.flowPlace(source, false)) |place| {
                const fact = self.flow.?.facts.get(self.state.refinements, place);
                if (fact.type_id == null and fact.previous != 0) {
                    const notes = try self.gpa.dupe(structures.Diagnostic.Note, &.{
                        .{ .span = self.flow.?.facts.record(fact.previous).span, .kind = .type_proof },
                        .{ .span = fact.span, .kind = .proof_invalidated },
                    });
                    try self.ctx.emit(structures.Diagnostic, .{ .file_id = self.file_id, .span = span, .kind = kind, .instance = self.instance, .notes = notes });
                    return error.SourceRejected;
                }
            };
            return self.reject(span, kind);
        }

        fn rejectLoopProof(self: *Self, actual: flow_types.Fact, required: flow_types.Fact) anyerror {
            const notes = try self.gpa.dupe(structures.Diagnostic.Note, &.{.{ .span = required.span, .kind = .type_proof }});
            try self.ctx.emit(structures.Diagnostic, .{ .file_id = self.file_id, .span = actual.span, .kind = .loop_invalidates_type_proof, .instance = self.instance, .notes = notes });
            return error.SourceRejected;
        }

        fn typeMismatch(_: *Self, expected: structures.TypeId, found: structures.TypeId) structures.Diagnostic.TypeMismatch {
            return .{ .expected = expected, .found = found };
        }

        fn finishAnalysis(self: *Self, measurements: ?*BodyMeasurements, retained_captures: ?*std.ArrayList(u32)) !structures.FunctionBodyAnalysis {
            try self.prepareAnalysis(measurements);
            const contract = try self.publishReferenceContract();
            var body = try self.finish(retained_captures);
            body.reference_contract = contract;
            return body;
        }

        fn finishReferenceAnalysis(self: *Self) !structures.ReferenceContract {
            try self.prepareAnalysis(null);
            return self.publishReferenceContract();
        }

        fn prepareAnalysis(self: *Self, measurements: ?*BodyMeasurements) !void {
            var phase: profiling.Scope = .{};
            phase.beginCurrent(.body_lifetimes);
            defer phase.end();
            std.debug.assert(!self.type_check_only);
            try self.resolvePendingReferenceUses();
            if (self.generations.items.len != 0) {
                try self.finishOwnershipMetadata();
                try self.analyzeLifetimes(measurements);
            }
            if (try self.emitExplicitAbandonmentDiagnostics()) return error.SourceRejected;
            try self.materializeCleanups(self.planned_endings.items);
            try self.validateEffectReferenceUses();
            if (measurements) |output| {
                output.snapshots = self.states.items.len;
                output.snapshot_bytes = self.states.items.len * @sizeOf(State);
                var pages: std.AutoHashMap(usize, void) = .init(self.gpa);

                for (self.states.items) |state| {
                    inline for (@typeInfo(State).@"struct".field_names) |name| {
                        output.snapshot_bytes += try @field(state, name).retainedBytes(&pages);
                    }
                }
                if (self.flow) |data| {
                    output.flow_fact_bytes = data.facts.records.items.len * @sizeOf(flow_types.Fact);
                    output.flow_place_bytes = data.origins.count() * @sizeOf(FlowOrigin) +
                        data.paths.count() * @sizeOf(FlowProjection) + data.places.items.len * @sizeOf(FlowPlace);
                    for (data.places.items) |place| output.flow_place_bytes += (place.origins.len + 1) * @sizeOf(u32);
                    output.flow_predicate_bytes = data.predicates.items.len * @sizeOf(@TypeOf(data.predicates.items[0]));
                    for (data.predicates.items) |predicate| {
                        output.flow_predicate_bytes += try predicate.matched.retainedBytes(&pages);
                        output.flow_predicate_bytes += try predicate.unmatched.retainedBytes(&pages);
                    }
                }
                const types = self.shared_initializer_types orelse &self.initializer_types;
                output.inference_key_bytes = types.count() * (@sizeOf(InitializerTypeKey) + @sizeOf(structures.TypeId));
                var keys = types.keyIterator();
                while (keys.next()) |key| if (key.flow_state != 0) {
                    const environment: flow_types.State = .{ .root = @ptrFromInt(key.flow_state) };
                    output.inference_key_bytes += try environment.retainedBytes(&pages);
                };
                output.blocks = self.blocks.items.len;
                output.generations = self.generations.items.len;
            }
        }

        fn publishReferenceContract(self: *Self) !structures.ReferenceContract {
            const allocator = self.gpa;
            var contracts: std.ArrayList(structures.ReferenceOriginContract) = .empty;
            var paths: std.ArrayList(structures.ReferencePathStep) = .empty;

            var requirements: std.ArrayList(structures.ReferenceRequirement) = .empty;
            var exclusions: std.ArrayList(structures.ReferenceExclusion) = .empty;

            try self.publishOutputOrigins(&contracts, &paths, null, self.returned_reference_origins);
            var outputs = self.capture_output_origins.iterator();
            while (outputs.next()) |output| {
                try self.publishOutputOrigins(&contracts, &paths, output.key_ptr.*, output.value_ptr.*);
            }
            for (self.reference_writes.items) |write| {
                var origins = self.originList(try self.completeReferenceOrigins(write.origins));
                while (origins.next()) |origin| {
                    const parameter = origin.parameter orelse continue;
                    const start = paths.items.len;
                    const source = try self.publishSourcePath(origin, &paths);
                    try appendUniqueContract(allocator, &requirements, .{
                        .parameter = parameter,
                        .kind = origin.source_kind,
                        .path = source.path,
                        .written_type = write.written_type,
                        .ends_lifetime = write.ends_lifetime,
                        .storage_depth = source.storage_depth,
                        .recursive_storage = source.recursive_storage,
                    }, &paths, start, structures.ReferenceContract.sameRequirement);
                }
            }
            for (self.reference_exclusions.items) |exclusion| {
                var references = self.originList(try self.completeReferenceOrigins(exclusion.reference));
                const invalidations = try self.completeReferenceOrigins(exclusion.invalidation);
                while (references.next()) |dependency| {
                    if (dependency.parameter == null) continue;
                    var mutations = self.originList(invalidations);
                    while (mutations.next()) |mutation| {
                        if (mutation.parameter == null) continue;
                        const start = paths.items.len;
                        try appendUniqueContract(allocator, &exclusions, .{
                            .reference = try self.publishExcludedOrigin(dependency, &paths),
                            .invalidation = try self.publishExcludedOrigin(mutation, &paths),
                        }, &paths, start, structures.ReferenceContract.sameExclusion);
                    }
                }
            }
            return .{ .origins = contracts.items, .requirements = requirements.items, .exclusions = exclusions.items, .paths = paths.items };
        }

        fn publishOutputOrigins(self: *Self, contracts: *std.ArrayList(structures.ReferenceOriginContract), paths: *std.ArrayList(structures.ReferencePathStep), output_parameter: ?u32, output_origins: ?u32) !void {
            if (output_origins == null) return;
            var origins = self.originList(try self.completeReferenceOrigins(output_origins));
            while (origins.next()) |origin| {
                if (origin.parameter == null and !origin.permanent) continue;
                const start = paths.items.len;
                const source = try self.publishSourcePath(origin, paths);
                var result = origin.projection;
                while (result) |projection| {
                    const part = self.reference_storage.projections.keys()[projection];
                    try paths.append(self.gpa, part.step);
                    result = part.next;
                }
                const output_type = if (output_parameter) |parameter| self.block_arguments.items[parameter].type_id else self.return_type;
                _ = try self.normalizeReferencePath(paths, source.path.end, output_type);
                try appendUniqueContract(self.gpa, contracts, .{
                    .output_parameter = output_parameter,
                    .parameter = origin.parameter,
                    .kind = origin.source_kind,
                    .source_path = source.path,
                    .result_path = .{ .start = source.path.end, .end = @intCast(paths.items.len) },
                    .readonly = origin.readonly,
                    .variant_guard = origin.variant_guard,
                    .storage_depth = source.storage_depth,
                    .recursive_storage = source.recursive_storage,
                    .stable = origin.stable,
                    .reads_contents = origin.read != null,
                    .readonly_owned = origin.readonly_owned,
                    .after_write = origin.source_kind == .place,
                }, paths, start, structures.ReferenceContract.sameOrigin);
            }
        }

        /// Keeps one entry per equivalent dependency and discards a duplicate's paths.
        fn appendUniqueContract(allocator: std.mem.Allocator, entries: anytype, entry: @TypeOf(entries.items[0]), paths: *std.ArrayList(structures.ReferencePathStep), start: usize, comptime same: anytype) !void {
            const view: structures.ReferenceContract = .{ .paths = paths.items };
            for (entries.items) |previous| if (same(view, previous, view, entry)) {
                paths.shrinkRetainingCapacity(start);
                return;
            };
            try entries.append(allocator, entry);
        }

        const PublishedSourcePath = struct { path: structures.FunctionValueRange, storage_depth: u32, recursive_storage: bool };

        /// A recursive parameter path keeps at most one level of storage depth.
        fn publishSourcePath(self: *Self, origin: ReferenceOrigin, paths: *std.ArrayList(structures.ReferencePathStep)) !PublishedSourcePath {
            const start: u32 = @intCast(paths.items.len);
            try self.referenceSourcePath(origin, paths);
            const recursive = if (origin.parameter) |parameter|
                try self.normalizeReferencePath(paths, start, self.block_arguments.items[parameter].type_id)
            else
                false;
            return .{
                .path = .{ .start = start, .end = @intCast(paths.items.len) },
                .storage_depth = if (recursive) @min(origin.storage_depth, 1) else origin.storage_depth,
                .recursive_storage = recursive and origin.storage_depth != 0,
            };
        }

        fn publishExcludedOrigin(self: *Self, origin: ReferenceOrigin, paths: *std.ArrayList(structures.ReferencePathStep)) !structures.ReferenceOriginContract {
            const source = try self.publishSourcePath(origin, paths);
            return .{
                .parameter = origin.parameter.?,
                .kind = origin.source_kind,
                .source_path = source.path,
                .result_path = .{ .start = source.path.end, .end = source.path.end },
                .readonly = false,
                .storage_depth = source.storage_depth,
                .recursive_storage = source.recursive_storage,
                .stable = origin.stable,
            };
        }

        fn referencePathStepType(self: *Self, initial: structures.TypeId, step: structures.ReferencePathStep) !?structures.TypeId {
            var type_id = initial;
            if (step == .field or step == .variant or step.isElement())
                while (try self.analysis_context.facts().borrowElement(type_id)) |element| {
                    type_id = element;
                };
            switch (step) {
                .field => |index| {
                    const definition = (try self.analysis_context.facts().structDefinition(type_id)) orelse return null;
                    if (index >= definition.fields.len) return null;
                    return try self.analysis_context.facts().fieldStorageType(definition.fields[index]);
                },
                .variant => |member| return member,
                .element, .element_at => return self.referencePathElementType(type_id),
                .without_element, .without_field, .without_variant => return type_id,
                .target, .referent => return self.analysis_context.facts().borrowElement(type_id),
                .descendants => return null,
            }
        }

        fn referencePathElementType(self: *Self, type_id: structures.TypeId) !?structures.TypeId {
            if (try self.analysis_context.facts().arrayType(type_id)) |array| return array.element_type;
            if (try self.analysis_context.facts().boxElement(type_id)) |element| return element;
            if (try self.analysis_context.facts().allocationElement(type_id)) |element| return element;
            if (try self.analysis_context.facts().storageAccess(type_id)) |element| return element;
            if (try self.analysis_context.facts().collectionLiteralType(type_id)) |collection| return collection.element_type;
            return null;
        }

        fn referenceOriginType(self: *Self, origin: ReferenceOrigin) !?structures.TypeId {
            const parameter = origin.parameter orelse return null;
            var type_id = self.block_arguments.items[parameter].type_id;
            var path: std.ArrayList(structures.ReferencePathStep) = .empty;

            try self.referenceSourcePath(origin, &path);
            for (path.items) |step| type_id = (try self.referencePathStepType(type_id, step)) orelse return null;
            return type_id;
        }

        fn normalizeReferencePath(self: *Self, paths: *std.ArrayList(structures.ReferencePathStep), start: u32, initial: structures.TypeId) !bool {
            const Visit = struct { type_id: structures.TypeId, position: usize };
            var visited: std.ArrayList(Visit) = .empty;

            try visited.append(self.gpa, .{ .type_id = initial, .position = start });
            var type_id = initial;
            var position: usize = start;
            while (position < paths.items.len) : (position += 1) {
                const step = paths.items[position];
                if (step.isExclusion()) continue;
                if (step == .descendants) {
                    paths.shrinkRetainingCapacity(position + 1);
                    return true;
                }
                type_id = (try self.referencePathStepType(type_id, step)) orelse return false;
                for (visited.items) |visit| {
                    if (visit.type_id != type_id) continue;
                    paths.shrinkRetainingCapacity(visit.position);
                    try paths.append(self.gpa, .descendants);
                    return true;
                }
                try visited.append(self.gpa, .{ .type_id = type_id, .position = position + 1 });
            }
            return false;
        }

        fn build(self: *Self, parameters: []const structures.CallableParameter) !void {
            try self.init(parameters);
            if (self.options.builtin_body) |builtin| {
                switch (builtin.symbol) {
                    .primitive_operation => return self.buildPrimitiveOperation(builtin.operation.?),
                    .copy_value => return self.buildOwnershipMember(.copy),
                    .move_value => return self.buildOwnershipMember(.move),
                    .unsafe_initialize, .initialize_collection_element => return self.buildInitializedTarget(2, .{ .allocation_element = .{
                        .allocation = self.state.values.get(0).?.id,
                        .index = self.values.get(1).?.id,
                        .type_id = self.values.get(2).?.type_id,
                    } }, self.elementProjection(self.values.get(1).?.id)),
                    .initialize_collection => return self.buildCollectionInitializer(),
                    .array_filled => return self.buildArrayFilled(),
                    .array_borrow => return self.buildArrayBorrow(),
                    .unsafe_borrow, .unsafe_take, .unsafe_destroy => return self.buildMemoryOperation(builtin.symbol),
                    .literal_byte => return self.buildLiteralByte(),
                    .byte_int => return self.returnValue(try self.appendInstruction(.{ .byte_to_int = self.values.get(0).?.id }), .{ .start = 0, .end = 0 }),
                    .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => return self.buildCursorOperation(builtin.symbol),
                    else => unreachable,
                }
            }
            const result = try self.block(self.unresolved.root_block, self.options.expected_result_type);
            if (self.current_block == null) return;
            const root = self.unresolved.blocks[@backingInt(self.unresolved.root_block)];
            if (self.options.infer_return_type) {
                const value_to_return = result orelse return self.finishFunctionExit(root.span, .return_unit);
                self.return_type = value_to_return.type_id;
                return self.returnValue(value_to_return, root.span);
            }
            if (self.return_type != .unit) return self.reject(root.span, .{ .missing_return_value = self.return_type });
            try self.finishFunctionExit(root.span, .return_unit);
        }

        fn buildPrimitiveOperation(self: *Self, operation: structures.Operation) !void {
            switch (operation) {
                .@"+", .@"-", .@"*", .@"/" => return self.returnValue(try self.primitiveArithmetic(operation, .{ .lhs = self.values.get(0).?.id, .rhs = self.values.get(1).?.id }), .{ .start = 0, .end = 0 }),
                .@"%" => return self.buildPrimitiveRemainder(),
                .unary_minus => return self.returnValue(try self.appendInstruction(.{ .negi = self.values.get(0).?.id }), .{ .start = 0, .end = 0 }),
                .@"==", .@"<>", .@"<", .@">", .@"<=", .@">=", .not => return self.buildPrimitivePredicate(operation),
                .@"[]", .@"[]=" => unreachable,
            }
        }

        fn primitiveArithmetic(self: *Self, operation: structures.Operation, operands: structures.BinaryOperands) !Value {
            const instruction: structures.FunctionInstruction = switch (operation) {
                .@"+" => .{ .addi = operands },
                .@"-" => .{ .subi = operands },
                .@"*" => .{ .muli = operands },
                .@"/" => .{ .divsi = operands },
                else => unreachable,
            };
            return self.appendInstruction(instruction);
        }

        fn buildPrimitiveRemainder(self: *Self) !void {
            const left = self.values.get(0).?.id;
            const right = self.values.get(1).?.id;
            const quotient = try self.appendInstruction(.{ .divsi = .{ .lhs = left, .rhs = right } });
            const product = try self.appendInstruction(.{ .muli = .{ .lhs = quotient.id, .rhs = right } });
            try self.returnValue(try self.appendInstruction(.{ .subi = .{ .lhs = left, .rhs = product.id } }), .{ .start = 0, .end = 0 });
        }

        fn buildPrimitivePredicate(self: *Self, operation: structures.Operation) !void {
            const left = self.values.get(0).?;
            const right = if (operation == .not) try self.appendInstruction(.{ .const_bool = false }) else self.values.get(1).?;
            const predicate = primitivePredicateOperation(operation, left.type_id);
            try self.returnValue(try self.appendInstruction(.{ .compare = .{
                .operation = predicate,
                .operands = .{ .lhs = left.id, .rhs = right.id },
            } }), .{ .start = 0, .end = 0 });
        }

        fn primitivePredicateOperation(operation: structures.Operation, operand_type: structures.TypeId) structures.PredicateOperation {
            return switch (operation) {
                .@"==" => if (operand_type == .bool) .eqb else .eqi,
                .@"<>" => if (operand_type == .bool) .neb else .nei,
                .@"<" => .lti,
                .@">" => .gti,
                .@"<=" => .lei,
                .@">=" => .gei,
                .not => .eqb,
                else => unreachable,
            };
        }

        fn literalByteValue(self: *Self, value_id: structures.CompileTimeValueId, span: structures.SourceSpan) !Value {
            const constant = try self.analysis_context.lookupCompileTimeValue(value_id);
            std.debug.assert(constant == .runtime);
            std.debug.assert(constant.runtime.value == .int_literal);
            const byte = std.math.cast(u8, constant.runtime.value.int_literal) orelse return self.reject(span, .integer_literal_out_of_range);
            return self.appendInstruction(.{ .const_byte = byte });
        }

        fn staticStringValue(self: *Self, data: structures.ByteStringId) !Value {
            return self.appendInstruction(.{ .const_static_string = .{ .type_id = try self.analysis_context.staticStringType(), .data = data } });
        }

        fn buildCursorOperation(self: *Self, body: standard_library.External) !void {
            if (body == .empty_cursor) return self.returnValue(try self.permanentStorageCursor(.{ .type_id = self.return_type }), .{ .start = 0, .end = 0 });
            const source = self.values.get(0) orelse self.borrowLocalValue(@fromBackingInt(@as(u32, 0)));
            var result = switch (body) {
                .array_cursor, .allocation_cursor => try self.appendInstruction(.{ .storage_cursor = .{ .source = source.id, .type_id = self.return_type } }),
                .cursor_offset => try self.appendInstruction(.{ .cursor_offset = .{ .cursor = source.id, .index = self.values.get(1).?.id, .type_id = self.return_type } }),
                .cursor_element => try self.appendInstruction(.{ .cursor_element = .{ .cursor = source.id, .index = self.values.get(1).?.id, .type_id = self.return_type } }),
                .cursor_attenuate => try self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = self.return_type } }),
                else => unreachable,
            };
            if (try self.analysis_context.facts().storageCursorAccess(source.type_id) != null) {
                result.reference_origins = source.reference_origins;
            } else {
                result.reference_origins = (try self.withReferenceOrigin(source, result)).reference_origins;
                if (body == .array_cursor or body == .allocation_cursor) result.reference_origins = try self.elementReferenceOrigins(result.reference_origins, try self.analysis_context.facts().allocationElement(source.type_id) != null);
            }
            if (body == .cursor_attenuate)
                result.reference_origins = try self.readonlyOrigins(try self.readReferenceOrigins(result.reference_origins, null, @truncate(@backingInt(result.id)), false));
            try self.returnValue(result, .{ .start = 0, .end = 0 });
        }

        fn buildLiteralByte(self: *Self) !void {
            const value_id = (try self.analysis_context.resolveStatic("value")) orelse return error.Unavailable;
            try self.returnValue(try self.literalByteValue(value_id, .{ .start = 0, .end = 0 }), .{ .start = 0, .end = 0 });
        }

        fn buildCollectionInitializer(self: *Self) !void {
            const shape = (try self.analysis_context.facts().collectionLiteralType(self.values.get(1).?.type_id)) orelse unreachable;
            try self.buildInitializedTarget(1, .{ .storage_projection = .{
                .owner = self.state.values.get(0).?.id,
                .type_id = try self.analysis_context.internArrayType(shape),
                .projection = .allocation_array,
            } }, null);
        }

        /// Constructs an initializer parameter into the destination that local 0 owns.
        fn buildInitializedTarget(self: *Self, parameter: usize, destination: structures.FunctionInstruction, owner_step: ?structures.ReferencePathStep) !void {
            const span = self.unresolved.parameter_spans[parameter];
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            const result = try self.constructInitializer(self.values.get(parameter).?, span, try self.appendInstruction(destination));
            if (self.current_block == null) return;
            try self.recordConsume(result);
            const previous = self.state.values.get(0).?.reference_origins;
            const updated = if (owner_step) |step|
                try self.replaceProjectedOrigins(previous, step, result.reference_origins)
            else
                try self.mergeReferenceOrigins(previous, result.reference_origins);
            try self.updateLocal(0, .{ .reference_origins = updated });
            try self.closeBoundary(boundary);
            self.current_boundary = null;
            try self.finishFunctionExit(span, .return_unit);
        }

        fn buildOwnershipMember(self: *Self, operation: structures.OwnershipMember) !void {
            if (self.return_type == .never) return self.terminate(.diverge);
            const span = self.unresolved.parameter_spans[0];
            const storage = if (try self.usesIndirectStorage(self.return_type))
                try self.appendInstruction(.{ .result_storage = self.return_type })
            else
                null;
            const result = switch (operation) {
                .copy => try self.copyValue(self.values.get(0).?, span, storage),
                .move => try self.moveValue(self.state.values.get(0).?, span, storage),
            };
            if (storage != null) return self.returnConstructed(result, span);
            try self.returnValue(result, span);
        }

        fn buildArrayFilled(self: *Self) !void {
            const span = self.unresolved.parameter_spans[0];
            const source = self.values.get(0).?;
            const array = (try self.analysis_context.facts().arrayType(self.return_type)) orelse unreachable;
            std.debug.assert(source.type_id == array.element_type);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.copy == .none) return self.reject(span, .{ .type_not_copyable = .{
                .type_id = source.type_id,
                .is_movable = capabilities.move != .none,
            } });
            try self.recordUse(source);
            const storage = try self.appendInstruction(.{ .result_storage = self.return_type });
            if (array.length != 0) {
                const array_loop = try self.beginArrayLoop(array.length, false);
                const element = try self.arrayElement(storage, array_loop.index, array.element_type);
                _ = try self.transferValueBits(source, .copy, element);
                try self.endArrayLoop(array_loop, false);
            }
            var result = try self.defineOwnedValue(storage, span, false);
            if (array.length != 0) {
                var origins = try self.copyResultOrigins(source);
                if (capabilities.needs_custom_copy) try self.finishOwnershipEffects(source, &origins, .copy, try self.sourceReferenceOrigins(source));
                result.reference_origins = try self.transformReferenceOrigins(origins, .{ .prefix = .element });
            }
            try self.returnConstructed(result, span);
        }

        fn buildMemoryOperation(self: *Self, operation: standard_library.External) !void {
            if (self.return_type == .never) return self.terminate(.diverge);
            const span = self.unresolved.parameter_spans[0];
            const source = self.borrowLocalValue(@fromBackingInt(@as(u32, 0)));
            const step = self.elementProjection(self.values.get(1).?.id);
            const facts = self.analysis_context.facts();
            const element_type = (try facts.allocationElement(source.type_id)) orelse unreachable;
            var element = try self.appendInstruction(.{ .allocation_element = .{ .allocation = source.id, .index = self.values.get(1).?.id, .type_id = element_type } });
            if (operation == .unsafe_borrow) {
                const reference = try self.appendInstruction(.{ .borrow_address = .{ .source = element.id, .type_id = self.return_type } });
                var result = try self.withReferenceOrigin(source, reference);
                result.reference_origins = try self.projectElementReferenceOrigins(result.reference_origins, true, step);
                return self.returnValue(result, span);
            }
            // Taking owns the stored value. Its contained references follow
            // their referents rather than borrowing the allocation's slot.
            const destroying = operation == .unsafe_destroy;
            if (!destroying) try self.recordUse(source);
            element.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = step });
            try self.reference_writes.append(self.gpa, .{
                .origins = try self.projectElementReferenceOrigins(try self.sourceReferenceOrigins(source), true, step),
                .written_type = element_type,
                .ends_lifetime = true,
            });
            if (destroying) try self.dropValue(element, true, span);
            try self.updateLocal(0, .{ .reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .exclude = step }) });
            if (destroying) return self.finishFunctionExit(span, .return_unit);
            return self.returnValue(element, span);
        }

        fn buildArrayBorrow(self: *Self) !void {
            const span = self.unresolved.parameter_spans[0];
            const source = self.borrowLocalValue(@fromBackingInt(@as(u32, 0)));
            const array = (try self.analysis_context.facts().arrayType(source.type_id)) orelse unreachable;
            try self.recordUse(source);
            const element = try self.arrayElement(source, self.values.get(1).?, array.element_type);
            const reference = try self.appendInstruction(.{ .borrow_address = .{
                .source = element.id,
                .type_id = self.return_type,
            } });
            var result = try self.withReferenceOrigin(source, reference);
            result.reference_origins = try self.projectElementReferenceOrigins(result.reference_origins, false, self.elementProjection(self.values.get(1).?.id));
            try self.returnValue(result, span);
        }

        fn block(self: *Self, block_id: semantic.UnresolvedBody.BlockId, expected_type: ?structures.TypeId) !?Value {
            return self.blockWithResult(block_id, .{ .value = .{ .expected_type = expected_type } });
        }

        const Destination = struct {
            storage: Value,
            site: InitializationSite,
        };
        const InitializationSite = enum { local, field, argument, assignment, return_value };

        const ValueContext = struct {
            expected_type: ?structures.TypeId = null,
            access: enum { value, initialize, borrow, consume } = .value,
            fresh_destination: ?Value = null,
            allow_converters: bool = true,
            refine: bool = true,
        };

        const ResultRequest = struct {
            value: ValueContext = .{},
            destination: ?Destination = null,
            destination_span: ?structures.SourceSpan = null,
            discard: bool = false,
            reference: bool = false,
        };

        fn blockWithResult(self: *Self, block_id: semantic.UnresolvedBody.BlockId, mode: ResultRequest) !?Value {
            const unresolved_block = self.unresolved.blocks[@backingInt(block_id)];
            const baseline = try self.captureState();
            const enclosing_boundary = self.current_boundary;
            self.current_boundary = null;
            defer self.current_boundary = enclosing_boundary;
            for (self.unresolved.statements[unresolved_block.statements.start..unresolved_block.statements.end]) |statement| {
                if (self.current_block == null) return null;
                switch (statement) {
                    .discard, .lifetime_extend, .bind_local, .bind_pattern, .bind_conditional => try self.completedStatement(statement),
                    .break_loop => |value_id| try self.breakLoop(value_id),
                    .continue_loop => |span| try self.continueLoop(span),
                    .return_nothing => |span| try self.returnNothing(span),
                    .return_value => |returned| try self.returnExpression(returned),
                }
            }
            if (self.current_block == null) return null;
            var result: ?Value = null;
            if (unresolved_block.result) |result_id| {
                const boundary = try self.newBoundary(unresolved_block.span);
                self.current_boundary = boundary;
                const branch_result = try self.evaluateValue(result_id, mode);
                if (self.current_block == null) return null;
                result = if (mode.discard)
                    try self.discardResult(branch_result, unresolved_block.span)
                else
                    try self.ownValueEscapingSince(branch_result, baseline, unresolved_block.span);
                self.current_boundary = null;
                try self.closeBoundary(boundary);
            }
            try self.unbindLocalsSince(baseline);
            return result;
        }

        fn completedStatement(self: *Self, statement: semantic.UnresolvedBody.Statement) !void {
            const span = switch (statement) {
                .discard, .lifetime_extend => |value_use| value_use.span,
                .bind_conditional => |binding| binding.span,
                .bind_local => |binding| binding.span,
                .bind_pattern => |binding| binding.span,
                else => unreachable,
            };
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            switch (statement) {
                .discard, .lifetime_extend => |value_use| try self.discardValue(try self.discardedValue(value_use.value), value_use.span),
                .bind_conditional => |binding| try self.bindConditional(binding),
                .bind_local => |binding| try self.bindLocal(binding),
                .bind_pattern => |binding| try self.bindPatternStatement(binding),
                else => unreachable,
            }
            if (self.current_block != null) try self.closeBoundary(scope.boundary);
        }

        fn bindConditional(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_conditional")) anyerror!void {
            const flow = try self.condition(binding.condition);
            if (flow.unmatched) |unmatched| {
                try self.enterFlowExit(unmatched);
                _ = try self.blockWithResult(binding.otherwise, .{ .discard = true });
                if (self.current_block != null) return self.reject(binding.span, .binding_else_must_exit);
            }
            if (flow.matched) |matched| try self.enterFlowExit(matched);
        }

        fn bindLocal(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_local")) !void {
            var reference = binding.mode == .reference;
            var bound_value = if (binding.mode == .inferred) automatic: {
                var fields: std.ArrayList(PlaceField) = .empty;

                const transfer = self.explicitPlaceTransfer(binding.value);
                const initializer = if (self.values.get(@backingInt(binding.value))) |source| source.initializer_parameter != null else false;
                if (!transfer and !initializer and try self.resolveBorrowPlace(binding.value, &fields) != null) {
                    reference = true;
                    break :automatic try self.captureReference(.{ .value = binding.value, .span = binding.span });
                }
                const value_to_bind = try self.valueWithContext(binding.value, .{ .access = .initialize });
                reference = value_to_bind.place_reference != null;
                if (reference) break :automatic try self.captureReference(.{ .value = binding.value, .span = binding.span });
                var owned = try self.ownValue(value_to_bind, binding.span);
                // Inferred carriers retain the identity of their input. An
                // ordinary owning binding instead creates an independent place.
                owned.flow_origins = try self.valuePlaceOrigins(value_to_bind);
                break :automatic owned;
            } else if (binding.mode == .reference)
                try self.flowBindingReference(.{ .value = binding.value, .span = binding.span }, null)
            else if (try self.inPlaceControlFlowType(binding.value)) |type_id|
                try self.construct(binding.value, binding.span, .{ .storage = try self.localStorage(type_id), .site = .local })
            else
                try self.ownValue(try self.valueWithContext(binding.value, .{ .access = .initialize }), binding.span);
            if (bound_value.type_id == .never) return;
            if (reference and binding.mode == .inferred and !binding.mutable) {
                bound_value.writable = false;
                bound_value.reference_origins = try self.readonlyOrigins(bound_value.reference_origins);
            }
            try self.installLocal(binding.local, bound_value, reference, binding.mutable);
        }

        fn explicitPlaceTransfer(self: *Self, id: semantic.UnresolvedBody.ValueId) bool {
            const operation = self.expressionOperation(id) orelse return false;
            switch (operation.*) {
                .local_transfer, .field_transfer => return true,
                .annotation => |annotation| return self.explicitPlaceTransfer(annotation.value.value),
                else => return false,
            }
        }

        fn installLocal(self: *Self, local: semantic.UnresolvedBody.LocalId, source: Value, reference: bool, mutable: bool) !void {
            var bound_value = source;
            bound_value.binding_identity = try self.newBindingIdentity();
            bound_value.explicit_transfer = false;
            const index = @backingInt(local);
            std.debug.assert(self.state.values.get(index) == null);
            try self.state.values.set(self.gpa, index, bound_value);
            self.locals.items(.mutable)[index] = mutable or (reference and bound_value.writable);
            self.locals.items(.reference)[index] = reference;
            try self.state.availability.set(self.gpa, index, .available);
            if (!reference and bound_value.flow_origins == null) if (try self.flowPlace(self.borrowLocalValue(local), false)) |place|
                try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, .{ .version = try self.flow.?.facts.version() });
            if (!reference and try self.analysis_context.facts().isRuntimeCapable(bound_value.type_id))
                _ = try self.pinLocalStorage(local);
            for (self.field_places, 0..) |place, field_index| {
                if (place.local == local) try self.state.field_availability.set(self.gpa, field_index, .available);
            }
        }

        fn bindPatternStatement(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_pattern")) !void {
            const pattern = self.unresolved.binding_patterns[binding.pattern];
            const scope = try self.openBoundary(binding.span);
            defer self.current_boundary = scope.parent;
            try self.bindLocal(.{ .local = pattern.carrier, .value = binding.value, .span = binding.span, .mutable = true, .mode = .inferred });
            if (self.current_block == null) return;
            try self.closeBoundary(scope.boundary);
            self.current_boundary = scope.parent;
            try self.bindPattern(binding.pattern);
        }

        fn bindPattern(self: *Self, pattern_id: u32) anyerror!void {
            const pattern = self.unresolved.binding_patterns[pattern_id];
            if (pattern.shape != .name) if (pattern.annotation_type) |expected| {
                const actual = (try self.flowRead(try self.readLocal(pattern.carrier, pattern.span))).type_id;
                if (actual != expected) return self.reject(pattern.span, .{ .local_type_mismatch = self.typeMismatch(expected, actual) });
            };
            switch (pattern.shape) {
                .name => |name| try self.bindPatternName(pattern, name),
                .tuple => |children| try self.bindTuplePattern(pattern, children),
                .sequence => |sequence| try self.bindSequencePattern(pattern, sequence),
            }
        }

        fn bindPatternName(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern, name: semantic.UnresolvedBody.BindingPattern.Name) !void {
            const local = name.local orelse {
                if (pattern.annotation_type) |expected| {
                    const actual = (try self.flowRead(try self.readLocal(pattern.carrier, pattern.span))).type_id;
                    if (!try semantic.canWidenTo(self.analysis_context, actual, expected)) return self.reject(pattern.span, .{ .local_type_mismatch = self.typeMismatch(expected, actual) });
                }
                return;
            };
            const scope = try self.openBoundary(pattern.span);
            defer self.current_boundary = scope.parent;
            const reference = self.locals.items(.reference)[@backingInt(pattern.carrier)];
            if (name.mode == .reference or (name.mode == .inferred and reference)) {
                const value_to_bind = try self.flowBindingReference(.{ .value = pattern.read, .span = pattern.span }, pattern.annotation_type);
                const element = (try self.analysis_context.facts().borrowElement(value_to_bind.type_id)).?;
                if (pattern.annotation_type) |expected| if (element != expected)
                    return self.reject(pattern.span, .{ .local_type_mismatch = self.typeMismatch(expected, element) });
                var captured = value_to_bind;
                if (name.mode == .inferred) {
                    captured.writable = false;
                    captured.reference_origins = try self.readonlyOrigins(captured.reference_origins);
                }
                try self.installLocal(local, captured, true, name.mutable);
                try self.closeBoundary(scope.boundary);
                return;
            }
            var owned = if (reference)
                try self.ownValue(try self.readLocal(pattern.carrier, pattern.span), pattern.span)
            else
                self.state.values.get(@backingInt(pattern.carrier)).?;
            if (!reference) try self.state.availability.set(self.gpa, @backingInt(pattern.carrier), .transferred);
            if (pattern.annotation_type) |expected| owned = try self.contextualValue(owned, .{ .expected_type = expected, .access = .initialize }, pattern.span);
            if (owned.type_id == .never) return;
            try self.installLocal(local, owned, false, name.mutable);
            try self.closeBoundary(scope.boundary);
        }

        fn patternChildren(self: *Self, range: structures.FunctionValueRange) []const u32 {
            return self.unresolved.binding_pattern_children[range.start..range.end];
        }

        /// Decomposition changes the ownership partition, without relocating members.
        /// All child owners exist before the parent ends or any child binding runs.
        fn bindTuplePattern(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern, range: structures.FunctionValueRange) !void {
            const scope = try self.openBoundary(pattern.span);
            defer self.current_boundary = scope.parent;
            const source = try self.flowRead(try self.readLocal(pattern.carrier, pattern.span));
            const children = self.patternChildren(range);
            if (source.type_id == .unit and children.len == 0) return;
            const members = (try self.analysis_context.facts().tupleMembers(source.type_id)) orelse return self.reject(pattern.span, .destructure_requires_tuple);
            if (members.len != children.len) return self.reject(pattern.span, .{ .destructure_length_mismatch = .{ .expected = @intCast(children.len), .found = @intCast(members.len) } });
            const borrowed = self.locals.items(.reference)[@backingInt(pattern.carrier)];
            const reference = if (borrowed) try self.flowBindingReference(.{ .value = pattern.read, .span = pattern.span }, source.type_id) else null;
            try self.recordUse(source);
            for (members, children, 0..) |member, child_id, index| {
                const child = self.unresolved.binding_patterns[child_id];
                const field: PlaceField = .{ .name = "", .index = @intCast(index), .type_id = member.type_id, .kind = member.kind };
                if (member.kind == .reference) {
                    try self.installLocal(child.carrier, try self.referenceField(source, field), true, true);
                } else if (reference) |root| {
                    try self.installLocal(child.carrier, try self.projectReference(root, &.{field}), true, true);
                } else {
                    var storage = try self.projectStorage(source, member.type_id, .{ .field = @intCast(index) });
                    storage.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .field = @intCast(index) } });
                    try self.installLocal(child.carrier, try self.defineOwnedValue(storage, child.span, false), false, true);
                }
            }
            if (!borrowed) try self.finishPatternPartition(pattern.carrier);
            try self.closeBoundary(scope.boundary);
            self.current_boundary = scope.parent;
            try self.bindPatternChildren(children);
        }

        fn finishPatternPartition(self: *Self, carrier: semantic.UnresolvedBody.LocalId) !void {
            try self.recordConsume(self.state.values.get(@backingInt(carrier)).?);
            try self.state.availability.set(self.gpa, @backingInt(carrier), .transferred);
        }

        fn bindPatternChildren(self: *Self, children: []const u32) !void {
            for (children) |child| {
                if (self.current_block == null) return;
                try self.bindPattern(child);
            }
        }

        fn bindSequencePattern(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern, sequence: semantic.UnresolvedBody.BindingPattern.Sequence) !void {
            const scope = try self.openBoundary(pattern.span);
            defer self.current_boundary = scope.parent;
            const source = try self.readLocal(pattern.carrier, pattern.span);
            const children = self.patternChildren(sequence.children);
            if (try self.analysis_context.facts().arrayType(source.type_id)) |array| {
                return self.bindArrayPattern(pattern, array, children);
            }
            const list_element = try self.analysis_context.facts().listElement(source.type_id);
            const span_element = try self.analysis_context.facts().spanAccess(source.type_id);
            if (list_element == null and span_element == null) return self.reject(pattern.span, .destructure_requires_sequence);
            if (list_element != null and !self.locals.items(.reference)[@backingInt(pattern.carrier)] and !self.patternBorrowsAll(pattern))
                return self.bindOwnedListPattern(pattern, sequence, list_element.?);
            const length = try self.patternMemberCall(pattern.read, "len", &.{}, pattern.span);
            const count = try self.appendInstruction(.{ .const_int = @intCast(children.len) });
            const flow = try self.predicateFlow(.eqi, length.id, count.id);
            try self.patternMismatch(flow.unmatched.?, pattern.span);
            try self.enterFlowExit(flow.matched.?);
            for (children) |child_id| {
                const child = self.unresolved.binding_patterns[child_id];
                const element = try self.patternMemberCall(pattern.read, "[]", &.{.{ .value = child.position.?, .span = child.span }}, child.span);
                var reference = element;
                reference.id = element.place_reference.?;
                reference.type_id = try self.analysis_context.facts().referenceType(element.type_id);
                reference.reference_origins = element.place_origins;
                try self.installLocal(child.carrier, reference, true, true);
            }
            try self.closeBoundary(scope.boundary);
            self.current_boundary = scope.parent;
            try self.bindPatternChildren(children);
        }

        fn patternBorrowsAll(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern) bool {
            const range = switch (pattern.shape) {
                .name => |name| return name.local == null or name.mode == .reference,
                .tuple => |children| children,
                .sequence => |sequence| sequence.children,
            };
            for (self.patternChildren(range)) |child| if (!self.patternBorrowsAll(self.unresolved.binding_patterns[child])) return false;
            return true;
        }

        fn bindOwnedListPattern(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern, sequence: semantic.UnresolvedBody.BindingPattern.Sequence, element_type: structures.TypeId) !void {
            const scope = try self.openBoundary(pattern.span);
            defer self.current_boundary = scope.parent;
            const children = self.patternChildren(sequence.children);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
            if (!capabilities.isDirectlyMovable()) return self.reject(pattern.span, .{ .list_requires_direct_move = element_type });
            const length = try self.patternMemberCall(pattern.read, "len", &.{}, pattern.span);
            const expected = try self.appendInstruction(.{ .const_int = @intCast(children.len) });
            const flow = try self.predicateFlow(.eqi, length.id, expected.id);
            try self.patternMismatch(flow.unmatched.?, pattern.span);
            try self.enterFlowExit(flow.matched.?);
            const helper = (try self.analysis_context.stdMemoryFunction("destructure_list")) orelse return error.Unavailable;
            const element = try self.analysis_context.internCompileTimeValue(.{ .type = element_type });
            const size = try self.analysis_context.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(children.len) } } });
            const instance = try self.analysis_context.specializeFunction(.{ .item = helper }, &.{ element, size });
            const call: semantic.UnresolvedBody.Call = .{ .target = .{ .direct = instance }, .arguments = .{ .start = 0, .end = 0 }, .span = pattern.span };
            const resolved = try self.resolveCall(call, pattern.span, &.{.{ .value = pattern.read, .span = pattern.span }});
            std.debug.assert(resolved == .callable);
            const array = try self.resolvedCallResult(resolved.callable, call, pattern.span, .{});
            try self.installLocal(sequence.storage, array, false, true);
            try self.closeBoundary(scope.boundary);
            self.current_boundary = scope.parent;
            var partition = pattern;
            partition.carrier = sequence.storage;
            partition.read = sequence.storage_read;
            return self.bindArrayPattern(partition, (try self.analysis_context.facts().arrayType(array.type_id)).?, children);
        }

        fn bindArrayPattern(self: *Self, pattern: semantic.UnresolvedBody.BindingPattern, array: structures.ArrayType, children: []const u32) !void {
            const scope = try self.openBoundary(pattern.span);
            defer self.current_boundary = scope.parent;
            if (array.length != children.len) return self.reject(pattern.span, .{ .destructure_length_mismatch = .{ .expected = @intCast(children.len), .found = array.length } });
            const source = try self.readLocal(pattern.carrier, pattern.span);
            const borrowed = self.locals.items(.reference)[@backingInt(pattern.carrier)];
            try self.recordUse(source);
            for (children, 0..) |child_id, index| {
                const child = self.unresolved.binding_patterns[child_id];
                const position = try self.appendInstruction(.{ .const_int = @intCast(index) });
                var storage = try self.arrayElement(source, position, array.element_type);
                const step: structures.ReferencePathStep = .{ .element_at = .{ .offset = @intCast(index) } };
                storage.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = step });
                if (borrowed) {
                    var reference = try self.appendInstruction(.{ .borrow_address = .{ .source = storage.id, .type_id = try self.analysis_context.facts().referenceType(array.element_type) } });
                    reference.reference_origins = try self.appendSourcePath(try self.sourceReferenceOrigins(source), step);
                    reference.writable = source.writable;
                    try self.installLocal(child.carrier, reference, true, true);
                } else {
                    try self.installLocal(child.carrier, try self.defineOwnedValue(storage, child.span, false), false, true);
                }
            }
            if (!borrowed) try self.finishPatternPartition(pattern.carrier);
            try self.closeBoundary(scope.boundary);
            self.current_boundary = scope.parent;
            try self.bindPatternChildren(children);
        }

        fn patternMemberCall(self: *Self, receiver: semantic.UnresolvedBody.ValueId, name: []const u8, arguments: []const semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !Value {
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            const call: semantic.UnresolvedBody.Call = .{ .target = .{ .member = .{ .receiver = .{ .value = receiver, .span = span }, .name = name } }, .arguments = .{ .start = 0, .end = 0 }, .span = span };
            const resolved = try self.resolveCall(call, span, arguments);
            const result = switch (resolved) {
                .diverged => |diverged| diverged,
                .callable => |callable| try self.resolvedCallResult(callable, call, span, .{}),
            };
            if (self.current_block != null) try self.closeBoundary(scope.boundary);
            return result;
        }

        fn newBindingIdentity(self: *Self) !BindingIdentity {
            const identity = std.math.cast(u32, self.binding_versions.items.len) orelse return error.AnalysisTooLarge;
            try self.binding_versions.append(self.gpa, null);
            return .{ .fixed = identity };
        }

        fn valuePlaceOrigins(self: *Self, source: Value) !?u32 {
            if (source.flow_origins orelse source.place_origins) |origins| return origins;
            if (source.borrow_root != null or source.borrowed_generation != null or source.owned_generation != null)
                return self.sourceReferenceOrigins(source);
            if (@backingInt(source.id) < self.unresolved.parameter_count)
                return self.parameterPlaceOrigins(@intCast(@backingInt(source.id)), source);
            if (try self.analysis_context.facts().variantMembers(source.type_id) != null)
                return self.addReferenceOrigin(null, .{ .cleanup_value = source.id, .frame_type = source.type_id });
            return null;
        }

        fn flowOrigin(self: *Self, origin: ReferenceOrigin) FlowOrigin {
            return .{
                .scope = self.flow_scope,
                .handle = origin.flow_handle,
                .parameter = origin.parameter,
                .root = if (origin.parameter == null) origin.root else null,
                .generation = if (origin.parameter == null and origin.root == null) origin.generation else null,
                .cleanup_value = if (origin.parameter == null and origin.root == null and origin.generation == null) origin.cleanup_value else null,
            };
        }

        fn flowData(self: *Self) !*FlowData {
            if (self.flow == null) {
                if (self.flow_parent) |parent| {
                    self.flow = try parent.flowData();
                } else {
                    const data = try self.gpa.create(FlowData);
                    data.* = .{};
                    self.flow = data;
                }
            }
            if (self.flow_parent != null and self.flow_scope == 0) {
                self.flow_scope = self.flow.?.next_scope;
                self.flow.?.next_scope = std.math.add(u32, self.flow_scope, 1) catch return error.AnalysisTooLarge;
            }
            return self.flow.?;
        }

        fn flowOrigins(self: *Self, raw: ?u32) anyerror!?std.ArrayList(FlowOrigin) {
            // Initialize the shared interner and this body's scope before normalization.
            _ = try self.flowData();
            var incomplete = false;
            var origins = self.originList(try self.resolveReferenceOrigins(raw, &incomplete));
            if (incomplete) return null;
            var result: std.ArrayList(FlowOrigin) = .empty;
            while (origins.next()) |origin| {
                if (origin.projection != null) return null;
                var path: std.ArrayList(structures.ReferencePathStep) = .empty;
                try self.referenceSourcePath(origin, &path);
                const parameter = origin.parameter orelse if (origin.root != null and self.flow_parent != null and self.captured_locals[@backingInt(origin.root.?)] != null)
                    self.captured_locals[@backingInt(origin.root.?)]
                else if (origin.frame_type != null and origin.cleanup_value != null)
                    @as(?u32, @intCast(@backingInt(origin.cleanup_value.?)))
                else
                    null;
                if (self.flow_parent) |parent| if (parameter != null and parameter.? < self.flow_captures.len) {
                    const capture = self.flow_captures[parameter.?];
                    const reference = try self.analysis_context.facts().borrowElement(capture.type_id) != null;
                    var source = if (reference) capture.flow_origins orelse capture.reference_origins else if (origin.source_kind == .contents) capture.reference_origins else try parent.valuePlaceOrigins(capture);
                    for (path.items) |step| source = if (reference or origin.source_kind == .place)
                        try parent.appendSourcePath(source, step)
                    else
                        try parent.transformReferenceOrigins(source, .{ .select = step });
                    const mapped = (try parent.flowOrigins(source)) orelse return null;
                    for (mapped.items) |base| {
                        var normalized = base;
                        normalized.handle = origin.flow_handle orelse base.handle;
                        try result.append(self.gpa, normalized);
                    }
                    continue;
                };
                if (origin.source_kind == .place) if (origin.root) |root| {
                    if (self.state.values.get(@backingInt(root))) |owner| if (owner.flow_origins) |aliases| {
                        var list = self.originList(aliases);
                        var same_root = false;
                        while (list.next()) |alias| if (alias.root == root) {
                            same_root = true;
                        };
                        if (!same_root) {
                            const mapped = (try self.flowOrigins(aliases)) orelse return null;
                            for (mapped.items) |base| {
                                var normalized = try self.appendFlowOriginPath(base, path.items);
                                normalized.handle = origin.flow_handle orelse base.handle;
                                try result.append(self.gpa, normalized);
                            }
                            continue;
                        }
                    };
                };
                var normalized = self.flowOrigin(origin);
                if (normalized.root == null and normalized.parameter == null and normalized.generation == null and normalized.cleanup_value == null and normalized.handle == null) return null;
                normalized = try self.appendFlowOriginPath(normalized, path.items);
                try result.append(self.gpa, normalized);
            }
            return result;
        }

        fn appendFlowOriginPath(self: *Self, base: FlowOrigin, path: []const structures.ReferencePathStep) !FlowOrigin {
            var result = base;
            for (path) |step| {
                if (step == .descendants) break;
                const depth = if (result.path) |index| self.flow.?.paths.keys()[index].depth + 1 else 1;
                result.path = @intCast((try self.flow.?.paths.getOrPut(self.gpa, .{ .step = step, .parent = result.path, .depth = depth })).index);
            }
            return result;
        }

        fn flowPathsOverlap(self: *Self, first: ?u32, second: ?u32) bool {
            var left = first;
            var right = second;
            const paths = self.flow.?.paths.keys();
            if ((if (right) |index| paths[index].depth else 0) > (if (left) |index| paths[index].depth else 0)) return false;
            while (left != null and (if (right) |index| paths[index].depth else 0) < paths[left.?].depth) left = paths[left.?].parent;
            while (right != null and (if (left) |index| paths[index].depth else 0) < paths[right.?].depth) right = paths[right.?].parent;
            while (left != null and right != null) {
                if (!paths[left.?].step.overlaps(paths[right.?].step)) return false;
                left = paths[left.?].parent;
                right = paths[right.?].parent;
            }
            return true;
        }

        fn flowPlace(self: *Self, source: Value, track: bool) !?u32 {
            if (!track and (self.flow == null or self.flow.?.places.items.len == 0)) return null;
            if (try self.analysis_context.facts().variantMembers(source.type_id) == null) return null;
            const data = try self.flowData();
            const origins = (try self.flowOrigins(try self.valuePlaceOrigins(source))) orelse return null;
            var key: std.ArrayList(u32) = .empty;
            try key.append(self.gpa, @intCast(@backingInt(source.type_id)));
            for (origins.items) |normalized| {
                var path = normalized.path;
                while (path) |index| {
                    const projection = data.paths.keys()[index];
                    if (normalized.handle == null and (projection.step == .element or projection.step.isExclusion() or projection.step == .descendants)) return null;
                    path = projection.parent;
                }
                const id: u32 = if (data.origins.getIndex(normalized)) |index| @intCast(index) else if (track)
                    @intCast((try data.origins.getOrPut(self.gpa, normalized)).index)
                else {
                    return null;
                };
                if (std.mem.indexOfScalar(u32, key.items[1..], id) == null) try key.append(self.gpa, id);
            }
            if (key.items.len == 1) return null;
            std.mem.sort(u32, key.items[1..], {}, std.sort.asc(u32));
            const bytes = std.mem.sliceAsBytes(key.items);
            if (self.flow.?.indices.get(bytes)) |place| return place;
            if (!track) return null;
            const owned = try key.toOwnedSlice(self.gpa);
            const id: u32 = @intCast(self.flow.?.places.items.len);
            try self.flow.?.indices.put(self.gpa, std.mem.sliceAsBytes(owned), id);
            try self.flow.?.places.append(self.gpa, .{ .type_id = source.type_id, .origins = owned[1..] });
            return id;
        }

        fn refineFlowType(self: *Self, source: Value, target: structures.TypeId, positive: bool, span: structures.SourceSpan) !void {
            const found = try self.flowPlace(source, true);
            const place = found orelse return;
            const current = self.flow.?.facts.get(self.state.refinements, place);
            const original = current.type_id orelse source.type_id;
            const members = try self.matchInputMembers(original);
            const targets = try self.analysis_context.facts().variantMembers(target);
            var selected: structures.TypeId = .never;
            for (members) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                if (includesType(target, targets, logical) == positive)
                    selected = try joinTypes(self.analysis_context, selected, member, self.gpa);
            }
            var tested: structures.TypeId = .never;
            for (try self.matchInputMembers(source.type_id)) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                if (includesType(target, targets, logical) == positive)
                    tested = try joinTypes(self.analysis_context, tested, member, self.gpa);
            }
            try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, .{
                .version = current.version,
                .type_id = selected,
                .span = span,
                .parents = .{ if (selected != tested) self.state.refinements.get(place) else 0, 0 },
            });
        }

        fn copyFlowType(self: *Self, source: Value, local: semantic.UnresolvedBody.LocalId) !void {
            const original = (try self.flowPlace(source, false)) orelse return;
            const fact = self.flow.?.facts.get(self.state.refinements, original);
            if (fact.type_id == null) return;
            const place = (try self.flowPlace(self.borrowLocalValue(local), true)) orelse return;
            try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, .{ .version = self.flow.?.facts.get(self.state.refinements, place).version, .type_id = fact.type_id, .span = fact.span, .parents = if (place == original) fact.parents else .{ 0, 0 } });
        }

        fn mergeFlowTypes(self: *Self, state: *State, other: State) !void {
            const count = @max(state.refinements.len, other.refinements.len);
            for (0..count) |place| {
                const left = self.flow.?.facts.get(state.refinements, place);
                const right = self.flow.?.facts.get(other.refinements, place);
                if (std.meta.eql(left, right)) continue;
                const known = if (left.type_id != null and right.type_id != null)
                    try joinTypes(self.analysis_context, left.type_id.?, right.type_id.?, self.gpa)
                else
                    null;
                try self.flow.?.facts.put(self.gpa, &state.refinements, place, .{
                    .version = if (left.version == right.version) left.version else try self.flow.?.facts.version(),
                    .type_id = known,
                    .span = if (known != null) left.span else .{ .start = 0, .end = 0 },
                    .parents = .{ if (place < state.refinements.len) state.refinements.get(place) else 0, if (place < other.refinements.len) other.refinements.get(place) else 0 },
                });
            }
        }

        fn flowOriginWritten(self: *Self, origin: FlowOrigin, writes: ?std.ArrayList(FlowOrigin)) bool {
            const mutations = (writes orelse return true).items;
            if (mutations.len == 0) return true;
            for (mutations) |mutation| {
                const unknown_origin = origin.handle != null and origin.root == null and origin.parameter == null and origin.generation == null and origin.cleanup_value == null;
                const unknown_write = mutation.handle != null and mutation.root == null and mutation.parameter == null and mutation.generation == null and mutation.cleanup_value == null;
                if (unknown_origin or unknown_write) {
                    if (std.meta.eql(origin.handle, mutation.handle) and origin.handle != null) {
                        if (self.flowPathsOverlap(origin.path, mutation.path)) return true;
                        continue;
                    }
                    return true;
                }
                if (origin.scope != mutation.scope) continue;
                if (origin.parameter != null and mutation.parameter != null and origin.parameter != mutation.parameter) return true;
                if ((origin.root != null and origin.root == mutation.root) or
                    (origin.parameter != null and origin.parameter == mutation.parameter) or
                    (origin.generation != null and origin.generation == mutation.generation) or
                    (origin.cleanup_value != null and origin.cleanup_value == mutation.cleanup_value))
                {
                    if (self.flowPathsOverlap(origin.path, mutation.path)) return true;
                }
            }
            return false;
        }

        fn invalidateFlowTypes(self: *Self, written: ?u32, span: structures.SourceSpan) !void {
            if (self.flow == null or self.flow.?.places.items.len == 0) return;
            const resolved = try self.flowOrigins(written);
            for (self.flow.?.places.items, 0..) |place, index| {
                for (place.origins) |origin| {
                    if (!self.flowOriginWritten(self.flow.?.origins.keys()[origin], resolved)) continue;
                    try self.flow.?.facts.invalidate(self.gpa, &self.state.refinements, index, span);
                    break;
                }
            }
            for (0..self.state.values.len) |slot| {
                if (self.state.availability.get(slot) != .available or self.locals.items(.reference)[slot]) continue;
                const owner = self.state.values.get(slot) orelse continue;
                const previous = owner.owned_generation orelse continue;
                const selections = self.generations.items[@backingInt(previous)].cleanup_selections;
                if (selections.len == 0) continue;
                const origins = try self.flowOrigins(try self.valuePlaceOrigins(self.borrowLocalValue(@fromBackingInt(@intCast(slot)))));
                var retained: std.ArrayList(cleanup_shape.Selection) = .empty;
                for (selections) |selection| {
                    var affected = origins == null or origins.?.items.len != 1;
                    if (!affected) {
                        const origin = try self.appendFlowOriginPath(origins.?.items[0], selection.path);
                        affected = self.flowOriginWritten(origin, resolved);
                    }
                    if (!affected) try retained.append(self.gpa, selection);
                }
                if (retained.items.len == selections.len) continue;
                const restored = try self.replaceOwnerCleanup(owner, try retained.toOwnedSlice(self.gpa));
                try self.state.values.set(self.gpa, slot, restored);
            }
        }

        fn newFlowHandle(self: *Self, value_id: structures.FunctionValueId) !FlowHandle {
            _ = try self.flowData(); // Allocate this body's scope before naming its reference handle.
            return @fromBackingInt((@as(u64, self.flow_scope) << 32) | @as(u64, @backingInt(value_id)));
        }

        fn referenceFlowOrigins(self: *Self, reference: Value, element_type: structures.TypeId) !?u32 {
            const backing = reference.flow_origins orelse reference.reference_origins orelse return self.addReferenceOrigin(null, .{ .cleanup_value = reference.id, .frame_type = element_type, .source_kind = .place });
            var incomplete = false;
            _ = try self.resolveReferenceOrigins(backing, &incomplete); // Check whether backing identity is available for proof normalization.
            if (incomplete) return self.addReferenceOrigin(null, .{ .flow_handle = try self.newFlowHandle(reference.id) });
            var result: ?u32 = null;
            var origins = self.originList(backing);
            while (origins.next()) |original| {
                var origin = original;
                var imprecise = origin.projection != null;
                var path: std.ArrayList(structures.ReferencePathStep) = .empty;
                try self.referenceSourcePath(origin, &path);
                for (path.items) |step| imprecise = imprecise or step == .element or step == .descendants or step.isExclusion();
                if (imprecise) {
                    origin.flow_handle = origin.flow_handle orelse try self.newFlowHandle(reference.id);
                    origin.projection = null;
                }
                result = try self.addReferenceOrigin(result, origin);
            }
            return result;
        }

        fn flowReference(self: *Self, source: Value) !Value {
            const type_id = try self.analysis_context.facts().referenceType(source.type_id);
            if (source.place_reference) |address| return .{
                .id = address,
                .type_id = type_id,
                .reference_origins = source.place_origins,
                .flow_origins = try self.valuePlaceOrigins(source),
                .local_reference = source.local_reference,
                .writable = source.writable,
            };
            var storage = source;
            var fields: structures.FunctionValueRange = .{ .start = 0, .end = 0 };
            if (source.local_reference) |place| {
                storage = try self.pinLocalStorage(place.local);
                fields = place.projections;
            } else if (source.borrow_root) |root| {
                storage = try self.pinLocalStorage(root);
            }
            var reference = try self.appendInstruction(.{ .borrow_address = .{ .source = storage.id, .type_id = type_id, .fields = fields } });
            reference.reference_origins = source.place_origins orelse try self.sourceReferenceOrigins(source);
            reference.flow_origins = try self.valuePlaceOrigins(source);
            reference.reference_origins = try self.stableStorageOrigins(reference.reference_origins, if (source.local_reference) |place| place.local else source.borrow_root);
            if (source.place_origins == null) for (self.borrow_fields.items[fields.start..fields.end]) |step| {
                reference.reference_origins = try self.appendSourcePath(reference.reference_origins, switch (step) {
                    .field => |index| .{ .field = index },
                    .variant => |member| .{ .variant = member },
                });
            };
            reference.local_reference = source.local_reference orelse if (source.borrow_root) |local|
                LocalReference{ .local = local, .projections = .{ .start = 0, .end = 0 } }
            else
                null;
            reference.writable = source.writable;
            return reference;
        }

        fn flowOwned(self: *Self, source: Value, span: structures.SourceSpan) !Value {
            const place = (try self.flowPlace(source, false)) orelse return ownershipSource(source);
            const selected = self.flow.?.facts.get(self.state.refinements, place).type_id orelse return ownershipSource(source);
            if (selected == source.type_id) return ownershipSource(source);
            for (try self.matchInputMembers(selected)) |member| {
                if ((try self.analysis_context.facts().memberSpec(member)).kind != .owned)
                    return self.reject(span, .ownership_transfer_requires_owned_place);
            }
            return self.extractOwnedVariant(ownershipSource(source), selected, span);
        }

        fn flowBindingReference(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected: ?structures.TypeId) !Value {
            const reference = try self.captureReference(raw);
            if (reference.type_id == .never) return reference;
            const element = (try self.analysis_context.facts().borrowElement(reference.type_id)).?;
            if (expected == element) return reference;
            const operand = try self.readReference(reference, element);
            const found = try self.flowPlace(operand, false);
            const place = found orelse return reference;
            const members = self.flow.?.facts.get(self.state.refinements, place).type_id orelse return reference;
            const logical = try self.flowReadType(members);
            if (try self.analysis_context.facts().variantMembers(members) != null and try self.analysis_context.facts().variantMembers(logical) != null) {
                if (members == element) return reference;
                return self.reject(raw.span, .reference_projection_requires_member);
            }
            if (logical == .never) {
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.terminate(.diverge);
                return .{ .id = operand.id, .type_id = .never };
            }
            try self.requireFlowProof(place);
            return self.extractLogicalBinding(reference, element, logical, .reference, raw.span);
        }

        fn flowReadType(self: *Self, stored: structures.TypeId) !structures.TypeId {
            const members = (try self.analysis_context.facts().variantMembers(stored)) orelse
                return (try self.analysis_context.facts().memberSpec(stored)).type_id;
            const first = (try self.analysis_context.facts().memberSpec(members[0])).type_id;
            for (members[1..]) |member| {
                if ((try self.analysis_context.facts().memberSpec(member)).type_id != first) return stored;
            }
            return first;
        }

        fn relativeCleanupPath(self: *Self, base: FlowOrigin, descendant: FlowOrigin) !?[]const structures.ReferencePathStep {
            var left = base;
            var right = descendant;
            left.path = null;
            right.path = null;
            if (!std.meta.eql(left, right)) return null;
            var result: std.ArrayList(structures.ReferencePathStep) = .empty;
            var path = descendant.path;
            while (path != base.path) {
                const index = path orelse return null;
                const projection = self.flow.?.paths.keys()[index];
                try result.append(self.gpa, projection.step);
                path = projection.parent;
            }
            std.mem.reverse(structures.ReferencePathStep, result.items);
            return try result.toOwnedSlice(self.gpa);
        }

        fn replaceOwnerCleanup(self: *Self, source: Value, selections: []const cleanup_shape.Selection) !Value {
            const previous = source.owned_generation.?;
            const metadata = self.generations.items[@backingInt(previous)];
            if (selections.ptr == metadata.cleanup_selections.ptr and selections.len == metadata.cleanup_selections.len) return source;
            try self.recordConsume(source);
            var refined = source;
            const generation = (try self.allocateGeneration(source.type_id, metadata.span, metadata.cleanup_fields)).?;
            self.generations.items[@backingInt(generation)].cleanup_selections = selections;
            try self.copyMissingFields(generation, metadata.missing_fields, null, null);
            const data = &self.generations.items[@backingInt(generation)];
            data.cleanup_condition = metadata.cleanup_condition;
            data.lifetime_origin = metadata.lifetime_origin orelse previous;
            data.requires_explicit_drop = (try cleanup_shape.obligations(self.gpa, self.analysis_context, source.type_id, selections, data.missing_fields, data.cleanup_fields)).explicit;
            refined.owned_generation = generation;
            try self.recordEffect(.{ .define = .{ .generation = generation, .value = refined.id } });
            try self.rememberCleanupOrigins(refined);
            return refined;
        }

        fn refineFlowOwners(self: *Self) !void {
            if (self.flow == null) return;
            for (0..self.state.values.len) |slot| {
                if (self.state.availability.get(slot) != .available or self.locals.items(.reference)[slot]) continue;
                const source = self.state.values.get(slot) orelse continue;
                const generation = source.owned_generation orelse continue;
                const origins = (try self.flowOrigins(try self.valuePlaceOrigins(self.borrowLocalValue(@fromBackingInt(@intCast(slot)))))) orelse continue;
                if (origins.items.len != 1) continue;
                var selections = self.generations.items[@backingInt(generation)].cleanup_selections;
                for (self.flow.?.places.items, 0..) |place, index| {
                    if (place.origins.len != 1) continue;
                    const selected = self.flow.?.facts.get(self.state.refinements, index).type_id orelse continue;
                    if (selected == .never) continue;
                    const maybe_path = try self.relativeCleanupPath(origins.items[0], self.flow.?.origins.keys()[place.origins[0]]);
                    const path = maybe_path orelse continue;
                    if (try cleanup_shape.typeAt(self.analysis_context, source.type_id, path) == null) continue;
                    const current = cleanup_shape.membersAt(selections, path) orelse (try self.analysis_context.facts().variantMembers(place.type_id)).?;
                    const members = try self.matchInputMembers(selected);
                    var feasible: std.ArrayList(structures.TypeId) = .empty;
                    for (current) |member| if (containsType(members, member)) try feasible.append(self.gpa, member);
                    if (std.mem.eql(structures.TypeId, current, feasible.items)) continue;
                    selections = try cleanup_shape.withMembers(self.gpa, selections, path, try feasible.toOwnedSlice(self.gpa));
                }
                const refined = try self.replaceOwnerCleanup(source, selections);
                try self.state.values.set(self.gpa, slot, refined);
            }
        }

        fn flowRead(self: *Self, source: Value) !Value {
            const place = (try self.flowPlace(source, false)) orelse return source;
            const selected = self.flow.?.facts.get(self.state.refinements, place).type_id orelse return source;
            const logical = try self.flowReadType(selected);
            if (logical == source.type_id) return source;
            try self.requireFlowProof(place);
            if (selected == .never) return .{ .id = source.id, .type_id = .never };
            if (try self.analysis_context.facts().variantMembers(selected) != null and try self.analysis_context.facts().variantMembers(logical) != null) {
                const storage = try self.inPlaceStorage(selected);
                const extraction = try self.appendInstruction(.{ .variant_extract = .{
                    .operand = source.id,
                    .target_type = selected,
                    .tag_mapping = try self.appendExtractionTagMapping(source.type_id, selected),
                    .destination = if (storage) |destination| destination.id else null,
                } });
                var narrowed = storage orelse extraction;
                narrowed.borrowed_type = selected;
                narrowed.borrowed_generation = source.borrowed_generation orelse source.owned_generation;
                narrowed.borrowed_cleanup_value = source.borrowed_cleanup_value orelse source.id;
                narrowed.reference_origins = source.reference_origins;
                narrowed.borrow_root = source.borrow_root;
                narrowed.writable = source.writable;
                return narrowed;
            }
            if (selected == logical) {
                try self.recordUse(source);
                var narrowed = if (try self.usesIndirectStorage(logical))
                    try self.projectStorage(source, logical, .variant)
                else
                    try self.appendInstruction(.{ .variant_extract = .{ .operand = source.id, .target_type = selected } });
                if (logical.isPrimitive()) return narrowed;
                narrowed.borrowed_type = logical;
                narrowed.borrowed_generation = source.borrowed_generation orelse source.owned_generation;
                narrowed.borrowed_cleanup_value = source.borrowed_cleanup_value orelse source.id;
                narrowed.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = selected } });
                narrowed.place_origins = try self.variantPlaceOrigins(source.place_origins orelse try self.sourceReferenceOrigins(source), selected);
                narrowed.flow_origins = try self.appendSourcePath(try self.valuePlaceOrigins(source), .{ .variant = selected });
                narrowed.local_reference = try self.extendLocalReference(source.local_reference orelse if (source.borrow_root) |local| LocalReference{ .local = local, .projections = .{ .start = 0, .end = 0 } } else null, &.{}, selected);
                narrowed.borrow_root = source.borrow_root;
                narrowed.writable = source.writable;
                return narrowed;
            }
            const reference = try self.extractLogicalBinding(try self.flowReference(source), source.type_id, logical, .reference, self.activeLifetimeSpan());
            return self.readReference(reference, logical);
        }

        fn flowTypeView(self: *Self, source: Value) !Value {
            const place = (try self.flowPlace(source, false)) orelse return source;
            const selected = self.flow.?.facts.get(self.state.refinements, place).type_id orelse return source;
            const logical = try self.flowReadType(selected);
            if (logical == source.type_id) return source;
            var result = source;
            result.type_id = logical;
            if (try self.analysis_context.facts().variantMembers(selected) != null and try self.analysis_context.facts().variantMembers(logical) != null) {
                result.place_origins = null;
                return result;
            }
            var places: ?u32 = null;
            var contents: ?u32 = null;
            for (try self.matchInputMembers(selected)) |member| {
                const spec = try self.analysis_context.facts().memberSpec(member);
                places = try self.mergeReferenceOrigins(places, if (spec.kind == .reference)
                    try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = member } })
                else
                    try self.appendSourcePath(try self.valuePlaceOrigins(source), .{ .variant = member }));
                contents = try self.mergeReferenceOrigins(contents, try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = member } }));
            }
            result.place_origins = places;
            result.reference_origins = contents;
            return result;
        }

        /// Read only type/place metadata. Inference must not execute or cache an
        /// argument's value before preceding arguments have run their effects.
        fn readTypeValue(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!?Value {
            const source = (try self.readPlaceValue(id)) orelse return null;
            return try self.flowTypeView(source);
        }

        fn readPlaceValue(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!?Value {
            if (self.flow == null or self.flow.?.places.items.len == 0) return null;
            const operation = self.expressionOperation(id);
            if (self.capturedInput(id)) return self.values.get(@backingInt(id));
            if (operation == null or (operation.?.* != .local_read and operation.?.* != .local_transfer and operation.?.* != .field_access)) {
                if (self.values.get(@backingInt(id))) |cached| return cached;
            }
            if (operation == null) return null;
            switch (operation.?.*) {
                .local_read, .local_transfer => |local| {
                    const stored = self.state.values.get(@backingInt(local)) orelse return null;
                    if (!self.locals.items(.reference)[@backingInt(local)]) return self.borrowLocalValue(local);
                    var source = stored;
                    source.type_id = (try self.analysis_context.facts().borrowElement(stored.type_id)).?;
                    source.place_origins = stored.reference_origins;
                    source.reference_origins = try self.referenceContents(stored, stored.reference_origins);
                    return source;
                },
                .field_access => |access| {
                    const parent = (try self.readTypeValue(access.operand.value)) orelse return null;
                    const field = try self.resolvePlaceField(parent.type_id, access.name, access.operand.span, self.valueSpan(id));
                    var source = parent;
                    source.type_id = field.type_id;
                    source.reference_origins = try self.transformReferenceOrigins(parent.reference_origins, .{ .select = .{ .field = field.index } });
                    source.place_origins = if (field.kind == .reference) source.reference_origins else try self.appendSourcePath(parent.place_origins, .{ .field = field.index });
                    source.flow_origins = if (field.kind == .reference) source.reference_origins else try self.appendSourcePath(try self.valuePlaceOrigins(parent), .{ .field = field.index });
                    return source;
                },
                else => return null,
            }
        }

        fn joinBindingIdentities(self: *Self, first: BindingIdentity, second: BindingIdentity) !BindingIdentity {
            if (std.meta.eql(first, second)) return first;
            const index: u32 = @intCast(self.binding_joins.items.len);
            try self.binding_joins.append(self.gpa, .{ .initial = first, .complete = true });
            try self.binding_joins.items[index].alternatives.append(self.gpa, second);
            return .{ .join = index };
        }

        fn discardValue(self: *Self, value_to_discard: Value, span: structures.SourceSpan) !void {
            _ = try self.borrowValue(value_to_discard, span);
        }

        fn initializerExitBoundary(self: *Self) bool {
            if (self.is_initializer_region) return true;
            if (!self.type_check_only) return false;
            var parent = self.flow_parent;
            while (parent) |body| {
                if (body.is_initializer_region) return true;
                if (!body.type_check_only) return false;
                parent = body.flow_parent;
            }
            return false;
        }

        fn inferenceLoopResult(self: *Self) ?ResultRequest {
            if (!self.type_check_only) return null;
            var parent = self.flow_parent;
            while (parent) |body| {
                if (body.loop_stack.last()) |context| return context.result;
                if (body.is_initializer_region) return null;
                parent = body.flow_parent;
            }
            return null;
        }

        fn breakLoop(self: *Self, value_id: semantic.UnresolvedBody.ValueId) !void {
            if (self.is_initializer_region and self.loop_stack.items.len == 0) return self.reject(self.valueSpan(value_id), .initializer_exit_outside_boundary);
            if (self.loop_stack.items.len == 0) if (self.inferenceLoopResult()) |result| {
                _ = try self.evaluateValue(value_id, .{ .value = .{ .expected_type = if (result.destination) |destination| destination.storage.type_id else result.value.expected_type, .access = result.value.access }, .discard = result.discard, .reference = result.reference });
                if (self.current_block != null) self.terminate(.diverge);
                return;
            };
            if (self.loop_stack.items.len == 0 and self.initializerExitBoundary()) return self.reject(self.valueSpan(value_id), .initializer_exit_outside_boundary);
            const context = self.loop_stack.last().?;
            var value_to_break = try self.evaluateValue(value_id, context.result);
            if (value_to_break.type_id == .never) return;
            if (context.result.discard) value_to_break = try self.discardResult(value_to_break, self.valueSpan(value_id));
            value_to_break = try self.ownValueEscapingSince(value_to_break, context.baseline, self.unresolved.blocks[@backingInt(self.unresolved.root_block)].span);
            try self.finishReplacementUses(self.valueSpan(value_id));
            try self.unbindLocalsSince(context.baseline);
            const state = try self.captureState();
            try self.loop_breaks.append(self.gpa, .{ .block = self.suspendBlock(), .state = state, .constructed = value_to_break });
        }

        fn continueLoop(self: *Self, span: structures.SourceSpan) !void {
            if (self.is_initializer_region and self.loop_stack.items.len == 0) return self.reject(span, .initializer_exit_outside_boundary);
            if (self.loop_stack.items.len == 0 and self.inferenceLoopResult() != null) {
                self.terminate(.diverge);
                return;
            }
            if (self.loop_stack.items.len == 0 and self.initializerExitBoundary()) return self.reject(span, .initializer_exit_outside_boundary);
            const context = self.loop_stack.last().?;
            try self.finishReplacementUses(span);
            try self.unbindLocalsSince(context.baseline);
            try self.repeatLoop(context, span);
        }

        fn returnNothing(self: *Self, span: structures.SourceSpan) !void {
            if (self.initializerExitBoundary()) return self.reject(span, .initializer_exit_outside_boundary);
            if (self.return_type == .unit) return self.finishFunctionExit(span, .return_unit);
            const unit = try self.appendInstruction(.const_unit);
            const use = try self.coerceValue(unit.id, .unit, self.return_type) orelse
                return self.reject(span, .{ .missing_return_value = self.return_type });
            try self.finishFunctionExit(span, .{ .return_value = use });
        }

        fn returnExpression(self: *Self, returned: @FieldType(semantic.UnresolvedBody.Statement, "return_value")) !void {
            const id = returned.value.value;
            const span = returned.value.span;
            if (self.initializerExitBoundary()) return self.reject(span, .initializer_exit_outside_boundary);
            if (self.options.result_mode == .reference) return self.returnValue(try self.captureReference(.{ .value = id, .span = span }), span);
            if (returned.implicit and !self.options.infer_return_type and self.return_type == .unit) {
                const result = try self.discardedValue(id);
                if (result.type_id == .never) return;
                try self.discardValue(result, span);
                return self.returnNothing(span);
            }
            if (self.options.infer_return_type or !try self.usesIndirectStorage(self.return_type))
                return self.returnValue(try self.valueWithContext(id, .{ .expected_type = self.return_type, .access = .initialize }), span);
            const storage = try self.appendInstruction(.{ .result_storage = self.return_type });
            const result = try self.construct(id, span, .{ .storage = storage, .site = .return_value });
            if (result.type_id == .never) return;
            try self.returnConstructed(result, span);
        }

        fn returnConstructed(self: *Self, result: Value, span: structures.SourceSpan) !void {
            try self.validateEscapingBorrows(result, span);
            self.returned_reference_origins = try self.mergeReferenceOrigins(self.returned_reference_origins, result.reference_origins);
            try self.recordConsume(result);
            try self.finishFunctionExit(span, .{ .return_value = .{ .value = result.id } });
        }

        fn returnValue(self: *Self, value_to_return: Value, span: structures.SourceSpan) !void {
            if (value_to_return.type_id == .never) {
                std.debug.assert(self.current_block == null);
                return;
            }
            try self.validateEscapingBorrows(value_to_return, span);
            var use = try self.coerceValue(value_to_return.id, value_to_return.type_id, self.return_type) orelse
                return self.reject(span, .{ .return_type_mismatch = self.typeMismatch(self.return_type, value_to_return.type_id) });
            const owned = try self.ownValue(value_to_return, span);
            use.value = owned.id;
            var returned = if (use.coerce_to) |target_type| try self.retargetOwnership(owned, .{ .id = owned.id, .type_id = target_type }, span) else owned;
            returned.reference_origins = try self.coercedReferenceOrigins(owned, use);
            self.returned_reference_origins = try self.mergeReferenceOrigins(self.returned_reference_origins, returned.reference_origins);
            try self.recordConsume(returned);
            use.value = returned.id;
            try self.finishFunctionExit(span, if (self.return_type == .unit) .return_unit else .{ .return_value = use });
        }

        fn validateEscapingBorrows(self: *Self, candidate: Value, span: structures.SourceSpan) !void {
            if (self.options.infer_reference_contract) return;
            if (!try self.analysis_context.facts().canStoreBorrow(candidate.type_id)) return;
            const origins = candidate.reference_origins orelse return;
            var pending = false;
            const resolved = try self.resolveReferenceOrigins(origins, &pending);
            if (pending)
                try self.pending_reference_returns.append(self.gpa, .{ .origins = origins, .span = span })
            else
                try self.validateReferenceEscape(resolved, span);
        }

        fn validateReferenceEscape(self: *Self, origins: ?u32, span: structures.SourceSpan) !void {
            if (origins == null) return self.reject(span, .borrow_outlives_source);
            var list = self.originList(origins);
            while (list.next()) |origin| {
                if (origin.parameter == null and !origin.permanent) return self.reject(span, .borrow_outlives_source);
            }
        }

        fn patternMismatch(self: *Self, mismatch: FlowExit, span: structures.SourceSpan) !void {
            const scope = self.pattern_scope orelse return self.reject(span, .refutable_binding_requires_else);
            var exit = mismatch;
            exit.constructed = null;
            try scope.exits.append(self.gpa, exit);
        }

        /// Unbinds, youngest first, the locals bound since `baseline`, or every local without one.
        fn unbindLocalsSince(self: *Self, baseline: ?StateId) !void {
            var index = self.state.availability.len;
            while (index > 0) {
                index -= 1;
                const bound_before = if (baseline) |state| self.states.items[@backingInt(state)].availability.get(index) != .unbound else false;
                if (!bound_before and self.state.availability.get(index) != .unbound) try self.unbindLocal(index);
            }
        }

        fn finishFunctionExit(self: *Self, span: structures.SourceSpan, terminator: structures.FunctionTerminator) !void {
            if (self.is_initializer_region and (terminator == .return_value or terminator == .return_unit))
                try self.ordinary_completion_states.append(self.gpa, try self.captureState());
            const boundary = try self.newBoundary(span);
            const block_value = &self.blocks.items[@backingInt(self.current_block orelse unreachable)];
            try self.boundaries.items[@backingInt(boundary)].effects.appendSlice(
                self.gpa,
                block_value.terminator_effects.items,
            );
            block_value.terminator_effects.clearRetainingCapacity();
            const parent_boundary = self.current_boundary;
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            try self.recordReplacementUses();
            try self.writeMutParameters();
            try self.unbindLocalsSince(null);
            try self.closeBoundary(boundary);
            self.terminate(terminator);
        }

        fn ownValueEscapingSince(self: *Self, result: Value, baseline: StateId, span: structures.SourceSpan) !Value {
            if (self.type_check_only) return result;
            const root = result.borrow_root orelse return result;
            if (self.states.items[@backingInt(baseline)].availability.get(@backingInt(root)) != .unbound) return result;
            if (result.borrowed_generation == null) {
                if (self.state.values.get(@backingInt(root))) |owner| try self.recordUse(owner);
            }
            return self.ownValue(result, span);
        }

        /// Evaluate patches before acquiring writable snapshot storage.
        fn updateLocal(self: *Self, index: usize, patch: anytype) !void {
            var local = self.state.values.get(index).?;
            inline for (@typeInfo(@TypeOf(patch)).@"struct".field_names) |name| {
                @field(local, name) = @field(patch, name);
            }
            try self.state.values.set(self.gpa, index, local);
        }

        fn unbindLocal(self: *Self, index: usize) !void {
            try self.state.values.set(self.gpa, index, null);
            try self.state.availability.set(self.gpa, index, .unbound);
        }

        fn value(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!Value {
            return self.valueWithType(id, null);
        }

        fn valueWithType(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId) anyerror!Value {
            return self.valueWithContext(id, .{ .expected_type = expected_type });
        }

        fn valueWithContext(self: *Self, id: semantic.UnresolvedBody.ValueId, context: ValueContext) anyerror!Value {
            return self.evaluateValue(id, .{ .value = context });
        }

        fn acceptsNone(self: *Self, type_id: structures.TypeId) !bool {
            const members = (try self.analysis_context.facts().variantMembers(type_id)) orelse return false;
            return std.mem.indexOfScalar(structures.TypeId, members, .none) != null;
        }

        fn evaluateValue(self: *Self, id: semantic.UnresolvedBody.ValueId, request: ResultRequest) anyerror!Value {
            if (request.reference) {
                const operation = self.expressionOperation(id);
                if (operation == null or (operation.?.* != .if_else and operation.?.* != .match and operation.?.* != .loop and operation.?.* != .scope))
                    return self.captureReference(.{ .value = id, .span = self.valueSpan(id) });
            }
            return self.evaluateUncapturedValue(id, request);
        }

        fn selectConversion(self: *Self, source_type: structures.TypeId, target: structures.TypeId, source_value: ?structures.CompileTimeValueId, span: structures.SourceSpan) !?structures.ConversionCandidate {
            if (source_type != .never and try semantic.canWidenTo(self.analysis_context, source_type, target)) return null;
            const candidates = try self.analysis_context.conversionCandidates(if (source_type == .never) .none else source_type, target, source_value);
            var selected: ?structures.ConversionCandidate = null;
            for (candidates) |candidate| {
                if (source_type == .never and (candidate.source_mode != .imm or !try self.acceptsNone(candidate.input_type))) continue;
                if (selected != null) return self.reject(span, .{ .ambiguous_conversion = self.typeMismatch(target, source_type) });
                selected = candidate;
            }
            return selected;
        }

        fn prepareConversion(self: *Self, id: semantic.UnresolvedBody.ValueId, context: ValueContext) !?Value {
            const target = context.expected_type orelse return null;
            const discovered_type = try self.unevaluatedType(id, target);
            if (try self.staticConversion(id, context, discovered_type)) |converted| return converted;
            const source_type = discovered_type orelse return null;
            // A literal inferred through a branch still needs its ordinary
            // default before a runtime converter can receive the branch result.
            if (source_type == .string_literal) return null;
            if (source_type != .never and try semantic.canWidenTo(self.analysis_context, source_type, target)) return null;
            const span = self.valueSpan(id);
            if (try self.selectConversion(source_type, target, null, span)) |candidate| {
                if (candidate.source_mode != .imm) return null;
                const source = try self.valueWithContext(id, .{ .expected_type = candidate.input_type, .access = .initialize, .allow_converters = false });
                if (source.type_id == .never) return source;
                return try self.convertValue(source, candidate, context, span);
            }
            const conversions = (try self.selectVariantConversions(source_type, target, span)) orelse return null;
            const source = try self.valueWithContext(id, .{ .expected_type = source_type, .access = .initialize, .allow_converters = false });
            if (source.type_id == .never) return source;
            return try self.convertVariantValue(source, conversions, context, span);
        }

        const MemberConversion = union(enum) {
            widen,
            converter: structures.ConversionCandidate,
        };

        fn selectVariantConversions(self: *Self, source_type: structures.TypeId, target: structures.TypeId, span: structures.SourceSpan) !?[]MemberConversion {
            if (try semantic.canWidenTo(self.analysis_context, source_type, target)) return null;
            const members = (try self.analysis_context.facts().variantMembers(source_type)) orelse return null;
            const conversions = try self.gpa.alloc(MemberConversion, members.len);

            for (members, conversions) |member, *conversion| {
                conversion.* = .widen;
                if (try semantic.canWidenTo(self.analysis_context, member, target)) continue;
                const logical_type = (try self.analysis_context.facts().memberSpec(member)).type_id;
                if (try self.selectConversion(logical_type, target, null, span)) |candidate| {
                    conversion.* = .{ .converter = candidate };
                } else if (!try semantic.canWidenTo(self.analysis_context, logical_type, target)) return null;
            }
            return conversions;
        }

        fn convertVariantValue(self: *Self, source: Value, conversions: []const MemberConversion, context: ValueContext, span: structures.SourceSpan) anyerror!Value {
            const target = context.expected_type.?;
            if (self.type_check_only) return self.localStorage(target);
            const operand = try self.borrowValue(source, span);
            const members = (try self.analysis_context.facts().variantMembers(operand.type_id)).?;
            std.debug.assert(members.len == conversions.len);
            var carrier = operand;
            carrier.reference_origins = try self.sourceReferenceOrigins(operand);
            const destination = context.fresh_destination;
            const baseline = try self.captureState();
            const tag = try self.appendInstruction(.{ .variant_tag = operand.id });
            var exits: std.ArrayList(FlowExit) = .empty;
            const parent_boundary = self.current_boundary;
            defer self.current_boundary = parent_boundary;
            for (members, conversions, 0..) |member, conversion, index| {
                const next = try self.enterVariantCase(tag, index, index + 1 == members.len);
                const boundary = try self.newBoundary(span);
                self.current_boundary = boundary;
                const result = try self.convertVariantMember(carrier, operand, member, conversion, context, span);
                if (self.current_block != null) {
                    try self.closeBoundary(boundary);
                    try exits.append(self.gpa, (try self.valueExit(result)).?);
                }
                if (next) |next_block| {
                    self.enterBlock(next_block);
                    self.restoreState(baseline);
                }
            }
            if (exits.items.len == 0) {
                std.debug.assert(self.current_block == null);
                return .{ .id = @fromBackingInt(0), .type_id = .never };
            }
            const joined = try self.mergeExits(baseline, exits.items, .{
                .value = context,
                .destination = if (destination) |storage| .{ .storage = storage, .site = .local } else null,
            }, .condition);
            try self.enterFlowExit(joined);
            return joined.constructed.?;
        }

        fn convertVariantMember(self: *Self, carrier: Value, operand: Value, member: structures.TypeId, conversion: MemberConversion, context: ValueContext, span: structures.SourceSpan) !Value {
            const target = context.expected_type.?;
            const specification = try self.analysis_context.facts().memberSpec(member);
            const reference = try self.extractReferenceMember(carrier, operand, member, specification.type_id);
            const input = if (specification.kind == .reference and try semantic.canWidenTo(self.analysis_context, member, target))
                reference
            else
                try self.readReference(reference, specification.type_id);
            switch (conversion) {
                .converter => |candidate| return self.convertValue(input, candidate, context, span),
                .widen => {
                    if (context.fresh_destination) |storage| return self.placeValue(input, span, .{ .storage = storage, .site = .local });
                    const use = (try self.coerceValue(input.id, input.type_id, target)).?;
                    if (use.coerce_to == null) return input;
                    return self.coerceOwnedRepresentation(input, use, span, null);
                },
            }
        }

        fn captureExpectedVariant(self: *Self, id: semantic.UnresolvedBody.ValueId, context: ValueContext) !?Value {
            const target = context.expected_type orelse return null;
            const members = (try self.analysis_context.facts().variantMembers(target)) orelse return null;
            for (members) |member| {
                if ((try self.analysis_context.facts().memberSpec(member)).kind == .reference) break;
            } else return null;
            const source_type = (try self.unevaluatedType(id, target)) orelse return null;
            if (source_type == target or source_type == .never) return null;
            var reference_member: ?structures.TypeId = null;
            for (members) |member| {
                const specification = try self.analysis_context.facts().memberSpec(member);
                if (specification.kind == .reference and specification.type_id == source_type) reference_member = member;
            }
            if (reference_member == null) return null;
            const span = self.valueSpan(id);
            if (containsType(members, source_type)) {
                var fields: std.ArrayList(PlaceField) = .empty;

                if (try self.resolveBorrowPlace(id, &fields) == null) return null;
                return self.reject(span, .{ .ambiguous_variant_member = self.typeMismatch(target, source_type) });
            }
            const candidates = try self.analysis_context.conversionCandidates(source_type, target, null);

            if (candidates.len != 0) return self.reject(span, .{ .ambiguous_conversion = self.typeMismatch(target, source_type) });
            const reference = try self.captureReference(.{ .value = id, .span = span });
            if (reference.type_id == .never) return reference;
            std.debug.assert(reference.type_id == reference_member.?);
            const use = (try self.coerceValue(reference.id, reference.type_id, target)).?;
            return try self.coerceOwnedRepresentation(reference, use, span, context.fresh_destination);
        }

        fn capturedInput(self: *Self, id: semantic.UnresolvedBody.ValueId) bool {
            if (self.flow_parent == null or @backingInt(id) < self.unresolved.parameter_count) return false;
            const cached = self.values.get(@backingInt(id)) orelse return false;
            if (@backingInt(cached.id) >= self.block_arguments.items.len) return false;
            const operation = self.expressionOperation(id).?;
            if (operation.* == .local_read and self.state.values.get(@backingInt(operation.local_read)) != null) return false;
            return true;
        }

        fn evaluateUncapturedValue(self: *Self, id: semantic.UnresolvedBody.ValueId, request: ResultRequest) anyerror!Value {
            const index = @backingInt(id);
            const source_operation = self.expressionOperation(id);
            var context: ValueContext = if (request.destination) |destination| .{ .expected_type = destination.storage.type_id, .access = .initialize, .fresh_destination = destination.storage } else request.value;
            if (request.reference) context.allow_converters = false;
            if (context.expected_type == null) if (source_operation) |operation| {
                if (operation.* == .annotation) context.expected_type = operation.annotation.type_id;
                if (operation.* == .string_literal and context.allow_converters) context.expected_type = try self.analysis_context.stringType();
            };
            if (try self.captureExpectedVariant(id, context)) |captured| return captured;
            const contextual_collection = source_operation != null and source_operation.?.* == .collection_literal;
            if (context.allow_converters and !contextual_collection) if (try self.prepareConversion(id, context)) |converted| {
                try self.rememberCleanupOrigins(converted);
                return converted;
            };
            if (request.destination) |destination| {
                const span = request.destination_span orelse self.valueSpan(id);
                if (self.values.get(index)) |pending| if (pending.initializer_parameter != null) return self.constructInitializer(pending, span, destination.storage);
                if (!try self.constructsDirectly(id, destination.storage.type_id)) return self.placeEvaluated(id, span, destination);
            }
            if (context.access == .borrow) std.debug.assert(context.expected_type != null);
            if (context.fresh_destination != null) std.debug.assert(context.access == .consume or context.access == .initialize);
            if (context.access == .consume and (source_operation == null or source_operation.?.* != .call)) {
                var fields: std.ArrayList(PlaceField) = .empty;

                if (self.explicitPlaceTransfer(id)) return self.consumeOwnedPlace(id, context.expected_type, self.valueSpan(id));
                if (try self.resolveBorrowPlace(id, &fields)) |place| {
                    const selected = try self.consumeOwnedPlace(id, context.expected_type, self.valueSpan(id));
                    if (context.fresh_destination) |destination| {
                        if (self.is_initializer_region and place.root == .local and self.captured_locals[@backingInt(place.root.local)] == null) {
                            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(selected.type_id)) orelse return error.Unavailable;
                            if (capabilities.move == .none) return self.reject(self.valueSpan(id), .{ .type_not_movable = selected.type_id });
                            return self.moveValue(selected, self.valueSpan(id), destination);
                        }
                    }
                    return selected;
                }
            }
            if (self.values.get(index)) |resolved| {
                const source = if (!self.capturedInput(id) and source_operation != null and source_operation.?.* == .local_read)
                    try self.readLocal(source_operation.?.local_read, self.valueSpan(id))
                else
                    resolved;
                return self.contextualValue(source, context, self.valueSpan(id));
            }
            std.debug.assert(index >= self.unresolved.parameter_count);
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            const expected_type = context.expected_type;
            var child_context = context;
            child_context.allow_converters = true;
            // Fresh argument storage receives a construction the caller did not place.
            const fresh: ?Destination = request.destination orelse if (context.fresh_destination) |storage| .{ .storage = storage, .site = .argument } else null;
            const scope = try self.openBoundary(expression.span);
            defer self.current_boundary = scope.parent;
            const resolved: Value = switch (expression.operation) {
                .integer_literal, .int_literal_value => |integer| if (expected_type == .int_literal)
                    try self.appendInstruction(.{ .const_int_literal = integer })
                else
                    try self.appendInstruction(.{ .const_int = std.math.cast(i32, integer) orelse return self.reject(expression.span, .integer_literal_out_of_range) }),
                .string_literal => |data| if (expected_type != null and expected_type.? != .string_literal and try semantic.canWidenTo(self.analysis_context, try self.analysis_context.staticStringType(), expected_type.?))
                    try self.staticStringValue(data)
                else
                    try self.appendInstruction(.{ .const_string_literal = data }),
                .storage_cursor => |cursor| try self.permanentStorageCursor(cursor),
                .integer => |integer| try self.appendInstruction(.{ .const_int = integer }),
                .byte => |byte| try self.appendInstruction(.{ .const_byte = byte }),
                .boolean => |boolean| try self.appendInstruction(.{ .const_bool = boolean }),
                .type_value => |type_id| if (self.options.allow_type_values)
                    try self.appendInstruction(.{ .const_type = type_id })
                else
                    return self.reject(expression.span, .type_value_used_as_runtime_value),
                .unit => try self.appendInstruction(.const_unit),
                .none => try self.appendInstruction(.const_none),
                .function_ref => |reference| try self.appendInstruction(.{ .function_ref = reference }),
                .overloaded_function => |choices| try self.appendInstruction(.{ .function_ref = try self.overloadedFunction(choices, expected_type, expression.span) }),
                .local_read => |local| try self.readLocal(local, expression.span),
                .local_transfer => |local| explicitTransfer(try self.constructLocalTransfer(local, expression.span, fresh)),
                .field_transfer => |transfer| explicitTransfer(try self.constructFieldTransfer(transfer, expression.span, fresh)),
                .annotation => |annotation| if (self.type_check_only)
                    try self.annotate(annotation, context)
                else if (try self.temporaryDestination(request.destination, context, fresh)) |destination|
                    try self.constructAnnotated(annotation, destination)
                else
                    try self.annotate(annotation, context),
                .struct_init => try self.constructStruct(expression, try self.temporaryDestination(request.destination, context, fresh)),
                .array_init => |initializer| try self.constructArrayElements(expression, initializer.type_id, initializer.elements, request.destination orelse .{
                    .storage = context.fresh_destination orelse try self.localStorage(initializer.type_id),
                    .site = .local,
                }),
                .collection_literal => |literal| try self.collectionValue(id, expression, literal.elements, context),
                .collection_comprehension => |body| try self.valueWithContext(body.value, .{}),
                .collection_emit => |element| try self.emitCollectionElement(element),
                .collection_iteration => |iteration| try self.collectionIteration(iteration),
                .collection_spread => |spread| try self.emitCollectionSpread(spread, expression.span),
                .tuple_literal => |elements| try self.constructTuple(expression, elements, context),
                .field_access => |access| try self.accessField(access.operand, access.name, expression.span),
                .index_snapshot => |source| try self.snapshotIndex(source, expected_type),
                .assignment => try self.assignment(expression),
                .reference_assignment => |assignment_ref| try self.referenceAssignment(assignment_ref),
                .discard => |discarded| try self.discardResult(try self.discardedValue(discarded.value), discarded.span),
                .sequence => |operands| blk: {
                    const first = try self.value(operands.lhs.value);
                    if (first.type_id == .never) break :blk first;
                    break :blk try self.valueWithContext(operands.rhs.value, child_context);
                },
                .call => |call| try self.callFunction(call, expression.span, .{ .value = context, .destination = if (context.access == .consume) fresh else request.destination }),
                .comparison => |comparison| try self.comparisonValue(comparison, expression.span),
                .static_membership, .variant_membership, .iterator_membership, .conjunction, .disjunction, .negation, .pattern_test => try self.predicateValue(id, expression.span),
                .if_else => |expression_if| try self.conditional(expression_if, .{ .value = child_context, .destination = request.destination, .discard = request.discard, .reference = request.reference }),
                .match => |expression_match| try self.matchValue(expression_match, .{ .value = child_context, .destination = request.destination, .discard = request.discard, .reference = request.reference }),
                .loop => |body| try self.loop(body, .{ .value = child_context, .destination = request.destination, .discard = request.discard, .reference = request.reference }),
                .scope => |body| try self.scopeValue(body, request),
                .iterator => |iteration| try self.iteratorValue(iteration.source, iteration.acquisition, iteration.structural_array, expression.span),
                .iterator_item => |item| try self.iteratorItem(item),
            };
            const result = if (request.destination != null) resolved else try self.contextualValue(resolved, context, expression.span);
            if (self.current_block != null) try self.closeBoundary(scope.boundary);
            const cached = if (expression.operation == .local_read or expression.operation == .field_access) resolved else result;
            try self.values.set(self.gpa, index, cached);
            try self.rememberCleanupOrigins(result);
            return result;
        }

        /// Borrowed and consumed temporaries of a known type are built in argument storage.
        fn temporaryDestination(self: *Self, destination: ?Destination, context: ValueContext, fresh: ?Destination) !?Destination {
            if (context.access != .borrow and context.access != .consume) return destination;
            const expected = context.expected_type orelse return destination;
            return fresh orelse .{ .storage = try self.localStorage(expected), .site = .argument };
        }

        fn permanentStorageCursor(self: *Self, cursor: structures.StaticStorageCursor) !Value {
            var result = try self.appendInstruction(.{ .const_storage_cursor = cursor });
            result.reference_origins = try self.addReferenceOrigin(null, .{ .permanent = true });
            return result;
        }

        fn scopeValue(self: *Self, body: semantic.UnresolvedBody.BlockId, request: ResultRequest) !Value {
            if (try self.blockWithResult(body, request)) |result| return result;
            if (self.current_block == null) return .{ .id = @fromBackingInt(0), .type_id = .never };
            return self.appendInstruction(.const_unit);
        }

        fn contextualValue(self: *Self, raw_source: Value, context: ValueContext, span: structures.SourceSpan) !Value {
            const source = if (!context.refine or context.expected_type == raw_source.type_id) raw_source else try self.flowRead(raw_source);
            if (source.type_id == .never and source.initializer_parameter == null) {
                // Storage projections can have an uninhabited element type;
                // reading one cannot produce a successful value.
                if (self.current_block != null) {
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    self.terminate(.diverge);
                }
                return .{ .id = source.id, .type_id = .never };
            }
            if (source.type_id == .int_literal) if (try self.literalDefaultTarget(context.expected_type)) |target| {
                var default_context = context;
                default_context.expected_type = target;
                return self.stageStaticValue(source, default_context, span);
            };
            if (context.allow_converters) if (context.expected_type) |target| {
                if (try self.selectConversion(source.type_id, target, null, span)) |candidate|
                    return self.convertValue(source, candidate, context, span);
                if (try self.selectVariantConversions(source.type_id, target, span)) |conversions| {
                    return self.convertVariantValue(source, conversions, context, span);
                }
            };
            if (source.initializer_parameter) |parameter| {
                if (self.state.initializers.get(parameter) != .pending) return self.reject(span, .initializer_already_consumed);
                if (context.access == .initialize) return self.constructInitializer(source, span, null);
                if (context.access != .value) return self.reject(span, .initializer_requires_construction);
            }
            if (context.access == .value or context.access == .initialize) return source;
            if (context.access == .borrow and source.explicit_transfer) return self.reject(span, .ownership_transfer_requires_owning_context);
            if (context.access == .consume and source.borrowed_type != null) return self.reject(span, .ownership_transfer_requires_owned_place);
            const target_type = context.expected_type orelse return source;
            if (source.type_id == target_type) return source;
            if (source.preserves_storage) return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(target_type, source.type_id) });
            const use = try self.coerceValue(source.id, source.type_id, target_type) orelse
                return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(target_type, source.type_id) });
            return self.coerceOwnedRepresentation(source, use, span, if (try self.usesIndirectStorage(target_type)) context.fresh_destination orelse try self.localStorage(target_type) else null);
        }

        fn convertValue(self: *Self, source: ?Value, candidate: structures.ConversionCandidate, context: ValueContext, span: structures.SourceSpan) !Value {
            if (self.type_check_only) return self.localStorage(candidate.target_type);
            // Validate the selected converter's constraints at its actual use.
            _ = (try self.analysis_context.functionSignature(candidate.instance)) orelse return error.Unavailable;
            const consuming = candidate.source_mode == .init;
            std.debug.assert((candidate.source_mode == .static) == (source == null));
            var operand = if (source) |runtime_source| if (consuming) runtime_source else try self.borrowValue(runtime_source, span) else null;
            if (candidate.source_mode == .imm and operand.?.type_id != candidate.input_type) {
                const use = (try self.coerceValue(operand.?.id, operand.?.type_id, candidate.input_type)) orelse
                    return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(candidate.input_type, operand.?.type_id) });
                operand = try self.coerceOwnedRepresentation(operand.?, use, span, null);
            }
            if (consuming and operand.?.initializer_parameter != null) try self.consumeInitializer(operand.?, span);
            if (operand) |runtime_operand| try self.recordUse(runtime_operand);
            const contract = (try self.analysis_context.functionReferenceContract(candidate.instance)) orelse return error.Unavailable;
            var sources: [1]CallOriginSource = undefined;
            if (operand) |runtime_operand| sources[0] = .{ .type_id = runtime_operand.type_id, .contained = runtime_operand.reference_origins, .storage = try self.sourceReferenceOrigins(runtime_operand) };
            const arguments = sources[0..@intFromBool(operand != null)];
            try self.substituteReferenceExclusions(contract, arguments, span);
            const writable_start: u32 = @intCast(self.writable_call_references.items.len);
            var reference_effects: ReferenceEffects = .{};
            for (contract.requirements) |requirement| {
                const written = try self.recordRequirementWrite(contract, requirement, arguments, &reference_effects, span);
                if (requirement.written_type) |written_type|
                    try self.writable_call_references.append(self.gpa, .{ .id = operand.?.id, .type_id = try self.analysis_context.facts().referenceType(written_type), .reference_origins = written });
            }
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            if (operand) |runtime_operand|
                try self.call_arguments.append(self.gpa, if (consuming) .{ .initializer = runtime_operand.id } else .{ .prepared = .{ .value = runtime_operand.id } });
            const output_start: u32 = @intCast(self.pending_reference_outputs.items.len);
            try self.appendReferentOutputs(contract, arguments, self.call_arguments.items[argument_start..]);
            const origins = try self.substituteOutputOrigins(contract, arguments, null);
            const empty_mut: u32 = @intCast(self.pending_mut_arguments.items.len);
            const empty_consumed: u32 = @intCast(self.pending_consumed_arguments.items.len);
            const call: semantic.UnresolvedBody.Call = .{ .target = .{ .direct = candidate.instance }, .arguments = .{ .start = 0, .end = 0 }, .span = span };
            const callable: ResolvedCallable = .{
                .precise_reference_contract = true,
                .reference_outputs = .{ .start = output_start, .end = @intCast(self.pending_reference_outputs.items.len) },
                .operation = .{ .target = .{ .direct = candidate.instance }, .arguments = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) }, .return_type = candidate.target_type },
                .mut_arguments = .{ .start = empty_mut, .end = empty_mut },
                .consumed_arguments = .{ .start = empty_consumed, .end = empty_consumed },
                .writable_references = .{ .start = writable_start, .end = @intCast(self.writable_call_references.items.len) },
                .reference_effects = reference_effects,
                .reference_origins = origins,
            };
            const result = try self.resolvedCallResult(callable, call, span, .{ .value = context, .destination = if (context.fresh_destination) |storage| .{ .storage = storage, .site = .argument } else null });
            if (result.type_id == context.expected_type.?) return result;
            const widened = (try self.coerceValue(result.id, result.type_id, context.expected_type.?)).?;
            return self.coerceOwnedRepresentation(result, widened, span, if (try self.usesIndirectStorage(context.expected_type.?)) try self.localStorage(context.expected_type.?) else null);
        }

        fn staticConversion(self: *Self, id: semantic.UnresolvedBody.ValueId, context: ValueContext, discovered_type: ?structures.TypeId) !?Value {
            const target = context.expected_type orelse return null;
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) {
                const source = self.values.get(index).?;
                if (source.initializer_parameter != null or !try self.needsStaticConversion(source.type_id, target)) return null;
                return try self.stageStaticConversion(id, source.type_id, context, self.valueSpan(id));
            }
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            if (expression.source_node == .null) return null;
            const is_literal = expression.operation == .integer_literal or expression.operation == .int_literal_value;
            const source_type: structures.TypeId = switch (expression.operation) {
                .integer_literal, .int_literal_value => .int_literal,
                .string_literal => .string_literal,
                .struct_init => |initializer| if (initializer.target == .concrete) initializer.target.concrete else discovered_type orelse return null,
                .array_init => |initializer| initializer.type_id,
                .annotation => |annotation| annotation.type_id,
                .local_read => |local| if (stateValue(self.state.values, @backingInt(local))) |resolved| resolved.type_id else return null,
                .call, .field_access => discovered_type orelse return null,
                else => return null,
            };
            if (!try self.needsStaticConversion(source_type, target)) return null;
            if (expression.operation == .string_literal) return self.stringLiteralConversion(id, expression.operation.string_literal, context, expression.span);
            // Inference must not execute conversions nested inside the source.
            if (self.type_check_only) return try self.stageStaticConversion(id, source_type, context, expression.span);
            if (!is_literal and (self.options.allow_type_values or expression.operation == .local_read))
                return try self.stageStaticConversion(id, source_type, context, expression.span);
            const source_value = (try self.analysis_context.executeComptimeWithType(expression.source_node, source_type)) orelse return error.Unavailable;
            const candidate = (try self.selectConversion(source_type, target, source_value, expression.span)) orelse return null;
            return try self.convertValue(null, candidate, context, expression.span);
        }

        /// Compile-time-only values convert statically, except literals that default to `int`.
        fn needsStaticConversion(self: *Self, source_type: structures.TypeId, target: structures.TypeId) !bool {
            if (source_type == .int_literal and try self.literalDefaultTarget(target) != null) return false;
            return source_type != target and source_type != .never and source_type != .type and !try self.analysis_context.facts().isRuntimeCapable(source_type);
        }

        fn stringLiteralConversion(self: *Self, id: semantic.UnresolvedBody.ValueId, data: structures.ByteStringId, context: ValueContext, span: structures.SourceSpan) !?Value {
            const target = context.expected_type.?;
            if (try self.analysis_context.hasConverters(.string_literal, target)) {
                if (self.type_check_only) return try self.stageStaticConversion(id, .string_literal, context, span);
                const source_value = try self.analysis_context.internCompileTimeValue(.{ .runtime = .{ .type_id = .string_literal, .value = .{ .string_literal = data } } });
                if (try self.selectConversion(.string_literal, target, source_value, span)) |candidate| return try self.convertValue(null, candidate, context, span);
            }
            const static_string = try self.analysis_context.staticStringType();
            if (try semantic.canWidenTo(self.analysis_context, static_string, target)) return null;
            const candidate = (try self.selectConversion(static_string, target, null, span)) orelse return null;
            if (candidate.source_mode != .imm) return null;
            return try self.convertValue(try self.staticStringValue(data), candidate, context, span);
        }

        fn literalDefaultTarget(self: *Self, expected_type: ?structures.TypeId) !?structures.TypeId {
            const target = expected_type orelse return .int;
            if (target == .int) return target;
            const members = (try self.analysis_context.facts().variantMembers(target)) orelse return null;
            return if (std.mem.indexOfScalar(structures.TypeId, members, .int) != null) target else null;
        }

        fn stageStaticConversion(self: *Self, id: semantic.UnresolvedBody.ValueId, source_type: structures.TypeId, context: ValueContext, span: structures.SourceSpan) !Value {
            const source = try self.valueWithContext(id, .{ .expected_type = source_type, .allow_converters = false });
            return self.stageStaticValue(source, context, span);
        }

        fn stageStaticValue(self: *Self, source: Value, context: ValueContext, span: structures.SourceSpan) !Value {
            try self.recordUse(source);
            const destination = context.fresh_destination orelse try self.inPlaceStorage(context.expected_type.?);
            const converted = try self.appendInstruction(.{ .static_conversion = .{ .operand = source.id, .type_id = context.expected_type.?, .destination = if (destination) |storage| storage.id else null } });
            return try self.defineOwnedValue(destination orelse converted, span, false);
        }

        fn readLocal(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !Value {
            const index = @backingInt(local);
            try self.requireAvailablePlace(local, &.{}, span);
            if (self.locals.items(.reference)[index]) {
                const reference = self.state.values.get(index).?;
                return self.readReference(reference, (try self.analysis_context.facts().borrowElement(reference.type_id)).?);
            }
            return self.borrowLocalValue(local);
        }

        /// Rejects a use of a local, or of a field path within it, that was transferred or is being replaced.
        fn requireAvailablePlace(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan) !void {
            switch (self.state.availability.get(@backingInt(local))) {
                .unbound => unreachable,
                .available => {},
                .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
            }
            if (self.unavailableField(local, fields)) |availability| return self.reject(span, unavailableUse(availability));
        }

        fn borrowLocalValue(self: *Self, local: semantic.UnresolvedBody.LocalId) Value {
            var value_to_read = self.state.values.get(@backingInt(local)).?;
            value_to_read.writable = self.locals.items(.mutable)[@backingInt(local)];
            value_to_read.borrowed_generation = value_to_read.owned_generation orelse value_to_read.borrowed_generation;
            value_to_read.borrowed_cleanup_value = if (value_to_read.owned_generation != null) value_to_read.id else value_to_read.borrowed_cleanup_value orelse value_to_read.id;
            value_to_read.owned_generation = null;
            value_to_read.borrowed_type = value_to_read.type_id;
            value_to_read.borrow_root = local;
            return value_to_read;
        }

        fn explicitTransfer(transferred: Value) Value {
            var result = transferred;
            result.explicit_transfer = true;
            return result;
        }

        fn transferLocal(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan, destination: ?Value) !Value {
            if (self.locals.items(.reference)[@backingInt(local)]) return self.reject(span, .ownership_transfer_requires_owned_place);
            try self.validateInitializerWrite(local, span);
            const consumption_completion = try self.captureTransferParameter(local, &.{}, span);
            if (self.locals.items(.mut_parameter)[@backingInt(local)] != null and consumption_completion == null) return self.reject(span, .ownership_transfer_requires_owned_place);
            if (self.type_check_only) {
                const source = try self.readLocal(local, span);
                const viewed = try self.flowTypeView(source);
                try self.state.availability.set(self.gpa, @backingInt(local), .transferred);
                return destination orelse try self.localStorage(viewed.type_id);
            }
            var value_to_transfer = try self.flowOwned(try self.readLocal(local, span), span);
            value_to_transfer.consumption_completion = consumption_completion;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(value_to_transfer.type_id)) orelse return error.Unavailable;
            if (capabilities.move == .none) return self.reject(span, .{ .type_not_movable = value_to_transfer.type_id });
            try self.state.availability.set(self.gpa, @backingInt(local), .transferred);
            return self.moveValue(ownershipSource(value_to_transfer), span, destination);
        }

        fn captureTransferParameter(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan) !?structures.FunctionValueId {
            if (!self.is_initializer_region or self.captured_locals[@backingInt(local)] == null) return null;
            for (self.capture_transfers.items) |transfer| {
                const path: []const semantic.UnresolvedBody.FieldName = if (transfer.field) |field| self.field_places[field].fields else &.{};
                if (transfer.local == local and samePlacePath(path, fields)) return @fromBackingInt(@intCast(transfer.parameter));
            }
            return self.reject(span, .ownership_transfer_requires_owned_place);
        }

        fn samePlacePath(left: anytype, right: anytype) bool {
            return left.len == right.len and fieldPathContains(left, right);
        }

        fn fieldPathContains(prefix: anytype, path: anytype) bool {
            if (prefix.len > path.len) return false;
            for (prefix, path[0..prefix.len]) |left, right| {
                if (!std.mem.eql(u8, left.name, right.name)) return false;
            }
            return true;
        }

        fn unavailableField(self: *const Self, local: semantic.UnresolvedBody.LocalId, path: anytype) ?Availability {
            for (self.field_places, 0..self.state.field_availability.len) |place, flow_availability_index| {
                const availability = self.state.field_availability.get(flow_availability_index);
                if (place.local != local or availability == .available) continue;
                if (fieldPathContains(place.fields, path) or fieldPathContains(path, place.fields)) return availability;
            }
            return null;
        }

        const FieldTransfer = union(enum) { move: ?Value, consume };

        fn transferFieldProjection(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, path: []const structures.ReferencePathStep, span: structures.SourceSpan, transfer: FieldTransfer) !Value {
            if (self.locals.items(.reference)[@backingInt(local)]) return self.reject(span, .ownership_transfer_requires_owned_place);
            for (fields) |field| if (field.kind == .reference) return self.reject(span, .ownership_transfer_requires_owned_place);
            try self.validateInitializerWrite(local, span);
            const consumption_completion = try self.captureTransferParameter(local, fields, span);
            const local_index = @backingInt(local);
            const mutable_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            try self.requireAvailablePlace(local, fields, span);
            const root = self.state.values.get(local_index).?;
            const field_type = fields[fields.len - 1].type_id;
            const field_capabilities = (try self.analysis_context.facts().ownershipCapabilities(field_type)) orelse return error.Unavailable;
            if (transfer == .move and field_capabilities.move == .none) return self.reject(span, .{ .type_not_movable = field_type });
            const moves_owner = field_capabilities.needs_automatic_drop or field_capabilities.requires_explicit_drop;
            try self.validateMissingProjectionParents(local, path, span);
            try self.recordUse(root);
            if (moves_owner and !mutable_parameter) try self.recordConsume(root);
            var field = try self.projectOwnedPath(root, path);
            field.consumption_completion = consumption_completion;
            const moved = switch (transfer) {
                .move => |destination| try self.moveValue(field, span, destination),
                .consume => blk: {
                    var consumed = if (consumption_completion == null) try self.defineOwnedValue(field, span, false) else rawValue(field);
                    consumed.reference_origins = field.reference_origins;
                    consumed.consumption_completion = consumption_completion;
                    break :blk consumed;
                },
            };
            for (self.field_places, 0..) |*place, field_index| {
                if (place.local == local and samePlacePath(place.fields, fields)) {
                    place.moves_owner = moves_owner;
                    try self.state.field_availability.set(self.gpa, field_index, .transferred);
                }
            }
            if (moves_owner and !mutable_parameter and consumption_completion == null) {
                var remaining_generation: ?GenerationId = null;
                const previous_missing = if (root.owned_generation) |previous| self.generations.items[@backingInt(previous)].missing_fields else &.{};
                var missing: std.ArrayList([]const structures.ReferencePathStep) = .empty;
                try missing.appendSlice(self.gpa, previous_missing);
                try missing.append(self.gpa, path);
                if ((try cleanup_shape.obligations(self.gpa, self.analysis_context, root.type_id, &.{}, missing.items, missing.items.len != 0)).any()) {
                    const remaining = try self.defineOwnedValue(root, span, self.locals.items(.can_deinit)[local_index]);
                    remaining_generation = remaining.owned_generation;
                    if (root.owned_generation) |previous| try self.mergeVariantCleanup(remaining_generation.?, &.{previous});
                    try self.copyMissingPaths(remaining_generation.?, previous_missing, path, null);
                }
                try self.updateLocal(local_index, .{ .owned_generation = remaining_generation });
            }
            try self.updateLocal(local_index, .{ .binding_identity = try self.newBindingIdentity(), .storage_identity = null });
            return moved;
        }

        fn validateMissingFieldParents(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan) !void {
            return self.validateMissingProjectionParents(local, try self.ownershipFieldPath(fields), span);
        }

        fn validateMissingProjectionParents(self: *Self, local: semantic.UnresolvedBody.LocalId, path: []const structures.ReferencePathStep, span: structures.SourceSpan) !void {
            const local_index = @backingInt(local);
            const mutable_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            var parent_type = self.state.values.get(local_index).?.type_id;
            for (path, 0..) |step, depth| {
                const parent_capabilities = (try self.analysis_context.facts().ownershipCapabilities(parent_type)) orelse return error.Unavailable;
                const deinit_root = depth == 0 and self.locals.items(.can_deinit)[local_index];
                if (!deinit_root and parent_capabilities.drop != .fieldwise and parent_capabilities.drop != .trivial and
                    !(mutable_parameter and parent_capabilities.drop == .custom))
                    return self.reject(span, .partial_field_transfer_not_supported);
                if (parent_capabilities.needs_custom_move and !deinit_root)
                    return self.reject(span, .partial_field_transfer_not_supported);
                parent_type = (try cleanup_shape.typeAt(self.analysis_context, parent_type, &.{step})) orelse return self.reject(span, .ownership_transfer_requires_owned_place);
            }
        }

        fn remainingFieldOwnership(self: *Self, type_id: structures.TypeId, missing: []const []const structures.ReferencePathStep, moved: []const PlaceField) !cleanup_shape.Obligations {
            var paths: std.ArrayList([]const structures.ReferencePathStep) = .empty;
            try paths.appendSlice(self.gpa, missing);
            if (moved.len != 0) try paths.append(self.gpa, try self.ownershipFieldPath(moved));
            return cleanup_shape.obligations(self.gpa, self.analysis_context, type_id, &.{}, paths.items, paths.items.len != 0);
        }

        fn ownershipFieldPath(self: *Self, fields: []const PlaceField) ![]const structures.ReferencePathStep {
            const path = try self.gpa.alloc(structures.ReferencePathStep, fields.len);
            for (fields, path) |field, *step| step.* = .{ .field = field.index };
            return path;
        }

        fn writeMutParameters(self: *Self) !void {
            for (self.locals.items(.mut_parameter), 0..) |mut_parameter, local_index| {
                const index = mut_parameter orelse continue;
                if (self.is_initializer_region and self.captured_locals[local_index] != null) continue;
                if (self.state.availability.get(local_index) != .available) return self.reject(self.activeLifetimeSpan(), unavailableUse(self.state.availability.get(local_index)));
                for (self.field_places, 0..) |place, field| {
                    if (@backingInt(place.local) == local_index and self.state.field_availability.get(field) != .available)
                        return self.reject(self.activeLifetimeSpan(), .field_not_restored_before_mut_return);
                }
                const value_to_write = self.state.values.get(local_index).?;
                try self.validateEscapingBorrows(value_to_write, self.activeLifetimeSpan());
                if (try self.analysis_context.facts().canStoreBorrow(value_to_write.type_id)) {
                    try self.recordUse(value_to_write);
                    try self.recordOutputOrigins(index, value_to_write.reference_origins);
                }
                if (self.is_initializer_region) _ = try self.appendInstruction(.{ .value_copy = .{
                    .destination = @fromBackingInt(index),
                    .source = value_to_write.id,
                    .type_id = value_to_write.type_id,
                } });
            }
        }

        fn recordOutputOrigins(self: *Self, parameter: u32, origins: ?u32) !void {
            const entry = try self.capture_output_origins.getOrPut(self.gpa, parameter);
            if (!entry.found_existing) entry.value_ptr.* = null;
            entry.value_ptr.* = try self.mergeReferenceOrigins(entry.value_ptr.*, origins);
        }

        fn writeCapturedLocal(self: *Self, local: semantic.UnresolvedBody.LocalId) !void {
            if (!self.is_initializer_region) return;
            const parameter = self.captured_locals[@backingInt(local)] orelse return;
            const updated = self.state.values.get(@backingInt(local)).?;
            try self.recordOutputOrigins(parameter, updated.reference_origins);
            _ = try self.appendInstruction(.{ .value_copy = .{ .destination = @fromBackingInt(parameter), .source = updated.id, .type_id = updated.type_id } });
        }

        fn usesIndirectStorage(self: *Self, type_id: structures.TypeId) !bool {
            return try self.analysis_context.facts().argumentPassing(type_id) == .indirect;
        }

        fn localStorage(self: *Self, type_id: structures.TypeId) !Value {
            return self.appendInstruction(.{ .local_storage = type_id });
        }

        fn valueUsesStorage(self: *Self, source: Value) !bool {
            return source.representation == .storage or try self.usesIndirectStorage(source.type_id);
        }

        fn pinLocalStorage(self: *Self, local: semantic.UnresolvedBody.LocalId) !Value {
            const index = @backingInt(local);
            const previous = self.state.values.get(index).?;
            if (try self.valueUsesStorage(previous)) return previous;
            try self.recordUse(previous);
            var storage = try self.localStorage(previous.type_id);
            _ = try self.copyBits(rawValue(previous), storage);
            storage = try self.updateOwnedValue(previous, storage);
            storage.representation = .storage;
            storage.binding_identity = previous.binding_identity;
            storage.storage_identity = previous.storage_identity;
            storage.variant_identity = previous.variant_identity;
            storage.predicate = previous.predicate;
            storage.reference_origins = previous.reference_origins;
            storage.local_reference = previous.local_reference;
            try self.state.values.set(self.gpa, index, storage);
            try self.rememberCleanupOrigins(storage);
            return storage;
        }

        /// Parameters have no source expression.
        fn expressionOperation(self: *const Self, id: semantic.UnresolvedBody.ValueId) ?*const Expression.Operation {
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) return null;
            return &self.unresolved.expressions[index - self.unresolved.parameter_count].operation;
        }

        fn valueSpan(self: *const Self, id: semantic.UnresolvedBody.ValueId) structures.SourceSpan {
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) return self.unresolved.parameter_spans[index];
            return self.unresolved.expressions[index - self.unresolved.parameter_count].span;
        }

        fn initializationMismatch(self: *Self, site: InitializationSite, expected: structures.TypeId, found: structures.TypeId) structures.Diagnostic.Kind {
            const mismatch = self.typeMismatch(expected, found);
            return switch (site) {
                .local => .{ .local_type_mismatch = mismatch },
                .field => .{ .struct_initializer_field_type_mismatch = mismatch },
                .argument => .{ .call_argument_type_mismatch = mismatch },
                .assignment => .{ .assignment_type_mismatch = mismatch },
                .return_value => .{ .return_type_mismatch = mismatch },
            };
        }

        fn construct(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan, destination: Destination) anyerror!Value {
            return self.evaluateValue(id, .{ .destination = destination, .destination_span = span });
        }

        fn constructsDirectly(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: structures.TypeId) !bool {
            if (self.values.get(@backingInt(id)) != null) return false;
            const operation = self.expressionOperation(id) orelse return false;
            if (operation.* != .struct_init and !try self.usesIndirectStorage(expected_type)) return false;
            if (operation.* == .struct_init or operation.* == .array_init or operation.* == .call) if (try self.unevaluatedType(id, null)) |source_type| {
                if (source_type != expected_type and source_type != .never and !try semantic.canWidenTo(self.analysis_context, source_type, expected_type)) return false;
            };
            return switch (operation.*) {
                .struct_init, .array_init, .collection_literal, .tuple_literal, .call, .if_else, .match, .loop, .scope, .annotation, .local_transfer, .field_transfer => true,
                else => false,
            };
        }

        fn placeEvaluated(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan, destination: Destination) !Value {
            const source = try self.evaluateUncapturedValue(id, .{ .value = .{ .expected_type = destination.storage.type_id, .access = .initialize, .fresh_destination = destination.storage } });
            if (source.id == destination.storage.id) return source;
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            const placed = try self.placeValue(source, span, destination);
            if (self.current_block != null) try self.closeBoundary(scope.boundary);
            return placed;
        }

        fn placeValue(self: *Self, source: Value, span: structures.SourceSpan, destination: Destination) !Value {
            if (source.type_id == .never) return source;
            const target_type = destination.storage.type_id;
            if (!try self.usesIndirectStorage(source.type_id)) {
                var use = try self.coerceValue(source.id, source.type_id, target_type) orelse
                    return self.reject(span, self.initializationMismatch(destination.site, target_type, source.type_id));
                const owned = try self.ownValue(source, span);
                use.value = owned.id;
                if (use.coerce_to == null)
                    _ = try self.copyBits(owned, destination.storage)
                else
                    _ = try self.appendCoercion(use, destination.storage.id);
                try self.recordConsume(owned);
                var placed = try self.defineOwnedValue(destination.storage, span, false);
                placed.reference_origins = try self.coercedReferenceOrigins(owned, use);
                return placed;
            }
            const storage = try self.memberDestination(destination, source.type_id, span, .existing);
            if (source.borrowed_type == null or source.borrow_condition != null)
                return self.reject(span, .{ .relocation_requires_direct_move = source.type_id });
            if (try self.nonCopyableBorrow(source)) |details| return self.reject(span, .{ .type_not_copyable = details });
            return self.finishMemberStorage(try self.copyValue(source, span, storage), destination.storage, span);
        }

        fn memberStorage(self: *Self, destination: Value, source_type: structures.TypeId) !?Value {
            if (source_type == destination.type_id) return destination;
            const members = (try self.analysis_context.facts().variantMembers(destination.type_id)) orelse return null;
            if (try self.analysis_context.facts().variantMembers(source_type) != null or !containsType(members, source_type)) return null;
            return try self.projectStorage(destination, source_type, .variant);
        }

        fn memberDestination(self: *Self, destination: Destination, source_type: structures.TypeId, span: structures.SourceSpan, source: enum { fresh, existing }) !Value {
            if (try self.memberStorage(destination.storage, source_type)) |storage| return storage;
            if (!try semantic.canWidenTo(self.analysis_context, source_type, destination.storage.type_id))
                return self.reject(span, self.initializationMismatch(destination.site, destination.storage.type_id, source_type));
            if (source == .existing and try self.analysis_context.facts().variantMembers(source_type) != null) return destination.storage;
            return self.reject(span, .{ .relocation_requires_direct_move = source_type });
        }

        fn finishMemberStorage(self: *Self, member: Value, destination: Value, span: structures.SourceSpan) !Value {
            if (member.type_id == .never or member.id == destination.id) return member;
            const use = (try self.coerceValue(member.id, member.type_id, destination.type_id)).?;
            _ = try self.appendCoercion(use, destination.id);
            try self.recordConsume(member);
            var result = try self.defineOwnedValue(destination, span, false);
            result.reference_origins = try self.transformReferenceOrigins(member.reference_origins, .{ .prefix = .{ .variant = member.type_id } });
            return result;
        }

        fn constructStruct(self: *Self, expression: Expression, destination: ?Destination) !Value {
            const type_id = switch (try self.structInitType(expression.operation.struct_init)) {
                .diverged => |diverged| return diverged,
                .type_id => |resolved| resolved,
            };
            if (try self.analysis_context.isCollectionConstructionType(type_id)) return self.reject(expression.span, .{ .compile_time_only_type = type_id });
            const target = destination orelse return self.constructFields(expression, type_id, try self.localStorage(type_id));
            const storage = try self.memberDestination(target, type_id, expression.span, .fresh);
            return self.finishMemberStorage(try self.constructFields(expression, type_id, storage), target.storage, expression.span);
        }

        fn constructFields(self: *Self, expression: Expression, type_id: structures.TypeId, storage: Value) !Value {
            const initializer = expression.operation.struct_init;
            const definition = try self.structInitializerDefinition(initializer, type_id);
            const seen = try self.gpa.alloc(bool, definition.fields.len);

            @memset(seen, false);
            var fields: std.ArrayList(Value) = .empty;
            var reference_origins: ?u32 = null;
            for (self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |source_field| {
                const field = definition.resolveField(source_field.name).?;
                if (seen[field.index]) return self.reject(source_field.name_span, .duplicate_struct_initializer_field);
                seen[field.index] = true;
                const declared_field = definition.fields[field.index];
                const storage_type = try self.analysis_context.facts().fieldStorageType(declared_field);
                const field_storage = try self.projectStorage(storage, storage_type, .{ .field = field.index });
                const field_value = try self.constructMember(source_field.value, declared_field.kind, field.type_id, field_storage);
                if (field_value.type_id == .never) return field_value;
                try fields.append(self.gpa, field_value);
                if (declared_field.kind == .reference or try self.analysis_context.facts().canStoreBorrow(field.type_id))
                    reference_origins = try self.mergeReferenceOrigins(reference_origins, try self.transformReferenceOrigins(field_value.reference_origins, .{ .prefix = .{ .field = field.index } }));
            }
            for (seen, 0..) |was_seen, field_index| if (!was_seen) return self.reject(initializer.type_span, .{ .missing_struct_initializer_field = .{
                .type_id = type_id,
                .field_index = @intCast(field_index),
            } });
            for (fields.items) |field_value| try self.recordConsume(field_value);
            var constructed = try self.defineOwnedValue(storage, expression.span, false);
            constructed.reference_origins = reference_origins;
            return constructed;
        }

        fn tupleType(self: *Self, elements: structures.FunctionValueRange, expected_type: ?structures.TypeId, span: structures.SourceSpan) !structures.TypeId {
            const expected = expected_type orelse {
                var members: std.ArrayList(structures.MemberSpec) = .empty;
                for (self.unresolved.call_arguments[elements.start..elements.end]) |source| {
                    const type_id = (try self.unevaluatedType(source.value, null)) orelse try self.inferInitializerType(source, null);
                    if (type_id == .never) return .never;
                    try members.append(self.gpa, .{ .type_id = type_id });
                }
                return self.analysis_context.facts().internTuple(members.items);
            };
            if (try self.analysis_context.facts().tupleMembers(expected) != null) return expected;
            const alternatives = (try self.analysis_context.facts().variantMembers(expected)) orelse return self.reject(span, .tuple_context_not_tuple);
            var selected: ?structures.TypeId = null;
            for (alternatives) |alternative| {
                const member = try self.analysis_context.facts().memberSpec(alternative);
                if (member.kind != .owned or try self.analysis_context.facts().tupleMembers(member.type_id) == null) continue;
                if (selected != null) return self.reject(span, .{ .ambiguous_variant_member = self.typeMismatch(expected, member.type_id) });
                selected = member.type_id;
            }
            return selected orelse self.reject(span, .tuple_context_not_tuple);
        }

        fn constructTuple(self: *Self, expression: Expression, elements: structures.FunctionValueRange, context: ValueContext) !Value {
            const type_id = try self.tupleType(elements, context.expected_type, expression.span);
            if (type_id == .never) {
                for (self.unresolved.call_arguments[elements.start..elements.end]) |source| {
                    const value_to_check = try self.valueWithContext(source.value, .{ .access = .initialize });
                    if (value_to_check.type_id == .never) return value_to_check;
                }
                unreachable;
            }
            const members = (try self.analysis_context.facts().tupleMembers(type_id)).?;
            const sources = self.unresolved.call_arguments[elements.start..elements.end];
            if (sources.len != members.len) return self.reject(expression.span, .{ .tuple_member_count_mismatch = .{ .expected = @intCast(members.len), .found = @intCast(sources.len) } });
            const destination = context.fresh_destination orelse try self.localStorage(type_id);
            const storage = try self.memberDestination(.{ .storage = destination, .site = .local }, type_id, expression.span, .fresh);
            var completed: std.ArrayList(Value) = .empty;
            var origins: ?u32 = null;
            for (members, sources, 0..) |member, source, index| {
                const field_storage = try self.projectStorage(storage, try self.analysis_context.facts().memberStorageType(member), .{ .field = @intCast(index) });
                const element = try self.constructMember(source, member.kind, member.type_id, field_storage);
                if (element.type_id == .never) return element;
                try completed.append(self.gpa, element);
                origins = try self.mergeReferenceOrigins(origins, try self.transformReferenceOrigins(element.reference_origins, .{ .prefix = .{ .field = @intCast(index) } }));
            }
            for (completed.items) |element| try self.recordConsume(element);
            var result = try self.defineOwnedValue(storage, expression.span, false);
            result.reference_origins = origins;
            return self.finishMemberStorage(result, destination, expression.span);
        }

        /// Places an aggregate member; a reference member captures its source place.
        fn constructMember(self: *Self, source: semantic.UnresolvedBody.ValueUse, kind: structures.MemberKind, type_id: structures.TypeId, storage: Value) !Value {
            if (kind != .reference) return self.construct(source.value, source.span, .{ .storage = storage, .site = .field });
            const reference = try self.captureReference(source);
            if (reference.type_id == .never) return reference;
            const element = (try self.analysis_context.facts().borrowElement(reference.type_id)).?;
            if (element != type_id) return self.reject(source.span, .{ .struct_initializer_field_type_mismatch = self.typeMismatch(type_id, element) });
            return self.placeValue(reference, source.span, .{ .storage = storage, .site = .field });
        }

        fn collectionValue(self: *Self, id: semantic.UnresolvedBody.ValueId, expression: Expression, elements: structures.FunctionValueRange, context: ValueContext) !Value {
            const captures = self.initializerCaptureScope();
            defer self.endInitializerCaptureScope(captures);
            const array_type = try self.collectionType(elements, context.expected_type, expression.span);
            if (self.optional_collection_allocation and context.expected_type != null) {
                const target = (try @import("../intrinsics.zig").optionalPayload(self.analysis_context.facts(), context.expected_type.?)) orelse context.expected_type.?;
                if (try self.analysis_context.facts().listElement(target) != null) return self.constructDynamicCollection(expression, target, context);
            }
            if (try self.analysis_context.facts().arrayType(array_type) == null) return self.constructDynamicCollection(expression, array_type, context);
            if (!context.allow_converters) {
                var result = try self.constructArrayElements(expression, array_type, elements, .{ .storage = context.fresh_destination orelse try self.localStorage(array_type), .site = .local });
                if (context.expected_type) |expected| if (expected != array_type and result.type_id != .never and try self.analysis_context.facts().collectionLiteralType(expected) == null) {
                    std.debug.assert(self.type_check_only);
                    const source_type = try self.analysis_context.internCollectionLiteralType((try self.analysis_context.facts().arrayType(array_type)).?);
                    const candidates = try self.analysis_context.conversionCandidates(source_type, expected, null);

                    if (candidates.len == 1) result.type_id = candidates[0].target_type;
                };
                return result;
            }
            const shape = (try self.analysis_context.facts().arrayType(array_type)).?;
            const source_type = try self.analysis_context.internCollectionLiteralType(shape);
            const target = context.expected_type orelse array_type;
            const conversion_target = if (try semantic.canWidenTo(self.analysis_context, array_type, target)) array_type else target;
            const candidates = try self.analysis_context.conversionCandidates(source_type, conversion_target, null);

            if (candidates.len != 1) return self.reject(expression.span, if (candidates.len > 1) .{ .ambiguous_conversion = self.typeMismatch(target, source_type) } else .{ .local_type_mismatch = self.typeMismatch(target, source_type) });
            const initializer = try self.prepareInitializer(.{ .value = id, .span = expression.span }, source_type);
            var target_context = context;
            target_context.expected_type = target;
            return self.convertValue(initializer, candidates[0], target_context, expression.span);
        }

        const CollectionEmission = struct {
            expected: ?structures.TypeId = null,
            inferred: ?structures.TypeId = null,
            sink: ?semantic.UnresolvedBody.LocalId = null,
            bounded: bool = false,
            upper_bound: ?u32 = 0,
            multiplier: ?u32 = 1,
        };
        const CollectionEmissionShape = struct { element_type: ?structures.TypeId, upper_bound: ?u32 };

        fn collectionIteration(self: *Self, iteration: @FieldType(Expression.Operation, "collection_iteration")) !Value {
            const emission = self.collection_emission orelse unreachable;
            const previous = emission.multiplier;
            defer emission.multiplier = previous;
            if (emission.sink == null) {
                const source_type = try self.inferArgumentType(iteration.source);
                if (previous) |factor| {
                    emission.multiplier = if (try self.analysis_context.facts().arrayType(source_type)) |array|
                        std.math.mul(u32, factor, array.length) catch null
                    else
                        null;
                }
            }
            return self.value(iteration.body.value);
        }

        /// Comprehensions and spreads emit any number of elements through a collection sink.
        fn emitsElements(self: *Self, id: semantic.UnresolvedBody.ValueId) bool {
            const operation = self.expressionOperation(id) orelse return false;
            return operation.* == .collection_comprehension or operation.* == .collection_spread;
        }

        /// Upper bounds become unknown instead of overflowing.
        fn addBound(left: ?u32, right: ?u32) ?u32 {
            return std.math.add(u32, left orelse return null, right orelse return null) catch null;
        }

        fn collectionLength(self: *Self, elements: structures.FunctionValueRange, span: structures.SourceSpan) !?u32 {
            var count: u32 = 0;
            for (self.unresolved.call_arguments[elements.start..elements.end]) |element| {
                const operation = self.expressionOperation(element.value);
                var added: u32 = 1;
                if (operation) |entry| switch (entry.*) {
                    .collection_comprehension => return null,
                    .collection_spread => |spread| {
                        const type_id = (try self.unevaluatedType(spread.source.value, null)) orelse try self.inferArgumentType(spread.source);
                        const array = (try self.analysis_context.facts().arrayType(type_id)) orelse return null;
                        added = array.length;
                    },
                    else => {},
                };
                count = std.math.add(u32, count, added) catch return self.reject(span, .collection_size_out_of_range);
                if (count > std.math.maxInt(i32)) return self.reject(span, .collection_size_out_of_range);
            }
            return count;
        }

        fn inferCollectionEmission(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected: ?structures.TypeId) anyerror!CollectionEmissionShape {
            var region = self.initializerRegion(.unit);
            region.type_check_only = true;
            try self.bindInferenceCaptures(&region, raw.value);
            var emission: CollectionEmission = .{ .expected = expected };
            region.collection_emission = &emission;
            _ = try region.value(raw.value);
            return .{ .element_type = emission.inferred, .upper_bound = emission.upper_bound };
        }

        fn joinCollectionElement(self: *Self, current: ?structures.TypeId, next_type: structures.TypeId) !structures.TypeId {
            var next = next_type;
            if (next == .int_literal) next = .int;
            if (next == .string_literal) next = try self.analysis_context.stringType();
            return if (current) |previous| joinTypes(self.analysis_context, previous, next, self.gpa) else next;
        }

        fn expectedListElement(self: *Self, expected: structures.TypeId) !?structures.TypeId {
            if (try self.analysis_context.facts().listElement(expected)) |element| return element;
            const members = (try self.analysis_context.facts().variantMembers(expected)) orelse return null;
            var element: ?structures.TypeId = null;
            for (members) |member| if (try self.analysis_context.facts().listElement(member)) |candidate| {
                if (element != null and element.? != candidate) return null;
                element = candidate;
            };
            return element;
        }

        fn collectionType(self: *Self, elements: structures.FunctionValueRange, expected_type: ?structures.TypeId, span: structures.SourceSpan) !structures.TypeId {
            const length = try self.collectionLength(elements, span);
            var element_type: ?structures.TypeId = null;
            if (expected_type) |expected| {
                if ((try self.analysis_context.facts().arrayType(expected)) orelse try self.analysis_context.facts().collectionLiteralType(expected)) |array| element_type = array.element_type;
                if (element_type == null and length != null) element_type = try self.analysis_context.contextualCollectionElement(expected, length.?, span);
                if (element_type == null and length == null) element_type = try self.expectedListElement(expected);
            }
            const contextual = element_type;
            for (self.unresolved.call_arguments[elements.start..elements.end]) |element| {
                const inferred: ?structures.TypeId = if (self.emitsElements(element.value))
                    (try self.inferCollectionEmission(element, contextual)).element_type
                else
                    try self.inferInitializerType(element, contextual);
                if (contextual == null) if (inferred) |next| {
                    element_type = try self.joinCollectionElement(element_type, next);
                };
            }
            const result_element = element_type orelse return self.reject(span, .expression_not_supported);
            if (length) |count| return self.analysis_context.internArrayType(.{ .element_type = result_element, .length = count });
            if (expected_type) |expected| if (try self.analysis_context.facts().arrayType(expected) != null) return self.reject(span, .collection_requires_static_count);
            return self.analysis_context.listType(result_element);
        }

        fn emitCollectionElement(self: *Self, output: @FieldType(Expression.Operation, "collection_emit")) !Value {
            const element = output.element;
            const emission = self.collection_emission orelse unreachable;
            if (emission.sink != null) {
                const item_type = emission.expected.?;
                if (item_type == .never) return self.valueWithContext(element.value, .{ .expected_type = item_type, .access = .initialize });
                const item = (try self.analysis_context.stdMemoryFunction(if (emission.bounded) "append_collection_bounded" else if (self.optional_collection_allocation) "append_collection_optional" else "append_collection_growing")) orelse return error.Unavailable;
                const argument = try self.analysis_context.internCompileTimeValue(.{ .type = item_type });
                const instance = try self.analysis_context.specializeFunction(.{ .item = item }, &.{argument});
                const call: semantic.UnresolvedBody.Call = .{ .target = .{ .direct = instance }, .arguments = .{ .start = 0, .end = 0 }, .span = element.span };
                const resolved = try self.resolveCall(call, element.span, &.{ output.sink, element });
                return switch (resolved) {
                    .diverged => |value_to_return| value_to_return,
                    .callable => |callable| self.collectionAllocationResult(try self.resolvedCallResult(callable, call, element.span, .{}), .unit, element.span),
                };
            }
            const inferred = try self.inferInitializerType(element, emission.expected);
            emission.inferred = try self.joinCollectionElement(emission.inferred, emission.expected orelse inferred);
            emission.upper_bound = addBound(emission.upper_bound, emission.multiplier);
            return self.appendInstruction(.const_unit);
        }

        fn emitCollectionSpread(self: *Self, spread: @FieldType(Expression.Operation, "collection_spread"), _: structures.SourceSpan) !Value {
            const emission = self.collection_emission orelse unreachable;
            if (emission.sink == null) {
                const source_type = (try self.unevaluatedType(spread.source.value, null)) orelse try self.inferArgumentType(spread.source);
                if (try self.analysis_context.facts().arrayType(source_type)) |array| {
                    emission.inferred = try self.joinCollectionElement(emission.inferred, emission.expected orelse array.element_type);
                    if (emission.upper_bound != null) {
                        const repeated = if (emission.multiplier) |multiplier| std.math.mul(u32, array.length, multiplier) catch return error.AnalysisTooLarge else null;
                        emission.upper_bound = addBound(emission.upper_bound, repeated);
                    }
                    return self.appendInstruction(.const_unit);
                }
            }
            return self.valueWithContext(spread.iteration.value, .{});
        }

        fn collectionAllocationResult(self: *Self, result: Value, target: structures.TypeId, span: structures.SourceSpan) !Value {
            if (result.type_id == target or result.type_id == .never) return result;
            std.debug.assert(self.optional_collection_allocation);
            const members = (try self.analysis_context.facts().variantMembers(result.type_id)).?;
            const matched = try self.newEmptyBlock();
            const unmatched = try self.newEmptyBlock();
            try self.branchOnMembers(result, members, target, null, matched, unmatched);
            const state = try self.captureState();
            self.enterBlock(unmatched);
            self.restoreState(state);
            try self.returnValue(try self.appendInstruction(.const_none), span);
            self.enterBlock(matched);
            self.restoreState(state);
            return self.extractOwnedVariant(result, target, span);
        }

        fn constructDynamicCollection(self: *Self, expression: Expression, type_id: structures.TypeId, context: ValueContext) !Value {
            const literal = expression.operation.collection_literal;
            const element_type = (try self.analysis_context.facts().listElement(type_id)).?;
            const factory = (try self.analysis_context.stdMemoryFunction(if (self.optional_collection_allocation) "new_collection_list_optional" else "new_collection_list")) orelse return error.Unavailable;
            const element_argument = try self.analysis_context.internCompileTimeValue(.{ .type = element_type });
            var upper_bound: ?u32 = 0;
            for (self.unresolved.call_arguments[literal.elements.start..literal.elements.end]) |entry| {
                const bound: ?u32 = if (self.emitsElements(entry.value)) (try self.inferCollectionEmission(entry, element_type)).upper_bound else 1;
                upper_bound = addBound(upper_bound, bound);
            }
            if (upper_bound != null and upper_bound.? > std.math.maxInt(i32)) return error.AnalysisTooLarge;
            const count_argument = try self.analysis_context.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(upper_bound orelse 0) } } });
            const instance = try self.analysis_context.specializeFunction(.{ .item = factory }, &.{ element_argument, count_argument });
            const setup = try self.openBoundary(expression.span);
            defer self.current_boundary = setup.parent;
            var list = try self.callFunction(.{ .target = .{ .direct = instance }, .arguments = .{ .start = 0, .end = 0 }, .span = expression.span }, expression.span, .{ .value = .{ .access = .initialize } });
            list = try self.collectionAllocationResult(list, type_id, expression.span);
            if (list.type_id == .never) return list;
            list.binding_identity = try self.newBindingIdentity();
            const local = @backingInt(literal.sink);
            try self.state.values.set(self.gpa, local, list);
            try self.state.availability.set(self.gpa, local, .available);
            self.locals.items(.mutable)[local] = true;
            _ = try self.pinLocalStorage(literal.sink);
            try self.closeBoundary(setup.boundary);
            self.current_boundary = setup.parent;
            var emission: CollectionEmission = .{ .expected = element_type, .sink = literal.sink, .bounded = upper_bound != null };
            const previous = self.collection_emission;
            self.collection_emission = &emission;
            defer self.collection_emission = previous;
            for (self.unresolved.call_arguments[literal.elements.start..literal.elements.end], self.unresolved.call_arguments[literal.sink_reads.start..literal.sink_reads.end]) |element, sink_read| {
                const item = try self.openBoundary(element.span);
                const emitted = if (self.emitsElements(element.value))
                    try self.value(element.value)
                else
                    try self.emitCollectionElement(.{ .element = element, .sink = sink_read });
                if (emitted.type_id == .never) return emitted;
                try self.closeBoundary(item.boundary);
                self.current_boundary = item.parent;
            }
            const destination = if (context.fresh_destination != null and try semantic.canWidenTo(self.analysis_context, type_id, context.fresh_destination.?.type_id))
                try self.memberDestination(.{ .storage = context.fresh_destination.?, .site = .local }, type_id, expression.span, .existing)
            else
                null;
            const moved = try self.transferLocal(literal.sink, expression.span, destination);
            const result = if (destination != null) try self.finishMemberStorage(moved, context.fresh_destination.?, expression.span) else moved;
            return self.contextualValue(result, context, expression.span);
        }

        fn constructArrayElements(self: *Self, expression: Expression, type_id: structures.TypeId, elements: structures.FunctionValueRange, destination: Destination) !Value {
            const array = (try self.analysis_context.facts().arrayType(type_id)) orelse unreachable;
            const storage = try self.memberDestination(destination, type_id, expression.span, .fresh);
            var completed: std.ArrayList(Value) = .empty;
            var origins: ?u32 = null;
            var index: u32 = 0;
            for (self.unresolved.call_arguments[elements.start..elements.end]) |source| {
                if (self.expressionOperation(source.value)) |entry| if (entry.* == .collection_spread) {
                    const spread = entry.collection_spread;
                    const spread_scope = try self.openBoundary(source.span);
                    const source_value = try self.value(spread.source.value);
                    if (source_value.type_id == .never) return source_value;
                    const source_shape = (try self.analysis_context.facts().arrayType(source_value.type_id)).?;
                    for (0..source_shape.length) |offset| {
                        const source_position = try self.appendInstruction(.{ .const_int = @intCast(offset) });
                        var borrowed = try self.arrayElement(source_value, source_position, source_shape.element_type);
                        borrowed.borrowed_type = borrowed.type_id;
                        borrowed.reference_origins = try self.transformReferenceOrigins(source_value.reference_origins, .{ .select = .{ .element_at = .{ .offset = @intCast(offset) } } });
                        const position = try self.appendInstruction(.{ .const_int = @intCast(index) });
                        const element_storage = try self.arrayElement(storage, position, array.element_type);
                        const converted = try self.contextualValue(borrowed, .{ .expected_type = array.element_type, .access = .initialize, .fresh_destination = element_storage }, source.span);
                        const element = if (converted.id == element_storage.id) converted else try self.placeValue(converted, source.span, .{ .storage = element_storage, .site = .field });
                        if (element.type_id == .never) return element;
                        try completed.append(self.gpa, element);
                        origins = try self.mergeReferenceOrigins(origins, try self.transformReferenceOrigins(element.reference_origins, .{ .prefix = .{ .element_at = .{ .offset = @intCast(index) } } }));
                        index += 1;
                    }
                    try self.recordUse(source_value);
                    try self.closeBoundary(spread_scope.boundary);
                    self.current_boundary = spread_scope.parent;
                    continue;
                };
                const position = try self.appendInstruction(.{ .const_int = @intCast(index) });
                const element_storage = try self.arrayElement(storage, position, array.element_type);
                const element = try self.construct(source.value, source.span, .{ .storage = element_storage, .site = .field });
                if (element.type_id == .never) return element;
                try completed.append(self.gpa, element);
                origins = try self.mergeReferenceOrigins(origins, try self.transformReferenceOrigins(element.reference_origins, .{ .prefix = .{ .element_at = .{ .offset = @intCast(index) } } }));
                index += 1;
            }
            for (completed.items) |element| try self.recordConsume(element);
            var result = try self.defineOwnedValue(storage, expression.span, false);
            result.reference_origins = origins;
            return self.finishMemberStorage(result, destination.storage, expression.span);
        }

        fn constructAnnotated(self: *Self, annotation: @FieldType(Expression.Operation, "annotation"), destination: Destination) !Value {
            const storage = try self.memberStorage(destination.storage, annotation.type_id) orelse
                return self.placeValue(try self.annotate(annotation, .{ .access = .initialize }), annotation.value.span, destination);
            const annotated = try self.construct(annotation.value.value, annotation.value.span, .{ .storage = storage, .site = .local });
            return self.finishMemberStorage(annotated, destination.storage, annotation.value.span);
        }

        fn constructLocalTransfer(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan, destination: ?Destination) !Value {
            const target = destination orelse return self.transferLocal(local, span, null);
            const source_type = (try self.flowTypeView(try self.readLocal(local, span))).type_id;
            if (!try self.usesIndirectStorage(source_type)) return self.placeValue(try self.transferLocal(local, span, null), span, target);
            const storage = try self.memberDestination(target, source_type, span, .existing);
            return self.finishMemberStorage(try self.transferLocal(local, span, storage), target.storage, span);
        }

        fn resolveOwnedFields(self: *Self, local: semantic.UnresolvedBody.LocalId, source_fields: []const semantic.UnresolvedBody.FieldName, fields: *std.ArrayList(PlaceField)) ![]const structures.ReferencePathStep {
            var path: std.ArrayList(structures.ReferencePathStep) = .empty;
            var parent = self.borrowLocalValue(local);
            for (source_fields) |source| {
                if (try self.analysis_context.facts().variantMembers(parent.type_id) != null) {
                    const place = (try self.flowPlace(parent, false)) orelse return self.reject(source.span, .{ .field_access_not_struct = parent.type_id });
                    const selected = self.flow.?.facts.get(self.state.refinements, place).type_id orelse return self.reject(source.span, .{ .field_access_not_struct = parent.type_id });
                    const members = try self.matchInputMembers(selected);
                    if (members.len != 1) return self.reject(source.span, .reference_projection_requires_member);
                    const member = members[0];
                    if ((try self.analysis_context.facts().memberSpec(member)).kind == .reference) return self.reject(source.span, .ownership_transfer_requires_owned_place);
                    try self.requireFlowProof(place);
                    try path.append(self.gpa, .{ .variant = member });
                    parent = try self.projectOwnedPath(parent, &.{.{ .variant = member }});
                }
                const field = try self.resolvePlaceField(parent.type_id, source.name, source.span, source.span);
                try fields.append(self.gpa, field);
                const step: structures.ReferencePathStep = .{ .field = field.index };
                try path.append(self.gpa, step);
                if (field.kind == .reference) return self.reject(source.span, .ownership_transfer_requires_owned_place);
                parent = try self.projectOwnedPath(parent, &.{step});
            }
            return path.toOwnedSlice(self.gpa);
        }

        fn projectOwnedPath(self: *Self, root: Value, path: []const structures.ReferencePathStep) !Value {
            var value_to_project = root;
            for (path) |step| {
                const type_id = (try cleanup_shape.typeAt(self.analysis_context, value_to_project.type_id, &.{step})) orelse unreachable;
                const origins = try self.transformReferenceOrigins(value_to_project.reference_origins, .{ .select = step });
                const flow_origins = try self.appendSourcePath(try self.valuePlaceOrigins(value_to_project), step);
                value_to_project = try self.projectStorage(value_to_project, type_id, switch (step) {
                    .field => |index| .{ .field = index },
                    .variant => .variant,
                    else => unreachable,
                });
                value_to_project.reference_origins = origins;
                value_to_project.flow_origins = flow_origins;
            }
            return value_to_project;
        }

        fn constructFieldTransfer(self: *Self, transfer: @FieldType(Expression.Operation, "field_transfer"), span: structures.SourceSpan, destination: ?Destination) !Value {
            var fields: std.ArrayList(PlaceField) = .empty;
            const path = try self.resolveOwnedFields(transfer.target, self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end], &fields);
            const target = destination orelse return self.transferFieldProjection(transfer.target, fields.items, path, span, .{ .move = null });
            const source_type = fields.last().?.type_id;
            if (!try self.usesIndirectStorage(source_type))
                return self.placeValue(try self.transferFieldProjection(transfer.target, fields.items, path, span, .{ .move = null }), span, target);
            const storage = try self.memberDestination(target, source_type, span, .existing);
            return self.finishMemberStorage(try self.transferFieldProjection(transfer.target, fields.items, path, span, .{ .move = storage }), target.storage, span);
        }

        fn discardedValue(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!Value {
            return self.evaluateValue(id, .{ .discard = true });
        }

        fn discardResult(self: *Self, result: Value, span: structures.SourceSpan) !Value {
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            try self.discardValue(result, span);
            const unit = try self.appendInstruction(.const_unit);
            try self.closeBoundary(scope.boundary);
            return unit;
        }

        fn ownValue(self: *Self, value_to_own: Value, span: structures.SourceSpan) !Value {
            if (value_to_own.initializer_parameter != null) return self.constructInitializer(value_to_own, span, null);
            if (try self.nonCopyableBorrow(value_to_own)) |details| return self.reject(span, .{ .type_not_copyable = details });
            const owned = if (value_to_own.borrowed_type == null)
                withoutOwnershipSource(value_to_own)
            else if (value_to_own.borrow_condition) |borrow_predicate|
                try self.copyValueConditionally(value_to_own, borrow_predicate, span)
            else
                try self.copyValue(value_to_own, span, null);
            try self.rememberCleanupOrigins(owned);
            return owned;
        }

        fn ownCallArgument(self: *Self, operand: Value, argument: structures.FunctionValueUse, mode: structures.ParameterMode, span: structures.SourceSpan) !Value {
            if (mode == .@"var" and operand.borrowed_type == null and operand.initializer_parameter == null)
                return self.ownValue(operand, span);
            if (mode == .deinit and argument.coerce_to == null) return operand;
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            const owned = switch (mode) {
                .@"var" => try self.ownValue(operand, span),
                .deinit => try self.coerceOwnedRepresentation(operand, argument, span, null),
                else => unreachable,
            };
            try self.closeBoundary(scope.boundary);
            return owned;
        }

        fn validateInitializerWrite(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !void {
            var testing = self.match_testing_scope;
            while (testing) |scope| : (testing = scope.parent) {
                if (std.mem.indexOfScalar(semantic.UnresolvedBody.LocalId, scope.locals.items, local) != null)
                    return self.reject(span, .match_guard_invalidates_subject);
            }
            if (self.match_testing_scope != null and self.state.values.get(@backingInt(local)) != null)
                try self.checkMatchTestingWrite(try self.sourceReferenceOrigins(self.borrowLocalValue(local)), span);
            if (std.mem.indexOfScalar(semantic.UnresolvedBody.LocalId, self.pending_initializer_locals.items, local) != null)
                return self.reject(span, .initializer_capture_conflict);
        }

        const InitializerCaptureScope = struct { owners: usize, locals: usize };

        fn initializerCaptureScope(self: *const Self) InitializerCaptureScope {
            return .{ .owners = self.pending_initializer_owners.items.len, .locals = self.pending_initializer_locals.items.len };
        }

        fn endInitializerCaptureScope(self: *Self, scope: InitializerCaptureScope) void {
            self.pending_initializer_owners.shrinkRetainingCapacity(scope.owners);
            self.pending_initializer_locals.shrinkRetainingCapacity(scope.locals);
        }

        fn recordReplacementUses(self: *Self) !void {
            for (self.replacement_targets.items) |target| switch (target) {
                .local => |local| try self.recordLocalReplacementUse(local),
                .reference => |reference| try self.recordReferenceUses(reference, .retention),
            };
        }

        fn recordLocalReplacementUse(self: *Self, local: semantic.UnresolvedBody.LocalId) !void {
            const index = @backingInt(local);
            if (self.state.availability.get(index) != .available) return;
            const owner = self.state.values.get(index).?;
            try self.recordReferenceUses(owner, .retention);
            const generation = owner.owned_generation orelse return;
            try self.recordEffect(.{ .use = .{ .generation = generation, .cleanup_value = owner.id } });
        }

        fn finishReplacementUses(self: *Self, span: structures.SourceSpan) !void {
            if (self.replacement_targets.items.len == 0) return;
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            try self.recordReplacementUses();
            try self.closeBoundary(scope.boundary);
        }

        fn validateInitializerReferenceWrite(self: *Self, reference: Value, span: structures.SourceSpan) !void {
            try self.checkMatchTestingWrite(reference.reference_origins, span);
            if (self.is_initializer_region and reference.reference_origins != null) try self.capture_reference_writes.append(self.gpa, reference);
            if (self.pending_initializer_owners.items.len == 0) return;
            var incomplete = false;
            const origins = try self.resolveReferenceOrigins(reference.reference_origins, &incomplete);
            if (incomplete) {
                const gpa = self.gpa;
                const owners = try gpa.dupe(Value, self.pending_initializer_owners.items);
                const locals = try gpa.dupe(semantic.UnresolvedBody.LocalId, self.pending_initializer_locals.items);

                try self.initializer_write_checks.append(gpa, .{ .origins = reference.reference_origins, .owners = owners, .locals = locals, .span = span });
                return;
            }
            try self.checkInitializerReferenceWrite(origins, self.pending_initializer_owners.items, self.pending_initializer_locals.items, span);
        }

        fn checkInitializerReferenceWrite(self: *Self, resolved: ?u32, owners: []const Value, locals: []const semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !void {
            var origins = self.originList(resolved);
            while (origins.next()) |origin| {
                if (origin.root) |root| if (std.mem.indexOfScalar(semantic.UnresolvedBody.LocalId, locals, root) != null) return self.reject(span, .initializer_capture_conflict);
                for (owners) |owner| {
                    const generation = owner.owned_generation orelse owner.borrowed_generation;
                    if (generation != null and generation == origin.generation) return self.reject(span, .initializer_capture_conflict);
                    if (origin.parameter) |parameter| if (@backingInt(owner.id) == parameter) return self.reject(span, .initializer_capture_conflict);
                    // Borrowed parameters do not promise disjoint referents.
                    // Scalar copies are private, while source storage and
                    // contained allocations may alias another reference input.
                    if (origin.parameter != null and owner.borrowed_type != null and
                        try self.captureMayShareStorage(owner.type_id)) return self.reject(span, .initializer_capture_conflict);
                }
            }
        }

        fn captureMayShareStorage(self: *Self, type_id: structures.TypeId) anyerror!bool {
            if (try self.analysis_context.facts().argumentPassing(type_id) == .indirect) return true;
            if (try self.analysis_context.facts().boxElement(type_id) != null) return true;
            if (try self.analysis_context.facts().allocationElement(type_id) != null) return true;
            var components_iterator = try self.analysis_context.facts().components(type_id);
            while (components_iterator.next()) |component| {
                if (try self.captureMayShareStorage(component.type_id)) return true;
            }
            return false;
        }

        fn consumeInitializer(self: *Self, value_to_consume: Value, span: structures.SourceSpan) !void {
            const parameter = value_to_consume.initializer_parameter orelse unreachable;
            if (self.state.initializers.get(parameter) != .pending) return self.reject(span, .initializer_already_consumed);
            try self.state.initializers.set(self.gpa, parameter, .consumed);
        }

        fn constructInitializer(self: *Self, initializer: Value, span: structures.SourceSpan, destination: ?Value) !Value {
            const construction = try self.analysis_context.initializerConstruction(initializer.type_id);
            const result_type = construction.type_id;
            const result_origins = if (construction.projection) |field|
                try self.transformReferenceOrigins(initializer.reference_origins, .{ .select = .{ .field = field } })
            else
                initializer.reference_origins;
            if (destination) |storage| if (storage.type_id != result_type) {
                const member = try self.memberDestination(.{ .storage = storage, .site = .local }, result_type, span, .fresh);
                const constructed = try self.constructInitializer(initializer, span, member);
                return self.finishMemberStorage(constructed, storage, span);
            };
            try self.consumeInitializer(initializer, span);
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            var storage = destination;
            if (storage == null and try self.usesIndirectStorage(result_type)) storage = try self.localStorage(result_type);
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            const result = try self.ordinaryCallValue(.{
                .precise_reference_contract = true,
                .operation = .{
                    .target = .{ .initializer = initializer.id },
                    .arguments = .{ .start = argument_start, .end = argument_start },
                    .return_type = result_type,
                },
                .mut_arguments = .{ .start = 0, .end = 0 },
                .consumed_arguments = .{ .start = 0, .end = 0 },
                .writable_references = .{ .start = 0, .end = 0 },
                .reference_origins = result_origins,
            }, span, storage);
            if (self.current_block != null) try self.closeBoundary(scope.boundary);
            return result;
        }

        fn initializerRegion(self: *Self, return_type: structures.TypeId) Self {
            return .{
                .ctx = self.ctx,
                .gpa = self.gpa,
                .analysis_context = self.analysis_context,
                .instance = self.instance,
                .file_id = self.file_id,
                .unresolved = self.unresolved,
                .return_type = return_type,
                // Infer the deferred value before choosing its construction destination.
                .is_initializer_region = true,
                .optional_collection_allocation = self.optional_collection_allocation,
                .options = .{
                    .infer_reference_contract = self.options.infer_reference_contract,
                    .widen_reference_indices = self.options.widen_reference_indices,
                    .measurements = self.options.measurements,
                },
                .shared_initializer_types = self.shared_initializer_types orelse &self.initializer_types,
                .flow = self.flow,
                .flow_parent = self,
            };
        }

        /// Region block arguments in order, with the enclosing local each one reads.
        const RegionCaptures = struct {
            values: std.ArrayList(Value) = .empty,
            locals: std.ArrayList(?semantic.UnresolvedBody.LocalId) = .empty,
        };

        const InferenceDependencies = struct {
            parent: *Self,
            values: []bool,
            locals: []bool,
            blocks: []bool,

            fn visit(self: *@This(), item: anytype) anyerror!void {
                const Item = @TypeOf(item);
                const Body = semantic.UnresolvedBody;
                if (Item == Body.ValueId) {
                    const index = @backingInt(item);
                    if (self.values[index]) return;
                    self.values[index] = true;
                    if (self.parent.values.get(index)) |cached| if (cached.borrow_root) |local| try self.visit(local);
                    if (index < self.parent.unresolved.parameter_count) return;
                    return self.visit(self.parent.unresolved.expressions[index - self.parent.unresolved.parameter_count].operation);
                }
                if (Item == Body.LocalId) {
                    self.locals[@backingInt(item)] = true;
                    return;
                }
                if (Item == Body.BlockId) {
                    const index = @backingInt(item);
                    if (self.blocks[index]) return;
                    self.blocks[index] = true;
                    const unresolved_block = self.parent.unresolved.blocks[index];
                    for (self.parent.unresolved.statements[unresolved_block.statements.start..unresolved_block.statements.end]) |statement| try self.visit(statement);
                    return self.visit(unresolved_block.result);
                }
                if (Item == Body.Call) {
                    try self.visit(item.target);
                    if (item.target == .member or item.target == .overloaded) {
                        for (self.parent.unresolved.method_call_arguments[item.arguments.start..item.arguments.end]) |argument| try self.visit(argument.value);
                    } else try self.arguments(item.arguments);
                    return;
                }
                if (Item == Body.PatternBinding) {
                    try self.visit(item.value);
                    return self.visit(self.parent.unresolved.binding_patterns[item.pattern]);
                }
                if (Item == Body.BindingPattern) {
                    try self.visit(item.carrier);
                    try self.visit(item.read);
                    try self.visit(item.position);
                    switch (item.shape) {
                        .name => |name| try self.visit(name.local),
                        .tuple => |children| try self.patterns(children),
                        .sequence => |sequence| {
                            try self.visit(sequence.storage);
                            try self.visit(sequence.storage_read);
                            try self.patterns(sequence.children);
                        },
                    }
                    return;
                }
                if (Item == Body.MatchArm) {
                    try self.visit(self.parent.unresolved.match_patterns[item.pattern]);
                    try self.visit(item.condition);
                    return self.visit(item.body);
                }
                if (Item == Body.MatchPattern) {
                    try self.visit(item.carrier);
                    try self.visit(item.read);
                    try self.visit(item.binding);
                    switch (item.shape) {
                        .tuple => |children| {
                            for (self.parent.unresolved.match_pattern_children[children.start..children.end]) |index| try self.visit(self.parent.unresolved.match_patterns[index]);
                        },
                        else => try self.visit(item.shape),
                    }
                    return;
                }
                if (Item == Expression.Operation) {
                    switch (item) {
                        .struct_init => |initializer| {
                            for (self.parent.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |field| try self.visit(field.value);
                            return;
                        },
                        .array_init => |initializer| return self.arguments(initializer.elements),
                        .collection_literal => |literal| {
                            try self.visit(literal.sink);
                            try self.arguments(literal.elements);
                            return self.arguments(literal.sink_reads);
                        },
                        .tuple_literal => |elements| return self.arguments(elements),
                        .match => |expression_match| {
                            try self.visit(expression_match.subject);
                            try self.visit(expression_match.carrier);
                            try self.visit(expression_match.read);
                            for (self.parent.unresolved.match_arms[expression_match.arms.start..expression_match.arms.end]) |arm| try self.visit(arm);
                            return;
                        },
                        else => {},
                    }
                }
                switch (@typeInfo(Item)) {
                    .@"struct" => |info| inline for (info.field_names) |name| try self.visit(@field(item, name)),
                    .@"union" => switch (item) {
                        inline else => |payload| try self.visit(payload),
                    },
                    .optional => if (item) |payload| try self.visit(payload),
                    else => {},
                }
            }

            fn arguments(self: *@This(), range: structures.FunctionValueRange) !void {
                for (self.parent.unresolved.call_arguments[range.start..range.end]) |argument| try self.visit(argument);
            }

            fn patterns(self: *@This(), range: structures.FunctionValueRange) !void {
                for (self.parent.unresolved.binding_pattern_children[range.start..range.end]) |index| try self.visit(self.parent.unresolved.binding_patterns[index]);
            }
        };

        fn bindInferenceCaptures(self: *Self, region: *Self, value_id: semantic.UnresolvedBody.ValueId) !void {
            const captures = try self.bindRegionCaptures(region, value_id);
            if (self.options.measurements) |measurements| measurements.inference_capture_values += captures.values.items.len;
        }

        fn appendRegionCapture(self: *Self, captures: *RegionCaptures, capture: struct {
            source: Value,
            local: ?semantic.UnresolvedBody.LocalId = null,
            mode: structures.ParameterMode = .imm,
        }) !u32 {
            const gpa = self.gpa;
            if (self.options.measurements) |measurements| {
                if (captures.values.items.len == captures.values.capacity or
                    captures.locals.items.len == captures.locals.capacity or
                    self.block_arguments.items.len == self.block_arguments.capacity or
                    self.block_argument_generations.items.len == self.block_argument_generations.capacity or
                    self.parameter_modes.items.len == self.parameter_modes.capacity)
                    measurements.region_capture_buffer_growths += 1;
            }
            const argument = try self.appendBlockArgument(capture.source.type_id, null);
            self.block_arguments.items[argument].representation = .storage;
            try self.parameter_modes.append(gpa, capture.mode);
            try captures.values.append(gpa, capture.source);
            try captures.locals.append(gpa, capture.local);
            return argument;
        }

        /// A transferable place gets a completion flag that the region sets when it consumes the place.
        fn appendTransferCapture(self: *Self, region: *Self, captures: *RegionCaptures, local: semantic.UnresolvedBody.LocalId, field: ?usize) !void {
            const index = @backingInt(local);
            if (self.state.values.get(index) == null or self.locals.items(.mut_parameter)[index] != null) return;
            const argument = try region.appendRegionCapture(captures, .{ .source = .{ .id = @fromBackingInt(@intCast(0)), .type_id = .bool }, .mode = .mut });
            try region.capture_transfers.append(self.gpa, .{ .local = local, .parameter = argument, .field = field });
        }

        fn bindRegionCaptures(self: *Self, region: *Self, value_id: semantic.UnresolvedBody.ValueId) !RegionCaptures {
            const value_end = self.values.len;
            const local_end = value_end + self.state.values.len;
            const block_end = local_end + self.unresolved.blocks.len;
            const marks = try self.gpa.alloc(bool, block_end);
            defer self.gpa.free(marks);
            @memset(marks, false);
            var dependencies: InferenceDependencies = .{
                .parent = self,
                .values = marks[0..value_end],
                .locals = marks[value_end..local_end],
                .blocks = marks[local_end..],
            };
            try dependencies.visit(value_id);
            return self.bindSelectedRegionCaptures(region, &dependencies);
        }

        fn bindSelectedRegionCaptures(self: *Self, region: *Self, dependencies: ?*const InferenceDependencies) !RegionCaptures {
            const gpa = self.gpa;
            var captures: RegionCaptures = .{};
            const parameters = try gpa.alloc(structures.CallableParameter, self.unresolved.parameter_count);

            for (parameters, self.block_arguments.items[0..parameters.len]) |*parameter, source| parameter.* = .{ .mode = if (source.representation == .initializer) .init else .imm, .type_id = source.type_id };
            var capture_count = parameters.len;
            var transfer_count: usize = 0;
            for (parameters.len..self.values.len) |index| {
                if (dependencies) |selected| if (!selected.values[index]) continue;
                capture_count += @intFromBool(self.values.get(index) != null);
            }
            for (0..self.state.values.len) |index| {
                if (dependencies) |selected| if (!selected.locals[index]) continue;
                if (self.state.values.get(index) == null) continue;
                capture_count += 1;
                transfer_count += @intFromBool(self.locals.items(.mut_parameter)[index] == null);
            }
            for (self.field_places) |place| {
                const index = @backingInt(place.local);
                if (dependencies) |selected| if (!selected.locals[index]) continue;
                if (self.state.values.get(index) != null and self.locals.items(.mut_parameter)[index] == null) transfer_count += 1;
            }
            capture_count += transfer_count;
            try captures.values.ensureTotalCapacity(gpa, capture_count);
            try captures.locals.ensureTotalCapacity(gpa, capture_count);
            try region.block_arguments.ensureTotalCapacity(gpa, capture_count);
            try region.block_argument_generations.ensureTotalCapacity(gpa, capture_count);
            try region.parameter_modes.ensureTotalCapacity(gpa, capture_count);
            try region.capture_transfers.ensureTotalCapacity(gpa, transfer_count);
            try region.init(parameters);
            region.captured_locals = try gpa.alloc(?u32, self.state.values.len);
            @memset(region.captured_locals, null);
            for (parameters, 0..) |parameter, index| {
                const source = self.values.get(index) orelse Value{ .id = @fromBackingInt(@intCast(index)), .type_id = parameter.type_id };
                try captures.values.append(gpa, source);
                try captures.locals.append(gpa, null);
                region.block_arguments.items[index].representation = if (parameter.mode == .init) .initializer else .storage;
                if (self.values.get(index) != null) {
                    try region.values.set(gpa, index, .{
                        .id = @fromBackingInt(@intCast(index)),
                        .type_id = source.type_id,
                        .borrowed_type = if (parameter.mode == .init) null else source.type_id,
                        .initializer_parameter = source.initializer_parameter,
                        .reference_origins = region.values.get(index).?.reference_origins,
                        .flow_origins = try region.addReferenceOrigin(null, .{ .parameter = @intCast(index), .source_kind = .place }),
                    });
                } else try region.values.set(gpa, index, null);
            }
            for (parameters.len..self.values.len) |index| {
                if (dependencies) |selected| if (!selected.values[index]) continue;
                const source = self.values.get(index) orelse continue;
                const argument = try region.appendRegionCapture(&captures, .{ .source = source, .local = source.borrow_root });
                try region.values.set(gpa, index, .{ .id = @fromBackingInt(@intCast(argument)), .type_id = source.type_id, .predicate = source.predicate, .flow_origins = try region.addReferenceOrigin(null, .{ .parameter = argument, .source_kind = .place }), .borrowed_type = source.type_id, .reference_origins = if (try self.analysis_context.facts().canStoreBorrow(source.type_id)) try region.addReferenceOrigin(null, .{ .parameter = argument }) else null });
            }
            for (0..self.state.values.len) |index| {
                if (dependencies) |selected| if (!selected.locals[index]) continue;
                var source = self.state.values.get(index) orelse continue;
                source.borrow_root = @fromBackingInt(@intCast(index));
                const argument = try region.appendRegionCapture(&captures, .{ .source = source, .local = @fromBackingInt(@intCast(index)) });
                try region.state.values.set(region.gpa, index, .{ .id = @fromBackingInt(@intCast(argument)), .type_id = source.type_id, .predicate = source.predicate, .flow_origins = try region.addReferenceOrigin(null, .{ .parameter = argument, .source_kind = .place }), .binding_identity = try region.newBindingIdentity(), .reference_origins = if (try self.analysis_context.facts().canStoreBorrow(source.type_id)) try region.addReferenceOrigin(null, .{ .parameter = argument }) else null });
                try region.updateLocal(index, .{ .representation = .storage });
                try region.state.availability.set(region.gpa, index, self.state.availability.get(index));
                region.locals.items(.mutable)[index] = self.locals.items(.mutable)[index];
                region.locals.items(.reference)[index] = self.locals.items(.reference)[index];
                region.locals.items(.can_deinit)[index] = self.locals.items(.can_deinit)[index];

                region.captured_locals[index] = argument;
            }
            region.state.field_availability = self.state.field_availability.snapshot();
            for (0..self.state.values.len) |index| {
                if (dependencies) |selected| if (!selected.locals[index]) continue;
                try self.appendTransferCapture(region, &captures, @fromBackingInt(@intCast(index)), null);
            }
            for (self.field_places, 0..) |place, field| {
                if (dependencies) |selected| if (!selected.locals[@backingInt(place.local)]) continue;
                try self.appendTransferCapture(region, &captures, place.local, field);
            }
            region.blocks.items[0].argument_end = @intCast(captures.values.items.len);
            region.flow_captures = captures.values.items;
            region.state.refinements = self.state.refinements.snapshot();
            return captures;
        }

        fn inferInitializerType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId) anyerror!structures.TypeId {
            return self.inferExpressionType(raw, expected_type, true);
        }

        fn inferInitializerArgumentType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId) anyerror!structures.TypeId {
            if (self.expressionOperation(raw.value)) |operation| if (operation.* == .collection_literal) {
                if (expected_type != null and try self.analysis_context.collectionSequenceElement(expected_type.?) != null) {
                    const construction = try self.analysis_context.initializerConstruction(expected_type.?);
                    const previous_policy = self.optional_collection_allocation;
                    self.optional_collection_allocation = true;
                    defer self.optional_collection_allocation = previous_policy;
                    _ = try self.inferInitializerType(raw, construction.type_id);
                    return expected_type.?;
                }
                if (expected_type == null or try self.analysis_context.facts().collectionLiteralType(expected_type.?) != null) {
                    const array_type = try self.collectionType(operation.collection_literal.elements, expected_type, raw.span);
                    if (try self.analysis_context.facts().arrayType(array_type)) |array| return self.analysis_context.internCollectionLiteralType(array);
                    return array_type;
                }
            };
            return self.inferInitializerType(raw, expected_type);
        }

        fn inferArgumentType(self: *Self, raw: semantic.UnresolvedBody.ValueUse) anyerror!structures.TypeId {
            return self.inferExpressionType(raw, null, false);
        }

        fn inferExpressionType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId, initializer_boundary: bool) anyerror!structures.TypeId {
            if (self.values.get(@backingInt(raw.value))) |pending| if (pending.initializer_parameter != null) return pending.type_id;
            if (!initializer_boundary) if (try self.readTypeValue(raw.value)) |source| return source.type_id;
            const types = self.shared_initializer_types orelse &self.initializer_types;
            self.state.refinements = self.state.refinements.snapshot();
            const key: InitializerTypeKey = .{
                .expression = raw.value,
                .expected = expected_type,
                .initializer_boundary = initializer_boundary,
                .flow_state = if (self.state.refinements.root) |root| @intFromPtr(root) else 0,
            };
            if (types.get(key)) |type_id| return type_id;
            if (self.options.measurements) |measurements| measurements.type_only_regions += 1;
            var region = self.initializerRegion(if (initializer_boundary) expected_type orelse .unit else self.return_type);
            region.is_initializer_region = initializer_boundary;
            region.options.infer_return_type = initializer_boundary or self.options.infer_return_type;
            region.options.allow_type_values = self.options.allow_type_values;
            region.type_check_only = true;
            try self.bindInferenceCaptures(&region, raw.value);
            region.current_boundary = try region.newBoundary(raw.span);
            // Type the whole expression for inference without publishing or
            // executing its IR. The specialized call then checks ownership and
            // builds the region with its actual construction destination.
            const type_id = (try region.valueWithContext(raw.value, .{ .expected_type = expected_type, .access = .initialize, .allow_converters = false })).type_id;
            try types.put(self.gpa, key, type_id);
            return type_id;
        }

        fn prepareInitializer(self: *Self, raw: semantic.UnresolvedBody.ValueUse, type_id: structures.TypeId) !Value {
            if (self.values.get(@backingInt(raw.value))) |pending| if (pending.initializer_parameter != null) {
                if (pending.type_id != type_id) return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(type_id, pending.type_id) });
                try self.consumeInitializer(pending, raw.span);
                return pending;
            };
            const collection = try self.analysis_context.facts().collectionLiteralType(type_id);
            const construction = try self.analysis_context.initializerConstruction(type_id);
            const constructed_type = construction.type_id;
            const previous_policy = self.optional_collection_allocation;
            self.optional_collection_allocation = previous_policy or construction.optional_allocation;
            defer self.optional_collection_allocation = previous_policy;
            _ = try self.inferInitializerType(raw, constructed_type);
            if (self.type_check_only)
                return self.appendInstruction(.{ .initializer_ref = .{ .region = 0, .captures = .{ .start = 0, .end = 0 }, .type_id = type_id } });
            var region = self.initializerRegion(constructed_type);
            region.options.publish_instruction_spans = self.options.publish_instruction_spans;

            const gpa = self.gpa;
            const captures = try self.bindRegionCaptures(&region, raw.value);
            if (self.options.measurements) |measurements| measurements.initializer_capture_values += captures.values.items.len;
            if (try region.usesIndirectStorage(constructed_type)) {
                const storage = try region.appendInstruction(.{ .result_storage = constructed_type });
                const expression = if (@backingInt(raw.value) >= self.unresolved.parameter_count) self.unresolved.expressions[@backingInt(raw.value) - self.unresolved.parameter_count] else null;
                const constructed = if (collection != null and expression != null and expression.?.operation == .collection_literal)
                    try region.constructArrayElements(expression.?, constructed_type, expression.?.operation.collection_literal.elements, .{ .storage = storage, .site = .return_value })
                else
                    try region.construct(raw.value, raw.span, .{ .storage = storage, .site = .return_value });
                if (region.current_block != null) try region.returnConstructed(constructed, raw.span);
            } else {
                const result = try region.valueWithType(raw.value, constructed_type);
                if (region.current_block != null) try region.returnValue(result, raw.span);
            }
            var kept: std.ArrayList(u32) = .empty;
            const body = try region.finishAnalysis(null, &kept);

            const capture_start: u32 = @intCast(self.initializer_captures.items.len);
            for (kept.items) |index| {
                if (captures.locals.items[index]) |local| {
                    const current = self.state.values.get(@backingInt(local)).?;
                    if (captures.values.items[index].id == current.id and captures.values.items[index].type_id == current.type_id) {
                        captures.values.items[index] = try self.pinLocalStorage(local);
                        captures.values.items[index].borrow_root = local;
                    }
                }
                for (region.capture_transfers.items) |transfer| {
                    if (transfer.parameter != index) continue;
                    var fields: std.ArrayList(PlaceField) = .empty;

                    if (transfer.field) |field| try self.resolvePlaceFields(self.state.values.get(@backingInt(transfer.local)).?.type_id, self.field_places[field].fields, raw.span, &fields);
                    if (try self.captureTransferParameter(transfer.local, fields.items, raw.span)) |outer| {
                        captures.values.items[index] = .{ .id = outer, .type_id = .bool };
                    } else {
                        captures.values.items[index] = try self.newConsumptionCompletion(self.state.values.get(@backingInt(transfer.local)).?.owned_generation, transfer.field != null);
                    }
                }
                const source = captures.values.items[index];
                if (source.initializer_parameter != null) try self.consumeInitializer(source, raw.span);
                try self.initializer_captures.append(gpa, source.id);
            }
            const region_index: u32 = @intCast(self.initializer_regions.items.len);
            try self.initializer_regions.ensureUnusedCapacity(gpa, 1);
            var initializer = try self.appendInstruction(.{ .initializer_ref = .{
                .region = region_index,
                .captures = .{ .start = capture_start, .end = @intCast(self.initializer_captures.items.len) },
                .type_id = type_id,
            } });
            initializer.reference_origins = try self.importInitializerOrigins(&region, captures.values.items, region.returned_reference_origins, initializer.id);
            if (construction.projection) |field| initializer.reference_origins = try self.transformReferenceOrigins(initializer.reference_origins, .{ .prefix = .{ .field = field } });
            try self.prepareInitializerTransfers(&region, captures.values.items, kept.items, initializer.id, raw.span);
            var outputs = region.capture_output_origins.iterator();
            while (outputs.next()) |output| {
                const local = captures.locals.items[output.key_ptr.*] orelse continue;
                try self.validateInitializerWrite(local, raw.span);
                const origins = output.value_ptr.*;
                try self.initializer_writes.append(gpa, .{ .initializer = initializer.id, .local = local, .origins = try self.importInitializerOrigins(&region, captures.values.items, origins, initializer.id) });
            }
            for (region.capture_reference_writes.items) |write| {
                var written = region.originList(try region.completeReferenceOrigins(write.reference_origins));
                var external: ?u32 = null;
                while (written.next()) |origin| {
                    if (origin.parameter != null) external = try region.addReferenceOrigin(external, origin);
                }
                const origins = try self.importInitializerOrigins(&region, captures.values.items, external, initializer.id);
                if (origins == null) continue;
                try self.initializer_reference_writes.append(gpa, .{ .initializer = initializer.id, .reference = .{ .id = initializer.id, .type_id = write.type_id, .reference_origins = origins } });
            }
            for (kept.items) |index| {
                var owner = captures.values.items[index];
                if (owner.initializer_parameter != null) continue;
                if (captures.locals.items[index]) |local| {
                    owner.owned_generation = self.state.values.get(@backingInt(local)).?.owned_generation;
                    owner.borrowed_generation = null;
                    owner.borrow_root = local;
                    try self.pending_initializer_locals.append(gpa, local);
                }
                var storage_origins = try self.sourceReferenceOrigins(owner);
                if (index < self.unresolved.parameter_count) storage_origins = try self.addReferenceOrigin(storage_origins, .{ .parameter = index });
                owner.reference_origins = try self.readReferenceOrigins(storage_origins, null, @truncate(@backingInt(initializer.id)), true);
                var origins = self.originList(storage_origins);
                while (origins.next()) |captured| {
                    var origin = captured;
                    origin.deferred_capture = true;
                    owner.reference_origins = try self.addReferenceOrigin(owner.reference_origins, origin);
                }
                try self.initializer_owners.append(gpa, .{ .initializer = initializer.id, .owner = owner });
                try self.pending_initializer_owners.append(gpa, owner);
            }
            self.initializer_regions.appendAssumeCapacity(body);
            return initializer;
        }

        fn prepareInitializerTransfers(self: *Self, region: *Self, captures: []const Value, kept: []const u32, initializer: structures.FunctionValueId, span: structures.SourceSpan) !void {
            const gpa = self.gpa;
            const transfer_start = self.initializer_transfers.items.len;
            for (region.capture_transfers.items) |transfer| {
                if (std.mem.indexOfScalar(u32, kept, transfer.parameter) == null) continue;
                const local_index = @backingInt(transfer.local);
                try self.validateInitializerWrite(transfer.local, span);
                var owner = self.state.values.get(local_index).?;
                if (transfer.field) |field| {
                    var fields: std.ArrayList(PlaceField) = .empty;

                    try self.resolvePlaceFields(owner.type_id, self.field_places[field].fields, span, &fields);
                    try self.validateMissingFieldParents(transfer.local, fields.items, span);
                    const projected = try self.projectFields(owner, fields.items, true);
                    if (owner.owned_generation) |previous| {
                        const ancestor = self.generations.items[@backingInt(previous)];
                        try self.recordConsume(owner);
                        const remaining = try self.defineOwnedValue(owner, span, self.locals.items(.can_deinit)[local_index]);
                        if (remaining.owned_generation) |generation| {
                            try self.copyMissingFields(generation, ancestor.missing_fields, fields.items, null);
                            self.generations.items[@backingInt(generation)].cleanup_condition = ancestor.cleanup_condition;
                        }
                        try self.updateLocal(local_index, .{ .owned_generation = remaining.owned_generation });
                        for (self.initializer_transfers.items[transfer_start..]) |*prepared| {
                            if (prepared.local == transfer.local and prepared.field == null)
                                prepared.owner.owned_generation = remaining.owned_generation;
                        }
                    }
                    owner = if (self.is_initializer_region and self.captured_locals[local_index] != null) projected else try self.defineOwnedValue(projected, span, false);
                }
                if (owner.owned_generation) |generation| {
                    std.debug.assert(self.generations.items[@backingInt(generation)].cleanup_condition == null);
                    self.generations.items[@backingInt(generation)].cleanup_condition = captures[transfer.parameter].id;
                }
                var availability = if (transfer.field) |field| self.state.field_availability.get(field) else self.state.availability.get(local_index);
                // Construction can be skipped or leave by any return. Include the original state
                // and every completed region path without inspecting receiver bodies.
                for (region.ordinary_completion_states.items) |state| {
                    const snapshot = region.states.items[@backingInt(state)];
                    const current = if (transfer.field) |field| snapshot.field_availability.get(field) else snapshot.availability.get(local_index);
                    availability = joinAvailability(availability, current);
                }
                try self.initializer_transfers.append(gpa, .{ .initializer = initializer, .local = transfer.local, .owner = owner, .call_availability = availability, .field = transfer.field });
            }
            const transfers = self.initializer_transfers.items[transfer_start..];
            for (transfers) |ancestor| {
                const parent_path = self.field_places[ancestor.field orelse continue].fields;
                const generation = ancestor.owner.owned_generation orelse continue;
                for (transfers) |child| {
                    if (child.local != ancestor.local or child.field == null) continue;
                    const child_path = self.field_places[child.field.?].fields;
                    if (parent_path.len >= child_path.len or !fieldPathContains(parent_path, child_path)) continue;
                    var fields: std.ArrayList(PlaceField) = .empty;

                    try self.resolvePlaceFields(self.state.values.get(@backingInt(child.local)).?.type_id, child_path, span, &fields);
                    const previous = self.generations.items[@backingInt(generation)].missing_fields;
                    try self.copyMissingFields(generation, previous, fields.items[parent_path.len..], null);
                }
            }
        }

        fn importInitializerProjection(self: *Self, region: *Self, captures: []const Value, projection: ?u32, tail: ?u32) anyerror!?u32 {
            const index = projection orelse return tail;
            const source = region.reference_storage.projections.keys()[index];
            const next = try self.importInitializerProjection(region, captures, source.next, tail);
            return try self.reference_storage.projection(self.gpa, .{ .step = self.importInitializerStep(source.step, captures), .next = next });
        }

        fn importInitializerTransforms(self: *Self, region: *Self, captures: []const Value, origins: ?u32, transform: ?u32) anyerror!?u32 {
            const index = transform orelse return origins;
            const transformation = region.reference_storage.transforms.keys()[index];
            const previous = try self.importInitializerTransforms(region, captures, origins, transformation.previous);
            var operation = transformation.operation;
            switch (operation) {
                .prefix, .select, .exclude, .source_path => |*step| step.* = self.importInitializerStep(step.*, captures),
                .readonly, .readonly_owned, .widen => {},
                .read, .relocate_read, .refresh, .refresh_written, .place => unreachable,
            }
            return self.transformReferenceOrigins(previous, operation);
        }

        fn importInitializerStep(self: *Self, step: structures.ReferencePathStep, captures: []const Value) structures.ReferencePathStep {
            const selector = step.indexSelector() orelse return step;
            const parameter = selector.parameter orelse return step;
            return self.substituteReferenceIndex(step, captures[parameter].id);
        }

        fn importInitializerOrigins(self: *Self, region: *Self, captures: []const Value, head: ?u32, initializer: structures.FunctionValueId) !?u32 {
            var result: ?u32 = null;
            var origins = region.originList(try region.completeReferenceOrigins(head));
            while (origins.next()) |origin| {
                if (origin.permanent) {
                    result = try self.addReferenceOrigin(result, .{ .permanent = true, .readonly = origin.readonly, .readonly_owned = origin.readonly_owned, .projection = try self.importInitializerProjection(region, captures, origin.projection, null) });
                    continue;
                }
                const parameter = origin.parameter orelse return self.reject(self.activeLifetimeSpan(), .borrow_outlives_source);
                const capture = captures[parameter];
                const capture_origins = if (origin.root == null and try self.analysis_context.facts().canStoreBorrow(capture.type_id))
                    capture.reference_origins
                else
                    try self.sourceReferenceOrigins(capture);
                var path: std.ArrayList(structures.ReferencePathStep) = .empty;

                try region.referenceSourcePath(origin, &path);
                for (path.items) |*step| step.* = self.importInitializerStep(step.*, captures);
                var source = try self.followReferencePath(capture_origins, origin.source_kind, path.items);
                source = try self.importInitializerTransforms(region, captures, source, origin.transform);
                if (origin.readonly) source = try self.readonlyOrigins(source);
                if (origin.readonly_owned) |type_id| source = try self.readonlyOwnedOrigins(type_id, source);
                if (origin.read != null) source = try self.readReferenceOrigins(source, null, @truncate(@backingInt(initializer)), origin.deferred_capture);
                var sources = self.originList(source);
                while (sources.next()) |source_origin| {
                    var mapped = source_origin;
                    if (origin.root != null and capture.borrow_root != null and mapped.root == capture.borrow_root) {
                        mapped.initializer_owner = initializer;
                        mapped.stable = origin.stable;
                    }
                    mapped.storage_depth = std.math.add(u32, mapped.storage_depth, origin.storage_depth) catch return error.AnalysisTooLarge;
                    mapped.variant_guard = if (origin.storage_depth != 0) origin.variant_guard else mapped.variant_guard or origin.variant_guard;
                    mapped.projection = try self.importInitializerProjection(region, captures, origin.projection, mapped.projection);
                    result = try self.addReferenceOrigin(result, mapped);
                }
            }
            return result;
        }

        /// Place origins extend their source path; contents origins select within their referents.
        fn followReferencePath(self: *Self, origins: ?u32, kind: structures.ReferenceSourceKind, path: []const structures.ReferencePathStep) !?u32 {
            var result = origins;
            for (path) |step| {
                result = if (kind == .place) try self.appendSourcePath(result, step) else try self.transformReferenceOrigins(result, .{ .select = step });
            }
            return result;
        }

        fn requirementOrigins(self: *Self, contract: structures.ReferenceContract, requirement: structures.ReferenceRequirement, arguments: []const CallOriginSource) !?u32 {
            const argument = arguments[requirement.parameter];
            var origins = if (requirement.kind == .place) argument.storage else argument.contained;
            for (contract.paths[requirement.path.start..requirement.path.end]) |step| {
                const selected = self.substituteReferenceStep(step, arguments);
                origins = if (requirement.kind == .place)
                    try self.appendSourcePath(origins, selected)
                else
                    try self.transformReferenceOrigins(origins, .{ .select = selected });
            }
            return origins;
        }

        fn initializerOriginsOverlap(self: *Self, left: ?u32, right: ?u32) !bool {
            if (left == null or right == null) return false;
            var incomplete = false;
            var left_origins = self.originList(try self.resolveReferenceOrigins(left, &incomplete));
            const right_origins = try self.resolveReferenceOrigins(right, &incomplete);
            if (incomplete) return true;
            while (left_origins.next()) |first| {
                var right_list = self.originList(right_origins);
                while (right_list.next()) |second| {
                    if (first.root != null and first.root == second.root) return true;
                    if (first.generation != null and first.generation == second.generation) return true;
                    if (first.parameter != null and second.parameter != null) return true;
                }
            }
            return false;
        }

        fn validateInitializerInput(self: *Self, initializer: structures.FunctionValueId, input: Value, span: structures.SourceSpan) !void {
            const origins = try self.sourceReferenceOrigins(input);
            for (self.initializer_writes.items) |write| {
                if (write.initializer != initializer) continue;
                if (input.borrow_root == write.local) return self.reject(span, .initializer_capture_conflict);
                var owner = self.state.values.get(@backingInt(write.local)).?;
                owner.borrow_root = write.local;
                if (try self.initializerOriginsOverlap(try self.sourceReferenceOrigins(owner), origins)) return self.reject(span, .initializer_capture_conflict);
            }
            for (self.initializer_transfers.items) |transfer| {
                if (transfer.initializer != initializer) continue;
                if (input.borrow_root == transfer.local) return self.reject(span, .initializer_capture_conflict);
                var owner = transfer.owner;
                owner.borrow_root = transfer.local;
                if (try self.initializerOriginsOverlap(try self.sourceReferenceOrigins(owner), origins)) return self.reject(span, .initializer_capture_conflict);
            }
            for (self.initializer_reference_writes.items) |write| {
                if (write.initializer != initializer) continue;
                if (try self.initializerOriginsOverlap(write.reference.reference_origins, origins)) return self.reject(span, .initializer_capture_conflict);
            }
        }

        fn consumeOwnedPlace(self: *Self, expression: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId, span: structures.SourceSpan) !Value {
            var source_fields: std.ArrayList(semantic.UnresolvedBody.FieldName) = .empty;
            const operation = self.expressionOperation(expression);
            const source_root: SourcePlaceRoot = if (operation != null and operation.?.* == .local_transfer)
                .{ .local = operation.?.local_transfer }
            else if (operation != null and operation.?.* == .field_transfer) fields: {
                const transfer = operation.?.field_transfer;
                try source_fields.appendSlice(self.gpa, self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end]);
                break :fields .{ .local = transfer.target };
            } else (try self.appendSourcePlaceFields(true, expression, &source_fields)) orelse return self.reject(span, .ownership_transfer_requires_owned_place);
            if (source_root != .local) return self.reject(span, .ownership_transfer_requires_owned_place);
            const local = source_root.local;
            if (self.locals.items(.reference)[@backingInt(local)]) return self.reject(span, .ownership_transfer_requires_owned_place);
            var resolved: std.ArrayList(PlaceField) = .empty;
            const path = try self.resolveOwnedFields(local, source_fields.items, &resolved);
            const fields = resolved.items;
            try self.requireAvailablePlace(local, fields, span);
            try self.validateInitializerWrite(local, span);
            const local_index = @backingInt(local);
            const raw = try self.projectOwnedPath(self.borrowLocalValue(local), path);
            const type_id = if (expected_type == raw.type_id) raw.type_id else (try self.flowTypeView(raw)).type_id;
            if (expected_type) |expected| if (type_id != expected)
                return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(expected, type_id) });
            var source = if (fields.len != 0) try self.transferFieldProjection(local, fields, path, span, .consume) else whole: {
                const consumption_completion = try self.captureTransferParameter(local, &.{}, span);
                if (self.locals.items(.mut_parameter)[local_index] != null and consumption_completion == null)
                    return self.reject(span, .ownership_transfer_requires_owned_place);
                const read = try self.readLocal(local, span);
                try self.recordUse(read);
                try self.state.availability.set(self.gpa, local_index, .transferred);
                var whole = ownershipSource(read);
                whole.borrow_root = local;
                whole.consumption_completion = consumption_completion;
                break :whole whole;
            };
            if (type_id != raw.type_id) source = try self.flowOwned(source, span);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.isDirectlyMovable() and source.consumption_completion == null)
                return self.moveValue(source, span, null);
            const field_start: u32 = @intCast(self.pending_deinit_fields.items.len);
            try self.pending_deinit_fields.appendSlice(self.gpa, fields);
            try self.pending_deinit_places.append(self.gpa, .{
                .local = local,
                .fields = .{ .start = field_start, .end = @intCast(self.pending_deinit_fields.items.len) },
            });
            source.preserves_storage = true;
            return source;
        }

        fn rememberCleanupOrigins(self: *Self, source: Value) !void {
            if (source.reference_origins == null) return;
            try self.captureCleanupOrigins(source);
        }

        fn captureCleanupOrigins(self: *Self, source: Value) !void {
            if (source.reference_origins == null and !self.cleanup_origins.contains(source.id)) return;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (!capabilities.needs_automatic_drop) return;
            const block_id = self.current_block orelse return;
            const items = self.blocks.items[@backingInt(block_id)].items.items;
            const capture: CleanupCapture = .{
                .block = block_id,
                .position = if (items.len == 0) .entry else switch (items[items.len - 1]) {
                    .instruction => |instruction| .{ .instruction = instruction.id },
                    .boundary => |boundary| .{ .boundary = boundary },
                },
                .origins = source.reference_origins,
                .previous = self.cleanup_origins.get(source.id),
            };
            const index: u32 = @intCast(self.cleanup_captures.items.len);
            try self.cleanup_captures.append(self.gpa, capture);
            try self.cleanup_origins.put(self.gpa, source.id, index);
        }

        fn allocateGeneration(
            self: *Self,
            type_id: structures.TypeId,
            span: structures.SourceSpan,
            cleanup_fields: bool,
        ) !?GenerationId {
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (!capabilities.needs_automatic_drop and !capabilities.requires_explicit_drop) return null;
            // Generations start in allocation order.
            const start_order = std.math.cast(u32, self.generations.items.len) orelse return error.AnalysisTooLarge;
            try self.generations.append(self.gpa, .{
                .type_id = type_id,
                .start_order = start_order,
                .span = span,
                .requires_explicit_drop = capabilities.requires_explicit_drop,
                .cleanup_fields = false,
            });
            const id: GenerationId = @fromBackingInt(start_order);
            if (cleanup_fields) try self.setDeinitCleanup(id);
            return id;
        }

        fn setDeinitCleanup(self: *Self, generation: GenerationId) !void {
            const data = &self.generations.items[@backingInt(generation)];
            if ((try self.analysis_context.facts().structDefinition(data.type_id)) == null) return;
            data.requires_explicit_drop = (try cleanup_shape.obligations(self.gpa, self.analysis_context, data.type_id, data.cleanup_selections, data.missing_fields, true)).explicit;
            data.cleanup_fields = true;
        }

        fn defineOwnedValue(self: *Self, source: Value, span: structures.SourceSpan, cleanup_fields: bool) !Value {
            var owned = withoutOwnershipSource(source);
            if (try self.analysis_context.facts().borrowElement(source.type_id) == null) owned.local_reference = null;
            owned.owned_generation = try self.allocateGeneration(owned.type_id, span, cleanup_fields);
            if (owned.owned_generation) |generation| try self.recordEffect(.{ .define = .{
                .generation = generation,
                .value = owned.id,
            } });
            return owned;
        }

        fn recordEffect(self: *Self, effect: LifetimeEffect) !void {
            _ = try self.appendEffect(effect);
        }

        fn appendEffect(self: *Self, operation: ?LifetimeEffect) !EffectId {
            if (self.current_boundary) |boundary| {
                return self.appendEffectAt(boundary, operation);
            }
            const id = try self.newEffectId();
            try self.blocks.items[@backingInt(self.current_block orelse unreachable)].terminator_effects.append(self.gpa, .{ .id = id, .operation = operation });
            return id;
        }

        fn appendEffectAt(self: *Self, boundary: BoundaryId, operation: ?LifetimeEffect) !EffectId {
            const id = try self.newEffectId();
            try self.boundaries.items[@backingInt(boundary)].effects.append(self.gpa, .{ .id = id, .operation = operation });
            return id;
        }

        fn newEffectId(self: *Self) !EffectId {
            const id = self.next_effect_id;
            self.next_effect_id = std.math.add(u32, id, 1) catch return error.AnalysisTooLarge;
            return @fromBackingInt(id);
        }

        fn terminatorEffectSite(self: *Self, block_id: structures.FunctionBlockId) !ReferenceEffectSite {
            const identity = &self.blocks.items[@backingInt(block_id)].reference_effect;
            if (identity.* == null) identity.* = try self.newEffectId();
            return .{ .terminator = identity.*.? };
        }

        fn joinResultGenerations(self: *Self, type_id: structures.TypeId, span: structures.SourceSpan, incoming: []const ?GenerationId) !?GenerationId {
            const joined = try self.joinGenerationGroup(type_id, span, incoming);
            const previous = joined orelse return null;
            const metadata = self.generations.items[@backingInt(previous)];
            if (metadata.cleanup_condition == null) return joined;
            const forwarded = try self.allocateGeneration(type_id, span, metadata.cleanup_fields);
            if (forwarded) |generation| {
                try self.copyMissingFields(generation, metadata.missing_fields, null, null);
                try self.mergeVariantCleanup(generation, &.{previous});
            }
            return forwarded;
        }

        fn joinGenerationGroup(self: *Self, type_id: structures.TypeId, span: structures.SourceSpan, incoming: []const ?GenerationId) !?GenerationId {
            std.debug.assert(incoming.len != 0);
            const first = incoming[0];
            var all_equal = self.generationMatchesType(first, type_id);
            var cleanup_fields = if (first) |generation| self.generations.items[@backingInt(generation)].cleanup_fields else false;
            const first_missing = if (first) |generation| self.generations.items[@backingInt(generation)].missing_fields else &.{};
            for (incoming[1..]) |current| {
                all_equal = all_equal and current == first;
                const current_missing = if (current) |generation| self.generations.items[@backingInt(generation)].missing_fields else &.{};
                if (!sameMissingFields(first_missing, current_missing)) return self.reject(span, .partial_field_transfer_not_supported);
                cleanup_fields = cleanup_fields and if (current) |generation| self.generations.items[@backingInt(generation)].cleanup_fields else false;
            }
            if (all_equal) return first;
            const joined = try self.allocateGeneration(type_id, span, cleanup_fields);
            if (joined) |generation| {
                try self.copyMissingFields(generation, first_missing, null, null);
                try self.mergeVariantCleanup(generation, incoming);
            }
            return joined;
        }

        fn mergeVariantCleanup(self: *Self, generation: GenerationId, incoming: []const ?GenerationId) !void {
            const metadata = self.generations.items[@backingInt(generation)];
            const root_members = try self.analysis_context.facts().variantMembers(metadata.type_id);
            var paths: std.ArrayList([]const structures.ReferencePathStep) = .empty;
            if (root_members != null) try paths.append(self.gpa, &.{});
            for (incoming) |source| {
                const previous = source orelse continue;
                const original = self.generations.items[@backingInt(previous)];
                for (original.cleanup_selections) |selection| {
                    var path = selection.path;
                    if (root_members != null and try self.analysis_context.facts().variantMembers(original.type_id) == null) {
                        const prefixed = try self.gpa.alloc(structures.ReferencePathStep, path.len + 1);
                        prefixed[0] = .{ .variant = original.type_id };
                        @memcpy(prefixed[1..], path);
                        path = prefixed;
                    }
                    for (paths.items) |existing| {
                        if (cleanup_shape.samePath(existing, path)) break;
                    } else try paths.append(self.gpa, path);
                }
            }
            if (paths.items.len == 0) return;
            var selections: []const cleanup_shape.Selection = &.{};
            for (paths.items) |path| {
                const leaf = (try cleanup_shape.typeAt(self.analysis_context, metadata.type_id, path)) orelse continue;
                const members = (try self.analysis_context.facts().variantMembers(leaf)) orelse continue;
                var feasible: std.ArrayList(structures.TypeId) = .empty;
                for (members) |member| {
                    const capabilities = (try self.analysis_context.facts().ownershipCapabilities(member)) orelse return error.Unavailable;
                    for (incoming) |source| {
                        if (source) |previous| {
                            const original = self.generations.items[@backingInt(previous)];
                            const source_leaf = (try cleanup_shape.typeAt(self.analysis_context, original.type_id, path)) orelse continue;
                            const original_path = if (root_members != null and path.len != 0 and path[0] == .variant and path[0].variant == original.type_id)
                                path[1..]
                            else
                                path;
                            const possible = cleanup_shape.membersAt(original.cleanup_selections, original_path) orelse
                                (try self.analysis_context.facts().variantMembers(source_leaf)) orelse &.{source_leaf};
                            if (!containsType(possible, member)) continue;
                        } else if (capabilities.needs_automatic_drop or capabilities.requires_explicit_drop) continue;
                        try feasible.append(self.gpa, member);
                        break;
                    }
                }
                if (!std.mem.eql(structures.TypeId, members, feasible.items))
                    selections = try cleanup_shape.withMembers(self.gpa, selections, path, try feasible.toOwnedSlice(self.gpa));
            }
            const target = &self.generations.items[@backingInt(generation)];
            target.cleanup_selections = selections;
            target.requires_explicit_drop = (try cleanup_shape.obligations(self.gpa, self.analysis_context, target.type_id, selections, target.missing_fields, target.cleanup_fields)).explicit;
        }

        fn sameMissingFields(left: []const []const structures.ReferencePathStep, right: []const []const structures.ReferencePathStep) bool {
            if (left.len != right.len) return false;
            for (left) |path| {
                for (right) |other| {
                    if (cleanup_shape.samePath(path, other)) break;
                } else return false;
            }
            return true;
        }

        fn missingPathStartsWith(path: []const structures.ReferencePathStep, fields: []const PlaceField) bool {
            if (path.len < fields.len) return false;
            for (fields, path[0..fields.len]) |field, index| {
                if (index != .field or field.index != index.field) return false;
            }
            return true;
        }

        fn copyMissingFields(self: *Self, generation: GenerationId, previous: []const []const structures.ReferencePathStep, added: ?[]const PlaceField, restored: ?[]const PlaceField) !void {
            return self.copyMissingPaths(generation, previous, if (added) |fields| try self.ownershipFieldPath(fields) else null, if (restored) |fields| try self.ownershipFieldPath(fields) else null);
        }

        fn copyMissingPaths(self: *Self, generation: GenerationId, previous: []const []const structures.ReferencePathStep, added: ?[]const structures.ReferencePathStep, restored: ?[]const structures.ReferencePathStep) !void {
            var paths: std.ArrayList([]const structures.ReferencePathStep) = .empty;
            for (previous) |path| {
                if (restored) |prefix| if (path.len >= prefix.len and cleanup_shape.samePath(path[0..prefix.len], prefix)) continue;
                try paths.append(self.gpa, path);
            }
            if (added) |path| try paths.append(self.gpa, path);
            const data = &self.generations.items[@backingInt(generation)];
            data.missing_fields = try paths.toOwnedSlice(self.gpa);
            data.requires_explicit_drop = (try cleanup_shape.obligations(self.gpa, self.analysis_context, data.type_id, data.cleanup_selections, data.missing_fields, data.cleanup_fields)).explicit;
        }

        fn activeLifetimeSpan(self: *const Self) structures.SourceSpan {
            if (self.current_boundary) |boundary| return self.boundaries.items[@backingInt(boundary)].span;
            return self.unresolved.blocks[@backingInt(self.unresolved.root_block)].span;
        }

        fn withCleanupCondition(self: *Self, resolved: Value) Value {
            const generation = resolved.owned_generation orelse return resolved;
            const borrow_predicate = resolved.borrow_condition orelse return resolved;
            const generation_data = &self.generations.items[@backingInt(generation)];
            if (generation_data.cleanup_condition) |existing| std.debug.assert(existing == borrow_predicate);
            generation_data.cleanup_condition = borrow_predicate;
            return resolved;
        }

        fn hasNonowningPath(value_to_check: Value) bool {
            return value_to_check.borrowed_type != null or value_to_check.borrow_condition != null or
                (value_to_check.consumption_completion != null and value_to_check.owned_generation == null);
        }

        fn moveCurrentBoundaryEffectsToTerminator(self: *Self) !void {
            const boundary = &self.boundaries.items[@backingInt(self.current_boundary orelse unreachable)];
            const block_value = &self.blocks.items[@backingInt(self.current_block orelse unreachable)];
            try block_value.terminator_effects.appendSlice(self.gpa, boundary.effects.items);
            boundary.effects.clearRetainingCapacity();
        }

        fn copyValueConditionally(self: *Self, source: Value, borrow_predicate: structures.FunctionValueId, span: structures.SourceSpan) !Value {
            const paths = try self.beginConditionalJoin(source.type_id, borrow_predicate);
            const copied = try self.copyValueAcrossJoin(source, span);
            self.terminate(.{ .branch = try self.valuesBranch(paths.join, &.{copied}) });
            self.enterBlock(paths.owned);
            return self.finishConditionalJoin(paths, copied, source, span);
        }

        const ConditionalJoin = struct { argument: u32, owned: structures.FunctionBlockId, join: structures.FunctionBlockId };

        /// Branches on a borrow condition and enters its borrowed path; both paths join one value of `type_id`.
        fn beginConditionalJoin(self: *Self, type_id: structures.TypeId, borrow_condition: structures.FunctionValueId) !ConditionalJoin {
            const argument = try self.appendBlockArgument(type_id, null);
            const borrowed = try self.newEmptyBlock();
            const owned = try self.newEmptyBlock();
            const join = try self.newBlock(argument, argument + 1);
            const expected = try self.appendInstruction(.{ .const_bool = true });
            self.branchOn(.eqb, borrow_condition, expected.id, borrowed, owned);
            self.enterBlock(borrowed);
            return .{ .argument = argument, .owned = owned, .join = join };
        }

        /// Ends the owned path and enters the join, which combines both paths' ownership and references.
        fn finishConditionalJoin(self: *Self, paths: ConditionalJoin, borrowed: Value, owned: Value, span: structures.SourceSpan) !Value {
            self.terminate(.{ .branch = try self.valuesBranch(paths.join, &.{owned}) });
            const generation = try self.joinGenerationGroup(owned.type_id, span, &.{ borrowed.owned_generation, owned.owned_generation });
            self.block_argument_generations.items[paths.argument] = generation;
            self.enterBlock(paths.join);
            var result: Value = .{ .id = @fromBackingInt(@intCast(paths.argument)), .type_id = owned.type_id, .owned_generation = generation };
            try self.mergeValueReferences(&result, borrowed, owned);
            return result;
        }

        fn copyValueAcrossJoin(self: *Self, source: Value, span: structures.SourceSpan) !Value {
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.copy != .none) return self.copyValue(source, span, null);
            const members = (try self.analysis_context.facts().variantMembers(source.type_id)) orelse unreachable;
            if (!source.materialize_on_copy) try self.recordUse(source);
            const copied_bits = try self.mapVariantMember(source, members, .copy, null);
            return self.finishCopiedValue(source, copied_bits, span);
        }

        fn copyValue(self: *Self, source: Value, span: structures.SourceSpan, destination: ?Value) anyerror!Value {
            if (!source.materialize_on_copy) try self.recordUse(source);
            const copied_bits = try self.transferValueBits(source, .copy, destination);
            return self.finishCopiedValue(source, copied_bits, span);
        }

        fn finishCopiedValue(self: *Self, source: Value, copied_bits: Value, span: structures.SourceSpan) !Value {
            const materialized = if (source.materialize_on_copy and copied_bits.id == source.id)
                try self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = source.type_id } })
            else
                copied_bits;
            if (source.materialize_on_copy) {
                const scope = try self.openBoundary(span);
                defer self.current_boundary = scope.parent;
                try self.recordUse(source);
                try self.closeBoundary(scope.boundary);
            }
            var copied = try self.defineOwnedValue(materialized, span, false);
            const source_generation = source.borrowed_generation orelse source.owned_generation;
            if (copied.owned_generation) |generation| if (source_generation) |previous| {
                if (self.generations.items[@backingInt(previous)].type_id == source.type_id)
                    try self.mergeVariantCleanup(generation, &.{previous});
            };
            copied.reference_origins = try self.copyResultOrigins(source);
            copied.predicate = source.predicate;
            copied.local_reference = if (try self.analysis_context.facts().borrowElement(source.type_id) != null) source.local_reference else null;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.needs_custom_copy) {
                try self.finishOwnershipEffects(source, &copied.reference_origins, .copy, try self.sourceReferenceOrigins(source));
            } else copied.stable_reference_root = source.stable_reference_root;
            std.debug.assert(source_generation == null or source_generation != copied.owned_generation);
            return copied;
        }

        fn copyResultOrigins(self: *Self, source: Value) !?u32 {
            if (!try self.analysis_context.facts().canStoreBorrow(source.type_id)) return null;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            const origins = if (capabilities.needs_custom_copy) try self.sourceReferenceOrigins(source) else source.reference_origins;
            return if (source.writable) origins else self.readonlyOwnedOrigins(source.type_id, origins);
        }

        fn readonlyOwnedOrigins(self: *Self, type_id: structures.TypeId, origins: ?u32) anyerror!?u32 {
            return self.transformReferenceOrigins(origins, .{ .readonly_owned = type_id });
        }

        fn restrictOwnedOrigin(self: *Self, origin: *ReferenceOrigin, initial: structures.TypeId) !void {
            var type_id = initial;
            var projection = origin.projection;
            origin.readonly_owned = null;
            if (origin.readonly) return;
            while (true) {
                if (try self.analysis_context.facts().borrowElement(type_id) != null) return;
                if (try self.analysis_context.facts().storageAccess(type_id) != null) {
                    origin.readonly = true;
                    return;
                }
                const index = projection orelse {
                    if (try self.analysis_context.facts().canStoreBorrow(type_id)) origin.readonly_owned = type_id;
                    return;
                };
                const part = self.reference_storage.projections.keys()[index];
                if (part.step == .descendants) {
                    origin.readonly_owned = type_id;
                    return;
                }
                type_id = (try self.referencePathStepType(type_id, part.step)) orelse unreachable;
                projection = part.next;
            }
        }

        fn transferValueBits(self: *Self, source: Value, operation: structures.OwnershipMember, destination: ?Value) anyerror!Value {
            if (destination) |storage| if (storage.type_id != source.type_id)
                return self.mapVariantMember(source, (try self.analysis_context.facts().variantMembers(source.type_id)).?, operation, storage);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            const can_transfer = if (operation == .copy) capabilities.copy != .none else capabilities.move != .none;
            std.debug.assert(can_transfer);
            const needs_custom = if (operation == .copy) capabilities.needs_custom_copy else capabilities.needs_custom_move;
            if (!needs_custom) return self.copyBits(rawValue(source), destination orelse if (operation == .copy) try self.inPlaceStorage(source.type_id) else null);
            if (try self.analysis_context.facts().arrayType(source.type_id)) |array|
                return self.mapArrayElements(source, array, operation, destination orelse try self.localStorage(source.type_id));
            const custom_hook = if (operation == .copy) capabilities.copy == .custom else capabilities.move == .custom;
            if (custom_hook) return self.callOwnershipHook(source, if (operation == .copy) .copy else .move, destination, self.activeLifetimeSpan());
            const storage = destination orelse if (operation == .copy) try self.inPlaceStorage(source.type_id) else try self.localStorage(source.type_id);
            if (try self.analysis_context.facts().structDefinition(source.type_id)) |definition|
                return self.mapStructFields(source, definition, operation, storage orelse try self.localStorage(source.type_id));
            const members = (try self.analysis_context.facts().variantMembers(source.type_id)) orelse unreachable;
            return self.mapVariantMember(source, members, operation, storage);
        }

        fn moveValue(self: *Self, source: Value, span: structures.SourceSpan, destination: ?Value) anyerror!Value {
            try self.recordConsume(source);
            var moved = try self.defineOwnedValue(try self.transferValueBits(source, .move, destination), span, false);
            if (moved.owned_generation) |generation| try self.mergeVariantCleanup(generation, &.{source.owned_generation});
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            moved.reference_origins = source.reference_origins;
            moved.predicate = source.predicate;
            moved.local_reference = if (try self.analysis_context.facts().borrowElement(source.type_id) != null) source.local_reference else null;
            if (capabilities.needs_custom_move) {
                try self.finishOwnershipEffects(source, &moved.reference_origins, .move, try self.sourceReferenceOrigins(source));
            } else moved.stable_reference_root = source.stable_reference_root;
            try self.rememberCleanupOrigins(moved);
            return moved;
        }

        fn copyBits(self: *Self, source: Value, destination: ?Value) !Value {
            const storage = destination orelse {
                if (source.representation == .storage)
                    return self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = source.type_id } });
                return source;
            };
            _ = try self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = source.type_id, .destination = storage.id } });
            return storage;
        }

        fn inPlaceStorage(self: *Self, type_id: structures.TypeId) !?Value {
            return if (try self.usesIndirectStorage(type_id)) try self.localStorage(type_id) else null;
        }

        const OwnershipOperation = enum { copy, move, drop };

        fn callOwnershipHook(self: *Self, source: Value, operation: OwnershipOperation, destination: ?Value, span: structures.SourceSpan) !Value {
            const definition = (try self.analysis_context.facts().structDefinition(source.type_id)) orelse unreachable;
            const hook = switch (operation) {
                .copy => definition.ownership.copy.?.hook.?,
                .move => definition.ownership.move.?.hook.?,
                .drop => definition.ownership.drop.?.hook.?,
            };
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.append(self.gpa, if (operation == .copy) .{ .prepared = .{ .value = source.id } } else .{ .deinit = source.id });
            const result = try self.appendInstruction(.{ .call = .{
                .target = .{ .direct = hook },
                .arguments = .{ .start = argument_start, .end = argument_start + 1 },
                .return_type = if (operation == .drop) .unit else source.type_id,
                .destination = if (destination) |storage| storage.id else null,
            } });
            try self.recordOwnershipHookEffects(source, hook, @truncate(@backingInt(result.id)), span);
            return destination orelse result;
        }

        fn recordOwnershipHookEffects(self: *Self, source: Value, hook: structures.InstanceId, instruction: u31, span: structures.SourceSpan) !void {
            const contract = (try self.analysis_context.functionReferenceContract(hook)) orelse return error.Unavailable;
            const argument: CallOriginSource = .{
                .type_id = source.type_id,
                .contained = source.reference_origins,
                .storage = source.place_origins orelse try self.sourceReferenceOrigins(source),
            };
            try self.substituteReferenceExclusions(contract, &.{argument}, span);
            var effects: ReferenceEffects = .{};
            for (contract.requirements) |requirement| {
                _ = try self.recordRequirementWrite(contract, requirement, &.{argument}, &effects, span);
            }
            try self.recordReferenceEffects(.{ .instruction = instruction }, effects);
        }

        /// Checks and records a write that a callee's contract performs through an argument.
        fn recordRequirementWrite(self: *Self, contract: structures.ReferenceContract, requirement: structures.ReferenceRequirement, arguments: []const CallOriginSource, effects: *ReferenceEffects, span: structures.SourceSpan) !?u32 {
            const written = try self.requirementOrigins(contract, requirement, arguments);
            if (try self.originsReadonly(written)) return self.reject(span, .reference_not_writable);
            if (requirement.written_type) |written_type| {
                try self.includeReferenceWrite(effects, written, written_type, requirement.ends_lifetime);
                try self.reference_writes.append(self.gpa, .{ .origins = written, .written_type = written_type, .ends_lifetime = requirement.ends_lifetime });
            }
            return written;
        }

        fn includeReferenceWrite(self: *Self, effects: *ReferenceEffects, origins: ?u32, type_id: structures.TypeId, ends_lifetime: bool) !void {
            try self.checkMatchTestingWrite(origins, self.activeLifetimeSpan());
            effects.writes = try self.mergeReferenceOrigins(effects.writes, origins);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (ends_lifetime or capabilities.needs_automatic_drop or try self.analysis_context.facts().variantMembers(type_id) != null)
                effects.storage_invalidations = try self.mergeReferenceOrigins(effects.storage_invalidations, origins);
        }

        fn recordReferenceEffects(self: *Self, site: ReferenceEffectSite, effects: ReferenceEffects) !void {
            if (self.flow != null and effects.writes != null) try self.invalidateFlowTypes(effects.writes, self.activeLifetimeSpan());
            if (effects.writes != null) try self.reference_effects.put(self.gpa, site, effects);
        }

        fn finishOwnershipEffects(self: *Self, source: Value, origins: *?u32, operation: structures.OwnershipMember, storage_origins: ?u32) anyerror!void {
            if (try self.analysis_context.facts().structDefinition(source.type_id)) |definition| {
                const hook = switch (operation) {
                    .copy => if (definition.ownership.copy) |copy| copy.hook else null,
                    .move => if (definition.ownership.move) |move| move.hook else null,
                };
                if (hook) |instance| {
                    const contract = (try self.analysis_context.functionReferenceContract(instance)) orelse return error.Unavailable;
                    const argument: CallOriginSource = .{ .type_id = source.type_id, .contained = source.reference_origins, .storage = storage_origins };
                    const output_start: u32 = @intCast(self.pending_reference_outputs.items.len);
                    try self.appendReferentOutputs(contract, &.{argument}, &.{.{ .prepared = .{ .value = source.id } }});
                    const outputs: structures.FunctionValueRange = .{ .start = output_start, .end = @intCast(self.pending_reference_outputs.items.len) };
                    origins.* = try self.substituteOutputOrigins(contract, &.{argument}, null);
                    for (contract.requirements) |requirement| {
                        const written_type = requirement.written_type orelse continue;
                        const written = try self.requirementOrigins(contract, requirement, &.{argument});
                        try self.invalidateWritableReferences(&.{.{ .id = source.id, .type_id = try self.analysis_context.facts().referenceType(written_type), .reference_origins = written }}, .{ .value = origins });
                    }
                    try self.applyReferenceOutputs(outputs);
                    return;
                }
            }
            const facts = self.analysis_context.facts();
            var components_iterator = try facts.components(source.type_id);
            if (components_iterator.shape == .empty) return;
            var result: ?u32 = null;
            while (components_iterator.next()) |component| {
                if (component.count == 0) return;
                const child_type = try facts.memberStorageType(.{ .type_id = component.type_id, .kind = component.kind });
                const child = try self.finishChildOwnershipEffects(source, component.step, child_type, component.kind == .owned, operation, storage_origins);
                result = try self.mergeReferenceOrigins(result, child);
            }
            origins.* = result;
        }

        /// Returns a child's finished origins, prefixed by its step within the parent.
        fn finishChildOwnershipEffects(self: *Self, parent: Value, step: structures.ReferencePathStep, child_type: structures.TypeId, owned: bool, operation: structures.OwnershipMember, storage_origins: ?u32) !?u32 {
            var child = parent;
            child.type_id = child_type;
            child.reference_origins = try self.transformReferenceOrigins(parent.reference_origins, .{ .select = step });
            var child_origins = child.reference_origins;
            if (owned) try self.finishOwnershipEffects(child, &child_origins, operation, try self.appendSourcePath(storage_origins, step));
            return self.transformReferenceOrigins(child_origins, .{ .prefix = step });
        }

        fn mapStructFields(
            self: *Self,
            source: Value,
            definition: *const structures.StructDefinition,
            operation: structures.OwnershipMember,
            destination: Value,
        ) anyerror!Value {
            for (definition.fields, 0..) |field, index| {
                const storage_type = try self.analysis_context.facts().fieldStorageType(field);
                const step: structures.ReferencePathStep = .{ .field = @intCast(index) };
                var extracted = try self.projectStorage(source, storage_type, .{ .field = @intCast(index) });
                extracted.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = step });
                extracted.place_origins = try self.appendSourcePath(source.place_origins orelse try self.sourceReferenceOrigins(source), step);
                const field_destination = try self.projectStorage(destination, storage_type, .{ .field = @intCast(index) });
                _ = try self.transferValueBits(extracted, operation, field_destination);
            }
            return destination;
        }

        const ArrayLoop = struct {
            header: structures.FunctionBlockId,
            exit: structures.FunctionBlockId,
            index: Value,
            one: Value,
        };

        fn beginArrayLoop(self: *Self, length: u32, reverse: bool) !ArrayLoop {
            std.debug.assert(length <= std.math.maxInt(i32));
            const zero = try self.appendInstruction(.{ .const_int = 0 });
            const limit = try self.appendInstruction(.{ .const_int = @intCast(length) });
            const one = try self.appendInstruction(.{ .const_int = 1 });
            const argument = try self.appendBlockArgument(.int, null);
            const header = try self.newBlock(argument, argument + 1);
            const body = try self.newEmptyBlock();
            const exit = try self.newEmptyBlock();
            self.terminate(.{ .branch = try self.valuesBranch(header, &.{if (reverse) limit else zero}) });
            self.enterBlock(header);
            var index: Value = .{ .id = @fromBackingInt(@intCast(argument)), .type_id = .int };
            self.branchOn(if (reverse) .gti else .lti, index.id, if (reverse) zero.id else limit.id, body, exit);
            self.enterBlock(body);
            if (reverse) index = try self.appendInstruction(.{ .subi = .{ .lhs = index.id, .rhs = one.id } });
            return .{ .header = header, .exit = exit, .index = index, .one = one };
        }

        fn endArrayLoop(self: *Self, array_loop: ArrayLoop, reverse: bool) !void {
            const next = if (reverse) array_loop.index else try self.appendInstruction(.{ .addi = .{ .lhs = array_loop.index.id, .rhs = array_loop.one.id } });
            self.terminate(.{ .branch = try self.valuesBranch(array_loop.header, &.{next}) });
            self.enterBlock(array_loop.exit);
        }

        fn arrayElement(self: *Self, array: Value, index: Value, element_type: structures.TypeId) !Value {
            return self.appendInstruction(.{ .array_element = .{
                .array = array.id,
                .index = index.id,
                .type_id = element_type,
            } });
        }

        fn mapArrayElements(self: *Self, source: Value, array: structures.ArrayType, operation: structures.OwnershipMember, destination: Value) anyerror!Value {
            if (array.length == 0) return destination;
            const array_loop = try self.beginArrayLoop(array.length, false);
            var element = try self.arrayElement(source, array_loop.index, array.element_type);
            element.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .element });
            element.place_origins = try self.appendSourcePath(source.place_origins orelse try self.sourceReferenceOrigins(source), .element);
            const target = try self.arrayElement(destination, array_loop.index, array.element_type);
            _ = try self.transferValueBits(element, operation, target);
            try self.endArrayLoop(array_loop, false);
            return destination;
        }

        fn dropArrayElements(self: *Self, source: Value, array: structures.ArrayType, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            if (array.length == 0) return;
            const array_loop = try self.beginArrayLoop(array.length, true);
            var element = try self.arrayElement(source, array_loop.index, array.element_type);
            element.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .element });
            try self.dropValue(element, can_deinit, span);
            try self.endArrayLoop(array_loop, true);
        }

        fn mapVariantMember(self: *Self, source: Value, members: []const structures.TypeId, operation: structures.OwnershipMember, destination: ?Value) anyerror!Value {
            return (try self.operateOnVariantMember(source, members, .{ .transfer = operation }, destination)).?;
        }

        fn projectStorage(self: *Self, source: Value, type_id: structures.TypeId, projection: @FieldType(structures.StorageProjection, "projection")) !Value {
            var storage = try self.appendInstruction(.{ .storage_projection = .{ .owner = source.id, .type_id = type_id, .projection = projection } });
            storage.representation = .storage;
            return storage;
        }

        fn fieldView(self: *Self, owner: Value, index: u32, field_type: structures.TypeId) !Value {
            if (try self.usesIndirectStorage(field_type)) return self.projectStorage(owner, field_type, .{ .field = index });
            return self.appendInstruction(.{ .field_access = .{ .operand = owner.id, .field_index = index, .field_type = field_type } });
        }

        /// Projects nested fields as storage or views, each selecting its part of the parent's origins.
        fn projectFields(self: *Self, root: Value, fields: []const PlaceField, storage: bool) !Value {
            var field = root;
            for (fields) |part| {
                const origins = try self.transformReferenceOrigins(field.reference_origins, .{ .select = .{ .field = part.index } });
                field = if (storage) try self.projectStorage(field, part.type_id, .{ .field = part.index }) else try self.fieldView(field, part.index, part.type_id);
                field.reference_origins = origins;
            }
            return field;
        }

        fn mapExtractedVariantMember(self: *Self, source: Value, member: structures.TypeId, operation: structures.OwnershipMember, destination: ?Value) anyerror!Value {
            var extracted = if (destination != null) try self.projectStorage(source, member, .variant) else try self.appendInstruction(.{ .variant_extract = .{
                .operand = source.id,
                .target_type = member,
            } });
            const step: structures.ReferencePathStep = .{ .variant = member };
            extracted.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = step });
            extracted.place_origins = try self.appendSourcePath(source.place_origins orelse try self.sourceReferenceOrigins(source), step);
            const member_destination = if (destination) |storage| try self.projectStorage(storage, member, .variant) else null;
            const owned = switch (operation) {
                .copy => blk: {
                    const capabilities = (try self.analysis_context.facts().ownershipCapabilities(member)) orelse return error.Unavailable;
                    break :blk if (capabilities.copy == .none) extracted else try self.transferValueBits(extracted, .copy, member_destination);
                },
                .move => try self.transferValueBits(extracted, .move, member_destination),
            };
            const use = (try self.coerceValue(owned.id, member, if (destination) |storage| storage.type_id else source.type_id)) orelse unreachable;
            if (destination) |storage| {
                _ = try self.appendInstruction(.{ .variant_coerce = .{
                    .operand = owned.id,
                    .target_type = storage.type_id,
                    .tag_mapping = use.variant_tag_mapping,
                    .destination = storage.id,
                } });
                return storage;
            }
            return if (use.coerce_to == null) owned else self.appendCoercion(use, null);
        }

        fn dropVariantMember(self: *Self, source: Value, members: []const structures.TypeId, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            _ = try self.operateOnVariantMember(source, members, .{ .drop = .{ .can_deinit = can_deinit, .span = span } }, null);
        }

        const VariantOwnershipOperation = union(enum) {
            transfer: structures.OwnershipMember,
            drop: struct { can_deinit: bool, span: structures.SourceSpan },
        };

        fn operateOnVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            operation: VariantOwnershipOperation,
            destination: ?Value,
        ) anyerror!?Value {
            std.debug.assert(members.len != 0);
            const tag = try self.appendInstruction(.{ .variant_tag = source.id });
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            if (operation == .transfer and destination == null) _ = try self.appendBlockArgument(source.type_id, null);
            const join = try self.newBlock(argument_start, @intCast(self.block_arguments.items.len));
            const destination_members = if (destination) |storage| (try self.analysis_context.facts().variantMembers(storage.type_id)).? else members;
            var remaining: usize = 0;
            for (members) |member| remaining += @intFromBool(containsType(destination_members, member));
            std.debug.assert(remaining != 0);

            const source_members = (try self.analysis_context.facts().variantMembers(source.type_id)).?;
            for (members) |member| {
                if (!containsType(destination_members, member)) continue;
                const member_index = std.mem.indexOfScalar(structures.TypeId, source_members, member).?;
                remaining -= 1;
                const next = try self.enterVariantCase(tag, member_index, remaining == 0);
                switch (operation) {
                    .drop => |drop| {
                        var extracted = try self.projectStorage(source, member, .variant);
                        extracted.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = member } });
                        try self.dropValue(extracted, drop.can_deinit, drop.span);
                        self.terminate(.{ .branch = self.emptyBranch(join) });
                    },
                    .transfer => |transfer| {
                        const result = try self.mapExtractedVariantMember(source, member, transfer, destination);
                        self.terminate(.{ .branch = if (destination != null) self.emptyBranch(join) else try self.valuesBranch(join, &.{result}) });
                    },
                }
                if (next) |next_block| self.enterBlock(next_block);
            }
            self.enterBlock(join);
            return switch (operation) {
                .drop => null,
                .transfer => destination orelse .{ .id = @fromBackingInt(@intCast(argument_start)), .type_id = source.type_id },
            };
        }

        fn enterVariantCase(self: *Self, tag: Value, member_index: usize, last: bool) !?structures.FunctionBlockId {
            if (last) return null;
            const next = try self.newEmptyBlock();
            const selected = try self.newEmptyBlock();
            const expected = try self.appendInstruction(.{ .const_int = @intCast(member_index) });
            self.branchOn(.eqi, tag.id, expected.id, selected, next);
            self.enterBlock(selected);
            return next;
        }

        fn dropValue(self: *Self, value_to_drop: Value, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(value_to_drop.type_id)) orelse return error.Unavailable;
            switch (capabilities.drop) {
                .trivial => {},
                .explicit => if (!can_deinit) return self.reject(span, .{ .value_requires_explicit_drop = value_to_drop.type_id }),
                .custom => _ = try self.callOwnershipHook(value_to_drop, .drop, null, span),
                .fieldwise => {
                    if (!capabilities.needs_automatic_drop and !capabilities.requires_explicit_drop) return;
                    if (try self.analysis_context.facts().arrayType(value_to_drop.type_id)) |array|
                        return self.dropArrayElements(value_to_drop, array, can_deinit, span);
                    if (try self.analysis_context.facts().variantMembers(value_to_drop.type_id)) |members|
                        return self.dropVariantMember(value_to_drop, members, can_deinit, span);
                    try self.dropValueExcluding(value_to_drop, &.{}, can_deinit, span);
                },
            }
        }

        fn nonCopyableBorrow(self: *Self, value_to_check: Value) !?structures.Diagnostic.TypeNotCopyable {
            const source_type = value_to_check.borrowed_type orelse return null;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source_type)) orelse return error.Unavailable;
            return if (capabilities.copy == .none) .{
                .type_id = source_type,
                .is_movable = capabilities.move != .none and !value_to_check.materialize_on_copy and
                    if (value_to_check.borrow_root) |root|
                        self.locals.items(.mut_parameter)[@backingInt(root)] == null
                    else
                        false,
            } else null;
        }

        fn borrowValue(self: *Self, borrowed: Value, span: structures.SourceSpan) !Value {
            if (borrowed.initializer_parameter != null) return self.reject(span, .initializer_requires_construction);
            if (borrowed.explicit_transfer) return self.reject(span, .ownership_transfer_requires_owning_context);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(borrowed.type_id)) orelse return error.Unavailable;
            const requires_explicit_drop = if (borrowed.owned_generation) |generation|
                self.generations.items[@backingInt(generation)].requires_explicit_drop
            else
                capabilities.requires_explicit_drop;
            if (borrowed.borrowed_type == null and requires_explicit_drop)
                return self.reject(span, .{ .value_requires_explicit_drop = borrowed.type_id });
            try self.recordUse(borrowed);
            return borrowed;
        }

        fn withoutOwnershipSource(resolved: Value) Value {
            return .{
                .id = resolved.id,
                .type_id = resolved.type_id,
                .owned_generation = resolved.owned_generation,
                .reference_origins = resolved.reference_origins,
                .local_reference = resolved.local_reference,
                .predicate = resolved.predicate,
                .stable_reference_root = resolved.stable_reference_root,
                .representation = resolved.representation,
            };
        }

        fn ownershipSource(resolved: Value) Value {
            var source = withoutOwnershipSource(resolved);
            source.owned_generation = resolved.owned_generation orelse resolved.borrowed_generation;
            source.flow_origins = resolved.flow_origins;
            source.consumption_completion = resolved.consumption_completion;
            source.pending_consumption_owners = resolved.pending_consumption_owners;
            return source;
        }

        fn rawValue(resolved: Value) Value {
            return .{ .id = resolved.id, .type_id = resolved.type_id, .representation = resolved.representation };
        }

        fn mergeValueReferences(self: *Self, result: *Value, first: Value, second: Value) !void {
            result.reference_origins = try self.mergeReferenceOrigins(first.reference_origins, second.reference_origins);
            result.stable_reference_root = sharedStableReferenceRoot(first.stable_reference_root, second.stable_reference_root);
            result.local_reference = if (std.meta.eql(first.local_reference, second.local_reference)) first.local_reference else null;
            result.predicate = if (first.predicate == second.predicate) first.predicate else null;
        }

        fn recordUse(self: *Self, source: Value) !void {
            if (source.initializer_parameter != null) return self.reject(self.activeLifetimeSpan(), .initializer_requires_construction);
            try self.rememberCleanupOrigins(source);
            try self.recordReferenceUses(source, .access);
            if (source.place_origins != null) try self.recordReferenceUses(.{ .id = source.id, .type_id = source.type_id, .reference_origins = source.place_origins }, .access);
            if (source.borrowed_generation) |generation| try self.recordEffect(.{ .use = .{
                .generation = generation,
                .cleanup_value = source.borrowed_cleanup_value orelse source.id,
            } });
            if (source.owned_generation) |generation| try self.recordEffect(.{ .use = .{
                .generation = generation,
                .cleanup_value = source.id,
                .cleanup_condition = source.borrow_condition,
            } });
        }

        fn recordReferenceUses(self: *Self, source: Value, kind: ReferenceUseKind) !void {
            if (source.reference_origins) |origins| {
                if (kind == .access) {
                    const checkpoint = try self.newBoundary(self.activeLifetimeSpan());
                    const identity = try self.appendEffectAt(checkpoint, null);
                    try self.closeBoundary(checkpoint);
                    try self.reference_uses.append(self.gpa, .{
                        .origins = origins,
                        .span = self.activeLifetimeSpan(),
                        .location = identity,
                    });
                }
                var pending = false;
                const resolved = try self.resolveReferenceOrigins(origins, &pending);
                var effects: std.ArrayList(LifetimeEffect) = .empty;

                if (!pending) try self.collectReferenceUses(resolved, self.state.snapshot(), self.activeLifetimeSpan(), kind, &effects, &pending);
                if (pending) {
                    const identity = try self.appendEffect(null);
                    try self.pending_reference_uses.append(self.gpa, .{
                        .kind = kind,
                        .origins = origins,
                        .state = try self.captureState(),
                        .span = self.activeLifetimeSpan(),
                        .location = identity,
                    });
                } else for (effects.items) |effect| try self.recordEffect(effect);
            }
        }

        fn collectReferenceUses(
            self: *Self,
            origins: ?u32,
            state: State,
            span: structures.SourceSpan,
            kind: ReferenceUseKind,
            effects: *std.ArrayList(LifetimeEffect),
            incomplete: *bool,
        ) !void {
            var list = self.originList(origins);
            while (list.next()) |origin| {
                std.debug.assert(origin.loop == null);
                var generation = origin.generation;
                var cleanup_value = origin.cleanup_value;
                if (origin.root) |root| {
                    const slot = @backingInt(root);
                    if (kind == .retention and state.availability.get(slot) != .available) continue;
                    switch (state.availability.get(slot)) {
                        .available => {},
                        .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
                        .unbound => {
                            return self.reject(span, .borrow_outlives_source);
                        },
                    }
                    if (kind == .access) {
                        const storage_depth = if (origin.stable and !origin.variant_guard) origin.storage_depth else null;
                        const expected = try self.resolveBindingIdentityAtDepth(origin.binding_identity, storage_depth);
                        const actual_identity = referenceIdentity(state.values.get(slot).?, origin);
                        const actual = try self.resolveBindingIdentityAtDepth(actual_identity, storage_depth);
                        if (expected.incomplete or actual.incomplete) {
                            incomplete.* = true;
                            continue;
                        }
                        const current_read = origin.read != null;
                        if (!((origin.stable or origin.deferred_capture or current_read) and std.meta.eql(origin.binding_identity, actual_identity)) and
                            (expected.conflicting or actual.conflicting or expected.value == null or expected.value != actual.value))
                        {
                            return self.reject(span, if (origin.deferred_capture) .initializer_capture_conflict else .borrow_outlives_source);
                        }
                    }
                    const owner = state.values.get(slot).?;
                    generation = owner.owned_generation orelse owner.borrowed_generation;
                    cleanup_value = if (owner.owned_generation != null) owner.id else owner.borrowed_cleanup_value orelse owner.id;
                }
                if (generation) |available_generation| try effects.append(self.gpa, .{ .use = .{
                    .generation = available_generation,
                    .cleanup_value = cleanup_value.?,
                } });
            }
        }

        fn resolveBindingIdentity(self: *Self, identity: BindingIdentity) !ResolvedBindingIdentity {
            return self.resolveBindingIdentityAtDepth(identity, null);
        }

        fn resolveBindingIdentityAtDepth(self: *Self, identity: BindingIdentity, storage_depth: ?u32) !ResolvedBindingIdentity {
            var pending: std.ArrayList(BindingIdentity) = .empty;
            defer pending.deinit(self.gpa);
            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.gpa);
            var result: ResolvedBindingIdentity = .{};
            var current = identity;
            while (true) {
                switch (current) {
                    .unknown => result.conflicting = true,
                    .fixed => |fixed| {
                        if (self.binding_versions.items[fixed]) |version| switch (version) {
                            .alias => |previous| {
                                current = previous;
                                continue;
                            },
                            .write => |write| if (storage_depth) |depth| {
                                if (depth <= write.preserved_storage_depth) {
                                    current = write.previous;
                                    continue;
                                }
                            },
                        };
                        if (result.value) |previous| {
                            if (previous != fixed) result.conflicting = true;
                        } else result.value = fixed;
                    },
                    .join => |index| {
                        // Joins share ancestors. Visit each once across the whole
                        // traversal, including cycles through loop backedges.
                        if (!(try visited.getOrPut(self.gpa, index)).found_existing) {
                            const join = self.binding_joins.items[index];
                            if (!join.complete) result.incomplete = true;
                            try pending.appendSlice(self.gpa, join.alternatives.items);
                            current = join.initial;
                            continue;
                        }
                    },
                }
                current = pending.pop() orelse break;
            }
            return result;
        }

        fn resolvePendingReferenceUses(self: *Self) !void {
            for (self.initializer_write_checks.items) |check| {
                try self.checkInitializerReferenceWrite(try self.completeReferenceOrigins(check.origins), check.owners, check.locals, check.span);
            }
            for (self.pending_mutable_alias_checks.items) |pending| {
                var origins = self.originList(try self.completeReferenceOrigins(pending.origins));
                const place_origins = try self.completeReferenceOrigins(pending.place_origins);
                while (origins.next()) |origin| {
                    if (self.originAliasesPlace(origin, pending.local, place_origins)) return self.reject(pending.span, .overlapping_mutable_arguments);
                }
            }
            for (self.pending_reference_invalidations.items) |pending| {
                var origins = self.originList(try self.completeReferenceOrigins(pending.origins));
                while (origins.next()) |origin| {
                    const root = origin.root orelse continue;
                    var known = self.originList(pending.known);
                    while (known.next()) |candidate| {
                        if (candidate.root == root) break;
                    } else return self.reject(pending.span, .borrow_outlives_source);
                }
            }
            for (self.pending_reference_returns.items) |pending_return| {
                try self.validateReferenceEscape(try self.completeReferenceOrigins(pending_return.origins), pending_return.span);
            }
            var pending_index = self.pending_reference_uses.items.len;
            while (pending_index > 0) {
                pending_index -= 1;
                const pending_use = self.pending_reference_uses.items[pending_index];
                const origins = try self.completeReferenceOrigins(pending_use.origins);
                var effects: std.ArrayList(LifetimeEffect) = .empty;
                var incomplete = false;

                try self.collectReferenceUses(origins, self.states.items[@backingInt(pending_use.state)], pending_use.span, pending_use.kind, &effects, &incomplete);
                std.debug.assert(!incomplete);
                const stored_effects = try self.gpa.alloc(body_graph.Effect, effects.items.len);
                defer self.gpa.free(stored_effects);
                for (effects.items, stored_effects) |effect, *stored| stored.* = .{ .id = try self.newEffectId(), .operation = effect };
                const location_effects, const effect_index = switch (self.findEffectLocation(pending_use.location)) {
                    .boundary => |location| .{ &self.boundaries.items[@backingInt(location.id)].effects, location.effect_index },
                    .terminator => |location| .{ &self.blocks.items[@backingInt(location.id)].terminator_effects, location.effect_index },
                };
                try location_effects.insertSlice(self.gpa, effect_index, stored_effects);
            }
        }

        fn recordConsume(self: *Self, source: Value) !void {
            var owners = source.pending_consumption_owners;
            while (owners) |index| {
                const owner = self.pending_consumption_owners.items[index];
                const availability = if (owner.field) |field| self.state.field_availability.get(field) else self.state.availability.get(@backingInt(owner.local));
                const place = if (owner.field) |field| self.state.values.len + field else @backingInt(owner.local);
                if (availability == .transferred) {
                    if (owner.generation) |generation| try self.recordEffect(.{ .consume = generation });
                    try self.state.completed_consumptions.set(self.gpa, place, true);
                } else if (owner.generation) |generation| {
                    try self.recordEffect(.{ .use = .{ .generation = generation, .cleanup_value = owner.cleanup_value } });
                }
                owners = owner.next;
            }
            if (source.consumption_completion) |completion| {
                for (self.capture_transfers.items) |transfer| {
                    if (@as(structures.FunctionValueId, @fromBackingInt(@intCast(transfer.parameter))) != completion) continue;
                    const place = if (transfer.field) |field| self.state.values.len + field else @backingInt(transfer.local);
                    try self.state.completed_consumptions.set(self.gpa, place, true);
                }
                const completed = try self.appendInstruction(.{ .const_bool = true });
                _ = try self.appendInstruction(.{ .value_copy = .{ .source = completed.id, .destination = completion, .type_id = .bool } });
            }
            if (source.owned_generation) |generation| try self.recordEffect(.{ .consume = generation });
        }

        fn addPendingConsumptionOwner(self: *Self, owners: ?u32, pending: PendingConsumptionOwner) !?u32 {
            var current = owners;
            while (current) |index| {
                const owner = self.pending_consumption_owners.items[index];
                if (owner.generation == pending.generation and owner.local == pending.local and owner.field == pending.field) return owners;
                current = owner.next;
            }
            const index: u32 = @intCast(self.pending_consumption_owners.items.len);
            var added = pending;
            added.next = owners;
            try self.pending_consumption_owners.append(self.gpa, added);
            return index;
        }

        fn newConsumptionCompletion(self: *Self, owner: ?GenerationId, field_owner: bool) !Value {
            const block_id = self.current_block.?;
            const item_start = self.blocks.items[@backingInt(block_id)].items.items.len;
            const flag = try self.localStorage(.bool);
            _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = field_owner }), flag);
            const initialization = try self.gpa.dupe(body_graph.BuildItem, self.blocks.items[@backingInt(block_id)].items.items[item_start..]);

            self.blocks.items[@backingInt(block_id)].items.shrinkRetainingCapacity(item_start);
            // Initialize the flag where its owner is defined, or at entry for an owner from outside the body.
            const owner_block: usize, const owner_item: usize = find: {
                const generation = owner orelse break :find .{ 0, 0 };
                for (self.blocks.items, 0..) |block_value, block_index| {
                    for (block_value.items.items, 0..) |item, item_index| {
                        if (item != .boundary) continue;
                        for (self.boundaries.items[@backingInt(item.boundary)].effects.items) |effect| {
                            const operation = effect.operation orelse continue;
                            if (operation == .define and operation.define.generation == generation) break :find .{ block_index, item_index };
                        }
                    }
                }
                break :find .{ 0, 0 };
            };
            try self.insertBlockItems(@fromBackingInt(@intCast(owner_block)), owner_item, initialization);
            _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = false }), flag);
            return flag;
        }

        fn mergePendingConsumptionOwners(self: *Self, first: ?u32, second: ?u32) !?u32 {
            var joined = first;
            var current = second;
            while (current) |index| {
                const owner = self.pending_consumption_owners.items[index];
                joined = try self.addPendingConsumptionOwner(joined, owner);
                current = owner.next;
            }
            return joined;
        }

        fn laterBorrowRoot(left: ?semantic.UnresolvedBody.LocalId, right: ?semantic.UnresolvedBody.LocalId) ?semantic.UnresolvedBody.LocalId {
            const left_id = left orelse return right;
            const right_id = right orelse return left;
            return if (@backingInt(left_id) >= @backingInt(right_id)) left_id else right_id;
        }

        const StructTypeResult = union(enum) { diverged: Value, type_id: structures.TypeId };

        fn inPlaceStructFieldType(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId) anyerror!StructTypeResult {
            if (self.expressionOperation(id)) |operation| if (operation.* == .struct_init) {
                const initializer = operation.struct_init;
                const type_id = switch (try self.structInitType(initializer)) {
                    .diverged => |diverged| return .{ .diverged = diverged },
                    .type_id => |resolved| resolved,
                };
                const capabilities = (try self.analysis_context.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
                // A struct that cannot move directly is typed field by field instead of evaluated.
                if (!capabilities.isDirectlyMovable()) {
                    const definition = try self.structInitializerDefinition(initializer, type_id);
                    if (initializer.target == .concrete) for (self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |field| {
                        const field_result = try self.inPlaceStructFieldType(field.value.value, definition.resolveField(field.name).?.type_id);
                        if (field_result == .diverged) return field_result;
                    };
                    return .{ .type_id = type_id };
                }
            };
            const operand = try self.valueWithType(id, expected_type);
            return if (operand.type_id == .never) .{ .diverged = operand } else .{ .type_id = operand.type_id };
        }

        fn unevaluatedType(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId) anyerror!?structures.TypeId {
            if (self.options.measurements) |measurements| measurements.unevaluated_type_visits += 1;
            if (try self.readTypeValue(id)) |source| return source.type_id;
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) return self.values.get(index).?.type_id;
            if (self.values.get(index)) |resolved| return resolved.type_id;
            return switch (self.unresolved.expressions[index - self.unresolved.parameter_count].operation) {
                .integer_literal => if (expected_type == .int_literal) .int_literal else if (expected_type == .byte) .byte else .int,
                .int_literal_value => .int_literal,
                .string_literal => if (expected_type == .string_literal)
                    .string_literal
                else if (expected_type != null and try semantic.canWidenTo(self.analysis_context, try self.analysis_context.staticStringType(), expected_type.?))
                    try self.analysis_context.staticStringType()
                else
                    try self.analysis_context.stringType(),
                .storage_cursor => |cursor| cursor.type_id,
                .integer => .int,
                .byte => .byte,
                .boolean => .bool,
                .unit => .unit,
                .none => .none,
                .function_ref => |reference| reference.type_id,
                .overloaded_function => |choices| (try self.overloadedFunction(choices, expected_type, self.valueSpan(id))).type_id,
                .annotation => |annotation| annotation.type_id,
                .array_init => |initializer| initializer.type_id,
                .collection_literal => |literal| try self.collectionType(literal.elements, expected_type, self.valueSpan(id)),
                .collection_comprehension, .collection_emit, .collection_spread, .collection_iteration => .unit,
                .tuple_literal => |elements| try self.tupleType(elements, expected_type, self.valueSpan(id)),
                .local_read, .local_transfer => |local| if (stateValue(self.state.values, @backingInt(local)) == null) null else try self.placeRootType(.{ .local = local }),
                .field_transfer => |transfer| blk: {
                    if (self.state.values.get(@backingInt(transfer.target)) == null) break :blk null;
                    var type_id = try self.placeRootType(.{ .local = transfer.target });
                    for (self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end]) |field|
                        type_id = (try self.resolvePlaceField(type_id, field.name, field.span, field.span)).type_id;
                    break :blk type_id;
                },
                .field_access => |access| blk: {
                    const operand_type = (try self.unevaluatedType(access.operand.value, null)) orelse break :blk null;
                    if (operand_type == .never) break :blk .never;
                    const definition = (try self.analysis_context.facts().structDefinition(operand_type)) orelse break :blk null;
                    const field = definition.resolveField(access.name) orelse break :blk null;
                    break :blk field.type_id;
                },
                .index_snapshot => |source| try self.unevaluatedType(source.value, expected_type),
                .discard => .unit,
                .comparison, .static_membership, .variant_membership, .iterator_membership, .conjunction, .disjunction, .negation, .pattern_test => .bool,
                .struct_init => |initializer| switch (initializer.target) {
                    .concrete => |type_id| type_id,
                    .inferred => |factory| if (try self.inferStructType(factory, initializer, false)) |result| result.type_id else null,
                },
                .call => |call| try self.unevaluatedCallType(call),
                .sequence => |operands| try self.unevaluatedType(operands.rhs.value, expected_type),
                .if_else => |branches| blk: {
                    if (expected_type != null) {
                        const literal_then = try self.unevaluatedBranchType(branches.then_block, .string_literal);
                        const literal_else = try self.unevaluatedBranchType(branches.else_block, .string_literal);
                        if ((literal_then == .string_literal or literal_then == .never) and (literal_else == .string_literal or literal_else == .never) and
                            (literal_then == .string_literal or literal_else == .string_literal))
                            break :blk .string_literal;
                    }
                    break :blk try self.inferArgumentType(.{ .value = id, .span = self.valueSpan(id) });
                },
                .match => |selection| blk: {
                    if (expected_type != null) {
                        var has_string = false;
                        for (self.unresolved.match_arms[selection.arms.start..selection.arms.end]) |arm| {
                            const literal = try self.unevaluatedBranchType(arm.body, .string_literal);
                            if (literal != .string_literal and literal != .never) break;
                            has_string = has_string or literal == .string_literal;
                        } else if (has_string) break :blk .string_literal;
                    }
                    break :blk try self.inferArgumentType(.{ .value = id, .span = self.valueSpan(id) });
                },
                .assignment, .reference_assignment => .unit,
                .loop, .scope, .iterator, .iterator_item => try self.inferArgumentType(.{ .value = id, .span = self.valueSpan(id) }),
                .type_value => .type,
            };
        }

        fn inPlaceControlFlowType(self: *Self, id: semantic.UnresolvedBody.ValueId) !?structures.TypeId {
            var expression = id;
            while (true) {
                const index = @backingInt(expression);
                if (index < self.unresolved.parameter_count or self.values.get(index) != null) return null;
                switch (self.unresolved.expressions[index - self.unresolved.parameter_count].operation) {
                    .annotation => |annotation| expression = annotation.value.value,
                    .if_else, .match, .loop, .scope => break,
                    else => return null,
                }
            }
            const type_id = (try self.unevaluatedType(id, null)) orelse return null;
            return if (try self.usesIndirectStorage(type_id)) type_id else null;
        }

        fn unevaluatedBranchType(self: *Self, block_id: semantic.UnresolvedBody.BlockId, expected_type: ?structures.TypeId) !?structures.TypeId {
            const result = self.unresolved.blocks[@backingInt(block_id)].result orelse return .never;
            if (expected_type == .string_literal) {
                const operation = self.expressionOperation(result) orelse return null;
                if (operation.* != .string_literal) return null;
            }
            return self.unevaluatedType(result, expected_type);
        }

        /// Specializes a struct factory from its initializer's field types. Without
        /// evaluation, unknown types make the result unknown; evaluating in place rejects failures.
        fn inferStructType(self: *Self, factory: structures.InstanceId, initializer: @FieldType(Expression.Operation, "struct_init"), comptime in_place: bool) !?StructTypeResult {
            const fields = self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end];
            var field_types: std.ArrayList(structures.TypeId) = .empty;

            for (fields) |field| {
                const expected = try self.analysis_context.independentStructFieldType(factory, field.name);
                const field_type = if (in_place) switch (try self.inPlaceStructFieldType(field.value.value, expected)) {
                    .diverged => |diverged| return .{ .diverged = diverged },
                    .type_id => |type_id| type_id,
                } else (try self.unevaluatedType(field.value.value, expected)) orelse return null;
                try field_types.append(self.gpa, field_type);
            }
            const arguments = switch (try self.analysis_context.inferStructArguments(factory, fields, field_types.items)) {
                .arguments => |arguments| arguments,
                .missing => return if (in_place) self.reject(initializer.type_span, .static_argument_cannot_be_inferred) else null,
                .conflict => return if (in_place) self.reject(initializer.type_span, .static_argument_inference_conflict) else null,
            };

            return .{ .type_id = try self.analysis_context.specializedStructType(try self.analysis_context.specializeFunction(factory, arguments)) };
        }

        const MemberFunction = struct {
            instance: structures.InstanceId,
            shape: structures.FunctionShape,
            ownership: bool = false,
        };
        const MemberTarget = union(enum) {
            field: structures.TypeId,
            function: MemberFunction,
            overloaded: structures.FunctionOverloadId,
            static_callable: structures.CompileTimeValue.Runtime,
        };

        fn memberTarget(self: *Self, receiver_type: structures.TypeId, member: semantic.UnresolvedBody.MemberCall, operands: usize, span: structures.SourceSpan) !MemberTarget {
            const operand_type = if (receiver_type == .int_literal) structures.TypeId.int else receiver_type;
            if (std.meta.stringToEnum(structures.OwnershipMember, member.name)) |operation| {
                const instance = (try self.analysis_context.ownershipMember(operand_type, operation)) orelse return self.reject(span, .unknown_namespace_member);
                return .{ .function = .{ .instance = instance, .shape = (try self.analysis_context.functionShape(instance.item)) orelse return error.Unavailable, .ownership = true } };
            }
            if (try self.analysis_context.facts().structDefinition(receiver_type)) |definition| {
                if (definition.resolveField(member.name) != null)
                    return .{ .field = (try self.resolvePlaceField(receiver_type, member.name, member.receiver.span, span)).type_id };
            } else if (!receiver_type.isPrimitive() and try self.analysis_context.facts().arrayType(receiver_type) == null)
                return self.rejectRead(member.receiver.span, .{ .field_access_not_struct = receiver_type }, member.receiver.value);
            const reference = (try self.analysis_context.typeNamespaceCallMember(operand_type, member.name, operands, span)) orelse {
                const kind: structures.Diagnostic.Kind = if (structures.Operation.fromName(member.name, operands)) |operation|
                    .{ .missing_operation = .{ .receiver = operand_type, .operation = operation } }
                else
                    .unknown_namespace_member;
                return self.rejectRead(span, kind, member.receiver.value);
            };
            if (reference == .overloaded_function) return .{ .overloaded = reference.overloaded_function };
            std.debug.assert(reference == .declaration);
            const instance = reference.declaration;
            if (try self.analysis_context.functionShape(instance.item)) |shape| return .{ .function = .{ .instance = instance, .shape = shape } };
            const value_id = (try self.analysis_context.staticItem(instance)) orelse return error.Unavailable;
            const callee = try self.analysis_context.lookupCompileTimeValue(value_id);
            if (callee != .runtime) return self.reject(span, .value_not_callable);
            return .{ .static_callable = callee.runtime };
        }

        fn arraySpreadIterator(self: *Self, source: semantic.UnresolvedBody.ValueUse, array: structures.ArrayType, span: structures.SourceSpan) !Value {
            const factory = (try self.analysis_context.stdMemoryFunction("collection_array_iterator")) orelse return error.Unavailable;
            const element = try self.analysis_context.internCompileTimeValue(.{ .type = array.element_type });
            const length = try self.analysis_context.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(array.length) } } });
            const instance = try self.analysis_context.specializeFunction(.{ .item = factory }, &.{ element, length });
            const call: semantic.UnresolvedBody.Call = .{ .target = .{ .direct = instance }, .arguments = .{ .start = 0, .end = 0 }, .span = span };
            switch (try self.resolveCall(call, span, &.{source})) {
                .diverged => |value_to_return| return value_to_return,
                .callable => |callable| return self.resolvedCallResult(callable, call, span, .{}),
            }
        }

        fn iteratorValue(self: *Self, source: semantic.UnresolvedBody.ValueUse, acquisition: semantic.UnresolvedBody.ValueId, structural_array: bool, span: structures.SourceSpan) !Value {
            const source_type = (try self.unevaluatedType(source.value, null)) orelse return error.Unavailable;
            if (structural_array) if (try self.analysis_context.facts().arrayType(source_type)) |array| return self.arraySpreadIterator(source, array, span);
            const definition = try self.analysis_context.facts().structDefinition(source_type);
            var factory: []const u8 = "iter";
            const transferred = if (self.values.get(@backingInt(acquisition))) |prepared| prepared.explicit_transfer else false;
            if (transferred and
                ((definition != null and definition.?.resolveField("consume_iter") != null) or
                    try self.analysis_context.typeNamespaceCallMember(source_type, "consume_iter", 1, span) != null)) factory = "consume_iter";
            const field = if (definition) |structure| structure.resolveField(factory) else null;
            if (field != null or try self.analysis_context.typeNamespaceCallMember(source_type, factory, 1, span) != null) {
                return self.callFunction(.{
                    .target = .{ .member = .{ .receiver = source, .name = factory } },
                    .arguments = .{ .start = 0, .end = 0 },
                    .span = span,
                }, span, .{});
            }
            const reference = try self.flowBindingReference(source, source_type);
            if (reference.type_id == .never) return reference;
            return self.readReference(reference, source_type);
        }

        fn overloadedFunction(self: *Self, overload: structures.FunctionOverloadId, expected_type: ?structures.TypeId, span: structures.SourceSpan) !structures.FunctionReference {
            const set = try self.analysis_context.functionOverloads(overload);
            const missing_context: structures.Diagnostic.Kind = if (set.declaration == null) .ambiguous_operation_reference else .overload_requires_callable_context;
            const expected = expected_type orelse return self.reject(span, missing_context);
            const signature = (try self.analysis_context.facts().callable(expected)) orelse return self.reject(span, missing_context);
            switch (try self.matchFunctionOverload(overload, signature, span)) {
                .none => return self.reject(span, .{ .no_matching_overload = expected }),
                .ambiguous => return self.reject(span, .ambiguous_overload),
                .unique => |instance| return (try self.analysis_context.functionItemReference(instance)) orelse return self.reject(span, .static_parameter_requires_specialization),
            }
        }

        const FunctionOverloadMatch = union(enum) { none, unique: structures.InstanceId, ambiguous };

        fn matchFunctionOverload(self: *Self, overload: structures.FunctionOverloadId, signature: structures.CallableType, span: structures.SourceSpan) !FunctionOverloadMatch {
            const set = try self.analysis_context.functionOverloads(overload);
            var argument_types: std.ArrayList(structures.TypeId) = .empty;

            for (signature.parameters) |parameter| try argument_types.append(self.gpa, parameter.type_id);
            var selected: ?structures.InstanceId = null;
            for (set.candidates) |candidate| {
                const instance = (try self.overloadInstance(candidate, argument_types.items)) orelse continue;
                const header = (try self.analysis_context.candidateSignature(instance)) orelse return error.Unavailable;
                try self.analysis_context.validateOverloadHeader(overload, instance, header, span);
                if (!header.parametersEql(signature) or header.return_type != signature.return_type or
                    header.result_mode != signature.result_mode) continue;
                if (selected != null) return .ambiguous;
                selected = instance;
            }
            return if (selected) |instance| .{ .unique = instance } else .none;
        }

        fn snapshotIndex(self: *Self, source: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId) !Value {
            var operand = try self.borrowValue(try self.valueWithType(source.value, expected_type), source.span);
            if (operand.type_id == .never) return operand;
            if (operand.type_id.isPrimitive() and try self.analysis_context.facts().argumentPassing(operand.type_id) == .direct) {
                operand.materialize_on_copy = true;
                operand = try self.ownValue(operand, source.span);
                if (!try self.analysis_context.facts().canStoreBorrow(operand.type_id)) operand.reference_origins = null;
            }
            return operand;
        }

        fn overloadInstance(self: *Self, candidate: structures.InstanceId, argument_types: []const structures.TypeId) !?structures.InstanceId {
            const shape = (try self.analysis_context.functionShape(candidate.item)) orelse return error.Unavailable;
            var runtime_count: usize = 0;
            var needs_inference = try self.analysis_context.needsInheritedInference(candidate);
            for (shape.parameters) |parameter| {
                if (parameter.mode == .static) {
                    needs_inference = true;
                } else runtime_count += 1;
            }
            if (runtime_count != argument_types.len) return null;
            if (!needs_inference) return candidate;
            const inferred = switch (try self.analysis_context.inferStaticArguments(candidate, argument_types)) {
                .arguments => |arguments| arguments,
                .missing, .conflict => return null,
            };

            return try self.analysis_context.specializeFunction(candidate, inferred);
        }

        fn overloadArgumentType(self: *Self, argument: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId, discovered_type: ?*?structures.TypeId) anyerror!?structures.TypeId {
            if (self.expressionOperation(argument.value)) |operation| switch (operation.*) {
                .overloaded_function => |overload| {
                    const expected = expected_type orelse return null;
                    const callable = (try self.analysis_context.facts().callable(expected)) orelse return null;
                    if (try self.matchFunctionOverload(overload, callable, argument.span) == .none) return null;
                    return expected;
                },
                .tuple_literal => |range| {
                    const expected = expected_type orelse return try self.tupleType(range, null, argument.span);
                    const members = (try self.analysis_context.facts().tupleMembers(expected)) orelse return null;
                    const elements = self.unresolved.call_arguments[range.start..range.end];
                    if (members.len != elements.len) return null;
                    for (members, elements) |member, element| {
                        const actual = (try self.overloadArgumentType(element, member.type_id, null)) orelse return null;
                        if (!try semantic.canWidenTo(self.analysis_context, actual, member.type_id)) return null;
                    }
                    return expected;
                },
                else => {},
            };
            if (discovered_type) |known| if (known.*) |type_id| return type_id;
            if (self.options.measurements) |measurements| measurements.overload_argument_discoveries += 1;
            const type_id = (try self.unevaluatedType(argument.value, null)) orelse try self.inferArgumentType(argument);
            if (discovered_type) |known| known.* = type_id;
            return type_id;
        }

        fn resolveOverload(
            self: *Self,
            overload: structures.FunctionOverloadId,
            provided: []const semantic.UnresolvedBody.MethodCallArgument,
            span: structures.SourceSpan,
            arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse),
        ) !structures.InstanceId {
            const set = try self.analysis_context.functionOverloads(overload);
            const operation = try self.analysis_context.overloadOperation(overload);
            const discovered_types = try self.gpa.alloc(?structures.TypeId, provided.len);

            @memset(discovered_types, null);
            var candidate_arguments: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
            var argument_types: std.ArrayList(structures.TypeId) = .empty;

            var static_arguments: std.ArrayList(structures.CompileTimeValueId) = .empty;
            var selected: ?structures.InstanceId = null;
            const start = arguments.items.len;
            candidates: for (set.candidates) |candidate| {
                const shape = (try self.analysis_context.functionShape(candidate.item)) orelse return error.Unavailable;
                var runtime_count: usize = 0;
                for (shape.parameters) |parameter| if (parameter.mode != .static) {
                    runtime_count += 1;
                };
                if (provided.len != runtime_count and provided.len != shape.parameters.len) continue;
                const concrete_header = if (runtime_count == shape.parameters.len and !try self.analysis_context.needsInheritedInference(candidate))
                    (try self.analysis_context.candidateSignature(candidate)) orelse return error.Unavailable
                else
                    null;
                candidate_arguments.clearRetainingCapacity();
                argument_types.clearRetainingCapacity();
                static_arguments.clearRetainingCapacity();
                var instance = candidate;
                if (provided.len == runtime_count) {
                    for (provided, 0..) |argument, runtime_index| {
                        const expected = if (concrete_header) |header| header.parameters[runtime_index].type_id else try self.analysis_context.independentParameterType(candidate, runtime_index);
                        const actual = (try self.overloadArgumentType(argument.value, expected, &discovered_types[runtime_index])) orelse continue :candidates;
                        try candidate_arguments.append(self.gpa, argument.value);
                        try argument_types.append(self.gpa, if (operation != null and actual == .int_literal) .int else actual);
                    }
                    if (concrete_header == null) instance = (try self.overloadInstance(candidate, argument_types.items)) orelse continue;
                } else {
                    if (try self.analysis_context.needsInheritedInference(candidate)) continue;
                    for (provided, shape.parameters, 0..) |argument, parameter, parameter_index| {
                        if (parameter.mode != .static) {
                            try candidate_arguments.append(self.gpa, argument.value);
                            continue;
                        }
                        if (argument.node == .null or argument.runtime_reference != null) continue :candidates;
                        const expected = if (parameter.is_meta_type) null else try self.analysis_context.staticParameterType(candidate, parameter_index, static_arguments.items);
                        const actual = (try self.overloadArgumentType(argument.value, expected, &discovered_types[parameter_index])) orelse continue :candidates;
                        if (!try semantic.canWidenTo(self.analysis_context, actual, expected orelse .type)) continue :candidates;
                        const static_value = (try self.analysis_context.staticCallArgument(argument.node, parameter.is_meta_type, expected)) orelse return error.Unavailable;
                        try static_arguments.append(self.gpa, static_value);
                    }
                    instance = try self.analysis_context.specializeFunction(candidate, static_arguments.items);
                }
                const header = concrete_header orelse (try self.analysis_context.candidateSignature(instance)) orelse return error.Unavailable;
                try self.analysis_context.validateOverloadHeader(overload, instance, header, span);
                if (provided.len != runtime_count) for (provided, shape.parameters, 0..) |argument, parameter, argument_index| {
                    if (parameter.mode == .static) continue;
                    const expected = header.parameters[argument_types.items.len].type_id;
                    const actual = (try self.overloadArgumentType(argument.value, expected, &discovered_types[argument_index])) orelse continue :candidates;
                    try argument_types.append(self.gpa, if (operation != null and actual == .int_literal) .int else actual);
                };
                std.debug.assert(header.parameters.len == argument_types.items.len);
                for (header.parameters, argument_types.items) |parameter, actual| {
                    if (!try semantic.canWidenTo(self.analysis_context, actual, parameter.type_id)) continue :candidates;
                }
                if (selected != null) return self.reject(span, if (set.declaration == null) .ambiguous_operation_reference else .ambiguous_overload);
                selected = instance;
                arguments.shrinkRetainingCapacity(start);
                try arguments.appendSlice(self.gpa, candidate_arguments.items);
            }
            const instance = selected orelse return self.reject(span, .{ .no_matching_overload = null });
            _ = (try self.analysis_context.functionSignature(instance)) orelse return error.Unavailable; // Validate only the selected specialization's constraints.
            return instance;
        }

        fn resolveValueOverload(self: *Self, overload: structures.FunctionOverloadId, provided: []const semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan, arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse)) !structures.InstanceId {
            var sources: std.ArrayList(semantic.UnresolvedBody.MethodCallArgument) = .empty;

            for (provided) |argument| try sources.append(self.gpa, .{ .node = .null, .value = argument, .runtime_reference = null });
            return self.resolveOverload(overload, sources.items, span, arguments);
        }

        fn resolveMemberOverload(self: *Self, overload: structures.FunctionOverloadId, call: semantic.UnresolvedBody.Call, receiver: semantic.UnresolvedBody.ValueUse, provided: []const semantic.UnresolvedBody.MethodCallArgument, arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse)) !structures.InstanceId {
            var sources: std.ArrayList(semantic.UnresolvedBody.MethodCallArgument) = .empty;

            try sources.append(self.gpa, .{ .node = .null, .value = receiver, .runtime_reference = null });
            try sources.appendSlice(self.gpa, provided);
            return self.resolveOverload(overload, sources.items, call.span, arguments);
        }

        fn operationTarget(self: *Self, receiver_type: structures.TypeId, operation: structures.Operation, arguments: []const semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !CallTarget {
            const operand_type = if (receiver_type == .int_literal) structures.TypeId.int else receiver_type;
            const reference = (try self.analysis_context.typeNamespaceCallMember(operand_type, operation.spelling(), arguments.len, span)) orelse
                return self.rejectRead(span, .{ .missing_operation = .{ .receiver = operand_type, .operation = operation } }, arguments[0].value);
            if (reference == .overloaded_function) {
                var resolved: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;

                return .{ .direct = try self.resolveValueOverload(reference.overloaded_function, arguments, span, &resolved) };
            }
            std.debug.assert(reference == .declaration);
            const instance = reference.declaration;
            if (try self.analysis_context.needsInheritedInference(instance)) return .{ .inferred = instance };
            const shape = (try self.analysis_context.functionShape(instance.item)) orelse return error.Unavailable;
            for (shape.parameters) |parameter| if (parameter.mode == .static) return .{ .inferred = instance };
            return .{ .direct = instance };
        }

        fn callOriginsForType(self: *Self, source: CallOriginSource, result_type: structures.TypeId) !?u32 {
            if (source.storage == null) return source.contained;
            if (try self.analysis_context.canBorrowStorageOf(result_type, source.type_id))
                return self.mergeReferenceOrigins(source.contained, source.storage);
            return source.contained;
        }

        fn unevaluatedTargetType(self: *Self, target: CallTarget, arguments: []const semantic.UnresolvedBody.ValueUse) !?structures.TypeId {
            const instance = switch (target) {
                .direct => |instance| instance,
                .inferred => |generic| (try self.unevaluatedSpecialization(generic, arguments, null)) orelse return null,
                .indirect => unreachable,
            };
            return ((try self.analysis_context.functionSignature(instance)) orelse return error.Unavailable).return_type;
        }

        fn unevaluatedCallType(self: *Self, call: semantic.UnresolvedBody.Call) !?structures.TypeId {
            const arguments = if (call.target == .member or call.target == .overloaded) &.{} else self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            const target: CallTarget = switch (call.target) {
                .direct => |instance| .{ .direct = instance },
                .inferred => |generic| .{ .inferred = generic },
                .overloaded => |overload| blk: {
                    var resolved: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
                    const instance = try self.resolveOverload(overload, self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end], call.span, &resolved);
                    break :blk .{ .direct = instance };
                },
                .operation => |name| blk: {
                    const receiver_type = (try self.unevaluatedType(arguments[0].value, null)) orelse return null;
                    if (receiver_type == .never) return .never;
                    break :blk try self.operationTarget(receiver_type, name, arguments, call.span);
                },
                .value => |callee| {
                    const callee_type = (try self.unevaluatedType(callee.value, null)) orelse return null;
                    if (callee_type == .never) return .never;
                    return (try self.callableSignature(callee_type, callee.span)).return_type;
                },
                .member => |member| return self.unevaluatedMemberCallType(call, member),
                .membership => return .unit,
                .unknown_function => return self.reject(call.span, .unknown_function),
            };
            return self.unevaluatedTargetType(target, arguments);
        }

        fn unevaluatedMemberCallType(self: *Self, call: semantic.UnresolvedBody.Call, member: semantic.UnresolvedBody.MemberCall) !?structures.TypeId {
            const receiver_type = (try self.unevaluatedType(member.receiver.value, null)) orelse return null;
            if (receiver_type == .never) return .never;
            switch (try self.memberTarget(receiver_type, member, call.arguments.end - call.arguments.start + 1, call.span)) {
                .field => |type_id| return (try self.callableSignature(type_id, call.span)).return_type,
                .static_callable => |callee| return (try self.callableSignature(callee.type_id, call.span)).return_type,
                .overloaded => |overload| {
                    var arguments: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
                    const instance = try self.resolveMemberOverload(overload, call, member.receiver, self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end], &arguments);
                    return self.unevaluatedTargetType(.{ .direct = instance }, arguments.items);
                },
                .function => |function| {
                    if (function.ownership) return self.unevaluatedTargetType(.{ .direct = function.instance }, &.{});
                    var arguments: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;

                    try arguments.append(self.gpa, member.receiver);
                    const target = try self.resolveMethodArguments(function.instance, function.shape, self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end], call.span, &arguments);
                    return self.unevaluatedTargetType(target, arguments.items);
                },
            }
        }

        fn callableSignature(self: *Self, type_id: structures.TypeId, span: structures.SourceSpan) !structures.CallableType {
            return (try self.analysis_context.facts().callable(type_id)) orelse
                self.reject(span, .value_not_callable);
        }

        fn unevaluatedSpecialization(self: *Self, generic: structures.InstanceId, arguments: []const semantic.UnresolvedBody.ValueUse, span: ?structures.SourceSpan) !?structures.InstanceId {
            const shape = (try self.analysis_context.functionShape(generic.item)) orelse return error.Unavailable;
            var argument_types: std.ArrayList(structures.TypeId) = .empty;

            for (shape.parameters) |parameter| {
                if (parameter.mode == .static) continue;
                const runtime_index = argument_types.items.len;
                if (runtime_index == arguments.len) return null;
                const expected = try self.analysis_context.independentParameterType(generic, runtime_index);
                const type_id = if (parameter.mode == .init)
                    try self.inferInitializerArgumentType(arguments[runtime_index], expected)
                else
                    (try self.unevaluatedType(arguments[runtime_index].value, expected)) orelse try self.inferArgumentType(arguments[runtime_index]);
                try argument_types.append(self.gpa, if (type_id == .int_literal and expected == null) .int else type_id);
            }
            if (argument_types.items.len != arguments.len) return null;
            const inferred = switch (try self.analysis_context.inferStaticArguments(generic, argument_types.items)) {
                .arguments => |inferred| inferred,
                .missing => {
                    if (span) |call_span| return self.reject(call_span, .static_argument_cannot_be_inferred);
                    return null;
                },
                .conflict => {
                    if (span) |call_span| return self.reject(call_span, .static_argument_inference_conflict);
                    return null;
                },
            };

            return try self.analysis_context.specializeFunction(generic, inferred);
        }

        fn structInitType(self: *Self, initializer: @FieldType(Expression.Operation, "struct_init")) !StructTypeResult {
            return switch (initializer.target) {
                .concrete => |concrete| .{ .type_id = concrete },
                .inferred => |factory| (try self.inferStructType(factory, initializer, false)) orelse (try self.inferStructType(factory, initializer, true)).?,
            };
        }

        fn accessField(self: *Self, operand_use: semantic.UnresolvedBody.ValueUse, name: []const u8, span: structures.SourceSpan) !Value {
            var place_fields: std.ArrayList(PlaceField) = .empty;

            if (try self.resolveArgumentPlace(operand_use.value, &place_fields)) |place| {
                if (place.root == .local and self.unavailableField(place.root.local, &[_]PlaceField{}) != null) {
                    const local_index = @backingInt(place.root.local);
                    if (self.state.availability.get(local_index) != .available)
                        return self.reject(span, unavailableUse(self.state.availability.get(local_index)));
                    const root = self.state.values.get(local_index).?;
                    const parent_type = if (place_fields.items.len == 0) root.type_id else place_fields.last().?.type_id;
                    try place_fields.append(self.gpa, try self.resolvePlaceField(parent_type, name, operand_use.span, span));
                    if (self.unavailableField(place.root.local, place_fields.items[place.fields.start..])) |availability|
                        return self.reject(span, unavailableUse(availability));
                    const source = try self.borrowValue(self.borrowLocalValue(place.root.local), operand_use.span);
                    var field = try self.projectFields(source, place_fields.items[place.fields.start..], false);
                    field.borrowed_type = field.type_id;
                    field.borrowed_generation = source.borrowed_generation;
                    field.borrowed_cleanup_value = source.borrowed_cleanup_value;
                    field.borrow_root = place.root.local;
                    field.binding_identity = source.binding_identity;
                    return field;
                }
            }
            const operand = try self.borrowValue(try self.value(operand_use.value), operand_use.span);
            if (operand.type_id == .never) return operand;
            const field = try self.resolvePlaceField(operand.type_id, name, operand_use.span, span);
            if (field.kind == .reference) {
                const reference = try self.referenceField(operand, field);
                return self.readReference(reference, field.type_id);
            }
            var result = try self.fieldView(operand, field.index, field.type_id);
            result.writable = operand.writable;
            result.place_origins = try self.appendSourcePath(operand.place_origins, .{ .field = field.index });
            if (!field.type_id.isPrimitive()) {
                result.flow_origins = try self.appendSourcePath(try self.valuePlaceOrigins(operand), .{ .field = field.index });
                const root = operand.local_reference orelse if (operand.borrow_root) |local|
                    LocalReference{ .local = local, .projections = .{ .start = 0, .end = 0 } }
                else
                    null;
                result.local_reference = try self.extendLocalReference(root, &.{field}, null);
            }
            result.reference_origins = if (try self.analysis_context.facts().isStaticString(operand.type_id))
                try self.addReferenceOrigin(null, .{ .permanent = true, .readonly = true })
            else
                try self.transformReferenceOrigins(operand.reference_origins, .{ .select = .{ .field = field.index } });
            result.binding_identity = operand.binding_identity;
            if (operand.borrowed_type != null) {
                result.borrowed_type = field.type_id;
                result.borrowed_generation = operand.borrowed_generation;
                result.borrowed_cleanup_value = operand.borrowed_cleanup_value;
                result.borrow_root = operand.borrow_root;
                if (operand.borrow_condition) |borrow_condition| {
                    return self.accessConditionalTemporary(operand, result, borrow_condition, span);
                }
            } else if ((try self.analysis_context.facts().ownershipCapabilities(operand.type_id) orelse return error.Unavailable).needs_automatic_drop) {
                result.borrowed_type = field.type_id;
                result.borrowed_generation = operand.owned_generation;
                result.borrowed_cleanup_value = operand.id;
                result = try self.ownValue(result, span);
            }
            return result;
        }

        fn accessConditionalTemporary(self: *Self, operand: Value, field: Value, borrow_condition: structures.FunctionValueId, span: structures.SourceSpan) !Value {
            const paths = try self.beginConditionalJoin(field.type_id, borrow_condition);
            self.terminate(.{ .branch = try self.valuesBranch(paths.join, &.{field}) });
            self.enterBlock(paths.owned);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(operand.type_id)) orelse return error.Unavailable;
            const owned_field = if (capabilities.needs_automatic_drop or capabilities.requires_explicit_drop) blk: {
                var borrowed_field = field;
                borrowed_field.borrowed_generation = operand.owned_generation;
                borrowed_field.borrowed_cleanup_value = operand.id;
                break :blk try self.ownValue(borrowed_field, span);
            } else withoutOwnershipSource(field);
            var result = try self.finishConditionalJoin(paths, field, owned_field, span);
            result.borrowed_generation = field.borrowed_generation;
            result.borrowed_cleanup_value = field.borrowed_cleanup_value;
            result.borrowed_type = field.type_id;
            result.borrow_condition = borrow_condition;
            result.borrow_root = field.borrow_root;
            return self.withCleanupCondition(result);
        }

        fn captureAvailability(self: *Self) !StateAvailability {
            return self.state.availability.snapshot();
        }

        fn captureState(self: *Self) !StateId {
            return self.appendState(self.state.snapshot());
        }

        fn appendState(self: *Self, state: State) !StateId {
            std.debug.assert(state.values.len == self.state.values.len);
            std.debug.assert(state.availability.len == self.state.values.len);
            std.debug.assert(state.field_availability.len == self.state.field_availability.len);
            const id: StateId = @fromBackingInt(@intCast(self.states.items.len));
            try self.states.append(self.gpa, state);
            return id;
        }

        fn restoreState(self: *Self, id: StateId) void {
            self.state = self.states.items[@backingInt(id)].snapshot();
        }

        fn activeStateValues(self: *Self, id: StateId) !std.ArrayList(Value) {
            var values: std.ArrayList(Value) = .empty;
            const snapshot = self.states.items[@backingInt(id)].values;
            for (0..snapshot.len) |slot| {
                const state_value = snapshot.get(slot) orelse continue;
                if (self.locals.items(.mutable)[slot] and !try self.valueUsesStorage(state_value)) try values.append(self.gpa, state_value);
            }
            return values;
        }

        fn stateWithArguments(self: *Self, baseline: StateId, argument_start: u32, predecessor: structures.FunctionBlockId) !StateId {
            var state = self.states.items[@backingInt(baseline)].snapshot();
            var argument = argument_start;
            for (0..state.values.len) |slot| {
                const current = state.values.get(slot) orelse continue;
                if (!self.locals.items(.mutable)[slot] and current.owned_generation == null) continue;
                // Cleanup shapes can change even when the binding cannot be reassigned.
                const in_place = !self.locals.items(.mutable)[slot] or try self.valueUsesStorage(current);
                const generation = if (in_place) try self.loopHeaderGeneration(current) else self.block_argument_generations.items[argument];
                var next = current;
                next.id = if (in_place) current.id else @fromBackingInt(@intCast(argument));
                next.owned_generation = generation;
                try state.values.set(self.gpa, slot, next);
                if (in_place) {
                    if (generation) |owner| try self.recordGenerationOnlyForward(predecessor, 0, current.owned_generation, owner);
                } else argument += 1;
            }
            return self.appendState(state);
        }

        fn loop(self: *Self, body: semantic.UnresolvedBody.BlockId, mode: ResultRequest) !Value {
            const baseline = try self.captureState();
            const initial_values = try self.activeStateValues(baseline);
            const state_type_start: u32 = @intCast(self.block_arguments.items.len);
            for (initial_values.items) |initial| _ = try self.appendBlockArgument(initial.type_id, try self.loopHeaderGeneration(initial));
            const state_type_end: u32 = @intCast(self.block_arguments.items.len);
            const header = try self.newBlock(state_type_start, state_type_end);
            const initial_branch = try self.valuesBranch(header, initial_values.items);
            const entry_predecessor = self.current_block.?;
            self.terminate(.{ .branch = initial_branch });
            const header_state = try self.stateWithArguments(baseline, state_type_start, entry_predecessor);
            const identity_start = self.binding_joins.items.len;
            const origin_start = self.loop_reference_origins.items.len;
            for (0..self.states.items[@backingInt(baseline)].values.len) |slot| {
                const initial = self.states.items[@backingInt(baseline)].values.get(slot) orelse continue;
                if (!self.locals.items(.mutable)[slot]) continue;
                var header_value = self.states.items[@backingInt(header_state)].values.get(slot).?;
                header_value.binding_identity = try self.loopBindingJoin(slot, .contents, initial.binding_identity);
                header_value.storage_identity = try self.loopBindingJoin(slot, .storage, initial.storage_identity orelse initial.binding_identity);
                header_value.variant_identity = try self.loopBindingJoin(slot, .variant, initial.variant_identity orelse initial.binding_identity);
                if (try self.typeContainsBorrow(initial.type_id)) {
                    const origin_index: u32 = @intCast(self.loop_reference_origins.items.len);
                    try self.loop_reference_origins.append(self.gpa, .{ .slot = @intCast(slot), .origins = initial.reference_origins });
                    header_value.reference_origins = try self.addReferenceOrigin(null, .{ .loop = origin_index });
                }
                try self.states.items[@backingInt(header_state)].values.set(self.gpa, slot, header_value);
            }
            const identity_end = self.binding_joins.items.len;
            const origin_end = self.loop_reference_origins.items.len;

            const break_start: u32 = @intCast(self.loop_breaks.items.len);
            const backedge_start = self.loop_backedges.items.len;
            try self.loop_stack.append(self.gpa, .{
                .body = body,
                .header = header,
                .baseline = baseline,
                .result = mode,
                .refinements = self.state.refinements.snapshot(),
            });
            self.enterBlock(header);
            self.restoreState(header_state);
            const read_checkpoint = try self.appendInstruction(.const_unit);
            for (self.loop_reference_origins.items[origin_start..origin_end]) |*origins|
                origins.read_checkpoint = @truncate(@backingInt(read_checkpoint.id));
            if (try self.block(body, null) != null) try self.repeatLoop(self.loop_stack.last().?, self.unresolved.blocks[@backingInt(body)].span);
            const context = self.loop_stack.pop().?;
            for (self.loop_backedges.items[backedge_start..]) |edge|
                try self.validateLoopTypeProofs(context, self.states.items[@backingInt(edge.state)].refinements);

            try self.completeLoopGenerations(header_state, self.loop_backedges.items[backedge_start..], self.unresolved.blocks[@backingInt(body)].span);
            for (self.binding_joins.items[identity_start..identity_end]) |*join| {
                for (self.loop_backedges.items[backedge_start..]) |backedge| {
                    const value_on_edge = self.states.items[@backingInt(backedge.state)].values.get(join.slot.?).?;
                    const identity = switch (join.kind) {
                        .contents => value_on_edge.binding_identity,
                        .storage => value_on_edge.storage_identity orelse value_on_edge.binding_identity,
                        .variant => value_on_edge.variant_identity orelse value_on_edge.binding_identity,
                    };
                    try join.alternatives.append(self.gpa, identity);
                }
                join.complete = true;
            }
            for (self.loop_reference_origins.items[origin_start..origin_end]) |*loop_origins| {
                for (self.loop_backedges.items[backedge_start..]) |backedge| {
                    loop_origins.origins = try self.mergeReferenceOrigins(loop_origins.origins, self.states.items[@backingInt(backedge.state)].values.get(loop_origins.slot).?.reference_origins);
                }
                loop_origins.complete = true;
            }
            self.loop_backedges.shrinkRetainingCapacity(backedge_start);

            const merged = try self.mergeExits(baseline, self.loop_breaks.items[break_start..], mode, .loop);
            self.loop_breaks.shrinkRetainingCapacity(break_start);
            try self.enterFlowExit(merged);
            if (merged.constructed.?.type_id == .never) self.terminate(.diverge);
            return merged.constructed.?;
        }

        /// A loop-carried identity joins its entry identity with every backedge.
        fn requireFlowProof(self: *Self, place: u32) !void {
            const current = self.state.refinements.get(place);
            for (self.loop_stack.items) |*context| {
                if (place < context.refinements.len and self.flow.?.facts.get(context.refinements, place).type_id != null and
                    try self.flow.?.facts.dependsOn(self.gpa, current, context.refinements.get(place)))
                    try context.proofs.put(self.gpa, place, {});
            }
        }

        fn validateLoopTypeProofs(self: *Self, context: LoopContext, incoming: flow_types.State) !void {
            var proofs = context.proofs.keyIterator();
            while (proofs.next()) |key| {
                const place = key.*;
                const required = self.flow.?.facts.get(context.refinements, place);
                const actual = self.flow.?.facts.get(incoming, place);
                const selected = actual.type_id orelse return self.rejectLoopProof(actual, required);
                for (try self.matchInputMembers(selected)) |member| {
                    if (!containsType(try self.matchInputMembers(required.type_id.?), member))
                        return self.rejectLoopProof(actual, required);
                }
            }
        }

        fn loopBindingJoin(self: *Self, slot: usize, kind: @FieldType(BindingJoin, "kind"), initial: BindingIdentity) !BindingIdentity {
            const index: u32 = @intCast(self.binding_joins.items.len);
            try self.binding_joins.append(self.gpa, .{ .slot = @intCast(slot), .kind = kind, .initial = initial });
            return .{ .join = index };
        }

        fn loopHeaderGeneration(self: *Self, initial: Value) !?GenerationId {
            const previous = initial.owned_generation orelse return null;
            const metadata = self.generations.items[@backingInt(previous)];
            const generation = (try self.allocateGeneration(initial.type_id, self.activeLifetimeSpan(), metadata.cleanup_fields)).?;
            try self.copyMissingFields(generation, metadata.missing_fields, null, null);
            try self.mergeVariantCleanup(generation, &.{previous});
            return generation;
        }

        fn completeLoopGenerations(self: *Self, header_state: StateId, backedges: []const LoopBackedge, span: structures.SourceSpan) !void {
            const values = self.states.items[@backingInt(header_state)].values;
            for (0..values.len) |slot| {
                const initial = values.get(slot) orelse continue;
                const generation = initial.owned_generation orelse continue;
                const missing = self.generations.items[@backingInt(generation)].missing_fields;
                var cleanup_fields = self.generations.items[@backingInt(generation)].cleanup_fields;
                var incoming_generations: std.ArrayList(?GenerationId) = .empty;
                try incoming_generations.append(self.gpa, generation);
                for (backedges) |backedge| {
                    const incoming = self.states.items[@backingInt(backedge.state)].values.get(slot).?.owned_generation;
                    try incoming_generations.append(self.gpa, incoming);
                    const incoming_missing = if (incoming) |owner| self.generations.items[@backingInt(owner)].missing_fields else &.{};
                    if (!sameMissingFields(missing, incoming_missing)) return self.reject(span, .partial_field_transfer_not_supported);
                    cleanup_fields = cleanup_fields and if (incoming) |owner| self.generations.items[@backingInt(owner)].cleanup_fields else false;
                    if (!self.locals.items(.mutable)[slot] or try self.valueUsesStorage(initial)) try self.recordGenerationOnlyForward(backedge.block, 0, incoming, generation);
                }
                if (!cleanup_fields) {
                    self.generations.items[@backingInt(generation)].cleanup_fields = false;
                    self.generations.items[@backingInt(generation)].requires_explicit_drop = ((try self.analysis_context.facts().ownershipCapabilities(initial.type_id)) orelse return error.Unavailable).requires_explicit_drop;
                }
                try self.mergeVariantCleanup(generation, incoming_generations.items);
            }
        }

        fn generationMatchesType(self: *const Self, generation: ?GenerationId, type_id: structures.TypeId) bool {
            return generation == null or self.generations.items[@backingInt(generation.?)].type_id == type_id;
        }

        fn valuesBranch(self: *Self, target: structures.FunctionBlockId, values: []const Value) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            for (values) |value_to_pass| {
                try self.rememberCleanupOrigins(value_to_pass);
                try self.appendBranchArgument(.{ .value = value_to_pass.id }, value_to_pass.owned_generation);
            }
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        /// Restores loop-carried places and branches back to the loop header.
        fn repeatLoop(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            try self.normalizeLoopBackedge(context, span);
            try self.validateLoopBackedge(context, span);
            const start: u32 = @intCast(self.branch_arguments.items.len);
            for (0..self.states.items[@backingInt(context.baseline)].values.len) |slot| {
                const initial = self.states.items[@backingInt(context.baseline)].values.get(slot) orelse continue;
                if (!self.locals.items(.mutable)[slot] or try self.valueUsesStorage(initial)) continue;
                const current = self.state.values.get(slot).?;
                try self.appendBranchArgument(.{ .value = current.id }, current.owned_generation);
            }
            try self.loop_backedges.append(self.gpa, .{ .block = self.current_block.?, .state = try self.captureState() });
            self.terminate(.{ .branch = .{ .target = context.header, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } } });
        }

        fn normalizeLoopBackedge(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            const baseline = self.states.items[@backingInt(context.baseline)];
            var scope: ?BoundaryScope = null;
            defer if (scope) |opened| {
                self.current_boundary = opened.parent;
            };
            for (self.field_places, 0..) |place, field| {
                if (!place.moves_owner or baseline.availability.get(@backingInt(place.local)) != .available or
                    baseline.field_availability.get(field) != .transferred or self.state.field_availability.get(field) != .available) continue;
                if (scope == null) scope = try self.openBoundary(span);
                try self.endField(place, span);
            }
            if (scope) |opened| try self.closeBoundary(opened.boundary);
        }

        fn validateLoopBackedge(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            const baseline = self.states.items[@backingInt(context.baseline)];
            for (0..self.state.initializers.len) |parameter| {
                if (self.state.initializers.get(parameter) != baseline.initializers.get(parameter)) return self.reject(span, .initializer_consumed_in_loop);
            }
            for (0..self.state.availability.len) |local| {
                if (baseline.availability.get(local) == .available and self.state.availability.get(local) != .available)
                    return self.reject(span, .transferred_value_not_restored_before_loop_backedge);
            }
            for (self.field_places, 0..) |place, field| {
                if (baseline.availability.get(@backingInt(place.local)) != .available or baseline.field_availability.get(field) != .available) continue;
                if (self.state.field_availability.get(field) != .available) return self.reject(span, .transferred_value_not_restored_before_loop_backedge);
            }
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation"), context: ValueContext) !Value {
            if (!self.type_check_only and try self.usesIndirectStorage(annotation.type_id))
                return self.constructAnnotated(annotation, .{ .storage = try self.localStorage(annotation.type_id), .site = .local });
            const operand = try self.valueWithContext(annotation.value.value, .{ .expected_type = annotation.type_id, .access = context.access });
            if (operand.type_id == .never) return operand;
            const use = try self.coerceValue(operand.id, operand.type_id, annotation.type_id) orelse
                return self.reject(annotation.value.span, .{ .local_type_mismatch = self.typeMismatch(annotation.type_id, operand.type_id) });
            if (use.coerce_to == null) return operand;
            return self.coerceOwnedRepresentation(operand, use, annotation.value.span, null);
        }

        fn coerceOwnedRepresentation(
            self: *Self,
            source: Value,
            use: structures.FunctionValueUse,
            span: structures.SourceSpan,
            destination: ?Value,
        ) !Value {
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (!capabilities.isDirectlyMovable()) return self.reject(span, .{ .relocation_requires_direct_move = source.type_id });
            var result = if (destination) |storage| blk: {
                _ = try self.appendCoercion(use, storage.id);
                break :blk storage;
            } else try self.appendCoercion(use, null);
            result.reference_origins = try self.coercedReferenceOrigins(source, use);
            if (source.borrowed_type != null) {
                result.place_origins = source.place_origins;
                result.borrowed_type = source.borrowed_type;
                result.borrowed_generation = source.borrowed_generation;
                result.borrowed_cleanup_value = source.borrowed_cleanup_value;
                result.borrow_condition = source.borrow_condition;
                result.borrow_root = source.borrow_root;
                result.owned_generation = source.owned_generation;
                result.explicit_transfer = source.explicit_transfer;
                return result;
            }
            return self.retargetOwnership(source, result, span);
        }

        /// Moves ownership to `result`, another representation of `source`, keeping its field-cleanup mode.
        fn retargetOwnership(self: *Self, source: Value, result: Value, span: structures.SourceSpan) !Value {
            const generation = source.owned_generation orelse return result;
            const cleanup_fields = self.generations.items[@backingInt(generation)].cleanup_fields;
            try self.recordConsume(source);
            const owned = try self.defineOwnedValue(result, span, cleanup_fields);
            if (owned.owned_generation) |next| try self.mergeVariantCleanup(next, &.{generation});
            return owned;
        }

        fn coercedReferenceOrigins(self: *Self, source: Value, use: structures.FunctionValueUse) !?u32 {
            const members = (try self.analysis_context.facts().variantMembers(use.coerce_to orelse return source.reference_origins)) orelse
                return source.reference_origins;
            if (try self.analysis_context.facts().variantMembers(source.type_id) != null) return source.reference_origins;
            const member = members[self.variant_coercion_tags.items[use.variant_tag_mapping.?.start]];
            return self.transformReferenceOrigins(source.reference_origins, .{ .prefix = .{ .variant = member } });
        }

        fn appendCoercion(self: *Self, use: structures.FunctionValueUse, destination: ?structures.FunctionValueId) !Value {
            const target_type = use.coerce_to.?;
            const operation: structures.FunctionInstruction = .{ .variant_coerce = .{
                .operand = use.value,
                .target_type = target_type,
                .tag_mapping = use.variant_tag_mapping.?,
                .destination = destination,
            } };
            return self.appendInstruction(operation);
        }

        fn coerceValue(
            self: *Self,
            value_id: structures.FunctionValueId,
            actual_type: structures.TypeId,
            target_type: structures.TypeId,
        ) !?structures.FunctionValueUse {
            if (actual_type == target_type) return .{ .value = value_id };
            if (actual_type == .never or !try semantic.canWidenTo(self.analysis_context, actual_type, target_type)) return null;
            const target_members = (try self.analysis_context.facts().variantMembers(target_type)).?;
            const mapping_start: u32 = @intCast(self.variant_coercion_tags.items.len);
            if (try self.analysis_context.facts().variantMembers(actual_type)) |actual_members| {
                for (actual_members) |actual_member| try self.appendVariantTag(target_members, actual_member);
            } else {
                try self.appendVariantTag(target_members, actual_type);
            }
            return .{
                .value = value_id,
                .coerce_to = target_type,
                .variant_tag_mapping = .{
                    .start = mapping_start,
                    .end = @intCast(self.variant_coercion_tags.items.len),
                },
            };
        }

        fn appendVariantTag(self: *Self, target_members: []const structures.TypeId, actual_member: structures.TypeId) !void {
            const tag = (try semantic.widenedVariantTag(self.analysis_context, actual_member, target_members)) orelse unreachable;
            try self.variant_coercion_tags.append(self.gpa, tag);
        }

        fn appendExtractionTagMapping(
            self: *Self,
            source_type: structures.TypeId,
            target_type: structures.TypeId,
        ) !?structures.FunctionValueRange {
            const target_members = try self.analysis_context.facts().variantMembers(target_type) orelse return null;
            const source_members = (try self.analysis_context.facts().variantMembers(source_type)).?;
            const start: u32 = @intCast(self.variant_coercion_tags.items.len);
            for (source_members) |source_member| {
                const target_tag = std.mem.indexOfScalar(structures.TypeId, target_members, source_member) orelse structures.invalid_variant_tag;
                try self.variant_coercion_tags.append(self.gpa, @intCast(target_tag));
            }
            return .{ .start = start, .end = @intCast(self.variant_coercion_tags.items.len) };
        }

        fn resolvePlaceFields(
            self: *Self,
            root_type: structures.TypeId,
            source_fields: []const semantic.UnresolvedBody.FieldName,
            root_span: structures.SourceSpan,
            fields: *std.ArrayList(PlaceField),
        ) !void {
            var target_type = root_type;
            for (source_fields, 0..) |source_field, index| {
                const field = try self.resolvePlaceField(target_type, source_field.name, if (index == 0) root_span else source_fields[index - 1].span, source_field.span);
                try fields.append(self.gpa, field);
                target_type = field.type_id;
            }
        }

        fn resolvePlaceField(self: *Self, parent_type: structures.TypeId, name: []const u8, parent_span: structures.SourceSpan, field_span: structures.SourceSpan) !PlaceField {
            const definition = (try self.analysis_context.facts().structDefinition(parent_type)) orelse
                return self.reject(parent_span, .{ .field_access_not_struct = parent_type });
            const field = definition.resolveField(name) orelse return self.reject(field_span, .unknown_field);
            if (!definition.fields[field.index].is_public and !try self.analysis_context.canAccessPrivateFields(parent_type))
                return self.reject(field_span, .{ .private_struct_field = parent_type });
            return .{ .index = field.index, .type_id = field.type_id, .kind = definition.fields[field.index].kind, .name = name };
        }

        fn structInitializerDefinition(self: *Self, initializer: @FieldType(Expression.Operation, "struct_init"), type_id: structures.TypeId) !*const structures.StructDefinition {
            const definition = (try self.analysis_context.facts().structDefinition(type_id)) orelse
                return self.reject(initializer.type_span, .{ .struct_initializer_not_struct = type_id });
            const private_access = initializer.canonical or try self.analysis_context.canAccessPrivateFields(type_id);
            for (self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |source_field| {
                const field = definition.resolveField(source_field.name) orelse
                    return self.reject(source_field.name_span, .unknown_struct_field);
                if (!definition.fields[field.index].is_public and !private_access)
                    return self.reject(source_field.name_span, .{ .private_struct_field = type_id });
            }
            if (!private_access) for (definition.fields) |field| {
                if (!field.is_public) return self.reject(initializer.type_span, .{ .private_struct_field = type_id });
            };
            return definition;
        }

        fn assignment(self: *Self, expression: Expression) !Value {
            const assignment_value = expression.operation.assignment;
            try self.validateInitializerWrite(assignment_value.target, assignment_value.target_span);
            const local_index = @backingInt(assignment_value.target);
            const source_fields = self.unresolved.assignment_fields[assignment_value.fields.start..assignment_value.fields.end];
            var fields: std.ArrayList(PlaceField) = .empty;
            if (self.locals.items(.reference)[local_index]) {
                const reference = self.state.values.get(local_index).?;
                const place = try self.resolveSourceFields(.{ .root = .{ .reference = reference }, .fields = .{ .start = 0, .end = 0 } }, source_fields, &fields);
                return self.assignBorrowedPlace(place, fields.items, assignment_value.value, assignment_value.target_span);
            }
            self.markCapturedMutation(local_index);
            const replaces = assignment_value.replaces;
            const mut_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            const root_availability = self.state.availability.get(local_index);
            if (root_availability == .replacing or (root_availability != .available and (source_fields.len != 0 or !replaces)))
                return self.reject(assignment_value.target_span, unavailableUse(root_availability));
            const root = self.state.values.get(local_index).?;
            const resolved_place = try self.resolveSourceFields(.{ .root = .{ .local = assignment_value.target }, .fields = .{ .start = 0, .end = 0 } }, source_fields, &fields);
            if (resolved_place.root == .reference) return self.assignBorrowedPlace(resolved_place, fields.items, assignment_value.value, assignment_value.target_span);
            const target_type = if (fields.items.len == 0) root.type_id else fields.last().?.type_id;
            const target_span = if (source_fields.len == 0) assignment_value.target_span else source_fields[source_fields.len - 1].span;
            const in_place = try self.valueUsesStorage(root);
            if (in_place) for (self.pending_deinit_places.items) |pending| {
                if (pending.local != assignment_value.target) continue;
                const consumed_fields = self.pending_deinit_fields.items[pending.fields.start..pending.fields.end];
                if (fieldPathContains(consumed_fields, fields.items) or fieldPathContains(fields.items, consumed_fields))
                    return self.reject(target_span, .consumed_storage_in_use);
            };
            const target_capabilities = (try self.analysis_context.facts().ownershipCapabilities(target_type)) orelse return error.Unavailable;
            const constructs_target = replaces and !target_capabilities.isDirectlyMovable();
            const replacement_start = self.replacement_targets.items.len;
            defer self.replacement_targets.shrinkRetainingCapacity(replacement_start);
            if (!constructs_target and root.owned_generation != null)
                try self.replacement_targets.append(self.gpa, .{ .local = assignment_value.target });
            const replaced_storage = if (constructs_target) try self.fieldStorage(rawValue(root), fields.items) else null;
            const early_replaced = if (replaced_storage) |storage| try self.beginInPlaceReplacement(assignment_value.target, storage, fields.items, source_fields, target_span) else null;
            const operand = if (replaced_storage) |storage|
                try self.construct(assignment_value.value.value, assignment_value.value.span, .{ .storage = storage, .site = .assignment })
            else
                try self.valueWithContext(assignment_value.value.value, .{ .expected_type = if (replaces) target_type else null, .access = if (replaces) .initialize else .value });
            if (operand.type_id == .never) return operand;
            if (self.locals.items(.mut_parameter)[local_index] != null) {
                const origins = try self.placeStorageOrigins(.{ .local = assignment_value.target }, fields.items);
                try self.reference_writes.append(self.gpa, .{ .origins = origins, .written_type = target_type });
            }
            if (fields.items.len != 0 and self.state.availability.get(local_index) != .available)
                return self.reject(assignment_value.target_span, unavailableUse(self.state.availability.get(local_index)));
            const replaced = early_replaced orelse try self.replacedFields(assignment_value.target, source_fields, fields.items.len != 0, target_span);
            if (!replaces and replaced.unavailable)
                return self.reject(target_span, .use_after_transfer);
            if (fields.items.len == 0 and mut_parameter and replaced.unavailable)
                return self.reject(target_span, .field_not_restored_before_mut_return);
            const result = if (constructs_target) operand else blk: {
                var latest_target = self.state.values.get(local_index).?;
                for (fields.items) |field| latest_target = try self.fieldView(latest_target, field.index, field.type_id);
                var use = try self.coerceValue(operand.id, operand.type_id, target_type) orelse
                    return self.reject(assignment_value.value.span, .{ .assignment_type_mismatch = self.typeMismatch(target_type, operand.type_id) });
                const owned = try self.ownValue(operand, assignment_value.value.span);
                use.value = owned.id;
                const prepared = if (use.coerce_to == null)
                    owned
                else
                    try self.coerceOwnedRepresentation(owned, use, assignment_value.value.span, null);
                try self.finishReplacementUses(target_span);
                if (fields.items.len != 0) {
                    // Partial-place lifetimes are not modeled yet, so a replaced field ends here.
                    if (self.state.availability.get(local_index) == .maybe_transferred and target_capabilities.needs_automatic_drop)
                        return self.reject(target_span, .possibly_transferred);
                    if (!replaced.skip_old_drop or self.state.values.get(local_index).?.owned_generation != null)
                        try self.dropReplacedField(self.state.values.get(local_index).?, latest_target, fields.items, self.locals.items(.can_deinit)[local_index], target_span);
                }
                break :blk prepared;
            };
            if (!constructs_target and fields.items.len == 0 and mut_parameter) {
                if (!(self.is_initializer_region and self.captured_locals[local_index] != null and root_availability == .transferred))
                    try self.dropValue(self.state.values.get(local_index).?, false, target_span);
                try self.recordConsume(self.state.values.get(local_index).?);
            }
            const previous_root = self.state.values.get(local_index).?;
            var updated = if (fields.items.len == 0)
                if (in_place and !constructs_target)
                    try self.moveValue(result, target_span, rawValue(previous_root))
                else
                    withoutOwnershipSource(result)
            else blk: {
                try self.recordConsume(result);
                if (!in_place) break :blk try self.updateOwnedValue(previous_root, try self.updateFields(previous_root, fields.items, result));
                if (!constructs_target) _ = try self.copyBits(result, try self.fieldStorage(rawValue(previous_root), fields.items));
                var rebuilt = previous_root;
                rebuilt.reference_origins = try self.fieldUpdateOrigins(previous_root.reference_origins, fields.items, result.reference_origins);
                break :blk try self.updateOwnedValue(previous_root, rebuilt);
            };
            if (fields.items.len == 0 and mut_parameter) {
                try self.recordConsume(updated);
                updated.owned_generation = null;
            } else if (fields.items.len != 0 and !mut_parameter) {
                updated = try self.restoreAssignedFields(assignment_value.target, updated, result, source_fields, fields.items, replaced.unavailable, expression.span, target_span);
            }
            if (updated.owned_generation) |generation| {
                if (self.locals.items(.can_deinit)[local_index]) try self.setDeinitCleanup(generation);
                // Installation is a use of the prepared generation, after the
                // old generation's ending boundary. An unused replacement must
                // not be destroyed while its RHS is still being prepared.
                try self.recordEffect(.{ .use = .{ .generation = generation, .cleanup_value = updated.id } });
            }
            updated.binding_identity = try self.newBindingIdentity();
            updated.storage_identity = if (in_place) previous_root.storage_identity orelse previous_root.binding_identity else null;
            updated.variant_identity = if (fields.items.len == 0 or try self.analysis_context.facts().variantMembers(target_type) != null)
                updated.binding_identity
            else
                previous_root.variant_identity orelse previous_root.binding_identity;
            var written = try self.valuePlaceOrigins(self.borrowLocalValue(assignment_value.target));
            for (fields.items) |field| written = try self.appendSourcePath(written, .{ .field = field.index });
            try self.state.values.set(self.gpa, local_index, updated);
            try self.invalidateFlowTypes(written, expression.span);
            try self.state.availability.set(self.gpa, local_index, .available);
            if (replaces) {
                for (self.field_places, 0..) |place, field_index| {
                    if (place.local == assignment_value.target and fieldPathContains(source_fields, place.fields))
                        try self.state.field_availability.set(self.gpa, field_index, .available);
                }
            }
            try self.writeCapturedLocal(assignment_value.target);
            if (replaces and (root_availability == .transferred or replaced.unavailable))
                try self.restoreCapturedOwnership(assignment_value.target, fields.items);
            return .{
                .id = result.id,
                .type_id = result.type_id,
                .borrowed_type = result.type_id,
                .borrow_root = assignment_value.target,
            };
        }

        const ReplacedFields = struct { unavailable: bool = false, skip_old_drop: bool = false };

        fn restoreCapturedOwnership(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField) !void {
            if (!self.is_initializer_region or self.captured_locals[@backingInt(local)] == null) return;
            for (self.capture_transfers.items) |transfer| {
                if (transfer.local != local) continue;
                if (transfer.field) |field| {
                    if (!fieldPathContains(fields, self.field_places[field].fields)) continue;
                } else if (fields.len != 0) continue;
                const retained = try self.appendInstruction(.{ .const_bool = false });
                _ = try self.copyBits(retained, .{ .id = @fromBackingInt(@intCast(transfer.parameter)), .type_id = .bool });
                const place = if (transfer.field) |field| self.state.values.len + field else @backingInt(transfer.local);
                try self.state.completed_consumptions.set(self.gpa, place, false);
            }
        }

        fn replacedFields(self: *Self, local: semantic.UnresolvedBody.LocalId, source_fields: []const semantic.UnresolvedBody.FieldName, has_fields: bool, span: structures.SourceSpan) !ReplacedFields {
            var replaced: ReplacedFields = .{};
            for (self.field_places, 0..self.state.field_availability.len) |place, flow_availability_index| {
                const availability = self.state.field_availability.get(flow_availability_index);
                if (place.local != local or availability == .available) continue;
                if (fieldPathContains(place.fields, source_fields) and place.fields.len < source_fields.len)
                    return self.reject(span, unavailableUse(availability));
                if (fieldPathContains(source_fields, place.fields)) {
                    replaced.unavailable = true;
                    if (place.moves_owner) {
                        if (availability == .maybe_transferred and has_fields)
                            return self.reject(span, .possibly_transferred);
                        replaced.skip_old_drop = true;
                    }
                }
            }
            return replaced;
        }

        fn beginInPlaceReplacement(
            self: *Self,
            local: semantic.UnresolvedBody.LocalId,
            storage: Value,
            fields: []const PlaceField,
            source_fields: []const semantic.UnresolvedBody.FieldName,
            span: structures.SourceSpan,
        ) !ReplacedFields {
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            const local_index = @backingInt(local);
            var replaced = try self.replacedFields(local, source_fields, fields.len != 0, span);
            if (fields.len == 0) {
                const root = self.state.values.get(local_index).?;
                if (self.locals.items(.mut_parameter)[local_index] != null) {
                    if (replaced.unavailable) return self.reject(span, .field_not_restored_before_mut_return);
                    try self.dropValue(root, false, span);
                    try self.recordConsume(root);
                }
                if (self.state.availability.get(local_index) == .available) try self.state.availability.set(self.gpa, local_index, .replacing);
            } else {
                replaced = try self.endReplacedField(local, storage, fields, replaced, span);
                for (self.field_places, 0..) |place, field_index| {
                    if (place.local == local and fieldPathContains(source_fields, place.fields)) try self.state.field_availability.set(self.gpa, field_index, .replacing);
                }
            }
            try self.closeBoundary(scope.boundary);
            return replaced;
        }

        fn endReplacedField(self: *Self, local: semantic.UnresolvedBody.LocalId, storage: Value, fields: []const PlaceField, previous: ReplacedFields, span: structures.SourceSpan) !ReplacedFields {
            try self.validateMissingFieldParents(local, fields, span);
            const local_index = @backingInt(local);
            const root = self.state.values.get(local_index).?;
            const can_deinit = self.locals.items(.can_deinit)[local_index];
            if (!previous.skip_old_drop or root.owned_generation != null)
                try self.dropReplacedField(root, storage, fields, can_deinit, span);
            try self.updateLocal(local_index, .{ .binding_identity = try self.newBindingIdentity(), .storage_identity = null });
            const generation = root.owned_generation orelse return previous;
            const field_capabilities = (try self.analysis_context.facts().ownershipCapabilities(fields[fields.len - 1].type_id)) orelse return error.Unavailable;
            if (!field_capabilities.needs_automatic_drop and !field_capabilities.requires_explicit_drop) return previous;
            for (self.field_places) |*place| {
                if (place.local == local and place.fields.len == fields.len and fieldPathContains(place.fields, fields)) place.moves_owner = true;
            }
            const missing = self.generations.items[@backingInt(generation)].missing_fields;
            try self.recordConsume(root);
            try self.updateLocal(local_index, .{ .owned_generation = null });
            if ((try self.remainingFieldOwnership(root.type_id, missing, fields)).any()) {
                const remaining = try self.defineOwnedValue(root, span, can_deinit);
                try self.copyMissingFields(remaining.owned_generation.?, missing, fields, fields);
                try self.updateLocal(local_index, .{ .owned_generation = remaining.owned_generation });
            }
            var replaced = previous;
            replaced.unavailable = true;
            return replaced;
        }

        fn fieldStorage(self: *Self, root: Value, fields: []const PlaceField) !Value {
            var storage = root;
            for (fields) |field| {
                const origins = try self.transformReferenceOrigins(storage.reference_origins, .{ .select = .{ .field = field.index } });
                const writable = storage.writable;
                storage = try self.projectStorage(storage, field.type_id, .{ .field = field.index });
                storage.reference_origins = origins;
                storage.writable = writable;
            }
            return storage;
        }

        fn referenceField(self: *Self, owner: Value, field: PlaceField) !Value {
            var reference = try self.fieldView(owner, field.index, try self.analysis_context.facts().referenceType(field.type_id));
            reference.place_origins = owner.place_origins;
            reference.reference_origins = try self.transformReferenceOrigins(owner.reference_origins, .{ .select = .{ .field = field.index } });
            reference.writable = !try self.originsReadonly(reference.reference_origins);
            return reference;
        }

        fn originProjection(field: anytype) @FieldType(ReferenceProjection, "step") {
            if (@TypeOf(field) == PlaceField) return .{ .field = field.index };
            switch (field) {
                .field => |index| return .{ .field = index },
                .variant => |member| return .{ .variant = member },
            }
        }

        fn fieldReferenceOrigins(self: *Self, origins: ?u32, fields: anytype) !?u32 {
            var result = origins;
            for (fields) |field| result = try self.transformReferenceOrigins(result, .{ .select = originProjection(field) });
            return result;
        }

        fn fieldUpdateOrigins(self: *Self, root_origins: ?u32, fields: anytype, leaf_origins: ?u32) anyerror!?u32 {
            if (fields.len == 0) return leaf_origins;
            const step = originProjection(fields[0]);
            const field_origins = try self.fieldUpdateOrigins(try self.transformReferenceOrigins(root_origins, .{ .select = step }), fields[1..], leaf_origins);
            return self.replaceProjectedOrigins(root_origins, step, field_origins);
        }

        fn restoreAssignedFields(
            self: *Self,
            local: semantic.UnresolvedBody.LocalId,
            assigned: Value,
            result: Value,
            source_fields: []const semantic.UnresolvedBody.FieldName,
            fields: []const PlaceField,
            replacing_unavailable_field: bool,
            span: structures.SourceSpan,
            target_span: structures.SourceSpan,
        ) !Value {
            const can_deinit = self.locals.items(.can_deinit)[@backingInt(local)];
            var updated = assigned;
            var still_partial = false;
            for (self.field_places, 0..self.state.field_availability.len) |place, flow_availability_index| {
                const availability = self.state.field_availability.get(flow_availability_index);
                if (place.local == local and availability != .available and
                    !fieldPathContains(source_fields, place.fields)) still_partial = true;
            }
            if (updated.owned_generation == null) {
                if (still_partial and result.owned_generation != null) {
                    var missing_paths: std.ArrayList([]const structures.ReferencePathStep) = .empty;
                    var path_fields: std.ArrayList(PlaceField) = .empty;

                    for (self.field_places, 0..self.state.field_availability.len) |place, flow_availability_index| {
                        const availability = self.state.field_availability.get(flow_availability_index);
                        if (place.local != local or !place.moves_owner or availability == .available or
                            fieldPathContains(source_fields, place.fields)) continue;
                        if (availability != .transferred) return self.reject(target_span, .possibly_transferred);
                        path_fields.clearRetainingCapacity();
                        try self.resolvePlaceFields(updated.type_id, place.fields, target_span, &path_fields);
                        try missing_paths.ensureUnusedCapacity(self.gpa, 1);
                        const path = try self.gpa.alloc(structures.ReferencePathStep, path_fields.items.len);
                        for (path_fields.items, path) |field, *step| step.* = .{ .field = field.index };
                        for (missing_paths.items) |existing| {
                            if (cleanup_shape.samePath(existing, path)) break;
                        } else missing_paths.appendAssumeCapacity(path);
                    }
                    updated = try self.defineOwnedValue(updated, span, can_deinit);
                    try self.copyMissingFields(updated.owned_generation.?, missing_paths.items, null, null);
                } else if (!still_partial) {
                    updated = try self.defineOwnedValue(updated, span, can_deinit);
                }
            } else if (replacing_unavailable_field and self.generations.items[@backingInt(updated.owned_generation.?)].missing_fields.len != 0) {
                const previous_missing = self.generations.items[@backingInt(updated.owned_generation.?)].missing_fields;
                try self.recordConsume(updated);
                updated = try self.defineOwnedValue(updated, span, can_deinit);
                try self.copyMissingFields(updated.owned_generation.?, previous_missing, null, fields);
            }
            return updated;
        }

        fn dropReplacedField(self: *Self, root: Value, target: Value, fields: []const PlaceField, can_deinit: bool, span: structures.SourceSpan) !void {
            const generation = root.owned_generation orelse return self.dropValue(target, can_deinit, span);
            var missing_children: std.ArrayList([]const structures.ReferencePathStep) = .empty;

            for (self.generations.items[@backingInt(generation)].missing_fields) |missing| {
                if (!missingPathStartsWith(missing, fields)) continue;
                if (missing.len == fields.len) return;
                try missing_children.append(self.gpa, missing[fields.len..]);
            }
            var selections = self.generations.items[@backingInt(generation)].cleanup_selections;
            for (fields) |field| selections = try cleanup_shape.children(self.gpa, selections, .{ .field = field.index });
            if (selections.len != 0) return self.dropSelectedValue(target, selections, missing_children.items, false, can_deinit, span);
            if (missing_children.items.len == 0)
                try self.dropValue(target, can_deinit, span)
            else
                try self.dropValueExcluding(target, missing_children.items, can_deinit, span);
        }

        const ResolvedCallable = struct {
            operation: structures.FunctionCall,
            result_mode: structures.ResultMode = .owned,
            precise_reference_contract: bool = false,
            reference_outputs: structures.FunctionValueRange = .{ .start = 0, .end = 0 },
            mut_arguments: structures.FunctionValueRange = .{ .start = 0, .end = 0 },
            consumed_arguments: structures.FunctionValueRange = .{ .start = 0, .end = 0 },
            writable_references: structures.FunctionValueRange = .{ .start = 0, .end = 0 },
            reference_origins: ?u32 = null,
            reference_effects: ReferenceEffects = .{},
        };

        fn knownCallableInstance(self: *Self, value_id: structures.FunctionValueId) ?structures.InstanceId {
            var current = value_id;
            while (@backingInt(current) & (@as(u32, 1) << 31) != 0) {
                switch (self.findInstruction(@truncate(@backingInt(current))) orelse return null) {
                    .function_ref => |reference| return reference.instance(),
                    .value_copy => |copy| {
                        if (copy.destination != null) return null;
                        current = copy.source;
                    },
                    .local_storage => current = self.immutableStorageSource(current) orelse return null,
                    else => return null,
                }
            }
            return null;
        }

        fn immutableStorageSource(self: *Self, storage: structures.FunctionValueId) ?structures.FunctionValueId {
            var immutable = false;
            for (0..self.state.values.len, self.locals.items(.mutable)) |flow_local_index, mutable| {
                const local = self.state.values.get(flow_local_index);
                if (local != null and local.?.id == storage and !mutable) immutable = true;
            }
            if (!immutable) return null;
            for (self.blocks.items) |ir_block| {
                for (ir_block.items.items) |item| {
                    if (item != .instruction or item.instruction.operation != .value_copy) continue;
                    const copy = item.instruction.operation.value_copy;
                    if (copy.destination == storage) return copy.source;
                }
            }
            return null;
        }

        fn findInstruction(self: *const Self, instruction_id: u31) ?structures.FunctionInstruction {
            for (self.blocks.items) |block_value| for (block_value.items.items) |item| {
                if (item == .instruction and item.instruction.id == instruction_id) return item.instruction.operation;
            };
            return null;
        }

        const ResolvedCall = union(enum) {
            diverged: Value,
            callable: ResolvedCallable,
        };

        fn resolveArgumentPlace(self: *Self, value_id: semantic.UnresolvedBody.ValueId, fields: *std.ArrayList(PlaceField)) !?ArgumentPlace {
            const place = (try self.resolveBorrowPlace(value_id, fields)) orelse return null;
            return switch (place.root) {
                .local => |local| .{ .root = .{ .local = local }, .fields = place.fields },
                .reference => |reference| .{ .root = .{ .reference = reference }, .fields = place.fields },
                .parameter => {
                    fields.shrinkRetainingCapacity(place.fields.start);
                    return null;
                },
            };
        }

        fn resolveBorrowPlace(
            self: *Self,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(PlaceField),
        ) !?BorrowPlace {
            const start: u32 = @intCast(fields.items.len);
            var source_fields: std.ArrayList(semantic.UnresolvedBody.FieldName) = .empty;
            const source_root = (try self.appendSourcePlaceFields(true, value_id, &source_fields)) orelse return null;
            const root: @FieldType(BorrowPlace, "root") = switch (source_root) {
                .local => |local| if (self.locals.items(.reference)[@backingInt(local)]) .{ .reference = self.state.values.get(@backingInt(local)).? } else .{ .local = local },
                .parameter => |parameter| .{ .parameter = parameter },
                .reference => |source| blk: {
                    const candidate = try self.value(source.value);
                    if (try self.analysis_context.facts().borrowElement(candidate.type_id) != null) break :blk .{ .reference = candidate };
                    const address = candidate.place_reference orelse
                        return self.resolveTemporaryReferencePlace(candidate, source_fields.items, fields, source.span);
                    var reference = candidate;
                    reference.id = address;
                    reference.type_id = try self.analysis_context.facts().referenceType(candidate.type_id);
                    reference.reference_origins = candidate.place_origins;
                    break :blk .{ .reference = reference };
                },
            };
            return try self.resolveSourceFields(.{ .root = root, .fields = .{ .start = start, .end = start } }, source_fields.items, fields);
        }

        fn resolveSourceFields(self: *Self, initial: BorrowPlace, source_fields: []const semantic.UnresolvedBody.FieldName, fields: *std.ArrayList(PlaceField)) !BorrowPlace {
            var place = initial;
            for (source_fields, 0..) |part, field_index| {
                var parent_type = if (place.fields.end != place.fields.start) fields.items[place.fields.end - 1].type_id else try self.placeRootType(place.root);
                if (self.flow != null and try self.analysis_context.facts().variantMembers(parent_type) != null) {
                    const address = try self.capturePlaceReference(place, fields.items, part.span);
                    const selected = try self.flowRead(try self.readReference(address, parent_type));
                    if (selected.type_id != parent_type) {
                        place.root = .{ .reference = try self.flowReference(selected) };
                        place.fields.start = place.fields.end;
                        parent_type = selected.type_id;
                    }
                }
                try fields.append(self.gpa, try self.resolvePlaceField(parent_type, part.name, if (field_index == 0) part.span else source_fields[field_index - 1].span, part.span));
                place.fields.end = @intCast(fields.items.len);
                place = try self.followReferenceFields(place, fields.items);
            }
            return place;
        }

        fn resolveTemporaryReferencePlace(self: *Self, candidate: Value, source_fields: []const semantic.UnresolvedBody.FieldName, fields: *std.ArrayList(PlaceField), span: structures.SourceSpan) !?BorrowPlace {
            const start: u32 = @intCast(fields.items.len);
            try self.resolvePlaceFields(candidate.type_id, source_fields, span, fields);
            for (fields.items[start..], start..) |field, index| {
                if (field.kind != .reference) continue;
                const owner = try self.fieldStorage(candidate, fields.items[start..index]);
                return try self.followReferenceFields(.{
                    .root = .{ .reference = try self.referenceField(owner, field) },
                    .fields = .{ .start = @intCast(index + 1), .end = @intCast(fields.items.len) },
                }, fields.items);
            }
            fields.shrinkRetainingCapacity(start);
            return null;
        }

        fn followReferenceFields(self: *Self, original: BorrowPlace, fields: []const PlaceField) !BorrowPlace {
            var place = original;
            for (fields[original.fields.start..original.fields.end], original.fields.start..) |field, index| {
                if (field.kind != .reference) continue;
                var root = switch (place.root) {
                    .local => |local| self.borrowLocalValue(local),
                    .parameter => |parameter| self.values.get(@backingInt(parameter)).?,
                    .reference => |reference| try self.readReference(reference, (try self.analysis_context.facts().borrowElement(reference.type_id)).?),
                };
                if (place.root == .parameter) root.writable = false;
                const owner = try self.fieldStorage(root, fields[place.fields.start..index]);
                place.root = .{ .reference = try self.referenceField(owner, field) };
                place.fields.start = @intCast(index + 1);
            }
            return place;
        }

        fn assignBorrowedPlace(self: *Self, place: BorrowPlace, fields: []const PlaceField, value_use: semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !Value {
            const reference = place.root.reference;
            return self.assignReference(try self.projectReference(reference, fields[place.fields.start..place.fields.end]), reference.id, value_use, span);
        }

        /// Narrows a reference to fields of its referent.
        fn projectReference(self: *Self, reference: Value, fields: []const PlaceField) !Value {
            if (fields.len == 0) return reference;
            const projected = try self.appendInstruction(.{ .borrow_address = .{
                .source = reference.id,
                .type_id = try self.analysis_context.facts().referenceType(fields[fields.len - 1].type_id),
                .fields = try self.publishBorrowFields(fields),
                .base_is_reference = true,
            } });
            var result = reference;
            result.id = projected.id;
            result.type_id = projected.type_id;
            result.local_reference = try self.extendLocalReference(reference.local_reference, fields, null);
            for (fields) |field| {
                result.reference_origins = try self.appendSourcePath(result.reference_origins, .{ .field = field.index });
                result.flow_origins = try self.appendSourcePath(result.flow_origins, .{ .field = field.index });
            }
            return result;
        }

        fn publishBorrowFields(self: *Self, fields: []const PlaceField) !structures.FunctionValueRange {
            const start: u32 = @intCast(self.borrow_fields.items.len);
            for (fields) |field| {
                try self.borrow_fields.append(self.gpa, .{ .field = field.index });
            }
            return .{ .start = start, .end = @intCast(self.borrow_fields.items.len) };
        }

        fn projectBorrowPlace(self: *Self, place: BorrowPlace, writable: bool, span: structures.SourceSpan) !Value {
            switch (place.root) {
                .local => |local| {
                    const index = @backingInt(local);
                    if (writable and !self.locals.items(.mutable)[index]) return self.reject(span, .mutable_borrow_requires_writable_place);
                    return self.state.values.get(index).?;
                },
                .parameter => |parameter| {
                    if (writable) return self.reject(span, .mutable_borrow_requires_writable_place);
                    const value_to_borrow = self.values.get(@backingInt(parameter)).?;
                    if (value_to_borrow.borrowed_type == null) return self.reject(span, .borrow_requires_place);
                    return value_to_borrow;
                },
                .reference => |reference| {
                    if (writable and !reference.writable) return self.reject(span, .reference_not_writable);
                    return reference;
                },
            }
        }

        fn placeRootType(self: *Self, root: @FieldType(BorrowPlace, "root")) !structures.TypeId {
            return switch (root) {
                .local => |local| if (self.locals.items(.reference)[@backingInt(local)]) (try self.analysis_context.facts().borrowElement(stateValue(self.state.values, @backingInt(local)).?.type_id)).? else stateValue(self.state.values, @backingInt(local)).?.type_id,
                .parameter => |parameter| self.values.get(@backingInt(parameter)).?.type_id,
                .reference => |reference| (try self.analysis_context.facts().borrowElement(reference.type_id)).?,
            };
        }

        fn argumentRootType(self: *Self, root: ArgumentRoot) !structures.TypeId {
            return self.placeRootType(switch (root) {
                .local => |local| .{ .local = local },
                .reference => |reference| .{ .reference = reference },
            });
        }

        fn argumentPlaceType(self: *Self, root: ArgumentRoot, fields: []const PlaceField) !structures.TypeId {
            return if (fields.len != 0) fields[fields.len - 1].type_id else self.argumentRootType(root);
        }

        /// Origins of the storage holding a local or referenced place.
        fn placeStorageOrigins(self: *Self, root: ArgumentRoot, fields: []const PlaceField) !?u32 {
            var origins = switch (root) {
                .local => |local| try self.sourceReferenceOrigins(self.borrowLocalValue(local)),
                .reference => |reference| reference.reference_origins,
            };
            for (fields) |field| origins = try self.appendSourcePath(origins, .{ .field = field.index });
            return origins;
        }

        /// Appends items to a body-wide table and returns their range.
        fn publishRange(self: *Self, table: anytype, items: anytype) !structures.FunctionValueRange {
            const start: u32 = @intCast(table.items.len);
            try table.appendSlice(self.gpa, items);
            return .{ .start = start, .end = @intCast(table.items.len) };
        }

        fn appendSourcePlaceFields(
            self: *Self,
            comptime typed: bool,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(semantic.UnresolvedBody.FieldName),
        ) !?SourcePlaceRoot {
            const index = @backingInt(value_id);
            if (index < self.unresolved.parameter_count or (typed and self.capturedInput(value_id))) return .{ .parameter = value_id };
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            return switch (expression.operation) {
                .local_read, .local_transfer => |local| .{ .local = local },
                .annotation => |annotation| if (!typed or try self.unevaluatedType(annotation.value.value, annotation.type_id) == annotation.type_id)
                    self.appendSourcePlaceFields(typed, annotation.value.value, fields)
                else
                    null,
                .index_snapshot => |source| if (!typed)
                    self.appendSourcePlaceFields(typed, source.value, fields)
                else if (try self.unevaluatedType(source.value, null)) |type_id|
                    if (type_id.isPrimitive()) null else self.appendSourcePlaceFields(typed, source.value, fields)
                else
                    null,
                .call => .{ .reference = .{ .value = value_id, .span = expression.span } },
                .field_transfer => |transfer| blk: {
                    try fields.appendSlice(self.gpa, self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end]);
                    break :blk .{ .local = transfer.target };
                },
                .field_access => |access| blk: {
                    const root = (try self.appendSourcePlaceFields(typed, access.operand.value, fields)) orelse return null;
                    try fields.append(self.gpa, .{ .name = access.name, .span = expression.span });
                    break :blk root;
                },
                else => null,
            };
        }

        fn sameReferencePlace(self: *Self, left: ArgumentPlace, right: ArgumentPlace) bool {
            if (left.root != .reference or right.root != .reference) return false;
            if (left.root.reference.id == right.root.reference.id) return true;
            if (left.root.reference.type_id != right.root.reference.type_id) return false;
            const first = self.reference_storage.origins.items[left.root.reference.reference_origins orelse return false];
            const second = self.reference_storage.origins.items[right.root.reference.reference_origins orelse return false];
            if (first.next != null or second.next != null) return false;
            if (first.root == null and first.parameter == null and first.cleanup_value == null) return false;
            return std.meta.eql(first, second);
        }

        fn placesOverlap(self: *Self, fields: []const PlaceField, left: ArgumentPlace, right: ArgumentPlace) bool {
            const same_local = left.root == .local and right.root == .local and left.root.local == right.root.local;
            if (!same_local and !self.sameReferencePlace(left, right)) return false;
            const left_fields = fields[left.fields.start..left.fields.end];
            const right_fields = fields[right.fields.start..right.fields.end];
            const shared_length = @min(left_fields.len, right_fields.len);
            for (left_fields[0..shared_length], right_fields[0..shared_length]) |left_field, right_field| {
                if (left_field.index != right_field.index) return false;
            }
            return true;
        }

        fn validateArgumentPlaceAvailability(self: *Self, place: ArgumentPlace, fields: []const PlaceField, span: structures.SourceSpan) !void {
            if (place.root != .local) return;
            const local = place.root.local;
            switch (self.state.availability.get(@backingInt(local))) {
                .available => {},
                .unbound => unreachable,
                .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
            }
            if (self.unavailableField(local, fields[place.fields.start..place.fields.end])) |availability| return self.reject(span, unavailableUse(availability));
        }

        fn validateMutableArgumentPlace(self: *Self, place: ArgumentPlace, fields: []const PlaceField, span: structures.SourceSpan) !void {
            switch (place.root) {
                .local => |local| {
                    try self.validateInitializerWrite(local, span);
                    self.markCapturedMutation(@backingInt(local));
                    if (!self.locals.items(.mutable)[@backingInt(local)]) return self.reject(span, .mutable_argument_requires_mutable_place);
                },
                .reference => |reference| {
                    if (!reference.writable or try self.originsReadonly(reference.reference_origins)) return self.reject(span, .mutable_argument_requires_mutable_place);
                    try self.validateInitializerReferenceWrite(reference, span);
                },
            }
            try self.validateArgumentPlaceAvailability(place, fields, span);
        }

        /// Writing an initializer capture makes its parameter mutable.
        fn markCapturedMutation(self: *Self, local_index: usize) void {
            if (!self.is_initializer_region) return;
            const parameter = self.captured_locals[local_index] orelse return;
            self.parameter_modes.items[parameter] = .mut;
            self.locals.items(.mut_parameter)[local_index] = parameter;
        }

        fn originAliasesPlace(self: *Self, origin: ReferenceOrigin, local: ?semantic.UnresolvedBody.LocalId, place_origins: ?u32) bool {
            if (local != null and origin.root == local) return true;
            var others = self.originList(place_origins);
            while (others.next()) |other| {
                if (origin.root != null and origin.root == other.root) return true;
                if (origin.parameter != null and origin.parameter == other.parameter) return true;
                if (origin.cleanup_value != null and origin.cleanup_value == other.cleanup_value) return true;
            }
            return false;
        }

        fn resolveScalarCall(self: *Self, instance: structures.InstanceId, signature: structures.CallableType, raw_arguments: []const semantic.UnresolvedBody.ValueUse, reverse_arguments: bool) !ResolvedCall {
            std.debug.assert(raw_arguments.len <= 2);
            var arguments: [2]structures.FunctionCallArgument = undefined;
            for (0..raw_arguments.len) |position| {
                const index = if (reverse_arguments) raw_arguments.len - 1 - position else position;
                const raw = raw_arguments[index];
                const parameter = signature.parameters[index];
                const scope = try self.openBoundary(raw.span);
                defer self.current_boundary = scope.parent;
                const input = try self.valueWithContext(raw.value, .{ .expected_type = parameter.type_id, .access = .value });
                if (input.type_id == .never) return .{ .diverged = input };
                var operand = try self.borrowValue(input, raw.span);
                if (try self.copiedScalarArgument(operand, raw.span)) |copied| operand = copied;
                arguments[index] = .{ .prepared = try self.coerceValue(operand.id, operand.type_id, parameter.type_id) orelse
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(parameter.type_id, operand.type_id) }) };
                try self.recordUse(operand);
                try self.closeBoundary(scope.boundary);
            }
            return .{ .callable = .{
                .operation = .{
                    .target = .{ .direct = instance },
                    .arguments = try self.publishRange(&self.call_arguments, arguments[0..raw_arguments.len]),
                    .return_type = signature.return_type,
                },
            } };
        }

        /// A borrowed direct scalar argument is copied so the callee receives its own value.
        inline fn copiedScalarArgument(self: *Self, operand: Value, span: structures.SourceSpan) !?Value {
            if (operand.borrowed_type == null and !operand.materialize_on_copy) return null;
            if (!operand.type_id.isPrimitive()) return null;
            var copied = operand;
            copied.materialize_on_copy = true;
            copied = try self.ownValue(copied, span);
            copied.reference_origins = null;
            return copied;
        }

        fn resolveCall(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, operation_arguments: ?[]const semantic.UnresolvedBody.ValueUse) !ResolvedCall {
            // Earlier deinit arguments retain their storage while later arguments,
            // including nested calls, are evaluated.
            const captures = self.initializerCaptureScope();
            defer self.endInitializerCaptureScope(captures);
            const replacement_start = self.replacement_targets.items.len;
            defer self.replacement_targets.shrinkRetainingCapacity(replacement_start);
            const deinit_place_start = self.pending_deinit_places.items.len;
            const deinit_field_start = self.pending_deinit_fields.items.len;
            defer {
                self.pending_deinit_places.shrinkRetainingCapacity(deinit_place_start);
                self.pending_deinit_fields.shrinkRetainingCapacity(deinit_field_start);
            }
            var target: CallTarget = undefined;
            var signature: structures.CallableType = undefined;
            var argument_storage: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
            var raw_arguments: []const semantic.UnresolvedBody.ValueUse = &.{};
            switch (call.target) {
                .unknown_function => return self.reject(span, .unknown_function),
                .operation => |name| {
                    raw_arguments = operation_arguments orelse self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    const receiver_type = (try self.unevaluatedType(raw_arguments[0].value, null)) orelse blk: {
                        const receiver = try self.value(raw_arguments[0].value);
                        if (receiver.type_id == .never) return .{ .diverged = receiver };
                        break :blk receiver.type_id;
                    };
                    target = try self.operationTarget(receiver_type, name, raw_arguments, span);
                    if (target == .direct) signature = (try self.analysis_context.functionSignature(target.direct)) orelse return error.Unavailable;
                },
                .direct => |instance| {
                    raw_arguments = operation_arguments orelse self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    target = .{ .direct = instance };
                    signature = try self.analysis_context.functionSignature(instance) orelse return error.Unavailable;
                },
                .inferred => |instance| {
                    raw_arguments = operation_arguments orelse self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    target = .{ .inferred = instance };
                },
                .overloaded => |overload| {
                    const instance = try self.resolveOverload(overload, self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end], span, &argument_storage);
                    raw_arguments = argument_storage.items;
                    target = .{ .direct = instance };
                    signature = (try self.analysis_context.functionSignature(instance)) orelse return error.Unavailable;
                },
                .value => |target_use| {
                    raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    const callee = try self.borrowValue(try self.value(target_use.value), target_use.span);
                    if (callee.type_id == .never) return .{ .diverged = callee };
                    signature = try self.callableSignature(callee.type_id, target_use.span);
                    target = .{ .indirect = callee };
                },
                .membership => |operands| {
                    if (try self.resolveMembershipCall(call, operands, &argument_storage, &target, &signature)) |diverged|
                        return .{ .diverged = diverged };
                    raw_arguments = argument_storage.items;
                },
                .member => |member| {
                    if (try self.resolveMemberCall(call, member, operation_arguments, &argument_storage, &target, &signature, null)) |diverged|
                        return .{ .diverged = diverged };
                    raw_arguments = argument_storage.items;
                },
            }
            if (target == .indirect) {
                const snapshot = try self.appendInstruction(.{ .value_copy = .{ .source = target.indirect.id, .type_id = target.indirect.type_id } });
                target.indirect.id = snapshot.id;
                target.indirect.representation = snapshot.representation;
            }
            if (target == .inferred) {
                const specialized = (try self.unevaluatedSpecialization(target.inferred, raw_arguments, span)) orelse
                    return self.reject(span, .static_argument_cannot_be_inferred);
                target = .{ .direct = specialized };
                signature = (try self.analysis_context.functionSignature(specialized)) orelse return error.Unavailable;
            }
            if (raw_arguments.len != signature.parameters.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(signature.parameters.len),
                .found = @intCast(raw_arguments.len),
            } });
            const membership = call.target == .membership;
            if (membership) try self.validateMembershipSignature(signature, call.target.membership.rhs, span);
            if (signature.return_type == .type and !self.options.allow_type_values) return self.reject(span, .type_value_used_as_runtime_value);
            if (target == .direct and signature.result_mode == .owned and signature.return_type.isPrimitive() and signature.parameters.len <= 2) {
                for (signature.parameters) |parameter| {
                    const scalar_type = parameter.type_id == .int or parameter.type_id == .bool or parameter.type_id == .byte or parameter.type_id == .unit or parameter.type_id == .none;
                    if (parameter.mode != .imm or !scalar_type) break;
                } else {
                    const resolved = try self.resolveScalarCall(target.direct, signature, raw_arguments, membership);
                    if (resolved == .callable) for (self.pending_initializer_owners.items[captures.owners..]) |owner| try self.recordUse(owner);
                    return resolved;
                }
            }
            return self.resolveGeneralCall(target, signature, raw_arguments, span, captures.owners, membership);
        }

        fn resolveGeneralCall(self: *Self, target: CallTarget, signature: structures.CallableType, raw_arguments: []const semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan, capture_owners_start: usize, reverse_arguments: bool) !ResolvedCall {
            const behavior = if (target == .direct) try self.analysis_context.callBehavior(target.direct.item) else .ordinary;
            const borrowed_return = signature.result_mode == .reference or try self.analysis_context.facts().canStoreBorrow(signature.return_type);
            var needs_reference_contract = borrowed_return;
            var borrowed_mut_output = false;
            for (signature.parameters) |parameter| {
                if (parameter.mode == .ref or parameter.mode == .mut or try self.analysis_context.facts().canStoreBorrow(parameter.type_id)) needs_reference_contract = true;
                if (parameter.mode == .mut and try self.analysis_context.facts().canStoreBorrow(parameter.type_id)) borrowed_mut_output = true;
            }
            const contract_instance: ?structures.InstanceId = if (target == .direct) target.direct else self.knownCallableInstance(target.indirect.id);
            const reference_contract: ?structures.ReferenceContract = if (self.type_check_only)
                .{}
            else if (contract_instance != null and needs_reference_contract)
                (try self.analysis_context.functionReferenceContract(contract_instance.?)) orelse return error.Unavailable
            else
                null;
            var place_fields: std.ArrayList(PlaceField) = .empty;
            const argument_places = try self.gpa.alloc(?ArgumentPlace, raw_arguments.len);

            const argument_reference_origins = try self.gpa.alloc(?u32, raw_arguments.len);
            const argument_sources = try self.gpa.alloc(CallOriginSource, raw_arguments.len);

            var mut_origin_sources: std.ArrayList(CallOriginSource) = .empty;
            var writable_references: std.ArrayList(Value) = .empty;

            const arguments_to_publish = try self.gpa.alloc(structures.FunctionCallArgument, raw_arguments.len);
            var arguments_to_consume: std.ArrayList(Value) = .empty;

            var borrowed_arguments: std.ArrayList(Value) = .empty;
            var mut_arguments_to_publish: std.ArrayList(PendingMutArgument) = .empty;

            var reference_origins: ?u32 = null;
            var mut_return_origin = false;
            const extracts_box = behavior == .box_value;
            // Finish each argument before evaluating the next one. Nested copy
            // hooks may publish their own calls, so the outer operands stay in
            // local storage until their complete contiguous range is known.
            // Evaluation order is independent of the callee's parameter order.
            for (0..raw_arguments.len) |position| {
                const argument_index = if (reverse_arguments) raw_arguments.len - 1 - position else position;
                const raw = raw_arguments[argument_index];
                const expected = signature.parameters[argument_index];
                const scope = try self.openBoundary(raw.span);
                defer self.current_boundary = scope.parent;
                if (expected.mode == .init) {
                    const initializer = try self.prepareInitializer(raw, expected.type_id);
                    arguments_to_publish[argument_index] = .{ .initializer = initializer.id };
                    argument_places[argument_index] = null;
                    argument_reference_origins[argument_index] = initializer.reference_origins;
                    argument_sources[argument_index] = .{ .type_id = expected.type_id, .contained = initializer.reference_origins };
                    if (borrowed_return)
                        reference_origins = try self.mergeReferenceOrigins(reference_origins, initializer.reference_origins);
                    if (borrowed_mut_output) try mut_origin_sources.append(self.gpa, .{ .type_id = expected.type_id, .contained = initializer.reference_origins });
                    try self.closeBoundary(scope.boundary);
                    continue;
                }
                if (expected.mode == .ref) {
                    const reference = try self.flowBindingReference(raw, expected.type_id);
                    if (reference.type_id == .never) return .{ .diverged = reference };
                    const element_type = (try self.analysis_context.facts().borrowElement(reference.type_id)).?;
                    if (element_type != expected.type_id) return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, element_type) });
                    if (reference_contract == null) {
                        if (!reference.writable or try self.originsReadonly(reference.reference_origins)) return self.reject(raw.span, .reference_not_writable);
                        try self.reference_writes.append(self.gpa, .{ .origins = reference.reference_origins, .written_type = element_type });
                        try writable_references.append(self.gpa, reference);
                    }
                    const source = try self.readReference(reference, element_type);
                    try borrowed_arguments.append(self.gpa, source);
                    arguments_to_publish[argument_index] = .{ .borrowed = source.id };
                    const field_start: u32 = @intCast(place_fields.items.len);
                    argument_places[argument_index] = .{ .root = .{ .reference = reference }, .fields = .{ .start = field_start, .end = field_start } };
                    argument_reference_origins[argument_index] = reference.reference_origins;
                    var contained_origins: ?u32 = null;
                    if (try self.analysis_context.facts().canStoreBorrow(expected.type_id)) {
                        contained_origins = try self.referenceContents(reference, source.reference_origins);
                        if (!source.writable) contained_origins = try self.readonlyOwnedOrigins(expected.type_id, contained_origins);
                    }
                    argument_sources[argument_index] = .{ .type_id = expected.type_id, .contained = contained_origins, .storage = reference.reference_origins };
                    if (borrowed_return) reference_origins = try self.mergeReferenceOrigins(reference_origins, reference.reference_origins);
                    if (borrowed_mut_output) try mut_origin_sources.append(self.gpa, .{ .type_id = expected.type_id, .contained = source.reference_origins, .storage = reference.reference_origins });
                    try self.closeBoundary(scope.boundary);
                    continue;
                }

                const raw_operand = if (expected.mode == .deinit)
                    try self.valueWithContext(raw.value, .{ .expected_type = expected.type_id, .access = .consume })
                else if (expected.mode == .@"var" and try self.usesIndirectStorage(expected.type_id))
                    try self.construct(raw.value, raw.span, .{ .storage = try self.localStorage(expected.type_id), .site = .argument })
                else if (expected.mode == .imm)
                    try self.valueWithContext(raw.value, .{
                        .expected_type = expected.type_id,
                        .access = if (try self.usesIndirectStorage(expected.type_id) and try self.analysis_context.facts().variantMembers(expected.type_id) != null) .borrow else .value,
                    })
                else
                    try self.valueWithContext(raw.value, .{ .expected_type = expected.type_id, .access = if (expected.mode == .@"var") .initialize else .value });
                if (raw_operand.type_id == .never) return .{ .diverged = raw_operand };
                var maybe_place = if (expected.mode == .imm or expected.mode == .mut)
                    try self.resolveArgumentPlace(raw.value, &place_fields)
                else
                    null;
                if (maybe_place) |place| {
                    if (try self.argumentPlaceType(place.root, place_fields.items[place.fields.start..place.fields.end]) != raw_operand.type_id) {
                        const empty: u32 = @intCast(place_fields.items.len);
                        if (raw_operand.place_reference != null) {
                            maybe_place = .{ .root = .{ .reference = try self.flowReference(raw_operand) }, .fields = .{ .start = empty, .end = empty } };
                        } else if (expected.mode == .mut) {
                            const reference = try self.flowBindingReference(raw, raw_operand.type_id);
                            maybe_place = if (try self.analysis_context.facts().borrowElement(reference.type_id) == raw_operand.type_id)
                                .{ .root = .{ .reference = reference }, .fields = .{ .start = empty, .end = empty } }
                            else
                                null;
                        } else maybe_place = null;
                    }
                }
                argument_places[argument_index] = maybe_place;
                var operand = switch (expected.mode) {
                    .imm, .mut => try self.borrowValue(raw_operand, raw.span),
                    .@"var", .deinit => raw_operand,
                    .static, .init, .ref => unreachable,
                };
                if (expected.mode == .imm) if (try self.copiedScalarArgument(operand, raw.span)) |copied| {
                    operand = copied;
                    maybe_place = null;
                    argument_places[argument_index] = null;
                };
                if (expected.mode == .mut and operand.type_id != expected.type_id)
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                var argument = try self.coerceValue(operand.id, operand.type_id, expected.type_id) orelse
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                if (argument.coerce_to != null and try self.usesIndirectStorage(expected.type_id)) {
                    const capabilities = (try self.analysis_context.facts().ownershipCapabilities(operand.type_id)) orelse return error.Unavailable;
                    if (!capabilities.isDirectlyMovable()) return self.reject(raw.span, .{ .relocation_requires_direct_move = operand.type_id });
                    std.debug.assert(expected.mode == .imm);
                    const storage = try self.localStorage(expected.type_id);
                    _ = try self.appendCoercion(argument, storage.id);
                    argument = .{ .value = storage.id };
                }
                const owned = switch (expected.mode) {
                    .@"var", .deinit => try self.ownCallArgument(operand, argument, expected.mode, raw.span),
                    else => null,
                };
                if (expected.mode == .imm or expected.mode == .mut)
                    try borrowed_arguments.append(self.gpa, operand);
                const argument_value = owned orelse operand;
                if (owned) |owned_argument| {
                    argument.value = owned_argument.id;
                    try arguments_to_consume.append(self.gpa, owned_argument);
                } else if (expected.mode == .mut) {
                    const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                    const root = switch (place.root) {
                        .local => |local| try self.pinLocalStorage(local),
                        .reference => |reference| try self.appendInstruction(.{ .borrow_read = .{ .source = reference.id, .type_id = (try self.analysis_context.facts().borrowElement(reference.type_id)).? } }),
                    };
                    argument.value = (try self.fieldStorage(root, place_fields.items[place.fields.start..place.fields.end])).id;
                    switch (place.root) {
                        .reference => |reference| try self.replacement_targets.append(self.gpa, .{ .reference = reference }),
                        .local => |local| try self.replacement_targets.append(self.gpa, .{ .local = local }),
                    }
                    const field_start: u32 = @intCast(self.mut_argument_fields.items.len);
                    try self.mut_argument_fields.appendSlice(self.gpa, place_fields.items[place.fields.start..place.fields.end]);
                    var writes_storage = reference_contract == null;
                    if (reference_contract) |contract| for (contract.requirements) |requirement| {
                        if (requirement.parameter == argument_index and requirement.kind == .place) writes_storage = true;
                    };
                    try mut_arguments_to_publish.append(self.gpa, .{
                        .result_identity = try self.newBindingIdentity(),
                        .place = .{
                            .root = place.root,
                            .fields = .{ .start = field_start, .end = @intCast(self.mut_argument_fields.items.len) },
                        },
                        .argument_index = @intCast(argument_index),
                        .return_origin = borrowed_return,
                        .writes_storage = writes_storage,
                    });
                }
                arguments_to_publish[argument_index] = if (expected.mode == .deinit) .{ .deinit = argument.value } else if (expected.mode == .mut) .{ .borrowed = argument.value } else .{ .prepared = argument };
                if (!extracts_box and reference_contract == null and expected.mode != .imm) {
                    const reference_start = writable_references.items.len;
                    try self.collectWritableReferences(argument_value, &writable_references);
                    for (writable_references.items[reference_start..]) |reference| {
                        if (try self.originsReadonly(reference.reference_origins)) return self.reject(raw.span, .reference_not_writable);
                        const written_type = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse (try self.analysis_context.facts().storageAccess(reference.type_id)).?;
                        try self.reference_writes.append(self.gpa, .{ .origins = reference.reference_origins, .written_type = written_type });
                        try self.replacement_targets.append(self.gpa, .{ .reference = reference });
                    }
                }
                argument_reference_origins[argument_index] = argument_value.reference_origins;
                const storage_origins = if (maybe_place) |place|
                    try self.placeStorageOrigins(place.root, place_fields.items[place.fields.start..place.fields.end])
                else
                    try self.sourceReferenceOrigins(operand);
                argument_sources[argument_index] = .{ .type_id = expected.type_id, .contained = if (try self.analysis_context.facts().canStoreBorrow(expected.type_id)) argument_value.reference_origins else null, .storage = storage_origins, .value = argument_value.id };
                const contributes_to_return = borrowed_return and expected.mode != .mut;
                if (borrowed_return and expected.mode == .mut) mut_return_origin = true;
                if (contributes_to_return or borrowed_mut_output) {
                    const scalar_copy = expected.mode == .imm and operand.type_id.isPrimitive();
                    var origin_source: CallOriginSource = .{
                        .type_id = operand.type_id,
                        .contained = if (!scalar_copy and try self.analysis_context.facts().canStoreBorrow(argument_value.type_id)) argument_value.reference_origins else null,
                        .storage = if (!scalar_copy and expected.mode == .imm and try self.analysis_context.facts().storageAccess(operand.type_id) == null) try self.sourceReferenceOrigins(operand) else null,
                    };
                    if (expected.mode == .imm) {
                        origin_source.contained = try self.readonlyOrigins(origin_source.contained);
                        origin_source.storage = try self.readonlyOrigins(origin_source.storage);
                    }
                    if (contributes_to_return) {
                        const origins = try self.callOriginsForType(origin_source, signature.return_type);
                        const returned = if (extracts_box)
                            try self.transformReferenceOrigins(origins, .{ .select = .element })
                        else
                            origins;
                        reference_origins = try self.mergeReferenceOrigins(reference_origins, returned);
                    }
                    if (borrowed_mut_output) try mut_origin_sources.append(self.gpa, origin_source);
                }
                try self.closeBoundary(scope.boundary);
            }
            for (self.pending_initializer_owners.items[capture_owners_start..]) |owner| try self.recordUse(owner);
            for (arguments_to_publish) |argument| {
                if (argument != .initializer) continue;
                for (self.initializer_transfers.items) |transfer| if (transfer.initializer == argument.valueId()) try self.recordUse(transfer.owner);
                for (arguments_to_publish, signature.parameters, argument_places, argument_reference_origins, 0..) |input, parameter, place, origins, argument_index| {
                    if (parameter.mode == .init) continue;
                    try self.validateInitializerInput(argument.valueId(), .{ .id = input.valueId(), .type_id = parameter.type_id, .borrow_root = if (place) |source| if (source.root == .local) source.root.local else null else null, .reference_origins = origins, .place_origins = if (parameter.mode == .mut or parameter.mode == .ref) argument_sources[argument_index].storage else null }, span);
                }
                if (target == .indirect) try self.validateInitializerInput(argument.valueId(), target.indirect, span);
            }
            for (writable_references.items) |reference| try self.validateInitializerReferenceWrite(reference, span);
            if (target == .indirect) try self.recordUse(target.indirect);
            for (borrowed_arguments.items) |argument| try self.recordUse(argument);
            for (raw_arguments, signature.parameters, argument_places, 0..) |raw, parameter, maybe_place, argument_index| {
                if (parameter.mode != .mut) continue;
                const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                try self.validateMutableArgumentPlace(place, place_fields.items, raw.span);
                for (signature.parameters, argument_places, 0..) |other_parameter, other_place, other_index| {
                    if (argument_index == other_index) continue;
                    if (other_place) |resolved_other| {
                        if ((other_parameter.mode == .imm or other_parameter.mode == .mut or other_parameter.mode == .ref) and
                            self.placesOverlap(place_fields.items, place, resolved_other))
                        {
                            return self.reject(raw.span, .overlapping_mutable_arguments);
                        }
                        if (self.sameReferencePlace(place, resolved_other)) continue;
                    }
                    if (argument_reference_origins[other_index] == null) continue;
                    var incomplete = false;
                    const other_origins = try self.resolveReferenceOrigins(argument_reference_origins[other_index], &incomplete);
                    const place_local = if (place.root == .local) place.root.local else null;
                    const place_origins = if (place.root == .reference) place.root.reference.reference_origins else null;
                    const resolved_place_origins = try self.resolveReferenceOrigins(place_origins, &incomplete);
                    if (incomplete) try self.pending_mutable_alias_checks.append(self.gpa, .{
                        .origins = argument_reference_origins[other_index],
                        .local = place_local,
                        .place_origins = place_origins,
                        .span = raw.span,
                    });
                    var origins = self.originList(other_origins);
                    while (origins.next()) |origin| {
                        if (self.originAliasesPlace(origin, place_local, resolved_place_origins)) return self.reject(raw.span, .overlapping_mutable_arguments);
                    }
                }
            }
            for (raw_arguments, argument_places, arguments_to_publish, argument_reference_origins, signature.parameters, argument_sources) |raw, maybe_place, argument, origins, parameter, source| {
                if (parameter.mode == .imm) if (maybe_place) |place| try self.validateArgumentPlaceAvailability(place, place_fields.items, raw.span);
                if (origins != null) try self.recordUse(.{ .id = argument.valueId(), .type_id = parameter.type_id, .reference_origins = origins });
                if (parameter.mode == .imm or parameter.mode == .mut or parameter.mode == .ref)
                    try self.recordReferenceUses(.{ .id = argument.valueId(), .type_id = parameter.type_id, .reference_origins = source.storage }, .retention);
            }
            var reference_effects: ReferenceEffects = .{};
            if (reference_contract) |contract| {
                try self.substituteReferenceExclusions(contract, argument_sources, span);
                for (contract.requirements) |requirement| {
                    const origins = try self.recordRequirementWrite(contract, requirement, argument_sources, &reference_effects, raw_arguments[requirement.parameter].span);
                    const written_type = requirement.written_type orelse continue;
                    if (signature.parameters[requirement.parameter].mode == .ref or requirement.kind == .contents) {
                        const place = argument_places[requirement.parameter];
                        const captured = if (place != null and place.?.root == .reference) place.?.root.reference else null;
                        try writable_references.append(self.gpa, .{
                            .id = if (captured) |reference| reference.id else arguments_to_publish[requirement.parameter].valueId(),
                            .type_id = try self.analysis_context.facts().referenceType(written_type),
                            .reference_origins = origins,
                            .local_reference = if (requirement.kind == .place and captured != null) captured.?.local_reference else null,
                        });
                    }
                }
            } else {
                for (writable_references.items) |reference| {
                    const type_id = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse (try self.analysis_context.facts().storageAccess(reference.type_id)).?;
                    try self.includeReferenceWrite(&reference_effects, reference.reference_origins, type_id, false);
                }
                for (mut_arguments_to_publish.items) |pending| {
                    if (!pending.writes_storage) continue;
                    const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
                    const origins = try self.placeStorageOrigins(pending.place.root, fields);
                    try self.includeReferenceWrite(&reference_effects, origins, try self.argumentPlaceType(pending.place.root, fields), false);
                }
            }
            const consumed_arguments = try self.publishRange(&self.pending_consumed_arguments, arguments_to_consume.items);
            const arguments = try self.publishRange(&self.call_arguments, arguments_to_publish);
            if (borrowed_mut_output) for (mut_arguments_to_publish.items) |*pending| {
                const output_type = signature.parameters[pending.argument_index].type_id;
                if (!try self.analysis_context.facts().canStoreBorrow(output_type)) continue;
                for (mut_origin_sources.items) |source|
                    pending.reference_origins = try self.mergeReferenceOrigins(pending.reference_origins, try self.callOriginsForType(source, output_type));
            };
            const mut_arguments = try self.publishRange(&self.pending_mut_arguments, mut_arguments_to_publish.items);
            const writable_range = try self.publishRange(&self.writable_call_references, writable_references.items);
            // A body validates escaping borrows at its return. With no owner or
            // reference inputs, a valid borrowed result can only be permanent.
            if (borrowed_return and reference_origins == null and !mut_return_origin and behavior == .ordinary)
                reference_origins = try self.addReferenceOrigin(null, .{ .permanent = true });
            if (borrowed_return) if (reference_contract) |contract| {
                reference_origins = try self.substituteOutputOrigins(contract, argument_sources, null);
            };
            const output_start: u32 = @intCast(self.pending_reference_outputs.items.len);
            if (reference_contract) |contract| {
                for (signature.parameters, argument_places, 0..) |parameter, place, parameter_index| {
                    if ((parameter.mode != .ref and parameter.mode != .mut) or !try self.analysis_context.facts().canStoreBorrow(parameter.type_id)) continue;
                    const reference: Value = .{
                        .id = arguments_to_publish[parameter_index].valueId(),
                        .type_id = try self.analysis_context.facts().referenceType(parameter.type_id),
                        .reference_origins = argument_sources[parameter_index].storage,
                        .local_reference = if (place != null and place.?.root == .reference) place.?.root.reference.local_reference else null,
                    };
                    {
                        try self.pending_reference_outputs.append(self.gpa, .{
                            .reference = reference,
                            .origins = try self.substituteOutputOrigins(contract, argument_sources, @intCast(parameter_index)),
                        });
                    }
                }
                try self.appendReferentOutputs(contract, argument_sources, arguments_to_publish);
            }
            return .{ .callable = .{
                .precise_reference_contract = reference_contract != null,
                .reference_outputs = .{ .start = output_start, .end = @intCast(self.pending_reference_outputs.items.len) },
                .result_mode = signature.result_mode,
                .operation = .{
                    .target = switch (target) {
                        .direct => |instance| .{ .direct = instance },
                        .indirect => |callee| .{ .indirect = callee.id },
                        .inferred => unreachable,
                    },
                    .arguments = arguments,
                    .return_type = if (signature.result_mode == .reference) try self.analysis_context.facts().referenceType(signature.return_type) else signature.return_type,
                },
                .mut_arguments = mut_arguments,
                .consumed_arguments = consumed_arguments,
                .writable_references = writable_range,
                .reference_effects = reference_effects,
                .reference_origins = reference_origins,
            } };
        }

        fn resolveMembershipCall(
            self: *Self,
            call: semantic.UnresolvedBody.Call,
            operands: semantic.UnresolvedBody.BinaryOperands,
            arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse),
            target: *CallTarget,
            signature: *structures.CallableType,
        ) !?Value {
            const receiver_type = (try self.unevaluatedType(operands.rhs.value, null)) orelse try self.inferArgumentType(operands.rhs);
            if (receiver_type == .never) {
                const tested = try self.value(operands.lhs.value);
                if (tested.type_id == .never) return tested;
                return try self.value(operands.rhs.value);
            }
            return self.resolveMemberCall(call, .{ .receiver = operands.rhs, .name = "contains" }, &.{operands.lhs}, arguments, target, signature, receiver_type);
        }

        fn validateMembershipSignature(self: *Self, signature: structures.CallableType, receiver: semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !void {
            if (signature.return_type != .bool or signature.result_mode != .owned or signature.parameters.len != 2)
                return self.reject(span, .invalid_membership_signature);
            for (signature.parameters) |parameter| if (parameter.mode != .imm)
                return self.reject(span, .invalid_membership_signature);
            const receiver_type = (try self.unevaluatedType(receiver.value, null)) orelse try self.inferArgumentType(receiver);
            if (signature.parameters[0].type_id != receiver_type) return self.reject(span, .invalid_membership_signature);
        }

        fn resolveMemberCall(
            self: *Self,
            call: semantic.UnresolvedBody.Call,
            member: semantic.UnresolvedBody.MemberCall,
            generated_arguments: ?[]const semantic.UnresolvedBody.ValueUse,
            arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse),
            target: *CallTarget,
            signature: *structures.CallableType,
            receiver_type_hint: ?structures.TypeId,
        ) !?Value {
            var fields: std.ArrayList(PlaceField) = .empty;
            const known = receiver_type_hint orelse try self.unevaluatedType(member.receiver.value, null);
            const receiver_type = blk: {
                if (known != null and known.? != .never) break :blk known.?;
                if (try self.resolveBorrowPlace(member.receiver.value, &fields)) |place|
                    break :blk if (fields.items.len == 0) try self.placeRootType(place.root) else fields.last().?.type_id;
                const receiver = try self.value(member.receiver.value);
                if (receiver.type_id == .never) return receiver;
                break :blk receiver.type_id;
            };
            var generated: std.ArrayList(semantic.UnresolvedBody.MethodCallArgument) = .empty;
            if (generated_arguments) |provided| for (provided) |argument| {
                try generated.append(self.gpa, .{ .node = .null, .value = argument, .runtime_reference = null });
            };
            const method_arguments = if (generated_arguments != null) generated.items else self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end];
            switch (try self.memberTarget(receiver_type, member, method_arguments.len + 1, call.span)) {
                .field => {
                    const callee = try self.borrowValue(try self.accessField(member.receiver, member.name, call.span), call.span);
                    signature.* = try self.callableSignature(callee.type_id, call.span);
                    target.* = .{ .indirect = callee };
                },
                .static_callable => |callee| {
                    signature.* = try self.callableSignature(callee.type_id, call.span);
                    target.* = .{ .indirect = try self.appendInstruction(.{ .function_ref = callee.value.function_ref }) };
                    try arguments.append(self.gpa, member.receiver);
                },
                .function => |function| {
                    try arguments.append(self.gpa, member.receiver);
                    target.* = if (function.ownership) .{ .direct = function.instance } else try self.resolveMethodArguments(function.instance, function.shape, method_arguments, call.span, arguments);
                    if (target.* == .direct) signature.* = (try self.analysis_context.functionSignature(target.direct)) orelse return error.Unavailable;
                    if (!function.ownership) return null;
                },
                .overloaded => |overload| {
                    const instance = try self.resolveMemberOverload(overload, call, member.receiver, method_arguments, arguments);
                    target.* = .{ .direct = instance };
                    signature.* = (try self.analysis_context.functionSignature(instance)) orelse return error.Unavailable;
                    return null;
                },
            }
            for (method_arguments) |argument| try arguments.append(self.gpa, argument.value);
            return null;
        }

        fn resolveMethodArguments(
            self: *Self,
            instance: structures.InstanceId,
            shape: structures.FunctionShape,
            method_arguments: []const semantic.UnresolvedBody.MethodCallArgument,
            span: structures.SourceSpan,
            arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse),
        ) !CallTarget {
            if (shape.parameters.len == 0 or shape.parameters[0].mode == .static)
                return self.reject(span, .static_argument_not_supported);
            var runtime_count: usize = 0;
            for (shape.parameters) |parameter| if (parameter.mode != .static) {
                runtime_count += 1;
            };
            if (method_arguments.len + 1 == runtime_count and runtime_count != shape.parameters.len) {
                for (method_arguments) |argument| try arguments.append(self.gpa, argument.value);
                return .{ .inferred = instance };
            }
            if (method_arguments.len + 1 != shape.parameters.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(shape.parameters.len - 1),
                .found = @intCast(method_arguments.len),
            } });
            var static_arguments: std.ArrayList(structures.CompileTimeValueId) = .empty;

            for (method_arguments, shape.parameters[1..], 1..) |argument, parameter, parameter_index| {
                if (parameter.mode != .static) {
                    try arguments.append(self.gpa, argument.value);
                    continue;
                }
                if (argument.runtime_reference) |reference_span|
                    return self.reject(reference_span, .comptime_runtime_capture);
                const expected_type = if (parameter.is_meta_type) null else try self.analysis_context.staticParameterType(instance, parameter_index, static_arguments.items);
                const value_id = (try self.analysis_context.staticCallArgument(argument.node, parameter.is_meta_type, expected_type)) orelse return error.Unavailable;
                const compile_time_value = try self.analysis_context.lookupCompileTimeValue(value_id);
                if (compile_time_value == .runtime and compile_time_value.runtime.value == .function_ref)
                    return self.reject(argument.value.span, .static_argument_not_supported);
                try static_arguments.append(self.gpa, value_id);
            }
            return .{ .direct = try self.analysis_context.specializeFunction(instance, static_arguments.items) };
        }

        fn callFunction(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, mode: ResultRequest) !Value {
            const resolved = try self.resolveCall(call, span, null);
            switch (resolved) {
                .diverged => |value_to_return| return value_to_return,
                .callable => |callable| return self.resolvedCallResult(callable, call, span, mode),
            }
        }

        fn resolvedCallResult(self: *Self, callable: ResolvedCallable, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, request: ResultRequest) !Value {
            if (request.destination == null and request.value.access != .borrow and request.value.access != .consume)
                return self.resolvedCallValue(callable, call, span, null);
            const return_type = callable.operation.return_type;
            if (!try self.usesIndirectStorage(return_type)) {
                const result = try self.resolvedCallValue(callable, call, span, null);
                return if (request.destination) |destination| self.placeValue(result, span, destination) else result;
            }
            const target = request.destination orelse Destination{ .storage = try self.localStorage(request.value.expected_type orelse return_type), .site = .argument };
            const storage = try self.memberDestination(target, return_type, span, .fresh);
            return self.finishMemberStorage(try self.resolvedCallValue(callable, call, span, storage), target.storage, span);
        }

        fn resolvedCallValue(self: *Self, resolved: ResolvedCallable, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, destination: ?Value) !Value {
            _ = call;
            const result = try self.ordinaryCallValue(resolved, span, destination);
            if (result.type_id == .never or resolved.result_mode == .owned) return result;
            return self.readReference(result, (try self.analysis_context.facts().borrowElement(result.type_id)).?);
        }

        fn ordinaryCallValue(self: *Self, resolved: ResolvedCallable, span: structures.SourceSpan, destination: ?Value) !Value {
            var callable = resolved;
            if (callable.operation.target == .direct) if (try self.analysis_context.inlineBuiltin(callable.operation.target.direct.item)) |builtin| {
                switch (builtin.symbol) {
                    .primitive_operation => switch (builtin.operation.?) {
                        .@"+", .@"-", .@"*", .@"/" => {
                            const arguments = self.call_arguments.items[callable.operation.arguments.start..callable.operation.arguments.end];
                            const result = try self.primitiveArithmetic(builtin.operation.?, .{ .lhs = arguments[0].valueId(), .rhs = arguments[1].valueId() });
                            return self.defineOwnedValue(result, span, false);
                        },
                        .@"==", .@"<>", .@"<", .@">", .@"<=", .@">=" => {
                            const arguments = self.call_arguments.items[callable.operation.arguments.start..callable.operation.arguments.end];
                            const signature = (try self.analysis_context.functionSignature(callable.operation.target.direct)) orelse return error.Unavailable;
                            return self.appendInstruction(.{ .compare = .{ .operation = primitivePredicateOperation(builtin.operation.?, signature.parameters[0].type_id), .operands = .{ .lhs = arguments[0].valueId(), .rhs = arguments[1].valueId() } } });
                        },
                        else => {},
                    },
                    .literal_byte => {
                        const arguments = try self.analysis_context.lookupCompileTimeTuple(callable.operation.target.direct.specialization.?);
                        std.debug.assert(arguments.len == 1);
                        return self.defineOwnedValue(try self.literalByteValue(arguments[0], span), span, false);
                    },
                    else => unreachable,
                }
            };
            if (callable.operation.target == .initializer) try self.recordInitializerUses(callable.operation.target.initializer);
            for (self.call_arguments.items[callable.operation.arguments.start..callable.operation.arguments.end]) |argument| {
                if (argument == .initializer) try self.recordInitializerUses(argument.initializer);
            }
            try self.recordCallArgumentConsumes(callable.consumed_arguments);
            if (destination) |storage| callable.operation.destination = storage.id;
            if (callable.operation.return_type == .never) try self.recordReplacementUses();
            var value_to_return = try self.appendInstruction(.{ .call = callable.operation });
            try self.recordReferenceEffects(.{ .instruction = @truncate(@backingInt(value_to_return.id)) }, callable.reference_effects);
            if (value_to_return.type_id == .never) {
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.terminate(.diverge);
            } else {
                value_to_return = try self.defineOwnedValue(destination orelse value_to_return, span, false);
                value_to_return.reference_origins = try self.finishCallEffects(callable);
                if (try self.analysis_context.facts().borrowElement(value_to_return.type_id)) |element| if (try self.analysis_context.facts().variantMembers(element) != null) {
                    value_to_return.flow_origins = try self.referenceFlowOrigins(value_to_return, element);
                };
            }
            return value_to_return;
        }

        fn projectResultOrigins(self: *Self, origins: ?u32, result_type: structures.TypeId) !?u32 {
            // A callable's signature cannot establish correspondence between
            // input and output fields. Every returned borrow retains all input
            // origins, with projections and content dependencies from its own shape.
            var visiting: std.ArrayList(structures.TypeId) = .empty;

            return self.projectResultOriginsAt(try self.transformReferenceOrigins(origins, .widen), result_type, &visiting);
        }

        fn substituteOutputOrigins(self: *Self, contract: structures.ReferenceContract, arguments: []const CallOriginSource, output_parameter: ?u32) !?u32 {
            var result: ?u32 = null;
            for (contract.origins) |entry| {
                if (entry.output_parameter != output_parameter) continue;
                if (output_parameter != null and referenceReferentStep(contract.paths[entry.result_path.start..entry.result_path.end]) != null) continue;
                result = try self.mergeReferenceOrigins(result, try self.substituteReferenceOrigin(contract, entry, arguments));
            }
            return result;
        }

        fn substituteReferenceExclusions(self: *Self, contract: structures.ReferenceContract, arguments: []const CallOriginSource, span: structures.SourceSpan) !void {
            for (contract.exclusions) |exclusion| {
                try self.reference_exclusions.append(self.gpa, .{
                    .reference = try self.substituteReferenceOrigin(contract, exclusion.reference, arguments),
                    .invalidation = try self.substituteReferenceOrigin(contract, exclusion.invalidation, arguments),
                    .span = span,
                });
            }
        }

        fn referenceReferentStep(path: []const structures.ReferencePathStep) ?usize {
            for (path, 0..) |step, index| if (step == .referent) return index;
            return null;
        }

        fn appendReferentOutputs(self: *Self, contract: structures.ReferenceContract, sources: []const CallOriginSource, arguments: []const structures.FunctionCallArgument) !void {
            for (contract.requirements) |requirement| {
                if (requirement.kind != .contents) continue;
                const written_type = requirement.written_type orelse continue;
                const parameter = requirement.parameter;
                const target_path = contract.paths[requirement.path.start..requirement.path.end];
                {
                    var output_origins: ?u32 = null;
                    var found = false;
                    for (contract.origins) |entry| {
                        if (entry.output_parameter != parameter) continue;
                        const path = contract.paths[entry.result_path.start..entry.result_path.end];
                        if (path.len <= target_path.len or path[target_path.len] != .referent) continue;
                        if (!structures.ReferenceContract.samePath(contract, requirement.path, contract, .{ .start = entry.result_path.start, .end = entry.result_path.start + @as(u32, @intCast(target_path.len)) })) continue;
                        var origins = try self.substituteReferenceOrigin(contract, entry, sources);
                        for (path[0 .. target_path.len + 1]) |step| origins = try self.transformReferenceOrigins(origins, .{ .select = self.substituteReferenceStep(step, sources) });
                        output_origins = try self.mergeReferenceOrigins(output_origins, origins);
                        found = true;
                    }
                    if (!found) continue;
                    var target_origins = sources[parameter].contained;
                    for (target_path) |step| target_origins = try self.transformReferenceOrigins(target_origins, .{ .select = self.substituteReferenceStep(step, sources) });
                    try self.pending_reference_outputs.append(self.gpa, .{
                        .reference = .{
                            .id = arguments[parameter].valueId(),
                            .type_id = try self.analysis_context.facts().referenceType(written_type),
                            .reference_origins = target_origins,
                        },
                        .origins = output_origins,
                    });
                }
            }
        }

        fn substituteReferenceOrigin(self: *Self, contract: structures.ReferenceContract, entry: structures.ReferenceOriginContract, arguments: []const CallOriginSource) !?u32 {
            var origins = if (entry.parameter) |parameter|
                if (entry.kind == .place) arguments[parameter].storage else arguments[parameter].contained
            else
                try self.addReferenceOrigin(null, .{ .permanent = true });
            for (contract.paths[entry.source_path.start..entry.source_path.end]) |step| {
                const substituted = self.substituteReferenceStep(step, arguments);
                origins = if (entry.kind == .place)
                    try self.appendSourcePath(origins, substituted)
                else if (step == .referent)
                    try self.referenceOriginContents(origins, origins)
                else
                    try self.transformReferenceOrigins(origins, .{ .select = substituted });
            }
            if (entry.kind == .place) {
                origins = try self.transformReferenceOrigins(origins, .{ .place = .{
                    .storage_depth = entry.storage_depth,
                    .stable = entry.stable,
                    .after_write = entry.after_write,
                } });
            }
            if (entry.readonly) origins = try self.readonlyOrigins(origins);
            if (entry.readonly_owned) |type_id| origins = try self.readonlyOwnedOrigins(type_id, origins);
            if (entry.reads_contents or entry.variant_guard or entry.storage_depth != 0) {
                origins = try self.readReferenceOrigins(origins, null, @intCast(self.instruction_count), false);
                if (entry.kind == .place and entry.storage_depth != 0) origins = try self.transformReferenceOrigins(origins, .{ .place = .{ .storage_depth = 0, .stable = entry.stable, .after_write = entry.after_write } });
            }
            var position = entry.result_path.end;
            while (position > entry.result_path.start) {
                position -= 1;
                origins = try self.transformReferenceOrigins(origins, .{ .prefix = self.substituteReferenceStep(contract.paths[position], arguments) });
            }
            return origins;
        }

        fn projectResultOriginsAt(self: *Self, origins: ?u32, result_type: structures.TypeId, visiting: *std.ArrayList(structures.TypeId)) anyerror!?u32 {
            if (origins == null or !try self.analysis_context.facts().canStoreBorrow(result_type)) return null;
            const retained = try self.retainResultFrames(origins, result_type);
            if (retained != origins) return self.projectResultOriginsAt(retained, result_type, visiting);
            return self.projectRetainedResultOrigins(origins, result_type, visiting);
        }

        fn retainResultFrames(self: *Self, origins: ?u32, result_type: structures.TypeId) !?u32 {
            var retained: ?u32 = null;
            var filtered = false;
            var current = self.originList(origins);
            while (current.next()) |origin| {
                if (origin.frame_type) |frame_type| if (!try self.analysis_context.canBorrowInlineStorageOf(result_type, frame_type)) {
                    filtered = true;
                    continue;
                };
                retained = try self.addReferenceOrigin(retained, origin);
            }
            return if (filtered) retained else origins;
        }

        fn projectRetainedResultOrigins(self: *Self, origins: ?u32, result_type: structures.TypeId, visiting: *std.ArrayList(structures.TypeId)) anyerror!?u32 {
            if (try self.analysis_context.facts().storageAccess(result_type) != null or try self.analysis_context.facts().borrowElement(result_type) != null)
                return origins;
            if (std.mem.indexOfScalar(structures.TypeId, visiting.items, result_type) != null)
                return self.readReferenceOrigins(origins, null, @intCast(self.instruction_count), false);
            try visiting.append(self.gpa, result_type);
            defer _ = visiting.pop();
            const facts = self.analysis_context.facts();
            if ((try facts.boxElement(result_type)) orelse try facts.allocationElement(result_type)) |element|
                return self.transformReferenceOrigins(try self.projectResultOriginsAt(origins, element, visiting), .{ .prefix = .element });
            var result: ?u32 = null;
            var components_iterator = try facts.components(result_type);
            while (components_iterator.next()) |component| {
                const child_origins = if (component.kind == .reference) origins else try self.projectResultOriginsAt(origins, component.type_id, visiting);
                result = try self.mergeReferenceOrigins(result, try self.transformReferenceOrigins(child_origins, .{ .prefix = component.step }));
            }
            return result;
        }

        fn finishCallEffects(self: *Self, callable: ResolvedCallable) !?u32 {
            var returned_origins = callable.reference_origins;
            if (callable.operation.target == .initializer)
                try self.finishInitializerEffects(callable.operation.target.initializer, &returned_origins, callable.mut_arguments);
            for (self.call_arguments.items[callable.operation.arguments.start..callable.operation.arguments.end]) |argument| {
                if (argument == .initializer) try self.finishInitializerEffects(argument.initializer, &returned_origins, callable.mut_arguments);
            }
            for (self.pending_mut_arguments.items[callable.mut_arguments.start..callable.mut_arguments.end]) |pending| try self.applyCallMutArgument(pending);
            for (self.pending_mut_arguments.items[callable.mut_arguments.start..callable.mut_arguments.end]) |pending| {
                if (pending.place.root == .local) returned_origins = try self.updatedRootOrigin(returned_origins, pending.place.root.local);
            }
            var mutable_origins = if (callable.precise_reference_contract) null else try self.mutReturnOrigins(callable.mut_arguments);
            if (try self.analysis_context.facts().storageAccess(callable.operation.return_type) != null or try self.analysis_context.facts().borrowElement(callable.operation.return_type) != null) {
                for (self.pending_mut_arguments.items[callable.mut_arguments.start..callable.mut_arguments.end]) |pending| {
                    if (!pending.return_origin) continue;
                    const root = if (pending.place.root == .local) pending.place.root.local else null;
                    mutable_origins = try self.stableStorageOrigins(mutable_origins, root);
                }
            }
            returned_origins = try self.mergeReferenceOrigins(returned_origins, mutable_origins);
            try self.invalidateWritableReferences(
                self.writable_call_references.items[callable.writable_references.start..callable.writable_references.end],
                .{ .slots = &returned_origins },
            );
            if (!callable.precise_reference_contract) try self.finishCallMutOrigins(callable.mut_arguments);
            try self.applyReferenceOutputs(callable.reference_outputs);
            if (returned_origins != null)
                returned_origins = try self.transformReferenceOrigins(returned_origins, .{ .refresh_written = try self.captureState() });
            if (callable.precise_reference_contract) return self.retainResultFrames(returned_origins, callable.operation.return_type);
            if (returned_origins == null and try self.analysis_context.facts().canStoreBorrow(callable.operation.return_type))
                returned_origins = try self.addReferenceOrigin(null, .{ .permanent = true });
            if (callable.operation.target == .indirect) returned_origins = try self.readonlyOrigins(returned_origins);
            return self.projectResultOrigins(returned_origins, callable.operation.return_type);
        }

        fn applyReferenceOutputs(self: *Self, outputs: structures.FunctionValueRange) !void {
            for (self.pending_reference_outputs.items[outputs.start..outputs.end]) |output| {
                const origins = if (output.origins != null)
                    try self.transformReferenceOrigins(output.origins, .{ .refresh_written = try self.captureState() })
                else
                    null;
                try self.storeReferenceContents(output.reference, origins);
            }
        }

        fn recordInitializerUses(self: *Self, initializer: structures.FunctionValueId) !void {
            for (self.initializer_owners.items) |retained| {
                if (retained.initializer == initializer) try self.recordUse(retained.owner);
            }
        }

        fn finishInitializerEffects(self: *Self, initializer: structures.FunctionValueId, returned_origins: *?u32, mut_arguments: structures.FunctionValueRange) !void {
            for (self.initializer_transfers.items) |transfer| {
                if (transfer.initializer != initializer) continue;
                const availability = transfer.call_availability;
                if (transfer.field) |field| {
                    try self.state.field_availability.set(self.gpa, field, availability);
                } else try self.state.availability.set(self.gpa, @backingInt(transfer.local), availability);
            }
            for (self.initializer_transfers.items) |transfer| {
                if (transfer.initializer != initializer or transfer.call_availability != .available) continue;
                const local_index = @backingInt(transfer.local);
                if (self.state.availability.get(local_index) != .available) continue;
                if (self.is_initializer_region and self.captured_locals[local_index] != null) continue;
                const owner = self.state.values.get(local_index).?;
                const previous = if (owner.owned_generation) |generation| self.generations.items[@backingInt(generation)].missing_fields else &.{};
                var fields: std.ArrayList(PlaceField) = .empty;

                if (transfer.field) |field| {
                    try self.resolvePlaceFields(owner.type_id, self.field_places[field].fields, self.activeLifetimeSpan(), &fields);
                    if (self.unavailableField(transfer.local, fields.items) != null) continue;
                    try self.retireGuardedOwner(transfer.owner);
                    try self.recordConsume(transfer.owner);
                }
                try self.retireGuardedOwner(owner);
                try self.recordConsume(owner);
                const retained = try self.defineOwnedValue(owner, self.activeLifetimeSpan(), self.locals.items(.can_deinit)[local_index]);
                if (retained.owned_generation) |generation|
                    try self.copyMissingFields(generation, previous, null, if (transfer.field != null) fields.items else null);
                try self.updateLocal(local_index, .{ .owned_generation = retained.owned_generation });
            }
            for (self.initializer_writes.items) |write| {
                if (write.initializer != initializer) continue;
                var local = self.state.values.get(@backingInt(write.local)).?;
                local.reference_origins = try self.mergeReferenceOrigins(local.reference_origins, write.origins);
                try self.state.values.set(self.gpa, @backingInt(write.local), local);
                try self.rememberCleanupOrigins(local);
                try self.advanceReferenceRoot(write.local, null, null);
                const identity = self.state.values.get(@backingInt(write.local)).?.binding_identity;
                returned_origins.* = try self.refreshInitializerOwnerOrigins(returned_origins.*, initializer, write.local, identity);
                for (self.pending_mut_arguments.items[mut_arguments.start..mut_arguments.end]) |*pending| {
                    pending.reference_origins = try self.refreshInitializerOwnerOrigins(pending.reference_origins, initializer, write.local, identity);
                }
            }
            for (self.initializer_reference_writes.items) |write| {
                if (write.initializer != initializer) continue;
                try self.advanceOwnedReferenceOrigins(write.reference, write.reference.id, .{ .value = returned_origins });
            }
        }

        fn retireGuardedOwner(self: *Self, owner: Value) !void {
            const generation = owner.owned_generation orelse return;
            const predicate = self.generations.items[@backingInt(generation)].cleanup_condition orelse return;
            _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = true }), .{ .id = predicate, .type_id = .bool });
        }

        fn stableStorageOrigins(self: *Self, origins: ?u32, storage_root: ?semantic.UnresolvedBody.LocalId) !?u32 {
            const root = storage_root orelse return origins;
            var result: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                if (origin.root == root and origin.projection == null) {
                    const owner = self.state.values.get(@backingInt(root)).?;
                    origin.stable = true;
                    origin.binding_identity = owner.storage_identity orelse owner.binding_identity;
                }
                result = try self.addReferenceOrigin(result, origin);
                current = origin.next;
            }
            return result;
        }

        fn addReferenceOrigin(self: *Self, head: ?u32, origin: ReferenceOrigin) !?u32 {
            return self.reference_storage.add(self.gpa, head, origin);
        }

        fn deferReferenceTransform(self: *Self, origin: *ReferenceOrigin, operation: @FieldType(ReferenceTransform, "operation")) !void {
            origin.transform = try self.reference_storage.transform(self.gpa, .{ .operation = operation, .previous = origin.transform });
        }

        fn applyReferenceTransforms(self: *Self, origins: ?u32, transform: ?u32) anyerror!?u32 {
            const index = transform orelse return origins;
            const transformation = self.reference_storage.transforms.keys()[index];
            const previous = try self.applyReferenceTransforms(origins, transformation.previous);
            return switch (transformation.operation) {
                .read => |read| self.readReferenceOrigins(previous, read.state, read.instruction, false),
                else => self.transformReferenceOrigins(previous, transformation.operation),
            };
        }

        fn transformReferenceOrigins(self: *Self, origins: ?u32, operation: @FieldType(ReferenceTransform, "operation")) !?u32 {
            std.debug.assert(operation != .read);
            if (origins == null) return null;
            if (operation == .select and operation.select == .without_element) {
                const index = operation.select.without_element orelse return origins;
                return self.transformReferenceOrigins(origins, .{ .exclude = .{ .element_at = index } });
            }
            if (operation == .select and operation.select == .without_field)
                return self.transformReferenceOrigins(origins, .{ .exclude = .{ .field = operation.select.without_field } });
            if (operation == .select and operation.select == .without_variant)
                return self.transformReferenceOrigins(origins, .{ .exclude = .{ .variant = operation.select.without_variant } });
            var result: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                current = origin.next;
                if (origin.loop != null) {
                    var deferred = operation;
                    if (deferred == .place and deferred.place.state == null) deferred.place.state = try self.captureState();
                    try self.deferReferenceTransform(&origin, deferred);
                } else switch (operation) {
                    .prefix => |step| {
                        origin.projection = try self.reference_storage.projection(self.gpa, .{ .step = step, .next = origin.projection });
                    },
                    .select => |step| if (step == .descendants) {
                        origin.projection = null;
                        if (origin.parameter != null and origin.root == null) try self.appendOriginSourcePath(&origin, step);
                    } else if (origin.projection) |projection_index| {
                        const projection = self.reference_storage.projections.keys()[projection_index];
                        if (projection.step == .descendants) {
                            if (origin.readonly_owned) |type_id|
                                try self.restrictOwnedOrigin(&origin, (try self.referencePathStepType(type_id, step)) orelse unreachable);
                        } else {
                            if (!projection.step.matches(step)) continue;
                            origin.projection = projection.next;
                        }
                    } else {
                        if (origin.readonly_owned) |type_id|
                            try self.restrictOwnedOrigin(&origin, (try self.referencePathStepType(type_id, step)) orelse unreachable);
                        if (origin.parameter != null and origin.root == null) try self.appendOriginSourcePath(&origin, step);
                    },
                    .exclude => |step| if (!try self.excludeReferenceOrigin(&origin, step)) continue,
                    .source_path => |step| {
                        if (origin.parameter != null or origin.frame_type != null or (origin.root != null and origin.source_kind == .place and origin.projection == null))
                            try self.appendOriginSourcePath(&origin, step);
                    },
                    .place => |metadata| try self.applyPlaceReferenceMetadata(&origin, metadata),
                    .readonly => {
                        origin.readonly = true;
                        origin.readonly_owned = null;
                    },
                    .readonly_owned => |type_id| try self.restrictOwnedOrigin(&origin, type_id),
                    .relocate_read => |relocation| if (origin.read == relocation.from) {
                        origin.read = relocation.to;
                    },
                    .refresh_written => |state| if (origin.after_write) {
                        if (origin.root) |root| {
                            const owner = self.states.items[@backingInt(state)].values.get(@backingInt(root)).?;
                            origin.binding_identity = referenceIdentity(owner, origin);
                        }
                        origin.after_write = false;
                    },
                    .refresh => |refresh| if (origin.root == refresh.root and !origin.variant_guard and origin.stable and origin.storage_depth <= refresh.preserved_storage_depth and std.meta.eql(origin.binding_identity, refresh.previous)) {
                        origin.binding_identity = if (origin.storage_depth == 0) refresh.storage_replacement orelse refresh.replacement else refresh.replacement;
                    },
                    .widen => {},
                    .read => unreachable,
                }
                if (operation == .widen) origin.projection = null;
                result = try self.addReferenceOrigin(result, origin);
            }
            return result;
        }

        fn applyPlaceReferenceMetadata(self: *Self, origin: *ReferenceOrigin, metadata: PlaceReferenceMetadata) !void {
            const stable_source = origin.stable;
            if (metadata.storage_depth != 0) origin.variant_guard = false;
            origin.storage_depth = std.math.add(u32, origin.storage_depth, metadata.storage_depth) catch return error.AnalysisTooLarge;
            if (origin.storage_depth != 0) self.promoteAllocatedParameterOrigin(origin);
            origin.stable = metadata.stable;
            origin.after_write = metadata.after_write;
            if (origin.stable or stable_source) if (origin.root) |root| {
                const values = if (metadata.state) |state| self.states.items[@backingInt(state)].values else self.state.values.snapshot();
                const owner = values.get(@backingInt(root)).?;
                origin.binding_identity = referenceIdentity(owner, origin.*);
            };
        }

        fn replaceProjectedOrigins(self: *Self, origins: ?u32, step: @FieldType(ReferenceProjection, "step"), replacement: ?u32) !?u32 {
            return self.mergeReferenceOrigins(try self.transformReferenceOrigins(origins, .{ .exclude = step }), try self.transformReferenceOrigins(replacement, .{ .prefix = step }));
        }

        fn excludeReferenceOrigin(self: *Self, origin: *ReferenceOrigin, step: structures.ReferencePathStep) !bool {
            // An unknown slot permits only a weak update: retain every capture.
            if (step == .element) return true;
            if (origin.projection) |projection| {
                const existing = self.reference_storage.projections.keys()[projection].step;
                return !std.meta.eql(existing, step);
            }
            if (origin.source_kind != .contents or origin.parameter == null or origin.root != null) return true;
            switch (step) {
                .element_at => |selector| try self.appendOriginSourcePath(origin, .{ .without_element = selector }),
                .field => |field| try self.appendOriginSourcePath(origin, .{ .without_field = field }),
                .variant => |member| try self.appendOriginSourcePath(origin, .{ .without_variant = member }),
                else => {},
            }
            return true;
        }

        fn elementProjection(self: *Self, index: structures.FunctionValueId) structures.ReferencePathStep {
            return if (self.referenceIndex(index, 0)) |selector| .{ .element_at = selector } else .element;
        }

        fn referenceIndex(self: *Self, id: structures.FunctionValueId, depth: u32) ?structures.ReferenceIndex {
            if (depth >= 32) return null;
            if (@backingInt(id) < self.parameter_modes.items.len) {
                if (self.options.widen_reference_indices) return null;
                const parameter = @backingInt(id);
                if (self.parameter_modes.items[parameter] != .imm or self.block_arguments.items[parameter].type_id != .int) return null;
                if (self.is_initializer_region) for (self.captured_locals, self.locals.items(.mutable)) |captured, mutable| {
                    if (captured == parameter and mutable) return null;
                };
                return .{ .parameter = parameter };
            }
            if (@backingInt(id) & (@as(u32, 1) << 31) == 0) return null;
            const operation = self.findInstruction(@truncate(@backingInt(id))) orelse return null;
            switch (operation) {
                .const_int => |integer| return .{ .offset = integer },
                .value_copy => |copy| return self.referenceIndex(copy.source, depth + 1),
                .borrow_read => |read| return self.referenceIndex(read.source, depth + 1),
                .borrow_address => |address| {
                    if (address.fields.start != address.fields.end) return null;
                    return self.referenceIndex(address.source, depth + 1);
                },
                .local_storage => {
                    const source = self.immutableStorageSource(id) orelse return null;
                    return self.referenceIndex(source, depth + 1);
                },
                .addi, .subi => |operands| return self.binaryReferenceIndex(operands, operation == .subi, depth + 1),
                else => return null,
            }
        }

        fn binaryReferenceIndex(self: *Self, operands: structures.BinaryOperands, subtract: bool, depth: u32) ?structures.ReferenceIndex {
            var left = self.referenceIndex(operands.lhs, depth) orelse return null;
            const right = self.referenceIndex(operands.rhs, depth) orelse return null;
            if (right.parameter != null) {
                if (subtract and left.parameter == right.parameter) return .{ .offset = left.offset -% right.offset };
                if (subtract or left.parameter != null) return null;
                var result = right;
                result.offset +%= left.offset;
                return result;
            }
            left.offset = if (subtract) left.offset -% right.offset else left.offset +% right.offset;
            return left;
        }

        fn substituteReferenceStep(self: *Self, step: structures.ReferencePathStep, arguments: []const CallOriginSource) structures.ReferencePathStep {
            const index = step.indexSelector() orelse return step;
            const parameter = index.parameter orelse return step;
            return self.substituteReferenceIndex(step, arguments[parameter].value);
        }

        fn substituteReferenceIndex(self: *Self, step: structures.ReferencePathStep, selector_value: ?structures.FunctionValueId) structures.ReferencePathStep {
            const index = step.indexSelector().?;
            const substituted = if (selector_value) |id| self.referenceIndex(id, 0) else null;
            var resolved = substituted orelse return if (step == .without_element) .{ .without_element = null } else .element;
            resolved.offset +%= index.offset;
            return if (step == .element_at) .{ .element_at = resolved } else .{ .without_element = resolved };
        }

        fn collectWritableReferences(self: *Self, value_to_check: Value, references: *std.ArrayList(Value)) anyerror!void {
            var visiting: std.ArrayList(structures.TypeId) = .empty;

            try self.collectWritableReferencesAt(value_to_check, references, &visiting);
        }

        fn collectWritableReferencesAt(self: *Self, value_to_check: Value, references: *std.ArrayList(Value), visiting: *std.ArrayList(structures.TypeId)) anyerror!void {
            if (value_to_check.reference_origins == null) return;
            if (std.mem.indexOfScalar(structures.TypeId, visiting.items, value_to_check.type_id) != null) return;
            try visiting.append(self.gpa, value_to_check.type_id);
            defer _ = visiting.pop();
            const facts = self.analysis_context.facts();
            if ((try facts.borrowElement(value_to_check.type_id)) orelse try facts.storageAccess(value_to_check.type_id)) |element_type| {
                if (value_to_check.writable) try references.append(self.gpa, value_to_check);
                if (!try self.analysis_context.facts().canStoreBorrow(element_type)) return;
                return self.collectWritableReferencesAt(try self.selectedPart(value_to_check, element_type, .element), references, visiting);
            }
            if (try facts.boxElement(value_to_check.type_id)) |element_type|
                return self.collectWritableReferencesAt(try self.selectedPart(value_to_check, element_type, .element), references, visiting);
            if (try facts.allocationElement(value_to_check.type_id)) |element_type| {
                var element = value_to_check;
                element.type_id = element_type;
                return self.collectWritableReferencesAt(element, references, visiting);
            }
            var components_iterator = try facts.components(value_to_check.type_id);
            while (components_iterator.next()) |component| {
                if (component.count == 0) continue;
                const child_type = try facts.memberStorageType(.{ .type_id = component.type_id, .kind = component.kind });
                try self.collectWritableReferencesAt(try self.selectedPart(value_to_check, child_type, component.step), references, visiting);
            }
        }

        /// A part of `whole` whose reference origins are selected by `step`.
        fn selectedPart(self: *Self, whole: Value, type_id: structures.TypeId, step: @FieldType(ReferenceProjection, "step")) !Value {
            var part = whole;
            part.type_id = type_id;
            part.reference_origins = try self.transformReferenceOrigins(whole.reference_origins, .{ .select = step });
            return part;
        }

        const OriginList = struct {
            origins: *const std.ArrayList(ReferenceOrigin),
            current: ?u32,

            fn next(self: *OriginList) ?ReferenceOrigin {
                const index = self.current orelse return null;
                const origin = self.origins.items[index];
                self.current = origin.next;
                return origin;
            }
        };

        /// Iterates a linked origin set; additions made meanwhile do not affect it.
        fn originList(self: *const Self, head: ?u32) OriginList {
            return .{ .origins = &self.reference_storage.origins, .current = head };
        }

        /// Resolves origins whose loop summaries are already complete.
        fn completeReferenceOrigins(self: *Self, origins: ?u32) !?u32 {
            var incomplete = false;
            const resolved = try self.resolveReferenceOrigins(origins, &incomplete);
            std.debug.assert(!incomplete);
            return resolved;
        }

        fn resolveReferenceOrigins(self: *Self, origins: ?u32, incomplete: *bool) !?u32 {
            var visiting: std.ArrayList(u32) = .empty;
            var resolved: ?u32 = null;
            try self.expandReferenceOrigins(origins, &resolved, &visiting, incomplete);
            return resolved;
        }

        fn expandReferenceOrigins(
            self: *Self,
            origins: ?u32,
            resolved: *?u32,
            visiting: *std.ArrayList(u32),
            incomplete: *bool,
        ) !void {
            var current = self.originList(origins);
            while (current.next()) |origin| {
                if (origin.loop) |loop_index| {
                    if (std.mem.indexOfScalar(u32, visiting.items, loop_index) == null) {
                        try visiting.append(self.gpa, loop_index);
                        const loop_origins = self.loop_reference_origins.items[loop_index];
                        if (!loop_origins.complete) incomplete.* = true;
                        var expanded: ?u32 = null;
                        try self.expandReferenceOrigins(loop_origins.origins, &expanded, visiting, incomplete);
                        expanded = try self.rebaseLoopReadOrigins(expanded, loop_origins.read_checkpoint.?);
                        resolved.* = try self.mergeReferenceOrigins(resolved.*, try self.applyReferenceTransforms(expanded, origin.transform));
                        _ = visiting.pop();
                    }
                } else {
                    resolved.* = try self.addReferenceOrigin(resolved.*, origin);
                }
            }
        }

        fn rebaseLoopReadOrigins(self: *Self, origins: ?u32, checkpoint: u31) !?u32 {
            var rebased: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                current = origin.next;
                if (origin.read != null) origin.read = checkpoint;
                rebased = try self.addReferenceOrigin(rebased, origin);
            }
            return rebased;
        }

        fn typeContainsBorrow(self: *Self, type_id: structures.TypeId) !bool {
            return self.analysis_context.facts().containsBorrow(type_id);
        }

        fn mergeReferenceOrigins(self: *Self, first: ?u32, second: ?u32) !?u32 {
            return self.reference_storage.merge(self.gpa, first, second);
        }

        fn sourceReferenceOrigins(self: *Self, source: Value) !?u32 {
            if (source.borrow_condition != null and source.owned_generation != null) {
                return self.mergeReferenceOrigins(source.place_origins, try self.addReferenceOrigin(null, .{
                    .generation = source.owned_generation,
                    .cleanup_value = source.id,
                    .source_kind = .place,
                }));
            }
            const generation = source.borrowed_generation orelse source.owned_generation;
            if (source.binding_identity == .unknown and source.reference_origins != null) {
                if (source.place_origins) |origins| return origins;
                if (generation == null or !try self.analysis_context.facts().canStoreBorrow(source.type_id)) return source.reference_origins;
            }
            if (generation == null and source.borrow_root == null) {
                if (source.reference_origins != null) return source.reference_origins;
                if (try self.analysis_context.facts().argumentPassing(source.type_id) == .indirect)
                    return self.addReferenceOrigin(null, .{ .cleanup_value = source.id });
                return null;
            }
            return self.addReferenceOrigin(null, .{
                .generation = generation,
                .cleanup_value = source.borrowed_cleanup_value orelse source.id,
                .root = source.borrow_root,
                .binding_identity = source.binding_identity,
                .source_kind = .place,
                .parameter = if (source.borrow_root) |root| self.locals.items(.mut_parameter)[@backingInt(root)] orelse
                    (if (self.is_initializer_region) self.captured_locals[@backingInt(root)] else null) else null,
            });
        }

        fn withReferenceOrigin(self: *Self, source: Value, reference: Value) !Value {
            var result = reference;
            result.reference_origins = try self.sourceReferenceOrigins(source);
            result.writable = source.writable;
            return result;
        }

        fn referenceContents(self: *Self, reference: Value, fallback: ?u32) !?u32 {
            if (reference.local_reference) |place| {
                const owner = self.state.values.get(@backingInt(place.local)) orelse return fallback;
                return self.fieldReferenceOrigins(owner.reference_origins, self.borrow_fields.items[place.projections.start..place.projections.end]);
            }
            return self.referenceOriginContents(reference.reference_origins, fallback);
        }

        fn referenceOriginContents(self: *Self, origins: ?u32, fallback: ?u32) !?u32 {
            var result: ?u32 = null;
            var found = false;
            var current = self.originList(origins);
            while (current.next()) |origin| {
                if (origin.source_kind == .contents and origin.parameter != null and origin.root == null and origin.projection == null) {
                    const symbolic = try self.addReferenceOrigin(null, origin);
                    const source_type = try self.referenceOriginType(origin);
                    const contents = if (source_type != null and try self.analysis_context.facts().borrowElement(source_type.?) != null)
                        try self.appendSourcePath(symbolic, .referent)
                    else
                        symbolic;
                    result = try self.mergeReferenceOrigins(result, contents);
                    found = true;
                    continue;
                }
                if (origin.source_kind != .place or origin.projection != null) continue;
                const owner = if (origin.root) |root|
                    self.state.values.get(@backingInt(root)) orelse continue
                else if (origin.parameter != null and origin.parameter.? < self.unresolved.parameter_count)
                    self.values.get(origin.parameter.?) orelse continue
                else if (origin.frame_type != null and origin.cleanup_value != null and @backingInt(origin.cleanup_value.?) < self.unresolved.parameter_count)
                    self.values.get(@backingInt(origin.cleanup_value.?)) orelse continue
                else
                    continue;
                var path: std.ArrayList(structures.ReferencePathStep) = .empty;

                try self.referenceSourcePath(origin, &path);
                var contents = owner.reference_origins;
                for (path.items) |step| contents = try self.transformReferenceOrigins(contents, .{ .select = step });
                result = try self.mergeReferenceOrigins(result, contents);
                found = true;
            }
            return if (found) result else fallback;
        }

        fn referenceSourcePath(self: *Self, origin: ReferenceOrigin, path: *std.ArrayList(structures.ReferencePathStep)) !void {
            const start = path.items.len;
            var current = origin.source_path;
            while (current) |index| {
                const projection = self.reference_storage.projections.keys()[index];
                try path.append(self.gpa, projection.step);
                current = projection.next;
            }
            std.mem.reverse(structures.ReferencePathStep, path.items[start..]);
        }

        fn storeReferenceContents(self: *Self, reference: Value, replacement: ?u32) !void {
            if (reference.local_reference) |place| {
                var owner = self.state.values.get(@backingInt(place.local)).?;
                owner.reference_origins = try self.fieldUpdateOrigins(owner.reference_origins, self.borrow_fields.items[place.projections.start..place.projections.end], replacement);
                try self.state.values.set(self.gpa, @backingInt(place.local), owner);
                try self.captureCleanupOrigins(owner);
                return;
            }
            var current = self.originList(reference.reference_origins);
            while (current.next()) |origin| {
                if (origin.projection != null) continue;
                const root = origin.root orelse {
                    if (origin.parameter != null and origin.source_kind == .contents) try self.storeSymbolicReferenceContents(reference, origin, replacement);
                    continue;
                };
                var owner = self.state.values.get(@backingInt(root)).?;
                var path: std.ArrayList(structures.ReferencePathStep) = .empty;

                try self.referenceSourcePath(origin, &path);
                owner.reference_origins = try self.replaceReferenceContentsAt(owner.reference_origins, path.items, replacement);
                try self.state.values.set(self.gpa, @backingInt(root), owner);
                try self.captureCleanupOrigins(owner);
            }
        }

        fn storeSymbolicReferenceContents(self: *Self, reference: Value, origin: ReferenceOrigin, replacement: ?u32) !void {
            try self.validateEscapingBorrows(.{ .id = reference.id, .type_id = (try self.analysis_context.facts().borrowElement(reference.type_id)).?, .reference_origins = replacement }, self.activeLifetimeSpan());
            var path: std.ArrayList(structures.ReferencePathStep) = .empty;

            try self.referenceSourcePath(origin, &path);
            var stored = try self.transformReferenceOrigins(replacement, .{ .prefix = .referent });
            var position = path.items.len;
            while (position > 0) {
                position -= 1;
                stored = try self.transformReferenceOrigins(stored, .{ .prefix = path.items[position] });
            }
            {
                try self.recordOutputOrigins(origin.parameter.?, stored);
            }
        }

        fn replaceReferenceContentsAt(self: *Self, origins: ?u32, path: []const structures.ReferencePathStep, replacement: ?u32) anyerror!?u32 {
            if (path.len == 0) return replacement;
            const step = path[0];
            if (step == .descendants) return self.mergeReferenceOrigins(origins, replacement);
            const previous = try self.transformReferenceOrigins(origins, .{ .select = step });
            const updated = try self.replaceReferenceContentsAt(previous, path[1..], replacement);
            return self.replaceProjectedOrigins(origins, step, updated);
        }

        fn appendSourcePath(self: *Self, origins: ?u32, step: structures.ReferencePathStep) !?u32 {
            return self.transformReferenceOrigins(origins, .{ .source_path = step });
        }

        fn appendOriginSourcePath(self: *Self, origin: *ReferenceOrigin, step: structures.ReferencePathStep) !void {
            if (origin.source_path) |last| if (self.reference_storage.projections.keys()[last].step == .descendants) return;
            if (step == .without_element and step.without_element == null) return;
            if (step.isExclusion()) {
                var previous = origin.source_path;
                while (previous) |index| {
                    const projection = self.reference_storage.projections.keys()[index];
                    if (!projection.step.isExclusion()) break;
                    if (std.meta.eql(projection.step, step)) return;
                    previous = projection.next;
                }
            }
            origin.source_path = try self.reference_storage.projection(self.gpa, .{ .step = step, .next = origin.source_path });
        }

        fn elementReferenceOrigins(self: *Self, origins: ?u32, allocated: bool) !?u32 {
            return self.projectElementReferenceOrigins(origins, allocated, .element);
        }

        fn projectElementReferenceOrigins(self: *Self, origins: ?u32, allocated: bool, step: structures.ReferencePathStep) !?u32 {
            var result: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                current = origin.next;
                const single = try self.addReferenceOrigin(null, origin);
                if (origin.source_kind != .place) {
                    result = try self.mergeReferenceOrigins(result, try self.transformReferenceOrigins(single, .{ .select = step }));
                    continue;
                }
                origin.stable = true;
                if (allocated) {
                    origin.variant_guard = false;
                    if (origin.root) |root| origin.binding_identity = self.state.values.get(@backingInt(root)).?.binding_identity;
                    origin.storage_depth = std.math.add(u32, origin.storage_depth, 1) catch return error.AnalysisTooLarge;
                    self.promoteAllocatedParameterOrigin(&origin);
                }
                const projected = try self.addReferenceOrigin(null, origin);
                result = try self.mergeReferenceOrigins(result, try self.appendSourcePath(projected, step));
            }
            return result;
        }

        fn promoteAllocatedParameterOrigin(self: *Self, origin: *ReferenceOrigin) void {
            if (origin.frame_type == null or origin.cleanup_value == null) return;
            const parameter = @backingInt(origin.cleanup_value.?);
            if (parameter >= self.unresolved.parameter_count) return;
            origin.parameter = parameter;
            origin.frame_type = null;
        }

        fn readonlyOrigins(self: *Self, origins: ?u32) !?u32 {
            return self.transformReferenceOrigins(origins, .readonly);
        }

        fn originsReadonly(self: *Self, origins: ?u32) !bool {
            var incomplete = false;
            var current = self.originList(try self.resolveReferenceOrigins(origins, &incomplete));
            while (current.next()) |origin| {
                if (origin.readonly) return true;
            }
            return false;
        }

        fn captureReference(self: *Self, raw: semantic.UnresolvedBody.ValueUse) anyerror!Value {
            if (self.expressionOperation(raw.value)) |operation| switch (operation.*) {
                .if_else, .match, .loop, .scope => return self.evaluateValue(raw.value, .{ .reference = true }),
                else => {},
            };
            var fields: std.ArrayList(PlaceField) = .empty;
            const place = (try self.resolveBorrowPlace(raw.value, &fields)) orelse {
                const value_to_borrow = try self.value(raw.value);
                if (value_to_borrow.type_id == .never) return value_to_borrow;
                const address = value_to_borrow.place_reference orelse return self.reject(raw.span, .borrow_requires_place);
                return .{ .id = address, .type_id = try self.analysis_context.facts().referenceType(value_to_borrow.type_id), .writable = value_to_borrow.writable, .reference_origins = value_to_borrow.place_origins, .flow_origins = value_to_borrow.flow_origins, .local_reference = value_to_borrow.local_reference };
            };
            return self.capturePlaceReference(place, fields.items, raw.span);
        }

        fn capturePlaceReference(self: *Self, place: BorrowPlace, fields: []const PlaceField, span: structures.SourceSpan) !Value {
            var root = try self.projectBorrowPlace(place, false, span);
            if (place.root == .local) root = try self.pinLocalStorage(place.root.local);
            const selected = fields[place.fields.start..place.fields.end];
            const element_type = if (selected.len != 0) selected[selected.len - 1].type_id else try self.placeRootType(place.root);
            var reference = try self.appendInstruction(.{ .borrow_address = .{
                .source = root.id,
                .type_id = try self.analysis_context.facts().referenceType(element_type),
                .fields = try self.publishBorrowFields(selected),
                .base_is_reference = place.root == .reference,
            } });
            switch (place.root) {
                .local => |local| {
                    const source = self.borrowLocalValue(local);
                    reference = try self.withReferenceOrigin(source, reference);
                    reference.flow_origins = try self.valuePlaceOrigins(source);
                    reference.reference_origins = try self.stableStorageOrigins(reference.reference_origins, local);
                    reference.local_reference = .{ .local = local, .projections = try self.publishBorrowFields(selected) };
                },
                .parameter => {
                    reference.writable = false;
                    reference.reference_origins = try self.parameterPlaceOrigins(@backingInt(root.id), root);
                    reference.flow_origins = reference.reference_origins;
                },
                .reference => {
                    reference.writable = root.writable;
                    reference.reference_origins = root.reference_origins;
                    reference.flow_origins = try self.referenceFlowOrigins(root, (try self.analysis_context.facts().borrowElement(root.type_id)).?);
                    reference.local_reference = try self.extendLocalReference(root.local_reference, selected, null);
                },
            }
            for (selected) |field| {
                reference.reference_origins = try self.appendSourcePath(reference.reference_origins, .{ .field = field.index });
                reference.flow_origins = try self.appendSourcePath(reference.flow_origins, .{ .field = field.index });
            }
            if (!reference.writable) reference.reference_origins = try self.readonlyOrigins(reference.reference_origins);
            return reference;
        }

        fn parameterPlaceOrigins(self: *Self, parameter: u32, storage: Value) !?u32 {
            return self.addReferenceOrigin(null, if (try self.analysis_context.facts().argumentPassing(storage.type_id) == .direct)
                .{ .cleanup_value = storage.id, .frame_type = storage.type_id, .source_kind = .place }
            else
                .{ .parameter = parameter, .source_kind = .place });
        }

        fn extendLocalReference(self: *Self, reference: ?LocalReference, fields: []const PlaceField, member: ?structures.TypeId) !?LocalReference {
            const source = reference orelse return null;
            if (fields.len == 0 and member == null) return source;
            // Reserve before slicing because appending can relocate the table.
            const old = source.projections;
            try self.borrow_fields.ensureUnusedCapacity(self.gpa, old.end - old.start + fields.len + @intFromBool(member != null));
            const start: u32 = @intCast(self.borrow_fields.items.len);
            self.borrow_fields.appendSliceAssumeCapacity(self.borrow_fields.items[old.start..old.end]);
            for (fields) |field| self.borrow_fields.appendAssumeCapacity(.{ .field = field.index });
            if (member) |type_id| self.borrow_fields.appendAssumeCapacity(.{ .variant = type_id });
            return .{ .local = source.local, .projections = .{ .start = start, .end = @intCast(self.borrow_fields.items.len) } };
        }

        fn readReference(self: *Self, reference: Value, element_type: structures.TypeId) !Value {
            try self.recordUse(reference);
            var incomplete = false;
            var origins = self.originList(try self.resolveReferenceOrigins(reference.reference_origins, &incomplete));
            var borrow_root: ?semantic.UnresolvedBody.LocalId = null;
            while (origins.next()) |origin| borrow_root = laterBorrowRoot(borrow_root, origin.root);
            var result = try self.appendInstruction(.{ .borrow_read = .{ .source = reference.id, .type_id = element_type } });
            result.borrowed_type = element_type;
            result.writable = reference.writable and !try self.originsReadonly(reference.reference_origins);
            result.place_reference = reference.id;
            result.place_origins = reference.reference_origins;
            result.flow_origins = reference.flow_origins orelse reference.reference_origins;
            if (try self.analysis_context.facts().variantMembers(element_type) != null) result.flow_origins = try self.referenceFlowOrigins(reference, element_type);
            result.borrow_root = borrow_root;
            result.local_reference = reference.local_reference;
            result.reference_origins = if (try self.analysis_context.facts().canStoreBorrow(element_type))
                try self.storedReferenceOrigins(try self.referenceContents(reference, reference.reference_origins))
            else
                try self.readReferenceOrigins(reference.reference_origins, null, @truncate(@backingInt(result.id)), false);
            result.materialize_on_copy = true;
            return result;
        }

        fn storedReferenceOrigins(self: *Self, origins: ?u32) !?u32 {
            var result: ?u32 = null;
            var current = self.originList(origins);
            while (current.next()) |origin| {
                if (origin.projection == null and origin.source_kind == .place) continue;
                result = try self.addReferenceOrigin(result, origin);
            }
            return result;
        }

        fn readReferenceOrigins(self: *Self, source_origins: ?u32, state: ?StateId, instruction: u31, deferred_capture: bool) !?u32 {
            var origins: ?u32 = null;
            var current = source_origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                current = origin.next;
                origin.deferred_capture = origin.deferred_capture or deferred_capture;
                if (origin.loop != null) {
                    try self.deferReferenceTransform(&origin, .{ .read = .{ .state = state orelse try self.captureState(), .instruction = instruction } });
                } else if (origin.projection) |projection_index| {
                    const projection = self.reference_storage.projections.keys()[projection_index];
                    if (projection.step.isElement()) origin.projection = projection.next;
                } else if (origin.stable) {
                    if (origin.root) |root| {
                        const values_at_read = if (state) |state_id| self.states.items[@backingInt(state_id)].values else self.state.values.snapshot();
                        if (@backingInt(root) < values_at_read.len) {
                            if (values_at_read.get(@backingInt(root))) |value_at_read| origin.binding_identity = if (origin.variant_guard)
                                value_at_read.variant_identity orelse value_at_read.binding_identity
                            else
                                value_at_read.binding_identity;
                        }
                    }
                    origin.stable = false;
                }
                origin.read = instruction;
                origins = try self.addReferenceOrigin(origins, origin);
            }
            return origins;
        }

        fn validateReferenceReplacement(self: *Self, element_type: structures.TypeId, span: structures.SourceSpan) !void {
            if (try referenceReplacementIssue(self.analysis_context, element_type)) |issue| return self.reject(span, issue);
        }

        fn referenceAssignment(self: *Self, assignment_ref: @FieldType(Expression.Operation, "reference_assignment")) !Value {
            var reference = try self.captureReference(assignment_ref.reference);
            if (reference.type_id == .never) return reference;
            const captured_handle = reference.id;
            const source_fields = self.unresolved.assignment_fields[assignment_ref.fields.start..assignment_ref.fields.end];
            if (source_fields.len != 0) {
                const element_type = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse
                    return self.reject(assignment_ref.reference.span, .borrow_requires_place);
                if (!reference.writable) return self.reject(assignment_ref.reference.span, .reference_not_writable);
                var fields: std.ArrayList(PlaceField) = .empty;

                try self.resolvePlaceFields(element_type, source_fields, assignment_ref.reference.span, &fields);
                reference = try self.projectReference(reference, fields.items);
            }
            return self.assignReference(reference, captured_handle, assignment_ref.value, assignment_ref.reference.span);
        }

        fn invalidateWritableReferences(self: *Self, references: []const Value, refresh: ReferenceRefresh) !void {
            for (references) |reference| {
                try self.validateInitializerReferenceWrite(reference, self.activeLifetimeSpan());
                try self.advanceOwnedReferenceOrigins(reference, reference.id, refresh);
            }
        }

        fn advanceOwnedReferenceOrigins(self: *Self, reference: Value, captured_handle: structures.FunctionValueId, fresh_result_origins: ?ReferenceRefresh) !void {
            const element_type = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse (try self.analysis_context.facts().storageAccess(reference.type_id)) orelse unreachable;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
            const refresh = if (!capabilities.needs_automatic_drop and fresh_result_origins != null and fresh_result_origins.? == .slots)
                ReferenceRefresh{ .value = fresh_result_origins.?.slots }
            else
                fresh_result_origins;
            var incomplete = false;
            const known = try self.resolveReferenceOrigins(reference.reference_origins, &incomplete);
            var refreshed = known;
            if (incomplete) try self.pending_reference_invalidations.append(self.gpa, .{
                .origins = reference.reference_origins.?,
                .known = known,
                .span = self.activeLifetimeSpan(),
            });
            var origins = self.originList(known);
            while (origins.next()) |origin| {
                if (origin.projection != null) continue;
                const root = origin.root orelse continue;
                const replaces_variant = try self.analysis_context.facts().variantMembers(element_type) != null;
                const replaces_owned_storage = capabilities.needs_automatic_drop or replaces_variant;
                const preserved_storage_depth = if (replaces_owned_storage) origin.storage_depth else std.math.maxInt(u32);
                try self.advanceReferenceRootStorage(root, captured_handle, refresh, preserved_storage_depth, !replaces_variant);
                refreshed = try self.updatedRootOrigin(refreshed, root);
            }
            if (incomplete) for (0..self.state.values.len, 0..self.state.availability.len, 0..) |flow_stored_index, flow_availability_index, local_index| {
                const stored = self.state.values.get(flow_stored_index);
                const availability = self.state.availability.get(flow_availability_index);
                if (availability == .available and stored != null and stored.?.id == captured_handle and
                    try self.analysis_context.facts().storageAccess(stored.?.type_id) != null)
                    try self.updateLocal(local_index, .{ .reference_origins = refreshed });
            };
        }

        fn advanceReferenceRoot(self: *Self, root: semantic.UnresolvedBody.LocalId, captured_handle: ?structures.FunctionValueId, fresh_result_origins: ?ReferenceRefresh) !void {
            const type_id = self.state.values.get(@backingInt(root)).?.type_id;
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            const replaces_variant = try self.analysis_context.facts().variantMembers(type_id) != null;
            const preserved_storage_depth: u32 = if (capabilities.needs_automatic_drop or replaces_variant) 0 else std.math.maxInt(u32);
            return self.advanceReferenceRootStorage(root, captured_handle, fresh_result_origins, preserved_storage_depth, !replaces_variant);
        }

        fn advanceReferenceRootStorage(self: *Self, root: semantic.UnresolvedBody.LocalId, captured_handle: ?structures.FunctionValueId, fresh_result_origins: ?ReferenceRefresh, preserved_storage_depth: u32, preserves_variant: bool) !void {
            const owner_index = @backingInt(root);
            var owner = self.state.values.get(owner_index).?;
            const previous_identity = owner.binding_identity;
            owner.storage_identity = if (owner.representation == .storage or captured_handle != null) owner.storage_identity orelse previous_identity else null;
            owner.binding_identity = try self.newBindingIdentity();
            self.binding_versions.items[owner.binding_identity.fixed] = .{ .write = .{ .previous = previous_identity, .preserved_storage_depth = preserved_storage_depth } };
            owner.variant_identity = if (preserves_variant) owner.variant_identity orelse previous_identity else owner.binding_identity;
            try self.state.values.set(self.gpa, owner_index, owner);
            for (0..self.state.values.len, 0..self.state.availability.len, 0..) |flow_other_value_index, flow_availability_index, local_index| {
                const other_value = self.state.values.get(flow_other_value_index);
                const availability = self.state.availability.get(flow_availability_index);
                if (availability != .available or other_value == null) continue;
                const current = other_value.?;
                var origins = current.reference_origins;
                const is_captured = captured_handle != null and current.id == captured_handle.? and
                    (try self.analysis_context.facts().storageAccess(current.type_id) != null or try self.analysis_context.facts().borrowElement(current.type_id) != null);
                if (is_captured or (preserved_storage_depth == std.math.maxInt(u32) and current.stable_reference_root == root and try self.hasCurrentRootOrigin(origins, root, previous_identity)))
                    origins = try self.updatedRootOrigin(origins, root);
                if (captured_handle != null)
                    origins = try self.transformReferenceOrigins(origins, .{ .refresh = .{ .root = root, .previous = previous_identity, .replacement = owner.binding_identity, .storage_replacement = owner.storage_identity, .preserved_storage_depth = preserved_storage_depth } });
                if (origins != current.reference_origins) try self.updateLocal(local_index, .{ .reference_origins = origins });
            }
            if (fresh_result_origins) |refresh| switch (refresh) {
                .value => |origins| origins.* = try self.updatedRootOrigin(origins.*, root),
                .slots => |origins| origins.* = try self.transformReferenceOrigins(origins.*, .{ .refresh = .{ .root = root, .previous = previous_identity, .replacement = owner.binding_identity, .storage_replacement = owner.storage_identity, .preserved_storage_depth = preserved_storage_depth } }),
            };
        }

        fn hasCurrentRootOrigin(self: *Self, origins: ?u32, root: semantic.UnresolvedBody.LocalId, identity: BindingIdentity) !bool {
            const actual = try self.resolveBindingIdentity(identity);
            if (actual.incomplete or actual.conflicting or actual.value == null) return false;
            var incomplete = false;
            const resolved = try self.resolveReferenceOrigins(origins, &incomplete);
            if (incomplete) return false;
            var found = false;
            var current = self.originList(resolved);
            while (current.next()) |origin| {
                if (origin.root != root) continue;
                const expected = try self.resolveBindingIdentity(origin.binding_identity);
                if (expected.incomplete or expected.conflicting or expected.value != actual.value) return false;
                found = true;
            }
            return found;
        }

        fn referenceIdentity(owner: Value, origin: ReferenceOrigin) BindingIdentity {
            if (origin.variant_guard) return owner.variant_identity orelse owner.binding_identity;
            if (origin.stable and origin.storage_depth == 0) return owner.storage_identity orelse owner.binding_identity;
            return owner.binding_identity;
        }

        fn updatedRootOrigin(self: *Self, origins: ?u32, root: semantic.UnresolvedBody.LocalId) !?u32 {
            var updated: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                if (origin.root == root) origin.binding_identity = referenceIdentity(self.state.values.get(@backingInt(root)).?, origin);
                updated = try self.addReferenceOrigin(updated, origin);
                current = origin.next;
            }
            return updated;
        }

        fn refreshInitializerOwnerOrigins(self: *Self, origins: ?u32, initializer: structures.FunctionValueId, root: semantic.UnresolvedBody.LocalId, identity: BindingIdentity) !?u32 {
            var updated: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_storage.origins.items[index];
                if (origin.root == root and origin.initializer_owner == initializer) origin.binding_identity = identity;
                updated = try self.addReferenceOrigin(updated, origin);
                current = origin.next;
            }
            return updated;
        }

        fn assignReference(self: *Self, reference: Value, captured_handle: structures.FunctionValueId, value_use: semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !Value {
            const element_type = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse
                return self.reject(span, .borrow_requires_place);
            if (!reference.writable or try self.originsReadonly(reference.reference_origins)) return self.reject(span, .reference_not_writable);
            try self.validateReferenceReplacement(element_type, value_use.span);
            const replacement_start = self.replacement_targets.items.len;
            defer self.replacement_targets.shrinkRetainingCapacity(replacement_start);
            try self.replacement_targets.append(self.gpa, .{ .reference = reference });
            const raw_value = try self.valueWithContext(value_use.value, .{ .expected_type = element_type, .access = .initialize });
            if (raw_value.type_id == .never) return raw_value;
            const use = try self.coerceValue(raw_value.id, raw_value.type_id, element_type) orelse
                return self.reject(value_use.span, .{ .assignment_type_mismatch = self.typeMismatch(element_type, raw_value.type_id) });
            const owned = try self.ownValue(raw_value, value_use.span);
            const operand = if (use.coerce_to) |_| try self.coerceOwnedRepresentation(owned, use, value_use.span, null) else owned;
            try self.reference_writes.append(self.gpa, .{ .origins = reference.reference_origins, .written_type = element_type });
            try self.invalidateFlowTypes(reference.flow_origins orelse reference.reference_origins, span);
            try self.recordConsume(operand);
            _ = try self.replaceReference(reference, reference.id, operand.id, span);
            var updated_reference = reference;
            try self.advanceOwnedReferenceOrigins(reference, captured_handle, .{ .value = &updated_reference.reference_origins });
            try self.storeReferenceContents(updated_reference, operand.reference_origins);
            return self.readReference(updated_reference, element_type);
        }

        fn replaceReference(self: *Self, reference: Value, reference_id: structures.FunctionValueId, item_id: structures.FunctionValueId, span: structures.SourceSpan) !Value {
            try self.validateInitializerReferenceWrite(reference, span);
            try self.recordUse(reference);
            const pinned = try self.appendInstruction(.{ .value_copy = .{ .source = reference_id, .type_id = reference.type_id } });
            const element_type = (try self.analysis_context.facts().borrowElement(reference.type_id)) orelse unreachable;
            var pinned_reference = reference;
            pinned_reference.id = pinned.id;
            const old_value = try self.readReference(pinned_reference, element_type);
            try self.dropValue(old_value, false, span);
            return self.appendInstruction(.{ .borrow_write = .{
                .reference = pinned.id,
                .value = item_id,
                .type_id = element_type,
            } });
        }

        fn applyCallMutArgument(self: *Self, pending: PendingMutArgument) !void {
            const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
            switch (pending.place.root) {
                .local => |local| try self.applyLocalMutArgument(local, fields, pending),
                .reference => |reference| try self.applyReferenceMutArgument(reference, fields, pending),
            }
        }

        fn applyReferenceMutArgument(self: *Self, source: Value, fields: []const PlaceField, pending: PendingMutArgument) !void {
            const root_type = (try self.analysis_context.facts().borrowElement(source.type_id)).?;
            const leaf_type = if (fields.len == 0) root_type else fields[fields.len - 1].type_id;
            var reference = source;
            if (fields.len != 0) {
                reference = try self.appendInstruction(.{ .borrow_address = .{
                    .source = source.id,
                    .type_id = try self.analysis_context.facts().referenceType(leaf_type),
                    .fields = try self.publishBorrowFields(fields),
                    .base_is_reference = true,
                } });
                reference.reference_origins = source.reference_origins;
            }
            if (try self.analysis_context.facts().canStoreBorrow(leaf_type)) {
                if (source.local_reference) |local_reference| {
                    const prefix = self.borrow_fields.items[local_reference.projections.start..local_reference.projections.end];
                    try self.mergeMutOwnerOrigins(local_reference.local, prefix, fields, pending.reference_origins);
                } else {
                    var origins = self.originList(try self.completeReferenceOrigins(reference.reference_origins));
                    while (origins.next()) |origin| {
                        if (origin.root) |owner| try self.mergeMutOwnerOrigins(owner, &.{}, &.{}, pending.reference_origins);
                    }
                }
            }
            if (pending.writes_storage) try self.advanceOwnedReferenceOrigins(reference, source.id, null);
        }

        fn applyLocalMutArgument(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, pending: PendingMutArgument) !void {
            const root = self.state.values.get(@backingInt(local)).?;
            const leaf_origins = try self.mergeReferenceOrigins(try self.fieldReferenceOrigins(root.reference_origins, fields), try self.transformReferenceOrigins(pending.reference_origins, .widen));
            var updated_root = root;
            std.debug.assert(try self.valueUsesStorage(root));
            updated_root.reference_origins = try self.fieldUpdateOrigins(root.reference_origins, fields, leaf_origins);
            if (!pending.writes_storage) {
                try self.state.values.set(self.gpa, @backingInt(local), updated_root);
                return;
            }
            var updated = try self.updateOwnedValue(root, updated_root);
            updated.binding_identity = pending.result_identity;
            updated.storage_identity = root.storage_identity orelse root.binding_identity;
            updated.variant_identity = if (fields.len == 0) pending.result_identity else root.variant_identity orelse root.binding_identity;
            try self.state.values.set(self.gpa, @backingInt(local), updated);
            try self.writeCapturedLocal(local);
        }

        fn mergeMutOwnerOrigins(self: *Self, local: semantic.UnresolvedBody.LocalId, prefix: []const structures.BorrowProjection, fields: []const PlaceField, origins: ?u32) !void {
            var owner = self.state.values.get(@backingInt(local)).?;
            if (!try self.analysis_context.facts().canStoreBorrow(owner.type_id)) return;
            var external_origins: ?u32 = null;
            var current = self.originList(origins);
            while (current.next()) |origin| {
                if (origin.root != local) external_origins = try self.addReferenceOrigin(external_origins, origin);
            }
            const prefix_origins = try self.fieldReferenceOrigins(owner.reference_origins, prefix);
            const leaf_origins = try self.mergeReferenceOrigins(
                try self.fieldReferenceOrigins(prefix_origins, fields),
                try self.transformReferenceOrigins(external_origins, .widen),
            );
            owner.reference_origins = try self.fieldUpdateOrigins(owner.reference_origins, prefix, try self.fieldUpdateOrigins(prefix_origins, fields, leaf_origins));
            try self.state.values.set(self.gpa, @backingInt(local), owner);
            try self.writeCapturedLocal(local);
        }

        fn finishCallMutOrigins(self: *Self, range: structures.FunctionValueRange) !void {
            var owners: std.ArrayList(semantic.UnresolvedBody.LocalId) = .empty;

            for (self.pending_mut_arguments.items[range.start..range.end]) |pending| {
                if (pending.reference_origins == null) continue;
                const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
                const leaf_type = try self.argumentPlaceType(pending.place.root, fields);
                switch (pending.place.root) {
                    .local => |local| try self.projectMutOwnerOrigins(local, &.{}, fields, leaf_type),
                    .reference => |reference| {
                        if (reference.local_reference) |local_reference| {
                            const prefix = self.borrow_fields.items[local_reference.projections.start..local_reference.projections.end];
                            try self.projectMutOwnerOrigins(local_reference.local, prefix, fields, leaf_type);
                            continue;
                        }
                        var origins = self.originList(try self.completeReferenceOrigins(reference.reference_origins));
                        while (origins.next()) |origin| {
                            if (origin.root) |root| if (std.mem.indexOfScalar(semantic.UnresolvedBody.LocalId, owners.items, root) == null)
                                try owners.append(self.gpa, root);
                        }
                    },
                }
            }
            for (owners.items) |local| {
                var owner = self.state.values.get(@backingInt(local)).?;
                if (try self.analysis_context.facts().canStoreBorrow(owner.type_id)) owner.reference_origins = try self.projectResultOrigins(owner.reference_origins, owner.type_id);
                try self.state.values.set(self.gpa, @backingInt(local), owner);
            }
        }

        fn projectMutOwnerOrigins(self: *Self, local: semantic.UnresolvedBody.LocalId, prefix: []const structures.BorrowProjection, fields: []const PlaceField, leaf_type: structures.TypeId) !void {
            var owner = self.state.values.get(@backingInt(local)).?;
            const prefix_origins = try self.fieldReferenceOrigins(owner.reference_origins, prefix);
            const leaf_origins = try self.projectResultOrigins(try self.fieldReferenceOrigins(prefix_origins, fields), leaf_type);
            owner.reference_origins = try self.fieldUpdateOrigins(owner.reference_origins, prefix, try self.fieldUpdateOrigins(prefix_origins, fields, leaf_origins));
            try self.state.values.set(self.gpa, @backingInt(local), owner);
        }

        fn mutReturnOrigins(self: *Self, range: structures.FunctionValueRange) !?u32 {
            var origins: ?u32 = null;
            for (self.pending_mut_arguments.items[range.start..range.end]) |pending| {
                if (!pending.return_origin) continue;
                origins = try self.mergeReferenceOrigins(origins, try self.placeStorageOrigins(pending.place.root, &.{}));
                const contents = switch (pending.place.root) {
                    .reference => |reference| try self.referenceContents(reference, null),
                    .local => |local| self.borrowLocalValue(local).reference_origins,
                };
                const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
                origins = try self.mergeReferenceOrigins(origins, try self.fieldReferenceOrigins(contents, fields));
            }
            return origins;
        }

        fn recordCallArgumentConsumes(self: *Self, range: structures.FunctionValueRange) !void {
            for (self.pending_consumed_arguments.items[range.start..range.end]) |argument| try self.recordConsume(argument);
        }

        fn updateOwnedValue(self: *Self, previous: Value, updated: Value) !Value {
            var result = withoutOwnershipSource(updated);
            result.flow_origins = previous.flow_origins;
            result.owned_generation = previous.owned_generation;
            if (result.owned_generation) |generation| try self.recordEffect(.{ .update = .{
                .generation = generation,
                .cleanup_value = result.id,
            } });
            try self.captureCleanupOrigins(result);
            std.debug.assert(result.owned_generation == previous.owned_generation);
            return result;
        }

        fn updateFields(self: *Self, root: Value, fields: []const PlaceField, updated_leaf: Value) !Value {
            if (fields.len == 0) {
                if (root.representation == .storage) {
                    _ = try self.copyBits(updated_leaf, rawValue(root));
                    return root;
                }
                return updated_leaf;
            }
            // Direct values retain SSA snapshots; address-passed owners retain their storage.
            var updated = if (try self.valueUsesStorage(root)) root else try self.copyBits(root, try self.localStorage(root.type_id));
            _ = try self.copyBits(updated_leaf, try self.fieldStorage(rawValue(updated), fields));
            updated.reference_origins = try self.fieldUpdateOrigins(root.reference_origins, fields, updated_leaf.reference_origins);
            return updated;
        }

        fn predicateValue(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan) !Value {
            const baseline = try self.captureAvailability();
            const flow = try self.condition(id);
            var exits: std.ArrayList(FlowExit) = .empty;
            for ([_]?FlowExit{ flow.matched, flow.unmatched }, [_]bool{ true, false }) |maybe_exit, truth| {
                if (maybe_exit) |exit| {
                    try self.enterFlowExit(exit);
                    const result = try self.appendInstruction(.{ .const_bool = truth });
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    try exits.append(self.gpa, (try self.valueExit(result)).?);
                }
            }
            if (exits.items.len == 0) return flow.diverged orelse .{ .id = @fromBackingInt(0), .type_id = .never };
            const joined = try self.mergeScopedExits(baseline, exits.items, .{ .value = .{ .expected_type = .bool } }, .condition);
            try self.enterFlowExit(joined);
            _ = span;
            var result = joined.constructed.?;
            if (self.flow) |data| if (flow.matched != null and flow.unmatched != null) {
                const matched = self.states.items[@backingInt(flow.matched.?.state)].refinements.snapshot();
                const unmatched = self.states.items[@backingInt(flow.unmatched.?.state)].refinements.snapshot();
                if (!matched.eql(unmatched)) {
                    result.predicate = @intCast(data.predicates.items.len);
                    try data.predicates.append(self.gpa, .{ .matched = matched, .unmatched = unmatched });
                }
            };
            return result;
        }

        fn condition(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!ConditionFlow {
            if (self.values.get(@backingInt(id))) |value_to_test| return self.booleanCondition(value_to_test, self.valueSpan(id), false);
            const expression = self.expressionOperation(id) orelse return self.booleanCondition(try self.value(id), self.valueSpan(id), false);
            switch (expression.*) {
                .static_membership => |membership| return self.staticMembershipCondition(membership),
                .variant_membership => |membership| return self.variantMembershipCondition(membership),
                .iterator_membership => |membership| return self.variantMembershipCondition(.{
                    .operand = membership.operand,
                    .target_type = try self.iteratorItemType(membership.operand, membership.end_type),
                }),
                .conjunction => |logical| return self.conjunctionCondition(logical),
                .disjunction => |logical| return self.disjunctionCondition(logical),
                .negation => |operand| return self.negatedCondition(operand),
                .pattern_test => |binding| return self.patternCondition(binding),
                else => return self.booleanCondition(try self.valueWithContext(id, .{ .access = .initialize }), self.valueSpan(id), false),
            }
        }

        fn booleanCondition(self: *Self, operand: Value, span: structures.SourceSpan, invert: bool) !ConditionFlow {
            if (operand.type_id == .never) return .{ .matched = null, .unmatched = null, .diverged = operand };
            if (operand.type_id != .bool) return self.reject(span, .{ .condition_not_bool = operand.type_id });
            try self.recordUse(operand);
            const expected = try self.appendInstruction(.{ .const_bool = !invert });
            var flow = try self.predicateFlow(.eqb, operand.id, expected.id);
            if (operand.predicate) |id| {
                const proof = self.flow.?.predicates.items[id];
                for ([_]*?FlowExit{ &flow.matched, &flow.unmatched }, [_]flow_types.State{
                    if (invert) proof.unmatched else proof.matched,
                    if (invert) proof.matched else proof.unmatched,
                }) |exit, facts| {
                    self.restoreState(exit.*.?.state);
                    for (0..facts.len) |place| {
                        const selected = self.flow.?.facts.get(facts, place);
                        const current = self.flow.?.facts.get(self.state.refinements, place);
                        if (selected.type_id != null and selected.version == current.version)
                            try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, selected);
                    }
                    exit.*.?.state = try self.captureState();
                }
            }
            return flow;
        }

        fn predicateFlow(self: *Self, operation: structures.PredicateOperation, lhs: structures.FunctionValueId, rhs: structures.FunctionValueId) !ConditionFlow {
            const matched = try self.newEmptyBlock();
            const unmatched = try self.newEmptyBlock();
            try self.moveCurrentBoundaryEffectsToTerminator();
            self.branchOn(operation, lhs, rhs, matched, unmatched);
            const state = try self.captureState();
            return .{ .matched = .{ .block = matched, .state = state }, .unmatched = .{ .block = unmatched, .state = state } };
        }

        fn patternCondition(self: *Self, binding: semantic.UnresolvedBody.PatternBinding) !ConditionFlow {
            var scope: PatternScope = .{ .baseline = try self.captureAvailability() };
            const parent = self.pattern_scope;
            self.pattern_scope = &scope;
            defer self.pattern_scope = parent;
            try self.bindPatternStatement(binding);
            var flow = if (self.current_block == null) ConditionFlow{ .matched = null, .unmatched = null } else try self.knownCondition(true);
            if (scope.exits.items.len != 0) flow.unmatched = try self.mergeScopedExits(scope.baseline, scope.exits.items, null, .condition);
            return flow;
        }

        fn staticMembershipCondition(self: *Self, membership: @FieldType(Expression.Operation, "static_membership")) !ConditionFlow {
            const matches = (try self.analysis_context.evaluateWhereMembership(membership.operand, membership.target_type)) orelse return error.Unavailable;
            return self.knownCondition(matches);
        }

        fn knownCondition(self: *Self, matches: bool) !ConditionFlow {
            const next = try self.newEmptyBlock();
            try self.moveCurrentBoundaryEffectsToTerminator();
            self.terminate(.{ .branch = self.emptyBranch(next) });
            const exit: FlowExit = .{ .block = next, .state = try self.captureState() };
            return if (matches) .{ .matched = exit, .unmatched = null } else .{ .matched = null, .unmatched = exit };
        }

        fn comparisonValue(self: *Self, comparison: @FieldType(Expression.Operation, "comparison"), span: structures.SourceSpan) !Value {
            const literal_operands = self.options.allow_type_values and
                ((try self.unevaluatedType(comparison.operands.lhs.value, null)) == .int_literal or
                    (try self.unevaluatedType(comparison.operands.rhs.value, null)) == .int_literal);
            const context: ValueContext = .{ .expected_type = if (literal_operands) .int_literal else null };
            const known_type = try self.unevaluatedType(comparison.operands.lhs.value, context.expected_type);
            const operation = comparison.operation;
            if (known_type != null and (known_type.? == .int or known_type.? == .bool or !known_type.?.isPrimitive())) {
                const call: semantic.UnresolvedBody.Call = .{
                    .target = .{ .operation = operation },
                    .arguments = .{ .start = 0, .end = 0 },
                    .span = span,
                };
                switch (try self.resolveCall(call, span, &.{ comparison.operands.lhs, comparison.operands.rhs })) {
                    .diverged => |value_to_return| return value_to_return,
                    .callable => |callable| return self.resolvedCallValue(callable, call, span, null),
                }
            }
            const lhs = try self.borrowValue(try self.valueWithContext(comparison.operands.lhs.value, context), comparison.operands.lhs.span);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.borrowValue(try self.valueWithContext(comparison.operands.rhs.value, context), comparison.operands.rhs.span);
            if (rhs.type_id == .never) return rhs;
            try self.recordUse(lhs);
            const predicate: structures.PredicateOperation = switch (comparison.operation) {
                .@"<", .@">", .@"<=", .@">=" => blk: {
                    if (lhs.type_id != .int and lhs.type_id != .int_literal) return self.reject(comparison.operands.lhs.span, .{ .comparison_operand_not_int = lhs.type_id });
                    if (rhs.type_id != .int and rhs.type_id != .int_literal) return self.reject(comparison.operands.rhs.span, .{ .comparison_operand_not_int = rhs.type_id });
                    break :blk primitivePredicateOperation(operation, .int);
                },
                .@"==", .@"<>" => blk: {
                    if (lhs.type_id != .int and lhs.type_id != .int_literal and lhs.type_id != .bool and lhs.type_id != .type)
                        return self.reject(comparison.operands.lhs.span, .{ .equality_operand_not_supported = lhs.type_id });
                    const integers = (lhs.type_id == .int or lhs.type_id == .int_literal) and (rhs.type_id == .int or rhs.type_id == .int_literal);
                    if (rhs.type_id != lhs.type_id and !integers)
                        return self.reject(comparison.operands.rhs.span, .{ .equality_operand_type_mismatch = self.typeMismatch(lhs.type_id, rhs.type_id) });
                    if (lhs.type_id == .type) break :blk if (comparison.operation == .@"==") .eqt else .net;
                    break :blk primitivePredicateOperation(operation, lhs.type_id);
                },
                else => unreachable,
            };
            return self.appendInstruction(.{ .compare = .{ .operation = predicate, .operands = .{ .lhs = lhs.id, .rhs = rhs.id } } });
        }

        fn variantMembershipCondition(self: *Self, membership: @FieldType(Expression.Operation, "variant_membership")) !ConditionFlow {
            var operand = try self.valueWithContext(membership.operand.value, .{ .access = .initialize, .refine = false });
            if (operand.type_id == .never) return .{ .matched = null, .unmatched = null, .diverged = operand };
            var target = membership.target_type;
            if (try self.analysis_context.facts().borrowElement(operand.type_id)) |element| {
                operand = try self.readReference(operand, element);
                target = (try self.analysis_context.facts().borrowElement(target)) orelse target;
            }
            operand = try self.borrowValue(operand, membership.operand.span);
            const source_members = try self.matchInputMembers(operand.type_id);
            const target_members = try self.analysis_context.facts().variantMembers(target);
            const matching = try self.countMembers(source_members, target, target_members);
            if (matching == 0) return self.knownCondition(false);
            if (matching == source_members.len) {
                try self.refineFlowType(operand, target, true, membership.operand.span);
                return self.knownCondition(true);
            }
            const matched = try self.newEmptyBlock();
            const unmatched = try self.newEmptyBlock();
            try self.moveCurrentBoundaryEffectsToTerminator();
            try self.branchOnMembers(operand, source_members, target, target_members, matched, unmatched);
            const state = try self.captureState();
            try self.refineFlowType(operand, target, true, membership.operand.span);
            const selected = try self.captureState();
            self.restoreState(state);
            try self.refineFlowType(operand, target, false, membership.operand.span);
            const rejected = try self.captureState();
            self.restoreState(state);
            return .{
                .matched = .{ .block = matched, .state = selected },
                .unmatched = .{ .block = unmatched, .state = rejected },
            };
        }

        fn iteratorItemType(self: *Self, operand: semantic.UnresolvedBody.ValueUse, end_type: structures.TypeId) !structures.TypeId {
            const source_type = try self.iteratorCarrierType(operand);
            if (source_type == .never) return .never;
            const members = try self.analysis_context.facts().variantMembers(source_type) orelse
                return self.reject(operand.span, .{ .iterator_result_requires_end = self.typeMismatch(end_type, source_type) });
            var target: structures.TypeId = .never;
            var found_end = false;
            for (members) |member| {
                const specification = try self.analysis_context.facts().memberSpec(member);
                if (specification.type_id == end_type) {
                    if (specification.kind != .owned)
                        return self.reject(operand.span, .{ .iterator_result_requires_end = self.typeMismatch(end_type, source_type) });
                    found_end = true;
                    continue;
                }
                target = try joinTypes(self.analysis_context, target, specification.type_id, self.gpa);
            }
            if (!found_end) return self.reject(operand.span, .{ .iterator_result_requires_end = self.typeMismatch(end_type, source_type) });
            return target;
        }

        fn iteratorItem(self: *Self, item: @FieldType(Expression.Operation, "iterator_item")) !Value {
            const target_type = try self.iteratorItemType(item.operand, item.end_type);
            const source_type = try self.iteratorCarrierType(item.operand);
            const members = (try self.analysis_context.facts().variantMembers(source_type)).?;
            var all_reference = true;
            var stored_type: structures.TypeId = .never;
            var item_count: usize = 0;
            for (members) |member| {
                const specification = try self.analysis_context.facts().memberSpec(member);
                if (specification.type_id == item.end_type) continue;
                if (specification.kind == .owned) all_reference = false;
                stored_type = try joinTypes(self.analysis_context, stored_type, member, self.gpa);
                item_count += 1;
            }
            const whole_reference = self.locals.items(.reference)[@backingInt(item.carrier)];
            if (item.binding.mode == .inferred and !whole_reference and item_count > 1) {
                const operand = try self.takeIteratorCarrier(item.carrier, item.operand.span);
                return self.extractLogicalBinding(operand, source_type, stored_type, .inferred, item.binding.span);
            }
            if (item.binding.mode == .reference or ((all_reference or whole_reference) and (item.binding.mode == .inferred or item_count == 1))) {
                const reference = try self.captureReference(item.operand);
                const extracted = try self.extractReferenceBinding(.{
                    .binding = item.binding,
                    .operand = reference,
                    .target_type = try self.analysis_context.facts().referenceType(target_type),
                }, item.binding.span);
                return self.readReference(extracted, target_type);
            }
            const operand = if (whole_reference)
                try self.valueWithContext(item.operand.value, .{ .access = .initialize })
            else
                try self.takeIteratorCarrier(item.carrier, item.operand.span);
            return self.extractVariantBinding(.{ .binding = item.binding, .operand = operand, .target_type = target_type }, item.binding.span);
        }

        fn iteratorCarrierType(self: *Self, operand: semantic.UnresolvedBody.ValueUse) !structures.TypeId {
            const operation = self.expressionOperation(operand.value).?;
            std.debug.assert(operation.* == .local_read);
            // The iterator contract describes the retained poll carrier, before
            // the successful edge selects its item alternative.
            return (try self.readLocal(operation.local_read, operand.span)).type_id;
        }

        fn takeIteratorCarrier(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !Value {
            std.debug.assert(!self.locals.items(.reference)[@backingInt(local)]);
            try self.validateInitializerWrite(local, span);
            const operand = try self.readLocal(local, span);
            try self.state.availability.set(self.gpa, @backingInt(local), .transferred);
            return ownershipSource(operand);
        }

        fn countMembers(self: *Self, members: []const structures.TypeId, target: structures.TypeId, target_members: ?[]const structures.TypeId) !usize {
            var count: usize = 0;
            for (members) |member| {
                if (includesType(target, target_members, (try self.analysis_context.facts().memberSpec(member)).type_id)) count += 1;
            }
            return count;
        }

        /// Branches on the variant tag to `matched` for members whose logical type `target` includes.
        fn branchOnMembers(
            self: *Self,
            variant: Value,
            members: []const structures.TypeId,
            target: structures.TypeId,
            target_members: ?[]const structures.TypeId,
            matched: structures.FunctionBlockId,
            unmatched: structures.FunctionBlockId,
        ) !void {
            try self.moveCurrentBoundaryEffectsToTerminator();
            var remaining = try self.countMembers(members, target, target_members);
            if (remaining == 0 or remaining == members.len)
                return self.terminate(.{ .branch = self.emptyBranch(if (remaining == 0) unmatched else matched) });
            const tag = try self.appendInstruction(.{ .variant_tag = variant.id });
            for (members, 0..) |member, member_index| {
                if (!includesType(target, target_members, (try self.analysis_context.facts().memberSpec(member)).type_id)) continue;
                remaining -= 1;
                const next_failure = if (remaining == 0) unmatched else try self.newEmptyBlock();
                const expected = try self.appendInstruction(.{ .const_int = @intCast(member_index) });
                self.branchOn(.eqi, tag.id, expected.id, matched, next_failure);
                if (remaining != 0) self.enterBlock(next_failure);
            }
        }

        fn extractReferenceBinding(self: *Self, extraction: PendingExtraction, span: structures.SourceSpan) !Value {
            const source = (try self.analysis_context.facts().borrowElement(extraction.operand.type_id)) orelse unreachable;
            const target = (try self.analysis_context.facts().borrowElement(extraction.target_type)) orelse unreachable;
            if (source != target) return self.extractLogicalBinding(extraction.operand, source, target, .reference, span);
            var result = try self.appendInstruction(.{ .borrow_address = .{ .source = extraction.operand.id, .type_id = extraction.target_type, .base_is_reference = true } });
            result.reference_origins = extraction.operand.reference_origins;
            result.writable = extraction.operand.writable;
            result.stable_reference_root = extraction.operand.stable_reference_root;
            result.local_reference = extraction.operand.local_reference;
            return result;
        }

        fn extractLogicalBinding(self: *Self, carrier: Value, source: structures.TypeId, target: structures.TypeId, kind: semantic.UnresolvedBody.BindingMode, span: structures.SourceSpan) anyerror!Value {
            const operand = if (kind == .reference and try self.analysis_context.facts().borrowElement(carrier.type_id) != null)
                try self.readReference(carrier, source)
            else
                carrier;
            const members = (try self.analysis_context.facts().variantMembers(source)).?;
            var matching: std.ArrayList(structures.TypeId) = .empty;
            const target_members = if (kind != .reference) try self.analysis_context.facts().variantMembers(target) else null;
            for (members) |member| {
                const logical_type = (try self.analysis_context.facts().memberSpec(member)).type_id;
                const selected_type = if (kind == .inferred) member else logical_type;
                if (selected_type == target or (kind != .reference and includesType(target, target_members, selected_type)))
                    try matching.append(self.gpa, member);
            }
            if (kind == .reference and matching.items.len == 0 and try self.analysis_context.facts().variantMembers(target) != null)
                return self.reject(span, .reference_projection_requires_member);
            std.debug.assert(matching.items.len != 0);
            if (matching.items.len == 1) return self.extractLogicalMember(carrier, operand, matching.items[0], target, kind, span);
            const baseline = try self.captureState();
            const tag = try self.appendInstruction(.{ .variant_tag = operand.id });
            try self.moveCurrentBoundaryEffectsToTerminator();
            var exits: std.ArrayList(FlowExit) = .empty;

            for (matching.items, 0..) |member, index| {
                const member_index = std.mem.indexOfScalar(structures.TypeId, members, member).?;
                const next = try self.enterVariantCase(tag, member_index, index + 1 == matching.items.len);
                const selected = try self.extractLogicalMember(carrier, operand, member, target, kind, span);
                try self.moveCurrentBoundaryEffectsToTerminator();
                try exits.append(self.gpa, (try self.valueExit(selected)).?);
                if (next) |unmatched| {
                    self.enterBlock(unmatched);
                    self.restoreState(baseline);
                }
            }
            const joined = try self.mergeExits(baseline, exits.items, .{ .value = .{ .expected_type = if (kind == .reference) try self.analysis_context.facts().referenceType(target) else target } }, .condition);
            try self.enterFlowExit(joined);
            return joined.constructed.?;
        }

        fn extractLogicalMember(self: *Self, carrier: Value, operand: Value, member: structures.TypeId, target: structures.TypeId, kind: semantic.UnresolvedBody.BindingMode, span: structures.SourceSpan) !Value {
            if (kind == .reference) return self.extractReferenceMember(carrier, operand, member, target);
            const specification = try self.analysis_context.facts().memberSpec(member);
            const owned = if (kind == .inferred or specification.kind == .owned) selected: {
                break :selected try self.extractOwnedVariant(carrier, if (kind == .inferred) member else specification.type_id, span);
            } else selected: {
                const reference = try self.extractReferenceMember(carrier, operand, member, specification.type_id);
                const borrowed = try self.readReference(reference, specification.type_id);
                const copied = try self.ownValue(borrowed, span);
                if (carrier.borrowed_type == null) try self.recordConsume(carrier);
                break :selected copied;
            };
            if (owned.type_id == target) return owned;
            const use = (try self.coerceValue(owned.id, owned.type_id, target)).?;
            return self.coerceOwnedRepresentation(owned, use, span, if (try self.usesIndirectStorage(target)) try self.localStorage(target) else null);
        }

        fn variantPlaceOrigins(self: *Self, origins: ?u32, member: structures.TypeId) !?u32 {
            var result: ?u32 = null;
            var current = self.originList(try self.appendSourcePath(origins, .{ .variant = member }));
            while (current.next()) |original| {
                var origin = original;
                origin.variant_guard = true;
                origin.stable = true;
                if (origin.root) |root| {
                    const owner = self.state.values.get(@backingInt(root)).?;
                    origin.binding_identity = owner.variant_identity orelse owner.binding_identity;
                }
                result = try self.addReferenceOrigin(result, origin);
            }
            return result;
        }

        fn extractReferenceMember(self: *Self, carrier: Value, operand: Value, member: structures.TypeId, target: structures.TypeId) !Value {
            const specification = try self.analysis_context.facts().memberSpec(member);
            if (specification.kind == .reference) {
                try self.recordUse(operand);
                var reference = try self.appendInstruction(.{ .variant_extract = .{ .operand = operand.id, .target_type = member } });
                reference.reference_origins = try self.transformReferenceOrigins(operand.reference_origins, .{ .select = .{ .variant = member } });
                reference.writable = !try self.originsReadonly(reference.reference_origins);
                reference.flow_origins = reference.reference_origins;
                return reference;
            }
            const start: u32 = @intCast(self.borrow_fields.items.len);
            try self.borrow_fields.append(self.gpa, .{ .variant = member });
            var result = if (try self.analysis_context.facts().borrowElement(carrier.type_id) != null)
                try self.appendInstruction(.{ .borrow_address = .{
                    .source = carrier.id,
                    .type_id = try self.analysis_context.facts().referenceType(target),
                    .fields = .{ .start = start, .end = start + 1 },
                    .base_is_reference = true,
                } })
            else result: {
                const payload = try self.projectStorage(operand, target, .variant);
                break :result try self.appendInstruction(.{ .borrow_address = .{ .source = payload.id, .type_id = try self.analysis_context.facts().referenceType(target) } });
            };
            result.reference_origins = try self.variantPlaceOrigins(try self.readReferenceOrigins(carrier.reference_origins, null, @truncate(@backingInt(result.id)), false), member);
            result.writable = carrier.writable;
            result.flow_origins = try self.appendSourcePath(carrier.flow_origins orelse carrier.reference_origins, .{ .variant = member });
            result.local_reference = try self.extendLocalReference(carrier.local_reference, &.{}, member);
            return result;
        }

        fn conjunctionCondition(
            self: *Self,
            logical: @FieldType(Expression.Operation, "conjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            const rhs = if (lhs.matched) |matched| blk: {
                try self.enterFlowExit(matched);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .matched = null, .unmatched = null };
            return .{
                .matched = rhs.matched,
                .unmatched = try self.mergeFlowExits(lhs.unmatched, rhs.unmatched),
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn disjunctionCondition(
            self: *Self,
            logical: @FieldType(Expression.Operation, "disjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            const rhs = if (lhs.unmatched) |unmatched| blk: {
                try self.enterFlowExit(unmatched);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .matched = null, .unmatched = null };
            return .{
                .matched = try self.mergeFlowExits(lhs.matched, rhs.matched),
                .unmatched = rhs.unmatched,
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn negatedCondition(self: *Self, operand: semantic.UnresolvedBody.ValueId) !ConditionFlow {
            const flow = try self.condition(operand);
            return .{ .matched = flow.unmatched, .unmatched = flow.matched, .diverged = flow.diverged };
        }

        fn enterFlowExit(self: *Self, exit: FlowExit) !void {
            self.enterPendingBlock(exit.block);
            self.restoreState(exit.state);
            if (self.flow == null) return;
            const scope = try self.openBoundary(self.activeLifetimeSpan());
            defer self.current_boundary = scope.parent;
            try self.refineFlowOwners();
            try self.closeBoundary(scope.boundary);
        }

        fn extractVariantBinding(self: *Self, extraction: PendingExtraction, span: structures.SourceSpan) !Value {
            if (extraction.binding.mode == .inferred) return self.extractInferredVariantBinding(extraction, span);
            if (extraction.binding.mode == .reference) {
                var reference = extraction;
                reference.target_type = try self.analysis_context.facts().referenceType(extraction.target_type);
                return self.extractLogicalBinding(reference.operand, extraction.operand.type_id, extraction.target_type, .reference, span);
            }
            const members = (try self.analysis_context.facts().variantMembers(extraction.operand.type_id)) orelse return self.ownValue(extraction.operand, span);
            const target_members = try self.analysis_context.facts().variantMembers(extraction.target_type);
            for (members) |member| {
                const specification = try self.analysis_context.facts().memberSpec(member);
                if (specification.kind == .reference and includesType(extraction.target_type, target_members, specification.type_id))
                    return self.extractLogicalBinding(extraction.operand, extraction.operand.type_id, extraction.target_type, .owned, span);
            }
            return self.extractOwnedVariant(extraction.operand, extraction.target_type, span);
        }

        fn extractInferredVariantBinding(self: *Self, extraction: PendingExtraction, span: structures.SourceSpan) !Value {
            var selected = extraction;
            if (extraction.operand.borrowed_type != null) {
                selected.target_type = try self.analysis_context.facts().referenceType(extraction.target_type);
                return self.extractLogicalBinding(selected.operand, extraction.operand.type_id, extraction.target_type, .reference, span);
            }
            const members = (try self.analysis_context.facts().variantMembers(extraction.operand.type_id)).?;
            const targets = try self.analysis_context.facts().variantMembers(extraction.target_type);
            var storage_type: structures.TypeId = .never;
            for (members) |member| {
                const specification = try self.analysis_context.facts().memberSpec(member);
                if (includesType(extraction.target_type, targets, specification.type_id))
                    storage_type = try joinTypes(self.analysis_context, storage_type, member, self.gpa);
            }
            selected.target_type = storage_type;
            return self.extractLogicalBinding(selected.operand, extraction.operand.type_id, storage_type, .inferred, span);
        }

        fn extractOwnedVariant(self: *Self, operand: Value, target_type: structures.TypeId, span: structures.SourceSpan) !Value {
            const in_place = target_type != .never and try self.usesIndirectStorage(target_type);
            if (in_place and try self.analysis_context.facts().variantMembers(target_type) != null) {
                if (operand.borrowed_type == null) {
                    const capabilities = (try self.analysis_context.facts().ownershipCapabilities(target_type)) orelse return error.Unavailable;
                    if (capabilities.move == .none) return self.reject(span, .{ .type_not_movable = target_type });
                    return self.moveValue(operand, span, try self.localStorage(target_type));
                }
                var narrowed = operand;
                narrowed.borrowed_type = target_type;
                if (try self.nonCopyableBorrow(narrowed)) |details| return self.reject(span, .{ .type_not_copyable = details });
                return self.copyValue(operand, span, try self.localStorage(target_type));
            }
            var extracted = if (in_place) try self.projectStorage(operand, target_type, .variant) else try self.appendInstruction(.{ .variant_extract = .{
                .operand = operand.id,
                .target_type = target_type,
                .tag_mapping = try self.appendExtractionTagMapping(operand.type_id, target_type),
            } });
            if (target_type == .never) return extracted;
            if (try self.analysis_context.facts().canStoreBorrow(target_type)) {
                extracted.reference_origins = if (try self.analysis_context.facts().variantMembers(target_type) != null)
                    operand.reference_origins
                else
                    try self.transformReferenceOrigins(operand.reference_origins, .{ .select = .{ .variant = target_type } });
            }
            if (operand.borrowed_type == null) {
                // The selected payload takes over ownership at its current
                // address. Consuming the variant suppresses its whole-value
                // cleanup on this edge; the unmatched edge retains that cleanup.
                try self.recordConsume(operand);
                return self.defineOwnedValue(extracted, span, false);
            }
            extracted.borrowed_type = target_type;
            extracted.borrowed_generation = operand.borrowed_generation orelse operand.owned_generation;
            extracted.borrowed_cleanup_value = operand.borrowed_cleanup_value orelse operand.id;
            return self.ownValue(extracted, span);
        }

        fn mergeFlowExits(self: *Self, first_exit: ?FlowExit, second_exit: ?FlowExit) !?FlowExit {
            const first = first_exit orelse return second_exit;
            const second = second_exit orelse return first;
            var exits = [_]FlowExit{ first, second };
            return try self.mergeExits(first.state, &exits, null, .condition);
        }
        const JoinPolicy = enum { condition, branch, loop };

        fn mergeExits(self: *Self, baseline: StateId, exits: []FlowExit, mode: ?ResultRequest, policy: JoinPolicy) !FlowExit {
            if (exits.len == 0) {
                const argument_start: u32 = @intCast(self.block_arguments.items.len);
                _ = try self.appendBlockArgument(.never, null);
                const block_id = try self.newBlock(argument_start, argument_start + 1);
                return .{ .block = block_id, .state = baseline, .constructed = .{ .id = @fromBackingInt(argument_start), .type_id = .never } };
            }
            return self.mergeScopedExits(self.states.items[@backingInt(baseline)].availability, exits, mode, policy);
        }

        fn mergeScopedExits(self: *Self, baseline: StateAvailability, exits: []FlowExit, mode: ?ResultRequest, policy: JoinPolicy) !FlowExit {
            std.debug.assert(exits.len != 0);
            if (exits.len == 1 and policy != .loop and self.canReuseExit(baseline, exits[0], mode)) {
                return exits[0];
            }
            const span = self.activeLifetimeSpan();
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            try self.normalizeJoinFields(exits, policy);
            const incoming = try self.gpa.alloc(?GenerationId, exits.len);
            const destination = if (mode) |request| if (request.destination) |target| target.storage else null else null;
            var result: ?Value = null;
            var borrow_argument: ?u32 = null;
            var completion_argument: ?u32 = null;
            if (mode != null) {
                var joined_type = if (destination) |storage| storage.type_id else exits[0].constructed.?.type_id;
                if (destination == null) for (exits[1..]) |exit| {
                    joined_type = try joinTypes(self.analysis_context, joined_type, exit.constructed.?.type_id, self.gpa);
                };
                var joined: Value = .{ .representation = exits[0].constructed.?.representation, .id = if (destination) |storage| storage.id else @fromBackingInt(argument_start), .type_id = joined_type, .stable_reference_root = exits[0].constructed.?.stable_reference_root };
                var any_borrowed = false;
                var all_borrowed = true;
                var conditional_borrow = false;
                var needs_completion = false;
                var borrowed_generation: ??GenerationId = null;
                var borrowed_cleanup: ??structures.FunctionValueId = null;
                for (exits, incoming) |exit, *generation| {
                    const value_on_edge = exit.constructed.?;
                    generation.* = value_on_edge.owned_generation;
                    joined.preserves_storage = joined.preserves_storage or value_on_edge.preserves_storage;
                    joined.explicit_transfer = joined.explicit_transfer or value_on_edge.explicit_transfer;
                    const edge_use = (try self.coerceValue(value_on_edge.id, value_on_edge.type_id, joined_type)).?;
                    joined.reference_origins = try self.mergeReferenceOrigins(joined.reference_origins, try self.coercedReferenceOrigins(value_on_edge, edge_use));
                    joined.place_origins = try self.mergeReferenceOrigins(joined.place_origins, value_on_edge.place_origins);
                    joined.stable_reference_root = sharedStableReferenceRoot(joined.stable_reference_root, value_on_edge.stable_reference_root);
                    joined.pending_consumption_owners = try self.mergePendingConsumptionOwners(joined.pending_consumption_owners, value_on_edge.pending_consumption_owners);
                    any_borrowed = any_borrowed or hasNonowningPath(value_on_edge);
                    all_borrowed = all_borrowed and hasNonowningPath(value_on_edge);
                    conditional_borrow = conditional_borrow or value_on_edge.borrow_condition != null;
                    needs_completion = needs_completion or value_on_edge.consumption_completion != null;
                    if (value_on_edge.borrowed_type) |source_type| {
                        joinBorrowedFact(GenerationId, &borrowed_generation, value_on_edge.borrowed_generation, policy == .loop);
                        joinBorrowedFact(structures.FunctionValueId, &borrowed_cleanup, value_on_edge.borrowed_cleanup_value, policy == .loop);
                        if (joined.borrowed_type) |previous| {
                            if (previous != source_type) joined.borrowed_type = joined_type;
                        } else joined.borrowed_type = source_type;
                        joined.borrow_root = laterBorrowRoot(joined.borrow_root, value_on_edge.borrow_root);
                    }
                }
                for (exits) |exit| {
                    const value_on_edge = exit.constructed.?;
                    if (value_on_edge.type_id != joined_type or value_on_edge.representation != joined.representation)
                        joined.representation = .value;
                    if (destination == null and !self.type_check_only and try self.usesIndirectStorage(joined_type) and value_on_edge.type_id != joined_type)
                        return self.reject(span, .{ .relocation_requires_direct_move = value_on_edge.type_id });
                    if (joined.preserves_storage and value_on_edge.type_id != joined_type)
                        return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(joined_type, value_on_edge.type_id) });
                }
                joined.owned_generation = try self.joinResultGenerations(joined_type, span, incoming);
                joined.borrowed_generation = borrowed_generation orelse null;
                joined.borrowed_cleanup_value = borrowed_cleanup orelse null;
                if (destination == null) {
                    const argument = try self.appendBlockArgument(joined_type, joined.owned_generation);
                    self.block_arguments.items[argument].representation = if (joined.preserves_storage) .storage else joined.representation;
                }
                if (any_borrowed and (conditional_borrow or !all_borrowed)) {
                    borrow_argument = try self.appendBlockArgument(.bool, null);
                    joined.borrow_condition = @fromBackingInt(borrow_argument.?);
                }
                if (needs_completion) {
                    completion_argument = try self.appendBlockArgument(.bool, null);
                    self.block_arguments.items[completion_argument.?].representation = .storage;
                    joined.consumption_completion = @fromBackingInt(completion_argument.?);
                }
                result = self.withCleanupCondition(joined);
            }

            var state = self.states.items[@backingInt(exits[0].state)].snapshot();
            for (exits[1..]) |exit| {
                const other = self.states.items[@backingInt(exit.state)];
                try state.joinFlow(self.gpa, other);
                try self.mergeFlowTypes(&state, other);
            }
            try state.availability.merge(self.gpa, baseline, struct {
                fn mask(current: Availability, initial: Availability) Availability {
                    return if (initial == .unbound) .unbound else current;
                }
            }.mask);
            var changed_slots: std.ArrayList(u32) = .empty;
            var generation_only: std.ArrayList(GenerationOnlyJoin) = .empty;

            const state_argument_start: u32 = @intCast(self.block_arguments.items.len);
            var slot: usize = 0;
            while (slot < state.values.len) : (slot += 1) {
                const shared_end = self.sharedJoinPageEnd(state, exits, slot);
                if (shared_end != slot) {
                    slot = shared_end - 1;
                    continue;
                }
                if (state.availability.get(slot) == .unbound) {
                    try state.values.set(self.gpa, slot, null);
                    continue;
                }
                if (state.values.get(slot) == null) continue;
                var output = self.states.items[@backingInt(exits[0].state)].values.get(slot).?;
                var changed = false;
                const original_identity = output.binding_identity;
                for (exits, incoming, 0..) |exit, *generation, index| {
                    const incoming_state = self.states.items[@backingInt(exit.state)];
                    const current = stateValue(incoming_state.values, slot).?;
                    std.debug.assert(output.type_id == current.type_id);
                    generation.* = if (incoming_state.availability.get(slot) == .transferred) null else current.owned_generation;
                    changed = changed or output.id != current.id;
                    if (current.representation == .storage) output.representation = .storage;
                    if (index == 0) continue;
                    try self.mergeValueReferences(&output, output, current.*);
                    output.storage_identity = try self.joinBindingIdentities(output.storage_identity orelse output.binding_identity, current.storage_identity orelse current.binding_identity);
                    output.variant_identity = try self.joinBindingIdentities(output.variant_identity orelse output.binding_identity, current.variant_identity orelse current.binding_identity);
                    output.binding_identity = try self.joinBindingIdentities(output.binding_identity, current.binding_identity);
                }
                if (policy == .branch and !std.meta.eql(original_identity, output.binding_identity)) {
                    const joined_identity = output.binding_identity;
                    output.binding_identity = try self.newBindingIdentity();
                    self.binding_versions.items[output.binding_identity.fixed] = .{ .alias = joined_identity };
                }
                const generation = try self.joinGenerationGroup(output.type_id, span, incoming);
                if (changed) {
                    const argument = try self.appendBlockArgument(output.type_id, generation);
                    self.block_arguments.items[argument].representation = output.representation;
                    try changed_slots.append(self.gpa, @intCast(slot));
                    output.id = @fromBackingInt(argument);
                    output.owned_generation = generation;
                } else if (generation != output.owned_generation) {
                    if (generation) |destination_generation|
                        try generation_only.append(self.gpa, .{ .slot = @intCast(slot), .destination = destination_generation });
                    output.owned_generation = generation;
                }
                try state.values.set(self.gpa, slot, output);
            }
            const merged = try self.newBlock(argument_start, @intCast(self.block_arguments.items.len));
            for (exits) |exit| {
                const predecessor = try self.setJoinTerminator(merged, exit, if (result != null and destination == null) result.?.type_id else null, changed_slots.items, borrow_argument != null, completion_argument != null);
                if (destination != null) if (result.?.owned_generation) |generation| {
                    try self.recordGenerationOnlyForward(predecessor, 0, exit.constructed.?.owned_generation, generation);
                };
                for (generation_only.items) |join| {
                    const incoming_state = self.states.items[@backingInt(exit.state)];
                    const generation = if (incoming_state.availability.get(join.slot) == .transferred) null else incoming_state.values.get(join.slot).?.owned_generation;
                    try self.recordGenerationOnlyForward(predecessor, 0, generation, join.destination);
                }
            }
            std.debug.assert(state_argument_start + changed_slots.items.len == self.block_arguments.items.len);
            return .{ .block = merged, .state = try self.appendState(state), .constructed = result };
        }

        fn sharedJoinPageEnd(self: *const Self, state: State, exits: []const FlowExit, slot: usize) usize {
            const first = self.states.items[@backingInt(exits[0].state)];
            if (!state.values.sharesPage(first.values, slot) or !state.availability.sharesPage(first.availability, slot)) return slot;
            const end = state.values.pageEnd(slot);
            for (exits[1..]) |exit| {
                const incoming = self.states.items[@backingInt(exit.state)];
                if (incoming.values.len < end or !first.values.sharesPage(incoming.values, slot) or !first.availability.sharesPage(incoming.availability, slot)) return slot;
            }
            for (slot..end) |index| {
                const value_in_state = stateValue(state.values, index) orelse continue;
                if (state.availability.get(index) != .available) return slot;
                if (!self.generationMatchesType(value_in_state.owned_generation, value_in_state.type_id)) return slot;
            }
            return end;
        }

        fn canReuseExit(self: *Self, baseline: StateAvailability, exit: FlowExit, mode: ?ResultRequest) bool {
            const incoming = self.states.items[@backingInt(exit.state)];
            if (!baseline.eql(incoming.availability)) return false;
            for (0..incoming.values.len) |index| {
                const availability = incoming.availability.get(index);
                if (availability == .unbound and stateValue(incoming.values, index) != null) return false;
                if (availability == .transferred) if (stateValue(incoming.values, index)) |resolved| {
                    if (resolved.owned_generation != null) return false;
                };
            }
            if (mode) |request| {
                const result = exit.constructed orelse return false;
                if (request.destination) |destination| {
                    if (result.id != destination.storage.id or result.type_id != destination.storage.type_id) return false;
                }
                if (!self.generationMatchesType(result.owned_generation, result.type_id)) return false;
                if (result.owned_generation) |generation| {
                    if (self.generations.items[@backingInt(generation)].cleanup_condition != null) return false;
                }
            }
            return true;
        }

        fn joinBorrowedFact(comptime Fact: type, joined: *??Fact, candidate: ?Fact, include_unknown: bool) void {
            if (candidate == null and !include_unknown) return;
            if (joined.*) |previous| {
                if (previous != candidate) joined.* = @as(?Fact, null);
            } else joined.* = candidate;
        }

        const MatchLiteral = struct {
            type_id: structures.TypeId,
            value: union(enum) {
                integer: i64,
                boolean: bool,
                text: structures.ByteStringId,
                unit,
                none,
            },
        };
        const MatchPattern = struct {
            source: u32,
            input_type: structures.TypeId,
            members: []const structures.TypeId,
            shape: union(enum) {
                any,
                type,
                literal: MatchLiteral,
                range: semantic.UnresolvedBody.MatchInterval,
                tuple: []const MatchPattern,
            },
        };
        const MatchDomain = struct {
            member: structures.TypeId,
            remaining: []const MatchSpace,
        };
        // A disjoint part of the typed domain. Tuples retain correlations between
        // fields; scalar complements avoid enumerating integer and text values.
        const MatchSpace = struct {
            type_id: structures.TypeId,
            shape: union(enum) {
                any,
                integer: semantic.UnresolvedBody.MatchInterval,
                literal: @FieldType(MatchLiteral, "value"),
                excluding: []const @FieldType(MatchLiteral, "value"),
                tuple: []const MatchSpace,
            } = .any,
        };
        const ResolvedMatchArm = struct {
            source: semantic.UnresolvedBody.MatchArm,
            pattern: MatchPattern,
            members: []const structures.TypeId,
            remaining: []const structures.TypeId,
            spaces: []const MatchSpace,
            pattern_can_fail: bool,
        };

        fn matchLiteral(self: *Self, raw: semantic.UnresolvedBody.ValueUse, members: []const structures.TypeId, subject_type: structures.TypeId) !MatchLiteral {
            const operation = self.expressionOperation(raw.value) orelse unreachable;
            const literal: @FieldType(MatchLiteral, "value") = switch (operation.*) {
                .integer_literal, .int_literal_value => |integer| .{ .integer = integer },
                .boolean => |boolean| .{ .boolean = boolean },
                .string_literal => |text| .{ .text = text },
                .unit => .unit,
                .none => .none,
                else => unreachable,
            };
            var selected: ?structures.TypeId = null;
            var ambiguous = false;
            for (members) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                const compatible = switch (literal) {
                    .integer => logical == .int or logical == .byte or logical == .int_literal,
                    .boolean => logical == .bool,
                    .unit => logical == .unit,
                    .none => logical == .none,
                    .text => !logical.isPrimitive() and try self.analysis_context.isMatchTextType(logical),
                };
                if (!compatible or selected == logical) continue;
                if (literal == .integer and logical == .int) {
                    selected = logical;
                    ambiguous = false;
                    continue;
                }
                if (literal == .integer and selected == .int) continue;
                if (selected != null) ambiguous = true;
                selected = logical;
            }
            if (ambiguous) return self.reject(raw.span, .{ .match_literal_ambiguous = subject_type });
            const type_id = selected orelse return self.reject(raw.span, .{ .match_pattern_incompatible = self.typeMismatch(subject_type, switch (literal) {
                .integer => .int,
                .boolean => .bool,
                .unit => .unit,
                .none => .none,
                .text => .string_literal,
            }) });
            if (literal == .integer) {
                if (type_id == .int and std.math.cast(i32, literal.integer) == null)
                    return self.reject(raw.span, .integer_literal_out_of_range);
                if (type_id == .byte and std.math.cast(u8, literal.integer) == null)
                    return self.reject(raw.span, .{ .match_pattern_incompatible = self.typeMismatch(.byte, .int_literal) });
            }
            return .{ .type_id = type_id, .value = literal };
        }

        fn matchInputMembers(self: *Self, type_id: structures.TypeId) ![]const structures.TypeId {
            if (try self.analysis_context.facts().variantMembers(type_id)) |members| return members;
            return self.gpa.dupe(structures.TypeId, &.{type_id});
        }

        fn matchLiteralAccepts(self: *Self, raw: semantic.UnresolvedBody.ValueUse, type_id: structures.TypeId) !bool {
            const operation = self.expressionOperation(raw.value) orelse unreachable;
            for (try self.matchInputMembers(type_id)) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                const compatible = switch (operation.*) {
                    .integer_literal, .int_literal_value => logical == .int or logical == .byte or logical == .int_literal,
                    .boolean => logical == .bool,
                    .unit => logical == .unit,
                    .none => logical == .none,
                    .string_literal => !logical.isPrimitive() and try self.analysis_context.isMatchTextType(logical),
                    else => unreachable,
                };
                if (compatible) return true;
            }
            return false;
        }

        fn resolveMatchPatterns(self: *Self, id: u32, type_id: structures.TypeId) anyerror![]const MatchPattern {
            const source = self.unresolved.match_patterns[id];
            const members = try self.matchInputMembers(type_id);
            var patterns: std.ArrayList(MatchPattern) = .empty;
            switch (source.shape) {
                .any => try patterns.append(self.gpa, .{ .source = id, .input_type = type_id, .members = members, .shape = .any }),
                .type => |target| {
                    const targets = try self.analysis_context.facts().variantMembers(target);
                    var selected: std.ArrayList(structures.TypeId) = .empty;
                    for (members) |member| {
                        const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                        if (includesType(target, targets, logical)) try selected.append(self.gpa, member);
                    }
                    if (selected.items.len != 0)
                        try patterns.append(self.gpa, .{ .source = id, .input_type = type_id, .members = try selected.toOwnedSlice(self.gpa), .shape = .type });
                },
                .literal => |raw| {
                    if (try self.matchLiteralAccepts(raw, type_id)) {
                        const literal = try self.matchLiteral(raw, members, type_id);
                        for (members) |member| if ((try self.analysis_context.facts().memberSpec(member)).type_id == literal.type_id)
                            try patterns.append(self.gpa, .{ .source = id, .input_type = type_id, .members = try self.gpa.dupe(structures.TypeId, &.{member}), .shape = .{ .literal = literal } });
                    }
                },
                .range => |interval| try self.resolveRangeMatchPatterns(&patterns, id, type_id, members, interval),
                .tuple => |range| try self.resolveTupleMatchPatterns(&patterns, id, type_id, members, range),
            }
            return patterns.toOwnedSlice(self.gpa);
        }

        fn matchIntegerDomain(type_id: structures.TypeId) semantic.UnresolvedBody.MatchInterval {
            switch (type_id) {
                .int => return .{ .first = std.math.minInt(i32), .last = std.math.maxInt(i32) },
                .byte => return .{ .first = 0, .last = std.math.maxInt(u8) },
                .int_literal => return .{ .first = std.math.minInt(i64), .last = std.math.maxInt(i64) },
                else => unreachable,
            }
        }

        fn resolveRangeMatchPatterns(self: *Self, patterns: *std.ArrayList(MatchPattern), id: u32, type_id: structures.TypeId, members: []const structures.TypeId, interval: semantic.UnresolvedBody.MatchInterval) !void {
            var selected: ?structures.TypeId = null;
            var ambiguous = false;
            for (members) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                if (logical != .int and logical != .byte and logical != .int_literal) continue;
                if (logical == .int) {
                    selected = .int;
                    ambiguous = false;
                    continue;
                }
                if (selected == .int or selected == logical) continue;
                if (selected != null) ambiguous = true;
                selected = logical;
            }
            if (ambiguous) return self.reject(self.unresolved.match_patterns[id].span, .{ .match_range_ambiguous = type_id });
            const logical = selected orelse return;
            const domain = matchIntegerDomain(logical);
            const intersection: semantic.UnresolvedBody.MatchInterval = .{ .first = @max(domain.first, interval.first), .last = @min(domain.last, interval.last) };
            if (intersection.first > intersection.last) return;
            for (members) |member| if ((try self.analysis_context.facts().memberSpec(member)).type_id == logical)
                try patterns.append(self.gpa, .{ .source = id, .input_type = type_id, .members = try self.gpa.dupe(structures.TypeId, &.{member}), .shape = .{ .range = intersection } });
        }

        fn resolveTupleMatchPatterns(self: *Self, patterns: *std.ArrayList(MatchPattern), id: u32, type_id: structures.TypeId, members: []const structures.TypeId, range: structures.FunctionValueRange) anyerror!void {
            const children = self.unresolved.match_pattern_children[range.start..range.end];
            for (members) |member| {
                const logical = (try self.analysis_context.facts().memberSpec(member)).type_id;
                const fields = (try self.analysis_context.facts().tupleMembers(logical)) orelse continue;
                if (fields.len != children.len) continue;
                var combinations: std.ArrayList([]const MatchPattern) = .empty;
                try combinations.append(self.gpa, &.{});
                for (children, fields) |child, field| {
                    const alternatives = try self.resolveMatchPatterns(child, field.type_id);
                    var next: std.ArrayList([]const MatchPattern) = .empty;
                    for (combinations.items) |prefix| for (alternatives) |alternative| {
                        const combination = try self.gpa.alloc(MatchPattern, prefix.len + 1);
                        @memcpy(combination[0..prefix.len], prefix);
                        combination[prefix.len] = alternative;
                        try next.append(self.gpa, combination);
                    };
                    combinations = next;
                }
                for (combinations.items) |combination|
                    try patterns.append(self.gpa, .{ .source = id, .input_type = type_id, .members = try self.gpa.dupe(structures.TypeId, &.{member}), .shape = .{ .tuple = combination } });
            }
        }

        fn matchPatternSelects(pattern: MatchPattern, member: structures.TypeId) bool {
            return containsType(pattern.members, member);
        }

        // Return the intersection and append the disjoint remainder. Resolved
        // Type subsets stay together; tuple products retain their field correlations.
        fn partitionMatchSpace(self: *Self, space: MatchSpace, pattern: MatchPattern, remainder: *std.ArrayList(MatchSpace)) anyerror!?MatchSpace {
            if (pattern.shape == .any) return space;
            const members = try self.matchInputMembers(space.type_id);
            if (members.len > 1) std.debug.assert(space.shape == .any);
            var selected: structures.TypeId = .never;
            for (members) |candidate| {
                if (containsType(pattern.members, candidate)) {
                    selected = try joinTypes(self.analysis_context, selected, candidate, self.gpa);
                } else try remainder.append(self.gpa, .{ .type_id = candidate, .shape = space.shape });
            }
            if (selected == .never) return null;
            const intersection: MatchSpace = .{ .type_id = selected, .shape = space.shape };
            switch (pattern.shape) {
                .any => unreachable,
                .type => return intersection,
                .literal => |literal| return self.partitionMatchLiteral(intersection, literal, remainder),
                .range => |interval| return self.partitionMatchInteger(intersection, interval, remainder),
                .tuple => |children| return self.partitionMatchTuple(intersection, children, remainder),
            }
        }

        fn partitionMatchLiteral(self: *Self, space: MatchSpace, literal: MatchLiteral, remainder: *std.ArrayList(MatchSpace)) !?MatchSpace {
            if (literal.value == .integer)
                return self.partitionMatchInteger(space, .{ .first = literal.value.integer, .last = literal.value.integer }, remainder);
            if (space.shape == .literal) {
                if (std.meta.eql(space.shape.literal, literal.value)) return space;
                try remainder.append(self.gpa, space);
                return null;
            }
            std.debug.assert(space.shape == .any or space.shape == .excluding);
            const excluded = if (space.shape == .excluding) space.shape.excluding else &.{};
            for (excluded) |excluded_literal| if (std.meta.eql(excluded_literal, literal.value)) {
                try remainder.append(self.gpa, space);
                return null;
            };
            const values = try self.gpa.alloc(@FieldType(MatchLiteral, "value"), excluded.len + 1);
            @memcpy(values[0..excluded.len], excluded);
            values[excluded.len] = literal.value;
            const finite: ?usize = switch (literal.type_id) {
                .bool => 2,
                .unit, .none => 1,
                else => null,
            };
            if (finite == null or values.len != finite.?)
                try remainder.append(self.gpa, .{ .type_id = space.type_id, .shape = .{ .excluding = values } });
            return .{ .type_id = space.type_id, .shape = .{ .literal = literal.value } };
        }

        fn partitionMatchInteger(self: *Self, space: MatchSpace, interval: semantic.UnresolvedBody.MatchInterval, remainder: *std.ArrayList(MatchSpace)) !?MatchSpace {
            std.debug.assert(space.shape == .any or space.shape == .integer);
            const domain = if (space.shape == .integer) space.shape.integer else matchIntegerDomain((try self.analysis_context.facts().memberSpec(space.type_id)).type_id);
            const intersection: semantic.UnresolvedBody.MatchInterval = .{ .first = @max(domain.first, interval.first), .last = @min(domain.last, interval.last) };
            if (intersection.first > intersection.last) {
                try remainder.append(self.gpa, space);
                return null;
            }
            if (domain.first < intersection.first)
                try remainder.append(self.gpa, .{ .type_id = space.type_id, .shape = .{ .integer = .{ .first = domain.first, .last = intersection.first - 1 } } });
            if (intersection.last < domain.last)
                try remainder.append(self.gpa, .{ .type_id = space.type_id, .shape = .{ .integer = .{ .first = intersection.last + 1, .last = domain.last } } });
            return .{ .type_id = space.type_id, .shape = .{ .integer = intersection } };
        }

        fn partitionMatchTuple(self: *Self, space: MatchSpace, patterns: []const MatchPattern, remainder: *std.ArrayList(MatchSpace)) anyerror!?MatchSpace {
            std.debug.assert(space.shape == .any or space.shape == .tuple);
            const children = if (space.shape == .tuple)
                try self.gpa.dupe(MatchSpace, space.shape.tuple)
            else children: {
                const logical = (try self.analysis_context.facts().memberSpec(space.type_id)).type_id;
                const fields = (try self.analysis_context.facts().tupleMembers(logical)).?;
                const result = try self.gpa.alloc(MatchSpace, fields.len);
                for (fields, result) |field, *child| child.* = .{ .type_id = field.type_id };
                break :children result;
            };
            std.debug.assert(children.len == patterns.len);
            for (children, patterns, 0..) |*child, pattern, index| {
                var rejected: std.ArrayList(MatchSpace) = .empty;
                const matched = try self.partitionMatchSpace(child.*, pattern, &rejected);
                for (rejected.items) |part| {
                    // Earlier fields matched; this field did not. Later fields
                    // retain their original domains, preserving the product.
                    const product = try self.gpa.dupe(MatchSpace, children);
                    product[index] = part;
                    try remainder.append(self.gpa, .{ .type_id = space.type_id, .shape = .{ .tuple = product } });
                }
                child.* = matched orelse return null;
            }
            return .{ .type_id = space.type_id, .shape = .{ .tuple = children } };
        }

        fn validateMatchCaptureTypes(self: *Self, pattern: MatchPattern, types: []?structures.TypeId) anyerror!void {
            const source = self.unresolved.match_patterns[pattern.source];
            if (source.binding) |binding| {
                const actual = pattern.input_type;
                const slot = &types[@backingInt(binding.local)];
                if (slot.*) |previous| {
                    if (previous != actual) return self.reject(binding.span, .match_tuple_capture_type_ambiguous);
                } else slot.* = actual;
            }
            if (pattern.shape == .tuple) for (pattern.shape.tuple) |child|
                try self.validateMatchCaptureTypes(child, types);
        }

        fn resolveMatchArms(self: *Self, source: @FieldType(Expression.Operation, "match"), type_id: structures.TypeId, members: []const structures.TypeId) ![]const ResolvedMatchArm {
            const domains = try self.gpa.alloc(MatchDomain, members.len);
            for (members, domains) |member, *domain| {
                const remaining = try self.gpa.alloc(MatchSpace, 1);
                remaining[0] = .{ .type_id = member };
                domain.* = .{ .member = member, .remaining = remaining };
            }
            const capture_types = try self.gpa.alloc(?structures.TypeId, self.unresolved.local_count);
            @memset(capture_types, null);
            var resolved: std.ArrayList(ResolvedMatchArm) = .empty;
            for (self.unresolved.match_arms[source.arms.start..source.arms.end]) |arm| {
                const patterns = try self.resolveMatchPatterns(arm.pattern, type_id);
                if (patterns.len == 0) {
                    const raw = self.unresolved.match_patterns[arm.pattern];
                    if (raw.shape == .literal) _ = try self.matchLiteral(raw.shape.literal, members, type_id);
                    if (raw.shape == .type) return self.reject(arm.span, .{ .match_pattern_incompatible = self.typeMismatch(type_id, raw.shape.type) });
                    if (raw.shape == .range) return self.reject(arm.span, .{ .match_pattern_incompatible = self.typeMismatch(type_id, .int) });
                    return self.reject(arm.span, .match_tuple_pattern_incompatible);
                }
                var before: std.ArrayList(structures.TypeId) = .empty;
                for (domains) |domain| if (domain.remaining.len != 0) try before.append(self.gpa, domain.member);
                const first = resolved.items.len;
                for (patterns) |pattern| {
                    try self.validateMatchCaptureTypes(pattern, capture_types);
                    var selected: std.ArrayList(structures.TypeId) = .empty;
                    var spaces: std.ArrayList(MatchSpace) = .empty;
                    var pattern_can_fail = false;
                    for (domains) |*domain| {
                        if (domain.remaining.len == 0) continue;
                        if (!matchPatternSelects(pattern, domain.member)) {
                            pattern_can_fail = true;
                            continue;
                        }
                        var remainder: std.ArrayList(MatchSpace) = .empty;
                        var useful = false;
                        for (domain.remaining) |space| {
                            if (try self.partitionMatchSpace(space, pattern, &remainder)) |intersection| {
                                useful = true;
                                try spaces.append(self.gpa, intersection);
                            }
                        }
                        if (useful) try selected.append(self.gpa, domain.member);
                        pattern_can_fail = pattern_can_fail or remainder.items.len != 0;
                        if (arm.condition == null) domain.remaining = try remainder.toOwnedSlice(self.gpa);
                    }
                    if (selected.items.len == 0) continue;
                    try resolved.append(self.gpa, .{ .source = arm, .pattern = pattern, .members = try selected.toOwnedSlice(self.gpa), .remaining = before.items, .spaces = try spaces.toOwnedSlice(self.gpa), .pattern_can_fail = pattern_can_fail });
                }
                if (resolved.items.len == first) return self.reject(arm.span, .match_redundant_arm);
                var remaining: std.ArrayList(structures.TypeId) = .empty;
                for (domains) |domain| if (domain.remaining.len != 0) try remaining.append(self.gpa, domain.member);
                resolved.items[resolved.items.len - 1].remaining = try remaining.toOwnedSlice(self.gpa);
            }
            for (domains) |domain| if (domain.remaining.len != 0)
                return self.reject(self.valueSpan(source.subject.value), .{ .match_not_exhaustive = (try self.analysis_context.facts().memberSpec(domain.member)).type_id });
            return resolved.toOwnedSlice(self.gpa);
        }

        fn refineVariantOwner(self: *Self, source: Value, members: []const structures.TypeId) !Value {
            const previous = source.owned_generation orelse return source;
            const metadata = self.generations.items[@backingInt(previous)];
            const original = cleanup_shape.membersAt(metadata.cleanup_selections, &.{}) orelse (try self.analysis_context.facts().variantMembers(source.type_id)) orelse return source;
            var feasible: std.ArrayList(structures.TypeId) = .empty;
            for (original) |member| if (containsType(members, member)) try feasible.append(self.gpa, member);
            if (std.mem.eql(structures.TypeId, original, feasible.items)) return source;
            const selections = try cleanup_shape.withMembers(self.gpa, metadata.cleanup_selections, &.{}, try feasible.toOwnedSlice(self.gpa));
            return self.replaceOwnerCleanup(source, selections);
        }

        fn refineMatchCarrier(self: *Self, carrier: semantic.UnresolvedBody.LocalId, members: []const structures.TypeId) !void {
            const scope = try self.openBoundary(self.activeLifetimeSpan());
            defer self.current_boundary = scope.parent;
            const source = try self.readLocal(carrier, self.activeLifetimeSpan());
            const place = (try self.flowPlace(source, true)) orelse {
                try self.closeBoundary(scope.boundary);
                return;
            };
            const current = self.flow.?.facts.get(self.state.refinements, place);
            const possible = try self.matchInputMembers(current.type_id orelse source.type_id);
            var selected: structures.TypeId = .never;
            for (members) |member| if (containsType(possible, member)) {
                selected = try joinTypes(self.analysis_context, selected, member, self.gpa);
            };
            try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, .{ .version = current.version, .type_id = selected, .span = self.activeLifetimeSpan() });
            try self.refineFlowOwners();
            try self.closeBoundary(scope.boundary);
        }

        fn matchLiteralTest(self: *Self, value_to_test: Value, literal: MatchLiteral, matched: structures.FunctionBlockId, unmatched: structures.FunctionBlockId, span: structures.SourceSpan) !void {
            _ = span;
            try self.recordUse(value_to_test);
            switch (literal.value) {
                .integer => |integer| {
                    const operand = try self.matchIntegerOperand(value_to_test);
                    const expected = try self.matchIntegerConstant(literal.type_id, integer);
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    self.branchOn(.eqi, operand.id, expected.id, matched, unmatched);
                },
                .boolean => |boolean| {
                    const expected = try self.appendInstruction(.{ .const_bool = boolean });
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    self.branchOn(.eqb, value_to_test.id, expected.id, matched, unmatched);
                },
                .unit, .none => {
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    self.terminate(.{ .branch = self.emptyBranch(matched) });
                },
                .text => |text| {
                    const function = try self.analysis_context.matchTextFunction(literal.type_id);
                    _ = (try self.analysis_context.functionSignature(function)) orelse return error.Unavailable;
                    const expected = try self.staticStringValue(text);
                    const comparison = try self.appendInstruction(.{ .call = .{
                        .target = .{ .direct = function },
                        .arguments = try self.publishRange(&self.call_arguments, &[_]structures.FunctionCallArgument{
                            .{ .prepared = .{ .value = value_to_test.id } },
                            .{ .prepared = .{ .value = expected.id } },
                        }),
                        .return_type = .bool,
                    } });
                    const truth = try self.appendInstruction(.{ .const_bool = true });
                    try self.moveCurrentBoundaryEffectsToTerminator();
                    self.branchOn(.eqb, comparison.id, truth.id, matched, unmatched);
                },
            }
        }

        fn matchIntegerOperand(self: *Self, operand: Value) !Value {
            if (operand.type_id != .byte) return operand;
            const function = try self.analysis_context.byteIntFunction();
            _ = (try self.analysis_context.functionSignature(function)) orelse return error.Unavailable;
            return self.appendInstruction(.{ .call = .{
                .target = .{ .direct = function },
                .arguments = try self.publishRange(&self.call_arguments, &[_]structures.FunctionCallArgument{.{ .prepared = .{ .value = operand.id } }}),
                .return_type = .int,
            } });
        }

        fn matchIntegerConstant(self: *Self, type_id: structures.TypeId, integer: i64) !Value {
            if (type_id == .int_literal) return self.appendInstruction(.{ .const_int_literal = integer });
            return self.appendInstruction(.{ .const_int = @intCast(integer) });
        }

        fn matchRangeTest(self: *Self, value_to_test: Value, interval: semantic.UnresolvedBody.MatchInterval, matched: structures.FunctionBlockId, unmatched: structures.FunctionBlockId) !void {
            try self.recordUse(value_to_test);
            const operand = try self.matchIntegerOperand(value_to_test);
            const domain = matchIntegerDomain(value_to_test.type_id);
            if (interval.first > domain.first) {
                const lower = try self.matchIntegerConstant(value_to_test.type_id, interval.first);
                const inside = try self.newEmptyBlock();
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.branchOn(.gei, operand.id, lower.id, inside, unmatched);
                self.enterBlock(inside);
            }
            if (interval.last < domain.last) {
                const upper = try self.matchIntegerConstant(value_to_test.type_id, interval.last);
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.branchOn(.lei, operand.id, upper.id, matched, unmatched);
            } else {
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.terminate(.{ .branch = self.emptyBranch(matched) });
            }
        }

        const PreparedMatchPattern = struct {
            pattern: MatchPattern,
            owned: bool,
            product_owned: bool = false,
            pending_capture: bool = false,
            children: []PreparedMatchPattern = &.{},
        };

        fn checkMatchTestingWrite(self: *Self, origins: ?u32, span: structures.SourceSpan) !void {
            if (origins == null) return;
            var current = self.match_testing_scope;
            while (current) |scope| : (current = scope.parent) {
                try self.reference_exclusions.append(self.gpa, .{ .reference = scope.origins, .invalidation = origins, .span = span, .match_testing = true });
            }
        }

        fn matchProjectedOrigins(self: *Self, pattern: MatchPattern, incoming: ?u32, protected: *?u32) anyerror!void {
            var selected = incoming;
            for (pattern.members) |member| {
                const spec = try self.analysis_context.facts().memberSpec(member);
                const origins = if (try self.analysis_context.facts().variantMembers(pattern.input_type) != null)
                    try self.transformReferenceOrigins(incoming, .{ .select = .{ .variant = member } })
                else
                    incoming;
                if (spec.kind == .reference) protected.* = try self.mergeReferenceOrigins(protected.*, origins);
                if (pattern.shape == .tuple) selected = origins;
            }
            if (pattern.shape != .tuple) return;
            const logical = (try self.analysis_context.facts().memberSpec(pattern.members[0])).type_id;
            const fields = (try self.analysis_context.facts().tupleMembers(logical)).?;
            for (fields, pattern.shape.tuple, 0..) |field, child, index| {
                const child_source = self.unresolved.match_patterns[child.source];
                if (child_source.shape == .any and child_source.binding == null) continue;
                const origins = try self.transformReferenceOrigins(selected, .{ .select = .{ .field = @intCast(index) } });
                if (field.kind == .reference)
                    protected.* = try self.mergeReferenceOrigins(protected.*, origins);
                try self.matchProjectedOrigins(child, origins, protected);
            }
        }

        fn recordMatchDispatchUse(self: *Self, origins: ?u32, span: structures.SourceSpan) !void {
            const protected = origins orelse return;
            const boundary = try self.newBoundary(span);
            const location = try self.appendEffectAt(boundary, null);
            try self.closeBoundary(boundary);
            try self.reference_uses.append(self.gpa, .{ .origins = protected, .span = span, .location = location, .match_testing = true });
            try self.recordReferenceUses(.{ .id = @fromBackingInt(0), .type_id = .unit, .reference_origins = protected }, .retention);
        }

        fn protectMatchLocal(self: *Self, local: semantic.UnresolvedBody.LocalId) !void {
            const scope = self.match_testing_scope orelse return;
            try scope.locals.append(self.gpa, local);
            const origins = if (self.locals.items(.reference)[@backingInt(local)])
                self.state.values.get(@backingInt(local)).?.reference_origins
            else
                try self.sourceReferenceOrigins(self.borrowLocalValue(local));
            scope.origins = try self.mergeReferenceOrigins(scope.origins, origins);
        }

        fn installMatchInput(self: *Self, pattern: MatchPattern, incoming: Value, reference: bool) !void {
            const source = self.unresolved.match_patterns[pattern.source];
            var value_to_bind = incoming;
            if (!reference) {
                value_to_bind.borrowed_generation = incoming.owned_generation orelse incoming.borrowed_generation;
                value_to_bind.borrowed_cleanup_value = if (incoming.owned_generation != null) incoming.id else incoming.borrowed_cleanup_value;
                value_to_bind.owned_generation = null;
            }
            try self.installLocal(source.carrier, value_to_bind, reference, true);
            try self.protectMatchLocal(source.carrier);
        }

        fn matchPatternMemberTest(self: *Self, pattern: MatchPattern, operand: Value, unmatched: ?structures.FunctionBlockId) !void {
            const members = (try self.analysis_context.facts().variantMembers(pattern.input_type)) orelse return;
            if (unmatched == null or pattern.members.len == members.len) return;
            const matched = try self.newEmptyBlock();
            const tag = try self.appendInstruction(.{ .variant_tag = operand.id });
            for (pattern.members, 0..) |member, index| {
                const next = if (index + 1 == pattern.members.len) unmatched.? else try self.newEmptyBlock();
                const member_index = std.mem.indexOfScalar(structures.TypeId, members, member).?;
                const expected = try self.appendInstruction(.{ .const_int = @intCast(member_index) });
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.branchOn(.eqi, tag.id, expected.id, matched, next);
                if (index + 1 != pattern.members.len) self.enterBlock(next);
            }
            self.enterBlock(matched);
        }

        fn testMatchPattern(self: *Self, pattern: MatchPattern, incoming: Value, reference: bool, unmatched: ?structures.FunctionBlockId) anyerror!PreparedMatchPattern {
            const source = self.unresolved.match_patterns[pattern.source];
            try self.installMatchInput(pattern, incoming, reference);
            var prepared: PreparedMatchPattern = .{ .pattern = pattern, .owned = !reference };
            const operand = try self.readLocal(source.carrier, source.span);
            try self.recordUse(operand);
            try self.matchPatternMemberTest(pattern, operand, unmatched);
            if (pattern.shape == .any or pattern.shape == .type) return prepared;
            std.debug.assert(pattern.members.len == 1);
            const member = pattern.members[0];
            const spec = try self.analysis_context.facts().memberSpec(member);
            const variant = try self.analysis_context.facts().variantMembers(pattern.input_type);
            const root_reference = try self.captureReference(.{ .value = source.read, .span = source.span });
            const selected_reference = if (variant != null)
                try self.extractReferenceMember(root_reference, operand, member, spec.type_id)
            else
                root_reference;
            const selected = if (variant != null) try self.readReference(selected_reference, spec.type_id) else operand;
            if (pattern.shape == .literal) {
                if (unmatched) |rejected| {
                    const matched = try self.newEmptyBlock();
                    try self.matchLiteralTest(selected, pattern.shape.literal, matched, rejected, source.span);
                    self.enterBlock(matched);
                }
                return prepared;
            }
            if (pattern.shape == .range) {
                if (unmatched) |rejected| {
                    const matched = try self.newEmptyBlock();
                    try self.matchRangeTest(selected, pattern.shape.range, matched, rejected);
                    self.enterBlock(matched);
                }
                return prepared;
            }
            const fields = (try self.analysis_context.facts().tupleMembers(spec.type_id)).?;
            prepared.product_owned = !reference and spec.kind == .owned;
            prepared.children = try self.gpa.alloc(PreparedMatchPattern, pattern.shape.tuple.len);
            var storage = self.state.values.get(@backingInt(source.carrier)).?;
            if (prepared.product_owned and variant != null) {
                const previous = storage;
                storage = try self.projectStorage(previous, spec.type_id, .variant);
                storage.reference_origins = try self.transformReferenceOrigins(previous.reference_origins, .{ .select = .{ .variant = member } });
                storage.borrowed_generation = previous.borrowed_generation;
                storage.borrowed_cleanup_value = previous.borrowed_cleanup_value;
            }
            for (fields, pattern.shape.tuple, prepared.children, 0..) |field, child, *child_prepared, index| {
                const place: PlaceField = .{ .name = "", .index = @intCast(index), .type_id = field.type_id, .kind = field.kind };
                if (field.kind == .reference) {
                    child_prepared.* = try self.testMatchPattern(child, try self.referenceField(selected, place), true, unmatched);
                } else if (prepared.product_owned) {
                    var projected = try self.projectStorage(storage, field.type_id, .{ .field = @intCast(index) });
                    projected.reference_origins = try self.transformReferenceOrigins(storage.reference_origins, .{ .select = .{ .field = @intCast(index) } });
                    projected.borrowed_generation = storage.borrowed_generation;
                    projected.borrowed_cleanup_value = storage.borrowed_cleanup_value;
                    child_prepared.* = try self.testMatchPattern(child, projected, false, unmatched);
                } else {
                    const projected = try self.projectReference(selected_reference, &.{place});
                    child_prepared.* = try self.testMatchPattern(child, projected, true, unmatched);
                }
            }
            return prepared;
        }

        fn prepareMatchCaptures(self: *Self, prepared: *PreparedMatchPattern, known_members: ?[]const structures.TypeId) anyerror!void {
            const pattern = prepared.pattern;
            const source = self.unresolved.match_patterns[pattern.source];
            if (source.binding) |binding| {
                if (binding.mode == .reference) {
                    const reference = try self.captureReference(.{ .value = source.read, .span = binding.span });
                    try self.installLocal(binding.local, reference, true, false);
                } else if (!prepared.owned) {
                    const operand = try self.flowRead(try self.readLocal(source.carrier, binding.span));
                    var captured = try self.ownValue(operand, binding.span);
                    if (known_members) |members| captured = try self.refineVariantOwner(captured, members);
                    try self.installLocal(binding.local, captured, false, false);
                } else {
                    var pending = self.state.values.get(@backingInt(source.carrier)).?;
                    pending.flow_origins = try self.valuePlaceOrigins(try self.readLocal(source.carrier, binding.span));
                    try self.installLocal(binding.local, pending, false, false);
                    try self.copyFlowType(try self.readLocal(source.carrier, binding.span), binding.local);
                    prepared.pending_capture = true;
                }
                try self.protectMatchLocal(binding.local);
            }
            for (prepared.children) |*child| try self.prepareMatchCaptures(child, null);
        }

        fn refineMatchFlow(self: *Self, prepared: PreparedMatchPattern, spaces: []const MatchSpace) anyerror!void {
            const source = self.unresolved.match_patterns[prepared.pattern.source];
            const operand = try self.readLocal(source.carrier, source.span);
            if (try self.flowPlace(operand, true)) |place| {
                var selected: structures.TypeId = .never;
                for (spaces) |space| selected = try joinTypes(self.analysis_context, selected, space.type_id, self.gpa);
                const current = self.flow.?.facts.get(self.state.refinements, place);
                try self.flow.?.facts.put(self.gpa, &self.state.refinements, place, .{ .version = current.version, .type_id = selected, .span = source.span });
            }
            for (prepared.children, 0..) |child, index| {
                const children = try self.gpa.alloc(MatchSpace, spaces.len);
                for (spaces, children) |space, *element| {
                    std.debug.assert(space.shape == .tuple);
                    element.* = space.shape.tuple[index];
                }
                try self.refineMatchFlow(child, children);
            }
        }

        fn commitMatchPattern(self: *Self, prepared: *PreparedMatchPattern, supplied_owner: ?Value) anyerror!void {
            const pattern = prepared.pattern;
            const source = self.unresolved.match_patterns[pattern.source];
            if (prepared.owned) {
                if (pattern.shape == .tuple and prepared.product_owned) {
                    if (supplied_owner) |owner| try self.recordConsume(owner);
                    try self.state.availability.set(self.gpa, @backingInt(source.carrier), .transferred);
                } else {
                    var owned = if (supplied_owner) |owner| owner else try self.defineOwnedValue(self.state.values.get(@backingInt(source.carrier)).?, source.span, false);
                    if (try self.analysis_context.facts().variantMembers(owned.type_id) != null)
                        owned = try self.refineVariantOwner(owned, pattern.members);
                    const identity = self.state.values.get(@backingInt(source.carrier)).?.binding_identity;
                    owned.binding_identity = identity;
                    try self.state.values.set(self.gpa, @backingInt(source.carrier), owned);
                    if (prepared.pending_capture) {
                        const binding = source.binding.?;
                        var captured = owned;
                        self.locals.items(.reference)[@backingInt(binding.local)] = false;
                        const previous = self.state.values.get(@backingInt(binding.local)).?;
                        captured.binding_identity = previous.binding_identity;
                        captured.flow_origins = previous.flow_origins;
                        if (previous.representation == .storage) {
                            captured.id = previous.id;
                            captured.representation = previous.representation;
                        }
                        try self.state.values.set(self.gpa, @backingInt(binding.local), captured);
                        try self.unbindLocal(@backingInt(source.carrier));
                    }
                }
            }
            for (prepared.children) |*child| try self.commitMatchPattern(child, null);
        }

        fn unbindMatchPattern(self: *Self, prepared: PreparedMatchPattern) anyerror!void {
            const source = self.unresolved.match_patterns[prepared.pattern.source];
            if (source.binding) |binding| {
                try self.unbindLocal(@backingInt(binding.local));
            }
            try self.unbindLocal(@backingInt(source.carrier));
            for (prepared.children) |child| try self.unbindMatchPattern(child);
        }

        fn matchValue(self: *Self, source: @FieldType(Expression.Operation, "match"), request: ResultRequest) anyerror!Value {
            const baseline = try self.captureState();
            const input_scope = try self.openBoundary(source.subject.span);
            try self.bindLocal(.{ .local = source.carrier, .value = source.subject.value, .span = source.subject.span, .mutable = true, .mode = .inferred });
            if (self.current_block == null) {
                self.current_boundary = input_scope.parent;
                return .{ .id = @fromBackingInt(0), .type_id = .never };
            }
            try self.closeBoundary(input_scope.boundary);
            self.current_boundary = input_scope.parent;
            const subject = try self.readLocal(source.carrier, source.subject.span);
            const members = try self.matchInputMembers(subject.type_id);
            const arms = try self.resolveMatchArms(source, subject.type_id, members);
            var dispatch_origins = if (self.locals.items(.reference)[@backingInt(source.carrier)])
                self.state.values.get(@backingInt(source.carrier)).?.reference_origins
            else
                try self.sourceReferenceOrigins(self.borrowLocalValue(source.carrier));
            for (members) |member| {
                if ((try self.analysis_context.facts().memberSpec(member)).kind == .reference)
                    dispatch_origins = try self.mergeReferenceOrigins(dispatch_origins, try self.transformReferenceOrigins(subject.reference_origins, .{ .select = .{ .variant = member } }));
            }
            for (arms) |arm| try self.matchProjectedOrigins(arm.pattern, subject.reference_origins, &dispatch_origins);
            const checkpoint = try self.appendInstruction(.const_unit);
            const dispatch_loan = try self.readReferenceOrigins(dispatch_origins, null, @truncate(@backingInt(checkpoint.id)), false);
            // Dispatch can replace ownership generations on its outgoing paths.
            // Retain the input in this block, before any arm refines its owner.
            try self.moveCurrentBoundaryEffectsToTerminator();
            // Tuple alternatives can instantiate one source arm on several
            // disjoint paths. Cached expressions belong to their path's SSA.
            const dispatch_values = self.values.snapshot();
            defer self.values = dispatch_values.snapshot();
            var exits: std.ArrayList(FlowExit) = .empty;
            const outer_testing = self.match_testing_scope;
            defer self.match_testing_scope = outer_testing;
            for (arms) |arm| {
                self.values = dispatch_values.snapshot();
                var testing: MatchTestingScope = .{ .parent = outer_testing, .origins = dispatch_origins };
                self.match_testing_scope = &testing;
                try self.protectMatchLocal(source.carrier);
                const before = try self.captureState();
                const next = if (arm.pattern_can_fail) try self.newEmptyBlock() else null;
                const incoming = self.state.values.get(@backingInt(source.carrier)).?;
                const preparation = try self.openBoundary(arm.source.span);
                var prepared = try self.testMatchPattern(arm.pattern, incoming, self.locals.items(.reference)[@backingInt(source.carrier)], next);
                try self.refineMatchFlow(prepared, arm.spaces);
                try self.prepareMatchCaptures(&prepared, arm.members);
                try self.closeBoundary(preparation.boundary);
                self.current_boundary = preparation.parent;
                var rejected: ?FlowExit = null;
                if (arm.source.condition) |condition_id| {
                    const flow = try self.condition(condition_id);
                    rejected = flow.unmatched;
                    if (flow.matched) |matched| try self.enterFlowExit(matched) else self.current_block = null;
                }
                self.match_testing_scope = outer_testing;
                if (self.current_block != null) {
                    const commit = try self.openBoundary(arm.source.span);
                    try self.recordUse(try self.readLocal(source.carrier, source.subject.span));
                    try self.recordMatchDispatchUse(dispatch_loan, arm.source.span);
                    const owner = if (!self.locals.items(.reference)[@backingInt(source.carrier)])
                        try self.refineVariantOwner(try self.takeIteratorCarrier(source.carrier, arm.source.span), arm.members)
                    else
                        null;
                    try self.commitMatchPattern(&prepared, owner);
                    try self.refineFlowOwners();
                    try self.closeBoundary(commit.boundary);
                    self.current_boundary = commit.parent;
                    var result = try self.blockWithResult(arm.source.body, request);
                    if (self.current_block != null) {
                        if (result) |selected_result| result = try self.ownValueEscapingSince(selected_result, baseline, arm.source.span);
                        try self.unbindMatchPattern(prepared);
                        try self.unbindLocal(@backingInt(source.carrier));
                    }
                    if (try self.valueExit(result)) |exit| try exits.append(self.gpa, exit);
                }
                if (arm.remaining.len != 0) {
                    var failures: std.ArrayList(FlowExit) = .empty;
                    if (next) |continuation| try failures.append(self.gpa, .{ .block = continuation, .state = before });
                    if (rejected) |unmatched| {
                        try self.enterFlowExit(unmatched);
                        try self.unbindMatchPattern(prepared);
                        try failures.append(self.gpa, .{ .block = self.suspendBlock(), .state = try self.captureState() });
                    }
                    const unmatched = try self.mergeExits(before, failures.items, null, .condition);
                    try self.enterFlowExit(unmatched);
                    try self.refineMatchCarrier(source.carrier, arm.remaining);
                }
            }
            if (exits.items.len == 0) {
                std.debug.assert(self.current_block == null);
                return .{ .id = @fromBackingInt(0), .type_id = .never };
            }
            const merged = try self.mergeExits(baseline, exits.items, request, .branch);
            try self.enterFlowExit(merged);
            if (merged.constructed.?.type_id == .never) self.terminate(.diverge);
            return merged.constructed.?;
        }

        fn conditional(self: *Self, expression: @FieldType(Expression.Operation, "if_else"), mode: ResultRequest) anyerror!Value {
            const baseline = try self.captureAvailability();
            const flow = try self.condition(expression.condition);
            if (flow.matched == null and flow.unmatched == null) {
                std.debug.assert(flow.diverged != null);
                return flow.diverged.?;
            }

            const then_exit = if (flow.matched) |matched| blk: {
                try self.enterFlowExit(matched);
                const result = try self.blockWithResult(expression.then_block, mode);
                break :blk try self.valueExit(result);
            } else null;
            const else_exit = if (flow.unmatched) |unmatched| blk: {
                try self.enterFlowExit(unmatched);
                break :blk try self.valueExit(try self.blockWithResult(expression.else_block, mode));
            } else null;

            var exits: std.ArrayList(FlowExit) = .empty;

            if (then_exit) |exit| try exits.append(self.gpa, exit);
            if (else_exit) |exit| try exits.append(self.gpa, exit);
            if (exits.items.len == 0) {
                std.debug.assert(self.current_block == null);
                return .{ .id = @fromBackingInt(0), .type_id = .never };
            }
            const merged = try self.mergeScopedExits(baseline, exits.items, mode, .branch);
            try self.enterFlowExit(merged);
            if (merged.constructed.?.type_id == .never) self.terminate(.diverge);
            return merged.constructed.?;
        }

        fn valueExit(self: *Self, result: ?Value) !?FlowExit {
            const value_to_exit = result orelse return null;
            const state = try self.captureState();
            return .{ .block = self.suspendBlock(), .state = state, .constructed = value_to_exit };
        }

        fn normalizeJoinFields(self: *Self, exits: []FlowExit, policy: JoinPolicy) !void {
            var slot: usize = 0;
            locals: while (slot < self.state.values.len) : (slot += 1) {
                const first_availability = self.states.items[@backingInt(exits[0].state)].availability;
                const shared = for (exits[1..]) |exit| {
                    if (!first_availability.sharesPage(self.states.items[@backingInt(exit.state)].availability, slot)) break false;
                } else true;
                if (shared) {
                    slot = first_availability.pageEnd(slot) - 1;
                    continue;
                }
                if (self.is_initializer_region and self.captured_locals[slot] != null) continue;
                var transferred = false;
                var available = false;
                for (exits) |exit| switch (self.states.items[@backingInt(exit.state)].availability.get(slot)) {
                    .transferred => transferred = true,
                    .available => available = true,
                    else => continue :locals,
                };
                if (!transferred or !available) continue;
                const owns_value = for (exits) |exit| {
                    const state = self.states.items[@backingInt(exit.state)];
                    if (state.availability.get(slot) == .available and stateValue(state.values, slot).?.owned_generation != null) break true;
                } else false;
                if (!owns_value) continue;
                for (exits) |*exit| {
                    if (self.states.items[@backingInt(exit.state)].availability.get(slot) != .available) continue;
                    exit.* = try self.endBeforeJoin(exit.*, .{ .local = @fromBackingInt(@intCast(slot)) });
                }
            }
            for (self.field_places, 0..) |place, index| {
                if (self.is_initializer_region and self.captured_locals[@backingInt(place.local)] != null) continue;
                if (!place.moves_owner) continue;
                const local_index = @backingInt(place.local);
                if (self.locals.items(.mut_parameter)[local_index] != null and try self.analysis_context.facts().variantMembers(self.state.values.get(local_index).?.type_id) != null) continue;
                var transferred = false;
                var available = false;
                var all_bound = true;
                var first: ?Availability = null;
                var different = false;
                var unsupported = false;
                for (exits) |exit| {
                    const state = self.states.items[@backingInt(exit.state)];
                    all_bound = all_bound and state.availability.get(local_index) == .available;
                    if (state.availability.get(local_index) != .available) continue;
                    const field = state.field_availability.get(index);
                    if (first) |initial| different = different or initial != field else first = field;
                    unsupported = unsupported or (field != .available and field != .transferred);
                    transferred = transferred or field == .transferred or (policy == .loop and field == .replacing);
                    available = available or field == .available;
                }
                if (policy != .loop and !all_bound) continue;
                if (policy != .loop and different and unsupported) return self.reject(self.activeLifetimeSpan(), .partial_field_transfer_not_supported);
                if (!transferred or !available) continue;
                for (exits) |*exit| {
                    const state = self.states.items[@backingInt(exit.state)];
                    if (state.availability.get(local_index) != .available) continue;
                    if (state.field_availability.get(index) == .available) exit.* = try self.endBeforeJoin(exit.*, .{ .field = place });
                }
            }
        }

        /// Ends an owner on one incoming path so that every path reaches the join without it.
        fn endBeforeJoin(self: *Self, exit: FlowExit, owner: union(enum) { local: semantic.UnresolvedBody.LocalId, field: FieldPlace }) !FlowExit {
            const span = self.activeLifetimeSpan();
            self.enterPendingBlock(exit.block);
            self.restoreState(exit.state);
            const scope = try self.openBoundary(span);
            defer self.current_boundary = scope.parent;
            switch (owner) {
                .local => |local| {
                    const value_to_end = self.state.values.get(@backingInt(local)).?;
                    try self.dropReplacedField(value_to_end, value_to_end, &.{}, self.locals.items(.can_deinit)[@backingInt(local)], span);
                    try self.recordConsume(value_to_end);
                    try self.state.availability.set(self.gpa, @backingInt(local), .transferred);
                },
                .field => |place| try self.endField(place, span),
            }
            try self.closeBoundary(scope.boundary);
            var result = exit;
            result.state = try self.captureState();
            result.block = self.suspendBlock();
            return result;
        }

        fn endField(self: *Self, place: FieldPlace, span: structures.SourceSpan) !void {
            var fields: std.ArrayList(PlaceField) = .empty;

            const path = try self.resolveOwnedFields(place.local, place.fields, &fields);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(fields.last().?.type_id)) orelse return error.Unavailable;
            if (capabilities.requires_explicit_drop) return self.reject(span, .explicit_drop_field_cannot_be_implicitly_ended);
            const field = try self.transferFieldProjection(place.local, fields.items, path, span, .consume);
            try self.dropValue(field, false, span);
            try self.recordConsume(field);
        }

        fn sharedStableReferenceRoot(first: ?semantic.UnresolvedBody.LocalId, second: ?semantic.UnresolvedBody.LocalId) ?semantic.UnresolvedBody.LocalId {
            return if (first == second) first else null;
        }

        fn setJoinTerminator(
            self: *Self,
            target: structures.FunctionBlockId,
            exit: FlowExit,
            result_type: ?structures.TypeId,
            changed_slots: []const u32,
            include_borrow_condition: bool,
            include_consumption_completion: bool,
        ) !structures.FunctionBlockId {
            self.enterPendingBlock(exit.block);
            self.restoreState(exit.state);
            if (!include_borrow_condition and !include_consumption_completion) {
                self.terminate(.{ .branch = try self.joinBranch(target, exit, result_type, changed_slots, null, null) });
                return exit.block;
            }
            const edge = try self.newEmptyBlock();
            self.terminate(.{ .branch = self.emptyBranch(edge) });
            self.enterBlock(edge);
            const borrowed_on_path = if (include_borrow_condition) exit.constructed.?.borrow_condition orelse (try self.appendInstruction(.{
                .const_bool = hasNonowningPath(exit.constructed.?),
            })).id else null;
            const completion = if (!include_consumption_completion) null else exit.constructed.?.consumption_completion orelse completed: {
                const flag = try self.localStorage(.bool);
                _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = true }), flag);
                break :completed flag.id;
            };
            self.terminate(.{ .branch = try self.joinBranch(target, exit, result_type, changed_slots, borrowed_on_path, completion) });
            return edge;
        }

        fn joinBranch(
            self: *Self,
            target: structures.FunctionBlockId,
            exit: FlowExit,
            result_type: ?structures.TypeId,
            changed_slots: []const u32,
            borrow_condition: ?structures.FunctionValueId,
            consumption_completion: ?structures.FunctionValueId,
        ) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            if (result_type) |type_id| {
                const result = (try self.coerceValue(exit.constructed.?.id, exit.constructed.?.type_id, type_id)) orelse unreachable;
                try self.appendBranchArgument(result, exit.constructed.?.owned_generation);
            }
            if (borrow_condition) |borrow_predicate| try self.appendBranchArgument(.{ .value = borrow_predicate }, null);
            if (consumption_completion) |completion| try self.appendBranchArgument(.{ .value = completion }, null);
            const state = self.states.items[@backingInt(exit.state)].values;
            for (changed_slots) |slot| try self.appendBranchArgument(.{ .value = state.get(slot).?.id }, state.get(slot).?.owned_generation);
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn joinAvailability(left: Availability, right: Availability) Availability {
            if (left == right) return left;
            if (left == .unbound or right == .unbound) return .unbound;
            return .maybe_transferred;
        }

        fn appendInstruction(self: *Self, instruction: structures.FunctionInstruction) !Value {
            std.debug.assert(self.current_block != null);
            const instruction_id = std.math.cast(u31, self.instruction_count) orelse return error.AnalysisTooLarge;
            self.instruction_count += 1;
            try self.blocks.items[@backingInt(self.current_block.?)].items.append(self.gpa, .{
                .instruction = .{
                    .id = instruction_id,
                    .operation = instruction,
                    .span = if (self.options.publish_instruction_spans)
                        self.activeLifetimeSpan()
                    else
                        .{ .start = 0, .end = 0 },
                },
            });
            // The final block-argument count and instruction layout are known
            // only after CFG construction and transformation. Temporary
            // high-bit IDs remain stable while block instructions are edited;
            // finish() rewrites them into the published contiguous namespace.
            const id: structures.FunctionValueId = @fromBackingInt(@intCast(@as(u32, 1) << 31 | @as(u32, instruction_id)));
            return .{ .id = id, .type_id = instruction.resultType() };
        }

        fn appendBlockArgument(self: *Self, type_id: structures.TypeId, generation: ?GenerationId) !u32 {
            std.debug.assert(self.block_arguments.items.len == self.block_argument_generations.items.len);
            try self.block_arguments.ensureUnusedCapacity(self.gpa, 1);
            try self.block_argument_generations.ensureUnusedCapacity(self.gpa, 1);
            const index: u32 = @intCast(self.block_arguments.items.len);
            self.block_arguments.appendAssumeCapacity(.{ .type_id = type_id });
            self.block_argument_generations.appendAssumeCapacity(generation);
            return index;
        }

        /// Appends an argument with the type, representation, and generation of an existing one.
        fn copyBlockArgument(self: *Self, source: usize) !u32 {
            const argument = try self.appendBlockArgument(self.block_arguments.items[source].type_id, self.block_argument_generations.items[source]);
            self.block_arguments.items[argument] = self.block_arguments.items[source];
            return argument;
        }

        fn appendBranchArgument(self: *Self, value_use: structures.FunctionValueUse, generation: ?GenerationId) !void {
            std.debug.assert(self.branch_arguments.items.len == self.branch_argument_generations.items.len);
            try self.branch_arguments.ensureUnusedCapacity(self.gpa, 1);
            try self.branch_argument_generations.ensureUnusedCapacity(self.gpa, 1);
            self.branch_arguments.appendAssumeCapacity(value_use);
            self.branch_argument_generations.appendAssumeCapacity(generation);
        }

        fn finishOwnershipMetadata(self: *Self) !void {
            std.debug.assert(self.ownership_forwards.items.len == 0);
            std.debug.assert(self.ownership_edges.items.len == 0);
            std.sort.block(OwnershipForwardHint, self.ownership_forward_hints.items, {}, ownershipHintLessThan);
            const start_orders = try self.gpa.alloc(bool, self.generations.items.len);

            @memset(start_orders, false);
            for (self.generations.items) |generation| {
                std.debug.assert(generation.start_order < start_orders.len);
                std.debug.assert(!start_orders[generation.start_order]);
                start_orders[generation.start_order] = true;
            }
            const origins = try self.gpa.alloc(GenerationOrigin, self.generations.items.len);
            @memset(origins, .none);
            for (self.boundaries.items) |boundary| {
                for (boundary.effects.items) |effect| self.validateEffect(effect, origins);
            }
            for (self.blocks.items, 0..) |block_value, block_index| {
                for (block_value.terminator_effects.items) |effect| self.validateEffect(effect, origins);
                const predecessor: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
                var terminator = block_value.terminator orelse unreachable;
                for (terminator.branches(), 0..) |maybe_branch, ordinal| if (maybe_branch) |branch| {
                    try self.appendOwnershipBranch(predecessor, @intCast(ordinal), branch.*);
                };
            }
            var edge_index: usize = 0;
            for (self.ownership_forward_hints.items) |hint| {
                const key = ownershipEdgeKey(hint.predecessor, hint.successor_ordinal);
                while (edge_index < self.ownership_edges.items.len and
                    ownershipEdgeKey(self.ownership_edges.items[edge_index].predecessor, self.ownership_edges.items[edge_index].successor_ordinal) < key) : (edge_index += 1)
                {}
                std.debug.assert(edge_index < self.ownership_edges.items.len);
                std.debug.assert(self.ownership_edges.items[edge_index].predecessor == hint.predecessor);
                std.debug.assert(self.ownership_edges.items[edge_index].successor_ordinal == hint.successor_ordinal);
            }
            self.validateGenerationOrigins(origins);
        }

        fn analyzeLifetimes(self: *Self, measurements: ?*BodyMeasurements) !void {
            var solver = try LifetimeSolver.init(
                self.gpa,
                self.generations.items,
                self.boundaries.items,
                self.blocks.items,
                self.block_argument_generations.items,
                self.ownership_forwards.items,
                self.ownership_edges.items,
                @fromBackingInt(@intCast(0)),
            );

            try solver.solve(&self.planned_endings);
            if (measurements) |result| result.lifetime_table_bytes = solver.tableBytes();
        }

        fn emitExplicitAbandonmentDiagnostics(self: *Self) !bool {
            for (self.planned_endings.items) |ending| {
                const generation = self.generations.items[@backingInt(ending.generation)];
                if (!generation.requires_explicit_drop) continue;
                try self.ctx.emit(structures.Diagnostic, .{
                    .file_id = self.file_id,
                    .instance = self.instance,
                    .span = generation.span,
                    .kind = .{ .value_requires_explicit_drop = generation.type_id },
                });
                return true;
            }
            return false;
        }

        fn materializeCleanups(self: *Self, cleanups: []const PlannedEnding) !void {
            std.debug.assert(self.current_block == null);
            if (cleanups.len == 0) return;
            const graph = try self.controlFlowGraph();
            const prepared = try self.gpa.alloc(PreparedCleanup, cleanups.len);
            for (cleanups, prepared) |cleanup, *result| {
                result.* = .{ .plan = cleanup, .origins = try self.cleanupOriginsAt(cleanup, graph) };
            }
            const LocationTag = std.meta.Tag(CleanupLocation);
            inline for ([_]LocationTag{ .edge, .boundary }) |location_tag| {
                var cleanup_start: usize = 0;
                while (cleanup_start < cleanups.len) {
                    var cleanup_end = cleanup_start + 1;
                    while (cleanup_end < cleanups.len and std.meta.eql(cleanups[cleanup_start].location, cleanups[cleanup_end].location)) {
                        cleanup_end += 1;
                    }
                    const location_cleanups = prepared[cleanup_start..cleanup_end];
                    if (std.meta.activeTag(location_cleanups[0].plan.location) == location_tag) switch (location_cleanups[0].plan.location) {
                        .boundary => |boundary| {
                            const location = self.findBoundary(boundary);
                            try self.materializeBlockCleanups(location.block, location.item_index + 1, location_cleanups);
                        },
                        .edge => |location| try self.materializeEdgeCleanups(location.predecessor, location.successor_ordinal, location_cleanups),
                    };
                    cleanup_start = cleanup_end;
                }
            }
        }

        const ControlFlowGraph = struct { index: control_flow.Index, edges: []const control_flow.Edge };

        fn controlFlowGraph(self: *Self) !ControlFlowGraph {
            var edges: std.ArrayList(control_flow.Edge) = .empty;
            for (self.blocks.items, 0..) |block_value, predecessor| {
                var terminator = block_value.terminator orelse unreachable;
                for (terminator.successors(), 0..) |target, ordinal| if (target) |successor| {
                    try edges.append(self.gpa, .{ .predecessor = @fromBackingInt(@intCast(predecessor)), .successor = successor.*, .successor_ordinal = @intCast(ordinal) });
                };
            }
            return .{ .index = try control_flow.Index.init(self.gpa, self.blocks.items.len, edges.items), .edges = edges.items };
        }

        fn cleanupOriginsAt(self: *Self, cleanup: PlannedEnding, graph: ControlFlowGraph) !?u32 {
            const latest = self.cleanup_origins.get(cleanup.cleanup_value) orelse return null;
            const Cursor = struct { block: structures.FunctionBlockId, end: usize };
            const start: Cursor = switch (cleanup.location) {
                .boundary => |boundary| blk: {
                    const location = self.findBoundary(boundary);
                    break :blk .{ .block = location.block, .end = location.item_index + 1 };
                },
                .edge => |edge| .{ .block = edge.predecessor, .end = self.blocks.items[@backingInt(edge.predecessor)].items.items.len },
            };
            var worklist: std.ArrayList(Cursor) = .empty;

            try worklist.append(self.gpa, start);
            const visited = try self.gpa.alloc(bool, self.blocks.items.len);

            @memset(visited, false);
            var origins: ?u32 = null;
            cursors: while (worklist.pop()) |cursor| {
                const block_index = @backingInt(cursor.block);
                if (cursor.end == self.blocks.items[block_index].items.items.len) {
                    if (visited[block_index]) continue;
                    visited[block_index] = true;
                }
                // The latest capture before the cursor, or the value's definition, ends this path.
                var candidate: ?u32 = latest;
                while (candidate) |index| {
                    const capture = self.cleanup_captures.items[index];
                    candidate = capture.previous;
                    if (capture.block != cursor.block or self.cleanupCapturePosition(capture) > cursor.end) continue;
                    origins = try self.mergeReferenceOrigins(origins, capture.origins);
                    continue :cursors;
                }
                const instruction_mask: u32 = 1 << 31;
                const representation = @backingInt(cleanup.cleanup_value);
                if (representation & instruction_mask != 0) for (self.blocks.items[block_index].items.items[0..cursor.end]) |item| {
                    if (item == .instruction and item.instruction.id == representation & ~instruction_mask) continue :cursors;
                };
                var incoming = graph.index.blocks[block_index].first_incoming;
                while (incoming) |edge| : (incoming = graph.index.previous_incoming[edge]) {
                    const predecessor = graph.edges[edge].predecessor;
                    try worklist.append(self.gpa, .{ .block = predecessor, .end = self.blocks.items[@backingInt(predecessor)].items.items.len });
                }
            }
            return origins;
        }

        fn cleanupCapturePosition(self: *Self, capture: CleanupCapture) usize {
            if (capture.position == .entry) return 0;
            for (self.blocks.items[@backingInt(capture.block)].items.items, 0..) |item, index| switch (capture.position) {
                .entry => unreachable,
                .instruction => |instruction| if (item == .instruction and item.instruction.id == instruction) return index + 1,
                .boundary => |boundary| if (item == .boundary and item.boundary == boundary) return index + 1,
            };
            unreachable;
        }

        fn materializeBlockCleanups(
            self: *Self,
            block_id: structures.FunctionBlockId,
            suffix_item_start: usize,
            cleanups: []const PreparedCleanup,
        ) !void {
            const suffix = try self.splitCompletedBlock(block_id, suffix_item_start);
            self.resumeBlock(block_id);
            try self.emitCleanupGroup(cleanups);
            self.terminate(.{ .branch = self.emptyBranch(suffix) });
            self.assignBlockLayout(suffix);
        }

        /// Routes an edge through a new block that runs the cleanups and forwards the target's arguments.
        fn materializeEdgeCleanups(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            cleanups: []const PreparedCleanup,
        ) !void {
            const target = self.edgeSuccessor(predecessor, successor_ordinal).*;
            const target_block = self.blocks.items[@backingInt(target)];
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            for (target_block.argument_start..target_block.argument_end) |target_argument| _ = try self.copyBlockArgument(target_argument);
            const argument_end: u32 = @intCast(self.block_arguments.items.len);
            const pass_through = try self.newBlock(argument_start, argument_end);
            const branch_start: u32 = @intCast(self.branch_arguments.items.len);
            for (argument_start..argument_end) |argument| {
                try self.appendBranchArgument(
                    .{ .value = @fromBackingInt(@intCast(argument)) },
                    self.block_argument_generations.items[argument],
                );
            }
            const forward: structures.FunctionBranch = .{
                .target = target,
                .arguments = .{ .start = branch_start, .end = @intCast(self.branch_arguments.items.len) },
            };
            self.edgeSuccessor(predecessor, successor_ordinal).* = pass_through;
            self.enterBlock(pass_through);
            try self.emitCleanupGroup(cleanups);
            self.terminate(.{ .branch = forward });
        }

        fn edgeSuccessor(self: *Self, predecessor: structures.FunctionBlockId, successor_ordinal: u2) *structures.FunctionBlockId {
            return self.blocks.items[@backingInt(predecessor)].terminator.?.successors()[successor_ordinal] orelse unreachable;
        }

        fn emitCleanupGroup(self: *Self, cleanups: []const PreparedCleanup) !void {
            for (cleanups) |cleanup| try self.emitConditionalCleanup(cleanup);
        }

        fn emitConditionalCleanup(self: *Self, prepared: PreparedCleanup) !void {
            const cleanup = prepared.plan;
            const cleanup_condition = cleanup.cleanup_condition orelse return self.emitDropCleanup(prepared);
            const borrowed = try self.newEmptyBlock();
            const owned = try self.newEmptyBlock();
            const join = try self.newEmptyBlock();
            const expected = try self.appendInstruction(.{ .const_bool = true });
            self.branchOn(.eqb, cleanup_condition, expected.id, borrowed, owned);
            self.enterBlock(borrowed);
            self.terminate(.{ .branch = self.emptyBranch(join) });
            self.enterBlock(owned);
            for (self.initializer_transfers.items) |transfer| {
                if (transfer.owner.owned_generation != cleanup.generation or transfer.field == null) continue;
                const path = self.field_places[transfer.field.?].fields;
                for (self.initializer_transfers.items) |ancestor| {
                    if (ancestor.initializer != transfer.initializer or ancestor.local != transfer.local) continue;
                    if (ancestor.field) |field| {
                        const parent = self.field_places[field].fields;
                        if (parent.len >= path.len or !fieldPathContains(parent, path)) continue;
                    }
                    const generation = ancestor.owner.owned_generation orelse continue;
                    const ancestor_predicate = self.generations.items[@backingInt(generation)].cleanup_condition orelse continue;
                    const retained = try self.newEmptyBlock();
                    self.branchOn(.eqb, ancestor_predicate, expected.id, join, retained);
                    self.enterBlock(retained);
                }
            }
            try self.emitDropCleanup(prepared);
            self.terminate(.{ .branch = self.emptyBranch(join) });
            self.enterBlock(join);
        }

        fn emitDropCleanup(self: *Self, prepared: PreparedCleanup) !void {
            const cleanup = prepared.plan;
            const generation = self.generations.items[@backingInt(cleanup.generation)];
            const value_to_drop: Value = .{
                .id = cleanup.cleanup_value,
                .type_id = generation.type_id,
                .reference_origins = prepared.origins,
            };
            if (generation.cleanup_selections.len != 0) {
                try self.dropSelectedValue(value_to_drop, generation.cleanup_selections, generation.missing_fields, generation.cleanup_fields, false, generation.span);
            } else if (generation.cleanup_fields or generation.missing_fields.len != 0)
                try self.dropValueExcluding(value_to_drop, generation.missing_fields, false, generation.span)
            else
                try self.dropValue(value_to_drop, false, generation.span);
        }

        fn dropSelectedValue(self: *Self, source: Value, selections: []const cleanup_shape.Selection, missing: []const []const structures.ReferencePathStep, fields_only: bool, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            if (selections.len == 0 and missing.len == 0 and !fields_only) return self.dropValue(source, can_deinit, span);
            const capabilities = (try self.analysis_context.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (!fields_only and capabilities.drop != .fieldwise) return self.dropValue(source, can_deinit, span);
            if (try self.analysis_context.facts().variantMembers(source.type_id)) |all| {
                const members = cleanup_shape.membersAt(selections, &.{}) orelse all;
                if (members.len == 0) return;
                const tag = try self.appendInstruction(.{ .variant_tag = source.id });
                const join = try self.newEmptyBlock();
                for (members, 0..) |member, index| {
                    const tag_index = std.mem.indexOfScalar(structures.TypeId, all, member).?;
                    const next = try self.enterVariantCase(tag, tag_index, index + 1 == members.len);
                    const specification = try self.analysis_context.facts().memberSpec(member);
                    if (specification.kind == .owned) {
                        var child = try self.projectStorage(source, member, .variant);
                        child.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = member } });
                        const nested = try cleanup_shape.children(self.gpa, selections, .{ .variant = member });
                        const nested_missing = (try cleanup_shape.missingChildren(self.gpa, missing, .{ .variant = member })) orelse &.{};
                        try self.dropSelectedValue(child, nested, nested_missing, false, can_deinit, span);
                    }
                    self.terminate(.{ .branch = self.emptyBranch(join) });
                    if (next) |block_id| self.enterBlock(block_id);
                }
                self.enterBlock(join);
                return;
            }
            const definition = (try self.analysis_context.facts().structDefinition(source.type_id)) orelse return self.dropValue(source, can_deinit, span);
            var index = definition.fields.len;
            while (index > 0) {
                index -= 1;
                const field = definition.fields[index];
                if (field.kind == .reference) continue;
                const nested_missing = (try cleanup_shape.missingChildren(self.gpa, missing, .{ .field = @intCast(index) })) orelse continue;
                var child = try self.projectStorage(source, field.type_id, .{ .field = @intCast(index) });
                child.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .field = @intCast(index) } });
                const nested = try cleanup_shape.children(self.gpa, selections, .{ .field = @intCast(index) });
                try self.dropSelectedValue(child, nested, nested_missing, false, can_deinit, span);
            }
        }

        fn dropValueExcluding(self: *Self, value_to_drop: Value, missing: []const []const structures.ReferencePathStep, can_deinit: bool, span: structures.SourceSpan) !void {
            return self.dropSelectedValue(value_to_drop, &.{}, missing, true, can_deinit, span);
        }

        fn findBoundary(self: *const Self, boundary: BoundaryId) body_graph.Boundary.Location {
            return self.boundaries.items[@backingInt(boundary)].location orelse unreachable;
        }

        fn insertBlockItems(self: *Self, block_id: structures.FunctionBlockId, index: usize, items: []const body_graph.BuildItem) !void {
            try self.blocks.items[@backingInt(block_id)].items.insertSlice(self.gpa, index, items);
            try self.relocateBlockBoundaries(block_id, index);
        }

        fn relocateBlockBoundaries(self: *Self, block_id: structures.FunctionBlockId, start: usize) !void {
            for (self.blocks.items[@backingInt(block_id)].items.items[start..], start..) |item, item_index| switch (item) {
                .instruction => {},
                .boundary => |boundary| self.boundaries.items[@backingInt(boundary)].location = .{
                    .block = block_id,
                    .item_index = std.math.cast(u32, item_index) orelse return error.AnalysisTooLarge,
                },
            };
        }

        fn splitCompletedBlock(self: *Self, block_id: structures.FunctionBlockId, suffix_item_start: usize) !structures.FunctionBlockId {
            const block_index = @backingInt(block_id);
            const original = self.blocks.items[block_index];
            std.debug.assert(original.layout_index != null);
            std.debug.assert(original.terminator != null);
            std.debug.assert(suffix_item_start <= original.items.items.len);
            const suffix = try self.newEmptyBlock();
            const prefix = &self.blocks.items[block_index];
            const moved = &self.blocks.items[@backingInt(suffix)];
            try moved.items.appendSlice(self.gpa, prefix.items.items[suffix_item_start..]);
            prefix.items.shrinkRetainingCapacity(suffix_item_start);
            // The suffix takes over the terminator and the effects published with it.
            moved.terminator_effects = prefix.terminator_effects;
            moved.terminator = prefix.terminator;
            moved.terminator_span = prefix.terminator_span;
            moved.reference_effect = prefix.reference_effect;
            prefix.terminator_effects = .empty;
            prefix.terminator = null;
            prefix.terminator_span = null;
            prefix.reference_effect = null;
            try self.relocateBlockBoundaries(suffix, 0);
            return suffix;
        }

        fn findEffectLocation(self: *const Self, identity: EffectId) EffectLocation {
            if (self.effect_locations.len != 0) return self.effect_locations[@backingInt(identity)] orelse unreachable;
            for (self.boundaries.items, 0..) |boundary, index| {
                for (boundary.effects.items, 0..) |effect, effect_index| {
                    if (effect.id == identity)
                        return .{ .boundary = .{ .id = @fromBackingInt(@intCast(index)), .effect_index = effect_index } };
                }
            }
            for (self.blocks.items, 0..) |block_value, index| {
                for (block_value.terminator_effects.items, 0..) |effect, effect_index| {
                    if (effect.id == identity)
                        return .{ .terminator = .{ .id = @fromBackingInt(@intCast(index)), .effect_index = effect_index } };
                }
            }
            unreachable;
        }

        fn indexEffectLocations(self: *Self) !void {
            self.effect_locations = try self.gpa.alloc(?EffectLocation, self.next_effect_id);
            @memset(self.effect_locations, null);
            for (self.boundaries.items, 0..) |boundary, index| {
                for (boundary.effects.items, 0..) |effect, effect_index| {
                    self.effect_locations[@backingInt(effect.id)] = .{ .boundary = .{ .id = @fromBackingInt(@intCast(index)), .effect_index = effect_index } };
                }
            }
            for (self.blocks.items, 0..) |block_value, index| {
                for (block_value.terminator_effects.items, 0..) |effect, effect_index| {
                    self.effect_locations[@backingInt(effect.id)] = .{ .terminator = .{ .id = @fromBackingInt(@intCast(index)), .effect_index = effect_index } };
                }
            }
        }

        fn validateEffectReferenceUses(self: *Self) !void {
            if (self.reference_effects.count() == 0 or self.reference_uses.items.len == 0) return self.validateReferenceExclusions();
            try self.indexEffectLocations();
            const graph = try self.controlFlowGraph();
            for (self.reference_uses.items) |use| {
                var origins = self.originList(try self.completeReferenceOrigins(use.origins));
                while (origins.next()) |origin| {
                    if (origin.read == null) continue;
                    if (try self.referenceCrossesInvalidation(origin, use.location, graph, null)) return self.reject(use.span, if (use.match_testing) .match_guard_invalidates_subject else if (origin.deferred_capture) .initializer_capture_conflict else .borrow_outlives_source);
                    if (origin.parameter == null) continue;
                    var effects = self.reference_effects.iterator();
                    while (effects.next()) |entry| {
                        const affected = if (origin.deferred_capture or !origin.stable) entry.value_ptr.writes else if (origin.storage_depth != 0) entry.value_ptr.storage_invalidations else null;
                        if (affected == null) continue;
                        var mutations = self.originList(try self.completeReferenceOrigins(affected));
                        if (!try self.referenceCrossesInvalidation(origin, use.location, graph, entry.key_ptr.*)) continue;
                        while (mutations.next()) |mutation| {
                            if (mutation.parameter == null) continue;
                            if (origin.stable and !origin.deferred_capture and origin.storage_depth <= mutation.storage_depth) continue;
                            try self.reference_exclusions.append(self.gpa, .{
                                .reference = try self.addReferenceOrigin(null, origin),
                                .invalidation = try self.addReferenceOrigin(null, mutation),
                                .span = use.span,
                            });
                        }
                    }
                }
            }
            try self.validateReferenceExclusions();
        }

        fn validateReferenceExclusions(self: *Self) !void {
            for (self.reference_exclusions.items) |exclusion| {
                var references = self.originList(try self.completeReferenceOrigins(exclusion.reference));
                const invalidations = try self.completeReferenceOrigins(exclusion.invalidation);
                while (references.next()) |origin| {
                    var mutations = self.originList(invalidations);
                    while (mutations.next()) |mutation| {
                        if (sharesOriginOwner(origin, mutation) and try self.referenceSourcePathsOverlap(origin, mutation))
                            return self.reject(exclusion.span, if (exclusion.match_testing) .match_guard_invalidates_subject else .borrow_outlives_source);
                    }
                }
            }
        }

        fn effectAffectsOrigin(self: *Self, site: ReferenceEffectSite, source: ReferenceOrigin) !bool {
            const effects = self.reference_effects.get(site) orelse return false;
            const affected = if (source.deferred_capture or !source.stable) effects.writes else if (source.storage_depth != 0) effects.storage_invalidations else null;
            var origins = self.originList(try self.completeReferenceOrigins(affected));
            while (origins.next()) |origin| {
                if (source.stable and !source.deferred_capture and source.storage_depth <= origin.storage_depth) continue;
                if (sharesOriginOwner(source, origin) and try self.referenceSourcePathsOverlap(source, origin)) return true;
                if (source.deferred_capture and origin.parameter != null and source.root == null and source.generation == null) {
                    if (source.parameter) |parameter| {
                        std.debug.assert(parameter < self.parameter_modes.items.len);
                        if (self.parameter_modes.items[parameter] == .imm and
                            try self.captureMayShareStorage(self.block_arguments.items[parameter].type_id)) return true;
                    }
                }
            }
            return false;
        }

        fn sharesOriginOwner(first: ReferenceOrigin, second: ReferenceOrigin) bool {
            return (first.root != null and first.root == second.root) or
                (first.generation != null and first.generation == second.generation) or
                (first.parameter != null and first.parameter == second.parameter);
        }

        fn referenceSourcePathsOverlap(self: *Self, first: ReferenceOrigin, second: ReferenceOrigin) !bool {
            var first_path: std.ArrayList(structures.ReferencePathStep) = .empty;
            var second_path: std.ArrayList(structures.ReferencePathStep) = .empty;

            try self.referenceSourcePath(first, &first_path);
            try self.referenceSourcePath(second, &second_path);
            const length = @min(first_path.items.len, second_path.items.len);
            for (first_path.items[0..length], second_path.items[0..length]) |first_step, second_step| {
                if (first_step == .descendants or second_step == .descendants) return true;
                if (!first_step.overlaps(second_step)) return false;
            }
            return true;
        }

        fn referenceCrossesInvalidation(self: *Self, origin: ReferenceOrigin, use: PendingReferenceUseLocation, graph: ControlFlowGraph, selected: ?ReferenceEffectSite) !bool {
            const Cursor = struct { block: structures.FunctionBlockId, end: usize, invalidated: bool = false, include_terminator: bool = false };
            const start: Cursor = switch (self.findEffectLocation(use)) {
                .boundary => |location| blk: {
                    const boundary = self.findBoundary(location.id);
                    break :blk .{ .block = boundary.block, .end = boundary.item_index };
                },
                .terminator => |location| .{ .block = location.id, .end = self.blocks.items[@backingInt(location.id)].items.items.len },
            };
            var worklist: std.ArrayList(Cursor) = .empty;

            try worklist.append(self.gpa, start);
            const visited = try self.gpa.alloc([2]bool, self.blocks.items.len);

            @memset(visited, .{ false, false });
            cursors: while (worklist.pop()) |cursor| {
                const block_index = @backingInt(cursor.block);
                const block_value = self.blocks.items[block_index];
                if (cursor.end == block_value.items.items.len) {
                    if (visited[block_index][@intFromBool(cursor.invalidated)]) continue;
                    visited[block_index][@intFromBool(cursor.invalidated)] = true;
                }
                var invalidated = cursor.invalidated;
                if (cursor.include_terminator) if (block_value.reference_effect) |identity| {
                    invalidated = invalidated or try self.selectedEffectAffectsOrigin(.{ .terminator = identity }, origin, selected);
                };
                var items = std.mem.reverseIterator(block_value.items.items[0..cursor.end]);
                while (items.next()) |item| {
                    if (item != .instruction) continue;
                    if (item.instruction.id == origin.read.?) {
                        if (invalidated) return true;
                        continue :cursors;
                    }
                    invalidated = invalidated or try self.selectedEffectAffectsOrigin(.{ .instruction = item.instruction.id }, origin, selected);
                }
                var incoming = graph.index.blocks[block_index].first_incoming;
                while (incoming) |edge| : (incoming = graph.index.previous_incoming[edge]) {
                    const predecessor = graph.edges[edge].predecessor;
                    try worklist.append(self.gpa, .{ .block = predecessor, .end = self.blocks.items[@backingInt(predecessor)].items.items.len, .invalidated = invalidated, .include_terminator = true });
                }
            }
            return false;
        }

        fn selectedEffectAffectsOrigin(self: *Self, site: ReferenceEffectSite, origin: ReferenceOrigin, selected: ?ReferenceEffectSite) !bool {
            if (selected) |candidate| return std.meta.eql(site, candidate);
            return self.effectAffectsOrigin(site, origin);
        }

        /// Every generation starts at a definition or an ownership join.
        fn validateGenerationOrigins(self: *Self, origins: []GenerationOrigin) void {
            for (self.ownership_forwards.items) |mapping| {
                if (mapping.source == null) continue;
                const origin = &origins[@backingInt(mapping.destination)];
                if (origin.* == .none) origin.* = .phi else std.debug.assert(origin.* == .phi);
            }
            for (origins) |origin| std.debug.assert(origin != .none);
        }

        fn markGenerationOrigin(origins: []GenerationOrigin, generation: GenerationId, origin: GenerationOrigin) void {
            const existing = &origins[@backingInt(generation)];
            std.debug.assert(existing.* == .none);
            existing.* = origin;
        }

        fn validateEffect(self: *const Self, effect: body_graph.Effect, origins: []GenerationOrigin) void {
            const operation = effect.operation orelse return;
            const generation = switch (operation) {
                .define => |definition| definition.generation,
                .use, .update => |use| use.generation,
                .consume => |consumed| consumed,
            };
            std.debug.assert(@backingInt(generation) < self.generations.items.len);
            if (operation == .define) markGenerationOrigin(origins, generation, .define);
        }

        fn appendOwnershipBranch(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            branch: structures.FunctionBranch,
        ) !void {
            const target = self.blocks.items[@backingInt(branch.target)];
            const argument_count = branch.arguments.end - branch.arguments.start;
            std.debug.assert(argument_count == target.argument_end - target.argument_start);
            const mapping_start: u32 = @intCast(self.ownership_forwards.items.len);
            for (branch.arguments.start..branch.arguments.end, target.argument_start..) |source_index, destination_index| {
                const destination = self.block_argument_generations.items[destination_index] orelse continue;
                const source = self.branch_argument_generations.items[source_index];
                if (source != destination) try self.ownership_forwards.append(self.gpa, .{ .source = source, .destination = destination });
            }
            for (self.ownershipHints(predecessor, successor_ordinal)) |hint| {
                try self.ownership_forwards.append(self.gpa, .{ .source = hint.source, .destination = hint.destination });
            }
            try self.ownership_edges.append(self.gpa, .{
                .predecessor = predecessor,
                .successor_ordinal = successor_ordinal,
                .successor = branch.target,
                .mappings = .{ .start = mapping_start, .end = @intCast(self.ownership_forwards.items.len) },
            });
        }

        fn recordGenerationOnlyForward(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            source: ?GenerationId,
            destination: GenerationId,
        ) !void {
            if (source == destination) return;
            try self.ownership_forward_hints.append(self.gpa, .{
                .predecessor = predecessor,
                .successor_ordinal = successor_ordinal,
                .source = source,
                .destination = destination,
            });
        }

        fn ownershipEdgeKey(predecessor: structures.FunctionBlockId, ordinal: u2) u64 {
            return (@as(u64, @backingInt(predecessor)) << 2) | ordinal;
        }

        fn ownershipHintLessThan(_: void, left: OwnershipForwardHint, right: OwnershipForwardHint) bool {
            return ownershipEdgeKey(left.predecessor, left.successor_ordinal) < ownershipEdgeKey(right.predecessor, right.successor_ordinal);
        }

        fn ownershipHints(self: *const Self, predecessor: structures.FunctionBlockId, ordinal: u2) []const OwnershipForwardHint {
            const hints = self.ownership_forward_hints.items;
            const start, const end = std.sort.equalRange(OwnershipForwardHint, hints, ownershipEdgeKey(predecessor, ordinal), struct {
                fn order(key: u64, hint: OwnershipForwardHint) std.math.Order {
                    return std.math.order(key, ownershipEdgeKey(hint.predecessor, hint.successor_ordinal));
                }
            }.order);
            return hints[start..end];
        }

        const BoundaryScope = struct { boundary: BoundaryId, parent: ?BoundaryId };

        /// Makes a new boundary current; the caller restores `parent` and appends `boundary` once its effects are recorded.
        fn openBoundary(self: *Self, span: structures.SourceSpan) !BoundaryScope {
            const scope: BoundaryScope = .{ .boundary = try self.newBoundary(span), .parent = self.current_boundary };
            self.current_boundary = scope.boundary;
            return scope;
        }

        fn newBoundary(self: *Self, span: structures.SourceSpan) !BoundaryId {
            const id: BoundaryId = @fromBackingInt(@intCast(self.boundaries.items.len));
            try self.boundaries.append(self.gpa, .{ .span = span });
            return id;
        }

        fn closeBoundary(self: *Self, boundary: BoundaryId) !void {
            std.debug.assert(self.current_block != null);
            if (self.boundaries.items[@backingInt(boundary)].effects.items.len == 0) return;
            return self.appendBoundary(boundary);
        }

        fn appendBoundary(self: *Self, boundary: BoundaryId) !void {
            std.debug.assert(self.current_block != null);
            const block_id = self.current_block.?;
            const item_index = std.math.cast(u32, self.blocks.items[@backingInt(block_id)].items.items.len) orelse return error.AnalysisTooLarge;
            std.debug.assert(self.boundaries.items[@backingInt(boundary)].location == null);
            try self.blocks.items[@backingInt(block_id)].items.append(self.gpa, .{ .boundary = boundary });
            self.boundaries.items[@backingInt(boundary)].location = .{ .block = block_id, .item_index = item_index };
        }

        fn newEmptyBlock(self: *Self) !structures.FunctionBlockId {
            const end: u32 = @intCast(self.block_arguments.items.len);
            return self.newBlock(end, end);
        }

        fn newBlock(self: *Self, argument_start: u32, argument_end: u32) !structures.FunctionBlockId {
            std.debug.assert(self.block_arguments.items.len == self.block_argument_generations.items.len);
            const id: structures.FunctionBlockId = @fromBackingInt(@intCast(self.blocks.items.len));
            try self.blocks.append(self.gpa, .{
                .argument_start = argument_start,
                .argument_end = argument_end,
            });
            return id;
        }

        fn enterBlock(self: *Self, block_id: structures.FunctionBlockId) void {
            std.debug.assert(self.current_block == null);
            self.assignBlockLayout(block_id);
            self.current_block = block_id;
        }

        fn enterPendingBlock(self: *Self, block_id: structures.FunctionBlockId) void {
            if (self.blocks.items[@backingInt(block_id)].layout_index == null)
                self.enterBlock(block_id)
            else
                self.resumeBlock(block_id);
        }

        fn assignBlockLayout(self: *Self, block_id: structures.FunctionBlockId) void {
            const block_value = &self.blocks.items[@backingInt(block_id)];
            std.debug.assert(block_value.layout_index == null);
            block_value.layout_index = self.block_layout_count;
            self.block_layout_count += 1;
        }

        fn resumeBlock(self: *Self, block_id: structures.FunctionBlockId) void {
            std.debug.assert(self.current_block == null);
            const block_value = self.blocks.items[@backingInt(block_id)];
            std.debug.assert(block_value.layout_index != null);
            std.debug.assert(block_value.terminator == null);
            self.current_block = block_id;
        }

        fn terminate(self: *Self, terminator: structures.FunctionTerminator) void {
            self.setBlockTerminator(self.suspendBlock(), terminator);
        }

        fn suspendBlock(self: *Self) structures.FunctionBlockId {
            const block_id = self.current_block.?;
            self.current_block = null;
            return block_id;
        }

        fn setBlockTerminator(self: *Self, block_id: structures.FunctionBlockId, terminator: structures.FunctionTerminator) void {
            const block_value = &self.blocks.items[@backingInt(block_id)];
            std.debug.assert(block_value.terminator == null);
            std.debug.assert(block_value.terminator_span == null);
            block_value.terminator = terminator;
            block_value.terminator_span = if (self.options.publish_instruction_spans)
                self.activeLifetimeSpan()
            else
                .{ .start = 0, .end = 0 };
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
        }

        fn branchOn(self: *Self, operation: structures.PredicateOperation, lhs: structures.FunctionValueId, rhs: structures.FunctionValueId, matched: structures.FunctionBlockId, unmatched: structures.FunctionBlockId) void {
            self.terminate(.{ .predicate_branch = .{
                .operation = operation,
                .operands = .{ .lhs = lhs, .rhs = rhs },
                .then_branch = self.emptyBranch(matched),
                .else_branch = self.emptyBranch(unmatched),
            } });
        }

        fn finish(self: *Self, retained_captures: ?*std.ArrayList(u32)) !structures.FunctionBodyAnalysis {
            var phase: profiling.Scope = .{};
            phase.beginCurrent(.body_freeze);
            defer phase.end();
            std.debug.assert(self.current_block == null);
            std.debug.assert(self.block_arguments.items.len == self.block_argument_generations.items.len);
            std.debug.assert(self.branch_arguments.items.len == self.branch_argument_generations.items.len);
            const gpa = self.gpa;
            const instruction_values = try gpa.alloc(structures.FunctionValueId, self.instruction_count);
            const block_layout = try gpa.alloc(structures.FunctionBlockId, self.blocks.items.len);

            std.debug.assert(self.block_layout_count == self.blocks.items.len);
            for (self.blocks.items, 0..) |block_value, block_index| {
                const layout_index = block_value.layout_index orelse unreachable;
                block_layout[layout_index] = @fromBackingInt(@intCast(block_index));
            }
            var body: structures.FunctionBodyAnalysis = .{
                .return_type = self.return_type,
                .is_initializer_region = self.is_initializer_region,
                .entry = @fromBackingInt(0),
            };

            const instructions = try gpa.alloc(structures.FunctionInstruction, self.instruction_count);
            body.instructions = instructions;
            const instruction_spans = try gpa.alloc(
                structures.SourceSpan,
                if (self.options.publish_instruction_spans) self.instruction_count else 0,
            );
            body.instruction_spans = instruction_spans;
            const terminator_spans = try gpa.alloc(
                structures.SourceSpan,
                if (self.options.publish_instruction_spans) self.blocks.items.len else 0,
            );
            body.terminator_spans = terminator_spans;
            const blocks = try gpa.alloc(structures.FunctionBlock, self.blocks.items.len);
            body.blocks = blocks;
            var instruction_index: u32 = 0;
            for (block_layout) |block_id| {
                const block_index = @backingInt(block_id);
                const build_block = self.blocks.items[block_index];
                const instruction_start = instruction_index;
                for (build_block.items.items) |item| switch (item) {
                    .instruction => |build_instruction| {
                        instructions[instruction_index] = build_instruction.operation;
                        if (self.options.publish_instruction_spans) instruction_spans[instruction_index] = build_instruction.span;
                        instruction_values[build_instruction.id] = @fromBackingInt(@intCast(instruction_index));
                        instruction_index += 1;
                    },
                    .boundary => {},
                };
                blocks[block_index] = .{
                    .argument_start = build_block.argument_start,
                    .argument_end = build_block.argument_end,
                    .instruction_start = instruction_start,
                    .instruction_end = instruction_index,
                    .terminator = build_block.terminator orelse unreachable,
                };
                if (self.options.publish_instruction_spans) terminator_spans[block_index] = build_block.terminator_span orelse unreachable;
            }
            std.debug.assert(instruction_index == self.instruction_count);
            const view: structures.FunctionBodyFinalization = .{
                .instructions = instructions,
                .blocks = blocks,
                .call_arguments = self.call_arguments.items,
                .branch_arguments = self.branch_arguments.items,
                .initializer_captures = self.initializer_captures.items,
            };
            const capture_count = if (retained_captures != null) blocks[0].argument_end else 0;
            const capture_mapping = try gpa.alloc(?u32, capture_count);

            @memset(capture_mapping, null);
            var removed: u32 = 0;
            if (retained_captures) |kept| {
                std.debug.assert(self.is_initializer_region);
                std.debug.assert(blocks[0].argument_start == 0);
                // Only actual reads capture caller storage; unused captures must
                // not extend caller lifetimes or change observable drop ordering.
                view.visitValueReferences(capture_mapping, markCaptureUsed);
                for (capture_mapping, 0..) |*mapped, old| if (mapped.* != null) {
                    mapped.* = @intCast(kept.items.len);
                    try kept.append(gpa, @intCast(old));
                    self.block_arguments.items[mapped.*.?] = self.block_arguments.items[old];
                    self.parameter_modes.items[mapped.*.?] = self.parameter_modes.items[old];
                };
                removed = capture_count - @as(u32, @intCast(kept.items.len));
                std.mem.copyForwards(structures.FunctionBlockArgument, self.block_arguments.items[kept.items.len..], self.block_arguments.items[capture_count..]);
                self.block_arguments.shrinkRetainingCapacity(self.block_arguments.items.len - removed);
                self.parameter_modes.shrinkRetainingCapacity(kept.items.len);
                for (blocks, 0..) |*finished_block, index| {
                    if (index != 0) finished_block.argument_start -= removed;
                    finished_block.argument_end -= removed;
                }
            }
            const argument_count: u32 = @intCast(std.math.cast(u31, self.block_arguments.items.len) orelse return error.AnalysisTooLarge);
            view.visitValueReferences(.{ .instructions = instruction_values, .argument_count = argument_count, .captures = capture_mapping, .removed = removed }, normalizeValueReference);
            body.block_arguments = self.block_arguments.items;
            body.parameter_modes = self.parameter_modes.items;
            body.variant_coercion_tags = self.variant_coercion_tags.items;
            body.borrow_fields = self.borrow_fields.items;
            body.call_arguments = self.call_arguments.items;
            body.initializer_regions = self.initializer_regions.items;
            body.initializer_captures = self.initializer_captures.items;
            body.branch_arguments = self.branch_arguments.items;
            return body;
        }
    };
}

fn markCaptureUsed(mapping: []?u32, value: *structures.FunctionValueId) void {
    const raw = @backingInt(value.*);
    if (raw < mapping.len) mapping[raw] = 0;
}

fn normalizeValueReference(mapping: anytype, value: *structures.FunctionValueId) void {
    const instruction_mask: u32 = 1 << 31;
    const raw = @backingInt(value.*);
    value.* = @fromBackingInt(if (raw & instruction_mask != 0)
        mapping.argument_count + @backingInt(mapping.instructions[raw & ~instruction_mask])
    else if (raw < mapping.captures.len)
        mapping.captures[raw].?
    else
        raw - mapping.removed);
}

fn includesType(container: structures.TypeId, members: ?[]const structures.TypeId, member: structures.TypeId) bool {
    return container == member or if (members) |variant_members| containsType(variant_members, member) else false;
}

fn joinTypes(analysis_context: anytype, left: structures.TypeId, right: structures.TypeId, gpa: std.mem.Allocator) !structures.TypeId {
    if (left == .never) return right;
    if (right == .never) return left;
    if (left == right) return left;
    if (try semantic.canWidenTo(analysis_context, left, right)) return right;
    if (try semantic.canWidenTo(analysis_context, right, left)) return left;

    const left_members = (try analysis_context.facts().variantMembers(left)) orelse &.{left};
    const right_members = (try analysis_context.facts().variantMembers(right)) orelse &.{right};
    var members: std.ArrayList(structures.TypeId) = .empty;
    defer members.deinit(gpa);
    try members.appendSlice(gpa, left_members);
    // Shared members are one inferred alternative, not duplicate source syntax.
    for (right_members) |member| {
        if (!containsType(left_members, member)) try members.append(gpa, member);
    }
    return (try analysis_context.facts().internVariant(members.items)).type_id;
}

fn containsType(types: []const structures.TypeId, needle: structures.TypeId) bool {
    return std.mem.indexOfScalar(structures.TypeId, types, needle) != null;
}

const TestMaterializerContext = struct {
    gpa: std.mem.Allocator,
    scratch: ?std.heap.ArenaAllocator = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        if (self.scratch == null) self.scratch = .init(self.gpa);
        return self.scratch.?.allocator();
    }

    fn deinit(self: *@This()) void {
        if (self.scratch) |*scratch| scratch.deinit();
    }

    fn emit(_: *@This(), comptime Accumulator: type, _: Accumulator) !void {
        unreachable;
    }
};

const TestMaterializerTypes = struct {
    pub fn fieldStorageType(_: @This(), field: structures.StructField) !structures.TypeId {
        std.debug.assert(field.kind == .owned);
        return field.type_id;
    }

    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn arrayType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
        return null;
    }

    pub fn collectionSequenceElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }
    pub fn isCollectionConstructionType(_: @This(), _: structures.TypeId) !bool {
        return false;
    }
    pub fn initializerConstruction(_: @This(), type_id: structures.TypeId) !structures.InitializerConstruction {
        return .{ .type_id = type_id };
    }

    pub fn collectionLiteralType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
        return null;
    }

    pub fn argumentPassing(self: @This(), type_id: structures.TypeId) !structures.ArgumentPassing {
        const capabilities = (try self.ownershipCapabilities(type_id)).?;
        return if (capabilities.isDirectlyMovable()) .direct else .indirect;
    }

    pub fn borrowElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn borrowAccess(_: @This(), _: structures.TypeId) !?struct { element_type: structures.TypeId, writable: bool } {
        return null;
    }

    pub fn storageAccess(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn boxElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn allocationElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn canStoreBorrow(_: @This(), _: structures.TypeId) !bool {
        return false;
    }

    pub fn functionReferenceContract(_: @This(), _: structures.InstanceId) !?structures.ReferenceContract {
        return .{};
    }

    pub fn inlineBuiltin(_: @This(), _: structures.ItemId) !?BuiltinBody {
        return null;
    }

    pub fn canBorrowInlineStorageOf(_: @This(), _: structures.TypeId, _: structures.TypeId) !bool {
        return false;
    }

    const custom_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(0)));
    const variant_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(1)));
    const second_custom_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(2)));
    const custom_drop_hook: structures.ItemId = @fromBackingInt(@intCast(1));
    const second_custom_drop_hook: structures.ItemId = @fromBackingInt(@intCast(2));
    const span: structures.SourceSpan = .{ .start = 0, .end = 0 };
    const variant_members = [_]structures.TypeId{ custom_type, .int };

    pub fn ownershipCapabilities(_: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
        if (type_id == custom_type or type_id == second_custom_type or type_id == variant_type) return .{
            .move = .none,
            .copy = .none,
            .drop = if (type_id == variant_type) .fieldwise else .custom,
            .needs_automatic_drop = true,
        };
        return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    }

    pub fn structDefinition(_: @This(), type_id: structures.TypeId) !?*const structures.StructDefinition {
        inline for (.{ custom_type, second_custom_type }, .{ custom_drop_hook, second_custom_drop_hook }) |candidate, hook| {
            if (type_id == candidate) return &.{
                .fields = &.{},
                .ownership = .{ .drop = .{
                    .capability = .custom,
                    .hook = .{ .item = hook },
                    .span = span,
                } },
            };
        }
        return null;
    }

    pub fn variantMembers(_: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
        return if (type_id == variant_type) &variant_members else null;
    }

    pub fn memberSpec(_: @This(), type_id: structures.TypeId) !structures.MemberSpec {
        return .{ .type_id = type_id };
    }

    pub fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }
};

const TestMaterializerBuilder = BodyBuilder(*TestMaterializerContext, TestMaterializerTypes);

fn testInitMaterializerBuilder(context: *TestMaterializerContext) TestMaterializerBuilder {
    return .{
        .ctx = context,
        .gpa = context.allocator(),
        .analysis_context = .{},
        .instance = .{ .item = @fromBackingInt(@intCast(0)) },
        .file_id = 1,
        .unresolved = .{
            .parameter_count = 0,
            .parameter_spans = &.{},
            .local_count = 0,
            .expressions = &.{},
            .conditions = &.{},
            .blocks = &.{},
            .statements = &.{},
            .method_call_arguments = &.{},
            .struct_field_values = &.{},
            .assignment_fields = &.{},
            .root_block = @fromBackingInt(@intCast(0)),
        },
        .return_type = .unit,
    };
}

fn testAppendMaterializerGeneration(
    builder: *TestMaterializerBuilder,
    type_id: structures.TypeId,
    start_order: u32,
) !GenerationId {
    const generation: GenerationId = @fromBackingInt(@intCast(builder.generations.items.len));
    try builder.generations.append(builder.ctx.allocator(), .{
        .type_id = type_id,
        .start_order = start_order,
        .span = TestMaterializerTypes.span,
        .requires_explicit_drop = false,
        .cleanup_fields = false,
    });
    return generation;
}

const TestMeasureBody = struct {
    const queries = @import("../queries.zig");
    pub const Input = structures.ItemId;
    pub const Output = BodyMeasurements;

    pub fn run(ctx: anytype, item: Input) !Output {
        const signature = (try ctx.get(queries.FunctionSignature, item)).*.?;
        const resolved = (try ctx.get(queries.ResolveItem, item)).*.?;
        const parsed = (try ctx.get(queries.ParseFile, resolved.file_id)).*.?;
        const source = (try ctx.input(queries.SourceText, resolved.file_id)).*;
        const instance: structures.InstanceId = .{ .item = item };
        const analysis: queries.AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = resolved.file_id,
            .instance = instance,
        };
        var unresolved = switch (try semantic.analyzer(&parsed, source, analysis, ctx.allocator()).buildUnresolvedBody(.{ .function = .{ .declaration = resolved.declaration, .parameters = signature.parameters } })) {
            .success => |body| body,
            .unsupported => return error.TestUnexpectedResult,
        };
        defer unresolved.deinit(ctx.allocator());
        var measurements: BodyMeasurements = .{};
        var body = (try resolveAndTypeBody(ctx, instance, resolved.file_id, signature.parameters, signature.return_type, .{ .measurements = &measurements }, analysis, unresolved)) orelse return error.TestUnexpectedResult;
        defer body.deinit(ctx.allocator());
        return measurements;
    }
};

test "expression value pages isolate branch results without allocating untouched slots" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    builder.values = @TypeOf(builder.values).init(4097);
    try std.testing.expectEqual(@as(?TestMaterializerBuilder.Value, null), builder.values.get(2048));
    try builder.values.set(context.allocator(), 4096, .{ .id = @fromBackingInt(1), .type_id = .int });
    var seen: std.AutoHashMap(usize, void) = .init(std.testing.allocator);
    defer seen.deinit();
    try std.testing.expect(try builder.values.retainedBytes(&seen) < 8192);
    const saved = builder.values.snapshot();
    try builder.values.set(context.allocator(), 4096, .{ .id = @fromBackingInt(2), .type_id = .int });
    try builder.values.set(context.allocator(), 0, .{ .id = @fromBackingInt(3), .type_id = .bool });
    builder.values = saved.snapshot();
    try std.testing.expectEqual(@as(u32, 1), @backingInt(builder.values.get(4096).?.id));
    try std.testing.expectEqual(@as(?TestMaterializerBuilder.Value, null), builder.values.get(0));
}

test "inference and initializer captures exclude unrelated live state" {
    const queries = @import("../queries.zig");
    const allocator = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll("func materialize(init value: int) int -> value\n");
    for ([_][]const u8{ "small", "large" }, [_]usize{ 0, 32 }) |name, unused_count| {
        try source.writer.print("func {s}() int\n    var selected = 41\n", .{name});
        for (0..unused_count) |index| try source.writer.print("    var unused_{d} = {d}\n", .{ index, index });
        try source.writer.writeAll("    const result = materialize(selected + 1)\n    return result\n");
    }
    const db = try @import("../query/engine.zig").Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    try @import("../modules.zig").registerSources(db, allocator, source.written(), &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const small = (try db.get(TestMeasureBody, scope.resolveFunction("small").?)).*;
    const large = (try db.get(TestMeasureBody, scope.resolveFunction("large").?)).*;
    try std.testing.expect(small.type_only_regions > 0);
    try std.testing.expect(small.inference_capture_values > 0);
    try std.testing.expectEqual(small.inference_capture_values, large.inference_capture_values);
    try std.testing.expect(small.initializer_capture_values > 0);
    try std.testing.expectEqual(small.initializer_capture_values, large.initializer_capture_values);
}

test "initializer captures reserve their complete entry argument range" {
    const queries = @import("../queries.zig");
    const allocator = std.testing.allocator;
    const db = try @import("../query/engine.zig").Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    try @import("../modules.zig").registerSources(db, allocator,
        \\struct Cell
        \\    value: int
        \\func materialize(init value: Cell) Cell -> value
        \\func probe(imm seed: Cell, mut output: int) int | none
        \\    var first = Cell{value = 20 + seed.value}
        \\    var second = Cell{value = 22}
        \\    const result: Cell = materialize(materialize(Cell{value = first.value + second.value}))
        \\    output = result.value
        \\    return output
        \\var output = 0
        \\const result = probe(Cell{value = 0}, output)
        \\if result is int -> exit(result) else exit(99)
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const measured = (try db.get(TestMeasureBody, scope.resolveFunction("probe").?)).*;
    try std.testing.expect(measured.type_only_regions > 1);
    try std.testing.expectEqual(@as(usize, 0), measured.region_capture_buffer_growths);
    try std.testing.expect((try db.get(queries.BuildExecutable, 0)).* != null);
}

test "ordinary optional arguments add no exit snapshots" {
    const queries = @import("../queries.zig");
    const allocator = std.testing.allocator;
    const db = try @import("../query/engine.zig").Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try @import("../modules.zig").registerSources(db, allocator,
        \\func empty() int -> 42
        \\func ordinary(first: int, second: int, third: int, fourth: int, fifth: int, sixth: int, seventh: int, eighth: int) int -> 42
        \\func captured(first: int | none, second: int | none, third: int | none, fourth: int | none, fifth: int | none, sixth: int | none, seventh: int | none, eighth: int | none) int -> 42
        \\func probe_empty() int -> empty()
        \\func probe_ordinary() int -> ordinary(1, 2, 3, 4, 5, 6, 7, 8)
        \\func probe_captured() int -> captured(1, 2, 3, 4, 5, 6, 7, 8)
        \\func produce(value: int) int | none
        \\    if not (value > 0) -> return none
        \\    return value
        \\func probe_optional() int -> captured(produce(1), 2, 3, 4, 5, 6, 7, 8)
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const empty = (try db.get(TestMeasureBody, scope.resolveFunction("probe_empty").?)).*;
    const ordinary = (try db.get(TestMeasureBody, scope.resolveFunction("probe_ordinary").?)).*;
    const captured = (try db.get(TestMeasureBody, scope.resolveFunction("probe_captured").?)).*;
    const optional = (try db.get(TestMeasureBody, scope.resolveFunction("probe_optional").?)).*;
    try std.testing.expectEqual(empty.snapshots, ordinary.snapshots);
    try std.testing.expectEqual(ordinary.snapshots, captured.snapshots);
    try std.testing.expectEqual(captured.snapshots, optional.snapshots);
}

test "overload argument discovery is independent of candidate count" {
    const queries = @import("../queries.zig");
    const allocator = std.testing.allocator;
    const db = try @import("../query/engine.zig").Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try @import("../modules.zig").registerSources(db, allocator,
        \\struct Leaf
        \\    value: int
        \\struct Middle
        \\    value: Leaf
        \\struct Outer
        \\    value: Middle
        \\func absent(value: none) int -> 0
        \\func boolean(value: bool) int -> 0
        \\func octet(value: byte) int -> 0
        \\func integer(value: int) int -> value
        \\overload one(integer)
        \\overload many(absent, boolean, octet, integer)
        \\func probe_shallow_one(imm source: Leaf) int -> one(source.value)
        \\func probe_shallow_many(imm source: Leaf) int -> many(source.value)
        \\func probe_deep_one(imm source: Outer) int -> one(source.value.value.value)
        \\func probe_deep_many(imm source: Outer) int -> many(source.value.value.value)
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const shallow_one = (try db.get(TestMeasureBody, scope.resolveFunction("probe_shallow_one").?)).*;
    const shallow_many = (try db.get(TestMeasureBody, scope.resolveFunction("probe_shallow_many").?)).*;
    const deep_one = (try db.get(TestMeasureBody, scope.resolveFunction("probe_deep_one").?)).*;
    const deep_many = (try db.get(TestMeasureBody, scope.resolveFunction("probe_deep_many").?)).*;
    try std.testing.expect(shallow_one.overload_argument_discoveries != 0);
    try std.testing.expectEqual(shallow_one.overload_argument_discoveries, shallow_many.overload_argument_discoveries);
    try std.testing.expectEqual(deep_one.overload_argument_discoveries, deep_many.overload_argument_discoveries);
    try std.testing.expectEqual(shallow_one.unevaluated_type_visits, shallow_many.unevaluated_type_visits);
    try std.testing.expectEqual(deep_one.unevaluated_type_visits, deep_many.unevaluated_type_visits);
    try std.testing.expect(deep_one.unevaluated_type_visits > shallow_one.unevaluated_type_visits);
}

test "expression boundaries omit empty markers and retain effect checkpoints" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const empty = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.closeBoundary(empty);
    try std.testing.expectEqual(@as(usize, 0), builder.blocks.items[@backingInt(entry)].items.items.len);
    try std.testing.expect(builder.boundaries.items[@backingInt(empty)].location == null);
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    const checkpoint = try builder.appendEffectAt(boundary, null);
    try builder.closeBoundary(boundary);
    try std.testing.expectEqual(@as(usize, 1), builder.blocks.items[@backingInt(entry)].items.items.len);
    try std.testing.expectEqual(boundary, builder.blocks.items[@backingInt(entry)].items.items[0].boundary);
    try std.testing.expectEqual(checkpoint, builder.boundaries.items[@backingInt(boundary)].effects.items[0].id);
    try std.testing.expectEqual(entry, builder.findBoundary(boundary).block);
}

test "cleanup materializer preserves effect identities across moves and repeated splits" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    builder.current_boundary = boundary;
    const checkpoint = try builder.appendEffect(null);
    try builder.moveCurrentBoundaryEffectsToTerminator();
    builder.current_boundary = null;
    try builder.appendBoundary(boundary);
    try std.testing.expectEqual(entry, builder.findEffectLocation(checkpoint).terminator.id);
    const effect_site = try builder.terminatorEffectSite(entry);
    try builder.recordReferenceEffects(effect_site, .{ .writes = 0 });
    try builder.reference_uses.append(builder.gpa, .{ .origins = 0, .span = TestMaterializerTypes.span, .location = checkpoint });
    try builder.pending_reference_uses.append(builder.gpa, .{
        .kind = .retention,
        .origins = 0,
        .state = @fromBackingInt(0),
        .span = TestMaterializerTypes.span,
        .location = checkpoint,
    });

    try builder.finishFunctionExit(TestMaterializerTypes.span, .return_unit);
    const moved_boundary = builder.findEffectLocation(checkpoint).boundary.id;
    const first_suffix = try builder.splitCompletedBlock(entry, 0);
    builder.assignBlockLayout(first_suffix);
    const second_suffix = try builder.splitCompletedBlock(first_suffix, 0);
    try std.testing.expectEqual(second_suffix, builder.findBoundary(moved_boundary).block);
    try std.testing.expectEqual(effect_site.terminator, builder.blocks.items[@backingInt(second_suffix)].reference_effect.?);
    try std.testing.expect(builder.blocks.items[@backingInt(entry)].reference_effect == null);
    try std.testing.expect(builder.blocks.items[@backingInt(first_suffix)].reference_effect == null);
    try std.testing.expectEqual(@as(usize, 1), builder.reference_effects.count());
    try std.testing.expectEqual(@as(?u32, 0), builder.reference_effects.get(effect_site).?.writes);
    try std.testing.expectEqual(checkpoint, builder.reference_uses.items[0].location);
    try std.testing.expectEqual(checkpoint, builder.pending_reference_uses.items[0].location);
    try builder.indexEffectLocations();
    try std.testing.expectEqual(moved_boundary, builder.findEffectLocation(checkpoint).boundary.id);
}

test "cleanup materializer inserts ordered custom drops at an interior boundary" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const first = try builder.appendInstruction(.{ .const_int = 40 });
    const second = try builder.appendInstruction(.{ .const_int = 41 });
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(boundary);
    _ = try builder.appendInstruction(.{ .const_int = 42 });
    builder.terminate(.return_unit);
    const first_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);
    const second_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.second_custom_type, 1);

    try builder.materializeCleanups(&.{
        .{
            .generation = second_generation,
            .cleanup_value = second.id,
            .location = .{ .boundary = boundary },
        },
        .{
            .generation = first_generation,
            .cleanup_value = first.id,
            .location = .{ .boundary = boundary },
        },
    });

    const body = try builder.finish(null);
    try std.testing.expectEqual(@as(usize, 2), body.blocks.len);
    try std.testing.expectEqual(@as(usize, 5), body.instructions.len);
    try std.testing.expectEqual(structures.FunctionInstruction.const_int, std.meta.activeTag(body.instructions[0]));
    try std.testing.expectEqual(structures.FunctionInstruction.const_int, std.meta.activeTag(body.instructions[1]));
    try std.testing.expectEqual(TestMaterializerTypes.second_custom_drop_hook, body.instructions[2].call.target.direct.item);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[3].call.target.direct.item);
    try std.testing.expectEqual(structures.FunctionInstruction.const_int, std.meta.activeTag(body.instructions[4]));
    try std.testing.expectEqual(@as(structures.FunctionBlockId, @fromBackingInt(@intCast(1))), body.blocks[@backingInt(entry)].terminator.branch.target);
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[1].terminator);
}

test "cleanup materializer finds shifted boundaries after earlier splits" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const first = try builder.appendInstruction(.{ .const_int = 40 });
    const first_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(first_boundary);
    const second = try builder.appendInstruction(.{ .const_int = 41 });
    const second_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(second_boundary);
    _ = try builder.appendInstruction(.{ .const_int = 42 });
    const third_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(third_boundary);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const allocator = builder.gpa;
        builder.gpa = failing.allocator();
        defer builder.gpa = allocator;
        try std.testing.expectEqual(@as(usize, 5), builder.findBoundary(third_boundary).item_index);
    }
    try std.testing.expectEqual(@as(usize, 5), builder.findBoundary(third_boundary).item_index);
    const fourth_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(fourth_boundary);
    _ = try builder.appendInstruction(.{ .const_bool = false });
    const initialization = builder.blocks.items[@backingInt(entry)].items.pop().?;
    try builder.insertBlockItems(entry, 0, &.{initialization});
    builder.terminate(.return_unit);
    const first_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);
    const second_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.second_custom_type, 1);

    try std.testing.expectEqual(entry, builder.findBoundary(third_boundary).block);
    try std.testing.expectEqual(@as(usize, 6), builder.findBoundary(third_boundary).item_index);

    try builder.materializeCleanups(&.{
        .{
            .generation = first_generation,
            .cleanup_value = first.id,
            .location = .{ .boundary = first_boundary },
        },
        .{
            .generation = second_generation,
            .cleanup_value = second.id,
            .location = .{ .boundary = second_boundary },
        },
    });

    const first_location = builder.findBoundary(first_boundary);
    const second_location = builder.findBoundary(second_boundary);
    const third_location = builder.findBoundary(third_boundary);
    const fourth_location = builder.findBoundary(fourth_boundary);
    try std.testing.expectEqual(entry, first_location.block);
    try std.testing.expectEqual(@as(usize, 2), first_location.item_index);
    try std.testing.expectEqual(builder.blocks.items[@backingInt(entry)].terminator.?.branch.target, second_location.block);
    try std.testing.expectEqual(@as(usize, 1), second_location.item_index);
    try std.testing.expectEqual(builder.blocks.items[@backingInt(second_location.block)].terminator.?.branch.target, third_location.block);
    try std.testing.expectEqual(@as(usize, 1), third_location.item_index);
    try std.testing.expectEqual(third_location.block, fourth_location.block);
    try std.testing.expectEqual(@as(usize, 2), fourth_location.item_index);

    const body = try builder.finish(null);
    try std.testing.expectEqual(@as(usize, 3), body.blocks.len);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[2].call.target.direct.item);
    try std.testing.expectEqual(TestMaterializerTypes.second_custom_drop_hook, body.instructions[4].call.target.direct.item);
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[2].terminator);
}

test "cleanup materializer preserves incoming arguments when splitting a boundary" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const argument = try builder.appendBlockArgument(TestMaterializerTypes.custom_type, null);
    const entry = try builder.newBlock(0, 0);
    const target = try builder.newBlock(argument, argument + 1);
    builder.enterBlock(entry);
    const source = try builder.appendInstruction(.{ .const_int = 42 });
    try builder.appendBranchArgument(.{ .value = source.id }, null);
    builder.terminate(.{ .branch = .{ .target = target, .arguments = .{ .start = 0, .end = 1 } } });
    builder.enterBlock(target);
    const boundary = try builder.newBoundary(.{ .start = 0, .end = 0 });
    try builder.appendBoundary(boundary);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = @fromBackingInt(@intCast(argument)),
        .location = .{ .boundary = boundary },
    }});

    const body = try builder.finish(null);
    const target_block = body.blocks[@backingInt(target)];
    try std.testing.expectEqual(@as(u32, 1), target_block.argument_end - target_block.argument_start);
    try std.testing.expectEqual(@as(u32, 1), target_block.instruction_end - target_block.instruction_start);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[target_block.instruction_start].call.target.direct.item);
    const suffix = target_block.terminator.branch.target;
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[@backingInt(suffix)].terminator);
}

test "cleanup materializer interposes only one predicate edge" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const value = try builder.appendInstruction(.{ .const_int = 42 });
    const condition = try builder.appendInstruction(.{ .const_bool = true });
    const expected = try builder.appendInstruction(.{ .const_bool = true });
    const argument = try builder.appendBlockArgument(.int, null);
    const then_block = try builder.newBlock(argument, argument + 1);
    const else_block = try builder.newBlock(argument + 1, argument + 1);
    try builder.appendBranchArgument(.{ .value = value.id }, null);
    builder.terminate(.{ .predicate_branch = .{
        .operation = .eqb,
        .operands = .{ .lhs = condition.id, .rhs = expected.id },
        .then_branch = .{ .target = then_block, .arguments = .{ .start = 0, .end = 1 } },
        .else_branch = builder.emptyBranch(else_block),
    } });
    builder.enterBlock(then_block);
    builder.terminate(.return_unit);
    builder.enterBlock(else_block);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = value.id,
        .location = .{ .edge = .{ .predecessor = entry, .successor_ordinal = 0 } },
    }});

    const body = try builder.finish(null);
    const predicate = body.blocks[@backingInt(entry)].terminator.predicate_branch;
    try std.testing.expect(predicate.then_branch.target != then_block);
    try std.testing.expectEqual(else_block, predicate.else_branch.target);
    const cleanup_block = predicate.then_branch.target;
    const cleanup_range = body.blocks[@backingInt(cleanup_block)];
    try std.testing.expectEqual(@as(u32, 1), cleanup_range.argument_end - cleanup_range.argument_start);
    try std.testing.expectEqual(then_block, cleanup_range.terminator.branch.target);
    const forwarded = cleanup_range.terminator.branch.arguments;
    try std.testing.expectEqual(@as(u32, 1), forwarded.end - forwarded.start);
    try std.testing.expectEqual(@as(structures.FunctionValueId, @fromBackingInt(@intCast(cleanup_range.argument_start))), body.branch_arguments[forwarded.start].value);
    try std.testing.expectEqual(@as(u32, 1), cleanup_range.instruction_end - cleanup_range.instruction_start);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[cleanup_range.instruction_start].call.target.direct.item);
}

test "cleanup materializer guards conditional ownership" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const value = try builder.appendInstruction(.{ .const_int = 42 });
    const borrowed = try builder.appendInstruction(.{ .const_bool = true });
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(boundary);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = value.id,
        .cleanup_condition = borrowed.id,
        .location = .{ .boundary = boundary },
    }});

    const body = try builder.finish(null);
    const predicate = body.blocks[@backingInt(entry)].terminator.predicate_branch;
    try std.testing.expectEqual(body.instructionValue(1), predicate.operands.lhs);
    const borrowed_block = body.blocks[@backingInt(predicate.then_branch.target)];
    const owned_block = body.blocks[@backingInt(predicate.else_branch.target)];
    try std.testing.expectEqual(@as(u32, 0), borrowed_block.instruction_end - borrowed_block.instruction_start);
    try std.testing.expectEqual(@as(u32, 1), owned_block.instruction_end - owned_block.instruction_start);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[owned_block.instruction_start].call.target.direct.item);
    try std.testing.expectEqual(borrowed_block.terminator.branch.target, owned_block.terminator.branch.target);
}

test "cleanup materializer rejoins variant cleanup with the suffix" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const value = try builder.appendInstruction(.{ .const_int = 42 });
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(boundary);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.variant_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = value.id,
        .location = .{ .boundary = boundary },
    }});

    const body = try builder.finish(null);
    const suffix: structures.FunctionBlockId = @fromBackingInt(@intCast(1));
    var custom_drop_count: usize = 0;
    var rejoins_suffix = false;
    for (body.instructions) |instruction| {
        if (instruction == .call and instruction.call.target == .direct and instruction.call.target.direct.item == TestMaterializerTypes.custom_drop_hook) custom_drop_count += 1;
    }
    for (body.blocks) |block_value| switch (block_value.terminator) {
        .branch => |branch| rejoins_suffix = rejoins_suffix or branch.target == suffix,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), custom_drop_count);
    try std.testing.expect(rejoins_suffix);
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[@backingInt(suffix)].terminator);
}

fn testCleanupMaterializerAllocationFailures(gpa: std.mem.Allocator) !void {
    var context: TestMaterializerContext = .{ .gpa = gpa };
    defer context.deinit();
    var builder = testInitMaterializerBuilder(&context);
    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const value = try builder.appendInstruction(.{ .const_int = 42 });
    const boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(boundary);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.variant_type, 0);
    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = value.id,
        .location = .{ .boundary = boundary },
    }});
    // Validate IR finalization after materializing cleanup.
    _ = try builder.finish(null);
}

test "cleanup materializer releases partial CFG mutations on allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCleanupMaterializerAllocationFailures, .{});
}
