const std = @import("std");
const structures = @import("../structures.zig");
const semantic = @import("semantic.zig");
const lifetime = @import("lifetime.zig");
const flow_snapshot = @import("flow_snapshot.zig");
const control_flow = @import("../control_flow.zig");

const GenerationId = lifetime.GenerationId;
const BoundaryId = lifetime.BoundaryId;
const Generation = lifetime.Generation;
const LifetimeEffect = lifetime.LifetimeEffect;
const OwnershipForward = lifetime.OwnershipForward;
const OwnershipEdge = lifetime.OwnershipEdge;
const PlannedCleanup = lifetime.PlannedCleanup;
const ExplicitAbandonment = lifetime.ExplicitAbandonment;
const Boundary = lifetime.Boundary;
const BuildInstruction = lifetime.BuildInstruction;
const BuildItem = lifetime.BuildItem;
const BuildBlock = lifetime.BuildBlock;
const CleanupLocation = lifetime.CleanupLocation;
const LifetimeSolver = lifetime.Solver;

pub const BodyOptions = struct {
    infer_return_type: bool = false,
    publish_instruction_spans: bool = false,
    allow_type_values: bool = false,
    expected_result_type: ?structures.TypeId = null,
    measurements: ?*BodyMeasurements = null,
    builtin_body: ?BuiltinBody = null,
    consuming_converter: bool = false,
};

pub const BuiltinBody = enum { copy, move, initialize_slot, initialize_collection, array_filled, array_from, array_borrow, array_borrow_mut, literal_byte };

pub const BodyMeasurements = struct {
    snapshots: usize = 0,
    snapshot_bytes: usize = 0,
    blocks: usize = 0,
    generations: usize = 0,
    lifetime_table_bytes: usize = 0,
};

pub fn emitSemanticIssue(ctx: anytype, file_id: structures.FileId, issue: semantic.Issue) !void {
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = issue.span, .kind = issue.kind });
}

pub fn referenceReplacementIssue(types: anytype, element_type: structures.TypeId) !?structures.Diagnostic.Kind {
    if (try types.containsBorrow(element_type)) return .{ .borrow_write_cannot_store_borrow = element_type };
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
    is_fallible: bool,
    options: BodyOptions,
    type_interner: anytype,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    if (options.measurements) |measurements| measurements.* = .{};
    var builder: BodyBuilder(@TypeOf(ctx), @TypeOf(type_interner)) = .{
        .ctx = ctx,
        .type_interner = type_interner,
        .instance = instance,
        .file_id = file_id,
        .unresolved = unresolved,
        .return_type = return_type,
        .is_fallible = is_fallible,
        .consuming_converter = options.consuming_converter,
        .infer_return_type = options.infer_return_type,
        .publish_instruction_spans = options.publish_instruction_spans,
        .allow_type_values = options.allow_type_values,
        .expected_result_type = options.expected_result_type,
    };
    defer builder.deinit();
    builder.build(parameters, options.builtin_body) catch |err| switch (err) {
        error.SourceRejected, error.Unavailable => return null,
        else => return err,
    };
    return builder.finishAnalysis(options.measurements) catch |err| switch (err) {
        error.SourceRejected, error.Unavailable => null,
        else => return err,
    };
}

fn BodyBuilder(comptime Context: type, comptime TypeInterner: type) type {
    return struct {
        const Self = @This();
        const ReferenceProjection = struct {
            step: union(enum) { field: u32, variant: structures.TypeId, element },
            next: ?u32,
        };
        const ReferenceTransform = struct {
            operation: union(enum) {
                prefix: @FieldType(ReferenceProjection, "step"),
                select: @FieldType(ReferenceProjection, "step"),
                exclude: @FieldType(ReferenceProjection, "step"),
                widen,
                read: struct { state: StateId, instruction: u31 },
                refresh: struct { root: semantic.UnresolvedBody.LocalId, previous: BindingIdentity, replacement: BindingIdentity },
            },
            previous: ?u32,
        };
        const ReferenceOrigin = struct {
            generation: ?GenerationId = null,
            cleanup_value: ?structures.FunctionValueId = null,
            root: ?semantic.UnresolvedBody.LocalId = null,
            binding_identity: BindingIdentity = .unknown,
            parameter: ?u32 = null,
            loop: ?u32 = null,
            projection: ?u32 = null,
            stable: bool = false,
            read: ?u31 = null,
            deferred_capture: bool = false,
            initializer_owner: ?structures.FunctionValueId = null,
            transform: ?u32 = null,
            next: ?u32 = null,
        };
        const BindingIdentity = union(enum) { unknown, fixed: u32, join: u32 };
        const ReferenceRefresh = union(enum) { value: *?u32, slots: *?u32 };
        const DropEffects = struct { writes: ?u32, storage_invalidations: ?u32 };
        const BindingJoin = struct {
            slot: ?u32 = null,
            storage: bool = false,
            initial: BindingIdentity,
            alternatives: std.ArrayList(BindingIdentity) = .empty,
            complete: bool = false,
        };
        const ResolvedBindingIdentity = struct {
            value: ?u32 = null,
            conflicting: bool = false,
            incomplete: bool = false,
        };
        const LoopReferenceOrigins = struct {
            slot: u32,
            origins: ?u32,
            complete: bool = false,
        };
        const Value = struct {
            id: structures.FunctionValueId,
            type_id: structures.TypeId,
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
            stable_reference_root: ?semantic.UnresolvedBody.LocalId = null,
            binding_identity: BindingIdentity = .unknown,
            storage_identity: ?BindingIdentity = null,
            materialize_on_copy: bool = false,
            explicit_transfer: bool = false,
            initializer_parameter: ?u32 = null,
            consumption_completion: ?structures.FunctionValueId = null,
            pending_consumption_owners: ?u32 = null,
            // Consuming an existing place keeps its address across result joins.
            preserves_storage: bool = false,
        };
        const CallTarget = union(enum) {
            direct: structures.InstanceId,
            inferred: structures.InstanceId,
            indirect: Value,
        };
        const InitAvailability = enum { absent, pending, consumed, maybe_consumed };
        const InitializerTypeKey = struct { expression: semantic.UnresolvedBody.ValueId, expected: ?structures.TypeId, initializer_boundary: bool };
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
        const StateValues = flow_snapshot.Snapshot(?Value, 16);
        const State = struct {
            values: StateValues,
            availability: []Availability,
            field_availability: []Availability,
            initializers: []InitAvailability,
            completed_consumptions: []bool = &.{},

            fn clone(self: State, allocator: std.mem.Allocator) !State {
                return self.capture(allocator, null);
            }

            fn capture(self: State, allocator: std.mem.Allocator, previous: ?StateValues) !State {
                var values = try self.values.capture(allocator, previous);
                errdefer values.deinit(allocator);
                const availability = try allocator.dupe(Availability, self.availability);
                errdefer allocator.free(availability);
                const fields = try allocator.dupe(Availability, self.field_availability);
                errdefer allocator.free(fields);
                const initializers = try allocator.dupe(InitAvailability, self.initializers);
                errdefer allocator.free(initializers);
                return .{ .values = values, .availability = availability, .field_availability = fields, .initializers = initializers, .completed_consumptions = try allocator.dupe(bool, self.completed_consumptions) };
            }

            fn deinit(self: *State, allocator: std.mem.Allocator) void {
                self.values.deinit(allocator);
                allocator.free(self.availability);
                allocator.free(self.field_availability);
                allocator.free(self.initializers);
                allocator.free(self.completed_consumptions);
                self.* = undefined;
            }

            /// Flow facts join independently of value and storage selection.
            fn joinFlow(self: State, other: State) void {
                for (self.availability, other.availability) |*left, right| left.* = joinAvailability(left.*, right);
                for (self.field_availability, other.field_availability) |*left, right| left.* = joinAvailability(left.*, right);
                for (self.initializers, other.initializers) |*left, right| {
                    if (left.* != right) left.* = .maybe_consumed;
                }
                for (self.completed_consumptions, other.completed_consumptions) |*left, right| left.* = left.* and right;
            }

            fn copyFlowFrom(self: State, other: State) void {
                @memcpy(self.availability, other.availability);
                @memcpy(self.field_availability, other.field_availability);
                @memcpy(self.initializers, other.initializers);
                @memcpy(self.completed_consumptions, other.completed_consumptions);
            }
        };
        const Expression = semantic.UnresolvedBody.Expression;
        const StateId = enum(u32) { _ };
        const PendingReferenceUseLocation = union(enum) {
            boundary: struct { id: BoundaryId, effect_index: usize },
            terminator: struct { id: structures.FunctionBlockId, effect_index: usize },
        };
        const PendingReferenceUse = struct {
            origins: u32,
            state: StateId,
            span: structures.SourceSpan,
            location: PendingReferenceUseLocation,
        };
        const ReferenceUse = struct {
            origins: u32,
            span: structures.SourceSpan,
            location: PendingReferenceUseLocation,
        };
        const PendingReferenceInvalidation = struct {
            origins: u32,
            known: ?u32,
            span: structures.SourceSpan,
        };
        const PendingReferenceReturn = struct { origins: u32, span: structures.SourceSpan };
        const PendingExtraction = struct {
            binding: semantic.UnresolvedBody.ConditionBinding,
            operand: Value,
            target_type: structures.TypeId,
        };
        const PendingConditionBinding = union(enum) {
            variant: PendingExtraction,
            call: semantic.UnresolvedBody.ConditionBinding,

            fn conditionBinding(self: @This()) semantic.UnresolvedBody.ConditionBinding {
                return switch (self) {
                    .variant => |extraction| extraction.binding,
                    .call => |binding| binding,
                };
            }
        };
        const FlowExit = struct {
            block: structures.FunctionBlockId,
            state: StateId,
            binding: ?PendingConditionBinding = null,
            reference_origins: ?u32 = null,
            constructed: ?Value = null,
        };
        const ConditionFlow = struct {
            success: ?FlowExit,
            failure: ?FlowExit,
            diverged: ?Value = null,
        };
        const LoopContext = struct {
            body: semantic.UnresolvedBody.BlockId,
            header: structures.FunctionBlockId,
            baseline: StateId,
            result: ResultRequest,
        };
        const LoopBackedge = struct {
            block: structures.FunctionBlockId,
            state: StateId,
        };
        const PlaceField = struct {
            index: u32,
            type_id: structures.TypeId,
            name: []const u8,
        };
        const ArgumentPlace = struct {
            local: semantic.UnresolvedBody.LocalId,
            fields: structures.FunctionValueRange,
        };
        const BorrowPlace = struct {
            root: union(enum) {
                local: semantic.UnresolvedBody.LocalId,
                parameter: semantic.UnresolvedBody.ValueId,
            },
            fields: structures.FunctionValueRange,
        };
        const ProjectedBorrowPlace = struct {
            root: Value,
            alias: ?Alias,
            fields: structures.FunctionValueRange,
            writable: bool,
        };
        const Alias = struct {
            root: ?@FieldType(BorrowPlace, "root") = null,
            fields: structures.FunctionValueRange = .{ .start = 0, .end = 0 },
            whole_root: bool = false,
        };
        const PendingMutArgument = struct {
            place: ArgumentPlace,
            argument_index: u32,
            reference_origins: ?u32 = null,
            return_origin: bool = false,
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
        const GenerationOrigin = enum { none, define, produce, phi };
        const LocalMetadata = struct { alias: ?Alias, mutable: bool, can_deinit: bool, mut_parameter: ?u32 };

        ctx: Context,
        type_interner: TypeInterner,
        instance: structures.InstanceId,
        file_id: structures.FileId,
        unresolved: semantic.UnresolvedBody,
        return_type: structures.TypeId,
        is_fallible: bool,
        infer_return_type: bool = false,
        type_check_only: bool = false,
        expected_result_type: ?structures.TypeId = null,
        publish_instruction_spans: bool = false,
        allow_type_values: bool = false,
        values: []?Value = &.{},
        init_availability: []InitAvailability = &.{},
        initializer_regions: std.ArrayList(structures.FunctionBodyAnalysis) = .empty,
        initializer_captures: std.ArrayList(structures.FunctionValueId) = .empty,
        initializer_types: InitializerTypes = .empty,
        // Region contexts borrow their root's type discovery cache. Executable
        // preparation still checks ownership and effects in each context.
        shared_initializer_types: ?*InitializerTypes = null,
        is_initializer_region: bool = false,
        consuming_converter: bool = false,
        captured_locals: []?u32 = &.{},
        captured_values: []bool = &.{},
        initializer_writes: std.ArrayList(InitializerWrite) = .empty,
        initializer_reference_writes: std.ArrayList(InitializerReferenceWrite) = .empty,
        capture_reference_writes: std.ArrayList(Value) = .empty,
        returned_reference_origins: ?u32 = null,
        capture_output_origins: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,
        capture_transfers: std.ArrayList(CaptureTransfer) = .empty,
        initializer_transfers: std.ArrayList(InitializerTransfer) = .empty,
        pending_consumption_owners: std.ArrayList(PendingConsumptionOwner) = .empty,
        ordinary_completion_states: std.ArrayList(StateId) = .empty,
        local_values: []?Value = &.{},
        locals: std.MultiArrayList(LocalMetadata) = .empty,
        local_availability: []Availability = &.{},
        field_places: []FieldPlace = &.{},
        field_availability: []Availability = &.{},
        completed_consumptions: []bool = &.{},
        states: std.ArrayList(State) = .empty,
        block_arguments: std.ArrayList(structures.FunctionBlockArgument) = .empty,
        parameter_modes: std.ArrayList(structures.ParameterMode) = .empty,
        block_argument_generations: std.ArrayList(?GenerationId) = .empty,
        variant_coercion_tags: std.ArrayList(u32) = .empty,
        struct_field_values: std.ArrayList(structures.StructFieldValue) = .empty,
        borrow_fields: std.ArrayList(u32) = .empty,
        reference_origins: std.ArrayList(ReferenceOrigin) = .empty,
        reference_projections: std.ArrayList(ReferenceProjection) = .empty,
        reference_transforms: std.ArrayList(ReferenceTransform) = .empty,
        binding_joins: std.ArrayList(BindingJoin) = .empty,
        loop_reference_origins: std.ArrayList(LoopReferenceOrigins) = .empty,
        loop_backedges: std.ArrayList(LoopBackedge) = .empty,
        pending_reference_uses: std.ArrayList(PendingReferenceUse) = .empty,
        reference_uses: std.ArrayList(ReferenceUse) = .empty,
        cleanup_origins: std.AutoHashMapUnmanaged(structures.FunctionValueId, u32) = .empty,
        drop_effects: std.AutoHashMapUnmanaged(u31, DropEffects) = .empty,
        pending_reference_invalidations: std.ArrayList(PendingReferenceInvalidation) = .empty,
        pending_reference_returns: std.ArrayList(PendingReferenceReturn) = .empty,
        call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
        mut_argument_fields: std.ArrayList(PlaceField) = .empty,
        pending_mut_arguments: std.ArrayList(PendingMutArgument) = .empty,
        writable_call_references: std.ArrayList(Value) = .empty,
        pending_consumed_arguments: std.ArrayList(Value) = .empty,
        pending_initializer_owners: std.ArrayList(Value) = .empty,
        pending_initializer_locals: std.ArrayList(semantic.UnresolvedBody.LocalId) = .empty,
        pending_deinit_places: std.ArrayList(ArgumentPlace) = .empty,
        pending_deinit_fields: std.ArrayList(PlaceField) = .empty,
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        branch_argument_generations: std.ArrayList(?GenerationId) = .empty,
        generations: std.ArrayList(Generation) = .empty,
        ownership_forwards: std.ArrayList(OwnershipForward) = .empty,
        ownership_edges: std.ArrayList(OwnershipEdge) = .empty,
        ownership_forward_hints: std.ArrayList(OwnershipForwardHint) = .empty,
        planned_cleanups: std.ArrayList(PlannedCleanup) = .empty,
        explicit_abandonments: std.ArrayList(ExplicitAbandonment) = .empty,
        boundaries: std.ArrayList(Boundary) = .empty,
        blocks: std.ArrayList(BuildBlock) = .empty,
        loop_stack: std.ArrayList(LoopContext) = .empty,
        loop_breaks: std.ArrayList(FlowExit) = .empty,
        current_block: ?structures.FunctionBlockId = null,
        current_boundary: ?BoundaryId = null,
        next_generation_start_order: u32 = 0,
        next_binding_identity: u32 = 0,
        instruction_count: u32 = 0,
        block_layout_count: u32 = 0,

        fn init(self: *Self, parameters: []const structures.CallableParameter) !void {
            std.debug.assert(parameters.len == self.unresolved.parameter_count);
            std.debug.assert(parameters.len == self.unresolved.parameter_spans.len);
            self.values = try self.ctx.allocator().alloc(?Value, parameters.len + self.unresolved.expressions.len);
            @memset(self.values, null);
            self.init_availability = try self.ctx.allocator().alloc(InitAvailability, parameters.len);
            @memset(self.init_availability, .absent);
            self.local_values = try self.ctx.allocator().alloc(?Value, self.unresolved.local_count);
            @memset(self.local_values, null);
            try self.locals.resize(self.ctx.allocator(), self.unresolved.local_count);
            @memset(self.locals.items(.alias), null);
            @memset(self.locals.items(.mutable), false);
            @memset(self.locals.items(.can_deinit), false);
            @memset(self.locals.items(.mut_parameter), null);
            self.local_availability = try self.ctx.allocator().alloc(Availability, self.unresolved.local_count);
            @memset(self.local_availability, .unbound);
            self.field_places = try self.collectFieldPlaces();
            self.field_availability = try self.ctx.allocator().alloc(Availability, self.field_places.len);
            @memset(self.field_availability, .available);
            self.completed_consumptions = try self.ctx.allocator().alloc(bool, self.local_values.len + self.field_places.len);
            @memset(self.completed_consumptions, false);
            try self.block_arguments.ensureUnusedCapacity(self.ctx.allocator(), parameters.len);
            try self.parameter_modes.ensureUnusedCapacity(self.ctx.allocator(), parameters.len);
            try self.block_argument_generations.ensureUnusedCapacity(self.ctx.allocator(), parameters.len);
            const root_span = self.unresolved.blocks[@backingInt(self.unresolved.root_block)].span;
            var parameter_local: usize = 0;
            for (parameters, 0..) |parameter, index| {
                var entry_value: Value = .{ .id = @fromBackingInt(@intCast(index)), .type_id = parameter.type_id };
                if (parameter.mode == .@"var" or parameter.mode == .deinit) {
                    entry_value.owned_generation = try self.allocateGeneration(parameter.type_id, self.unresolved.parameter_spans[index], parameter.mode == .deinit);
                }
                switch (parameter.mode) {
                    .init => {
                        self.values[index] = .{ .id = entry_value.id, .type_id = entry_value.type_id, .initializer_parameter = @intCast(index), .reference_origins = if (try self.type_interner.canStoreBorrow(parameter.type_id)) try self.addReferenceOrigin(null, .{ .parameter = @intCast(index) }) else null };
                        self.init_availability[index] = .pending;
                    },
                    .imm => {
                        self.values[index] = .{
                            .id = entry_value.id,
                            .type_id = entry_value.type_id,
                            .borrowed_type = entry_value.type_id,
                            .reference_origins = try self.addReferenceOrigin(null, .{ .parameter = @intCast(index) }),
                        };
                    },
                    .mut, .@"var", .deinit => {
                        if (try self.type_interner.canStoreBorrow(parameter.type_id)) {
                            entry_value.reference_origins = try self.addReferenceOrigin(null, .{ .parameter = @intCast(index) });
                        }
                        entry_value.binding_identity = try self.newBindingIdentity();
                        self.local_values[parameter_local] = entry_value;
                        self.locals.items(.mutable)[parameter_local] = true;
                        self.locals.items(.can_deinit)[parameter_local] = parameter.mode == .deinit;
                        if (parameter.mode == .mut) self.locals.items(.mut_parameter)[parameter_local] = @intCast(index);
                        self.local_availability[parameter_local] = .available;
                        parameter_local += 1;
                    },
                    .static => unreachable,
                }
                self.block_arguments.appendAssumeCapacity(.{ .type_id = parameter.type_id, .representation = switch (parameter.mode) {
                    .init => .initializer,
                    .deinit => .storage,
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
            for (self.local_values) |local_value| {
                const parameter_value = local_value orelse continue;
                if (parameter_value.owned_generation) |generation| try self.recordEffectAt(parameter_boundary, .{ .define = .{
                    .generation = generation,
                    .value = parameter_value.id,
                } });
            }
            try self.appendBoundary(parameter_boundary);
        }

        fn collectFieldPlaces(self: *Self) ![]FieldPlace {
            var places: std.ArrayList(FieldPlace) = .empty;
            defer places.deinit(self.ctx.allocator());
            errdefer for (places.items) |place| self.ctx.allocator().free(place.fields);
            var path: std.ArrayList(semantic.UnresolvedBody.FieldName) = .empty;
            defer path.deinit(self.ctx.allocator());
            for (self.unresolved.expressions, 0..) |expression, index| {
                path.clearRetainingCapacity();
                const local = switch (expression.operation) {
                    .field_access, .field_transfer => switch ((try self.appendSourcePlaceFields(@fromBackingInt(@intCast(self.unresolved.parameter_count + index)), &path)) orelse continue) {
                        .local => |local| local,
                        .parameter => continue,
                    },
                    .assignment => |target| blk: {
                        if (target.fields.start == target.fields.end) continue;
                        try path.appendSlice(self.ctx.allocator(), self.unresolved.assignment_fields[target.fields.start..target.fields.end]);
                        break :blk target.target;
                    },
                    else => continue,
                };
                var duplicate = false;
                for (places.items) |place| {
                    if (place.local == local and place.fields.len == path.items.len and fieldPathContains(place.fields, path.items)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                try places.ensureUnusedCapacity(self.ctx.allocator(), 1);
                places.appendAssumeCapacity(.{ .local = local, .fields = try path.toOwnedSlice(self.ctx.allocator()) });
            }
            return places.toOwnedSlice(self.ctx.allocator());
        }

        fn deinit(self: *Self) void {
            const gpa = self.ctx.allocator();
            gpa.free(self.values);
            gpa.free(self.init_availability);
            gpa.free(self.captured_locals);
            gpa.free(self.captured_values);
            self.initializer_writes.deinit(gpa);
            self.initializer_reference_writes.deinit(gpa);
            self.capture_reference_writes.deinit(gpa);
            self.capture_output_origins.deinit(gpa);
            self.capture_transfers.deinit(gpa);
            self.initializer_transfers.deinit(gpa);
            self.pending_consumption_owners.deinit(gpa);
            self.ordinary_completion_states.deinit(gpa);
            for (self.initializer_regions.items) |*region| region.deinit(gpa);
            self.initializer_regions.deinit(gpa);
            self.initializer_captures.deinit(gpa);
            self.initializer_types.deinit(gpa);
            gpa.free(self.local_values);
            self.locals.deinit(gpa);
            gpa.free(self.local_availability);
            gpa.free(self.completed_consumptions);
            for (self.field_places) |place| gpa.free(place.fields);
            gpa.free(self.field_places);
            gpa.free(self.field_availability);
            for (self.states.items) |*state| state.deinit(self.ctx.allocator());
            self.states.deinit(gpa);
            self.block_arguments.deinit(gpa);
            self.parameter_modes.deinit(gpa);
            self.block_argument_generations.deinit(gpa);
            self.variant_coercion_tags.deinit(gpa);
            self.struct_field_values.deinit(gpa);
            self.borrow_fields.deinit(gpa);
            self.reference_origins.deinit(gpa);
            self.reference_projections.deinit(gpa);
            self.reference_transforms.deinit(gpa);
            for (self.binding_joins.items) |*join| join.alternatives.deinit(gpa);
            self.binding_joins.deinit(gpa);
            self.loop_reference_origins.deinit(gpa);
            self.loop_backedges.deinit(gpa);
            self.pending_reference_uses.deinit(gpa);
            self.reference_uses.deinit(gpa);
            self.cleanup_origins.deinit(gpa);
            self.drop_effects.deinit(gpa);
            self.pending_reference_invalidations.deinit(gpa);
            self.pending_reference_returns.deinit(gpa);
            self.call_arguments.deinit(gpa);
            self.mut_argument_fields.deinit(gpa);
            self.pending_mut_arguments.deinit(gpa);
            self.writable_call_references.deinit(gpa);
            self.pending_consumed_arguments.deinit(gpa);
            self.pending_initializer_owners.deinit(gpa);
            self.pending_initializer_locals.deinit(gpa);
            self.pending_deinit_places.deinit(gpa);
            self.pending_deinit_fields.deinit(gpa);
            self.branch_arguments.deinit(gpa);
            self.branch_argument_generations.deinit(gpa);
            for (self.generations.items) |generation| {
                for (generation.missing_fields) |missing| gpa.free(missing);
                if (generation.missing_fields.len != 0) gpa.free(generation.missing_fields);
            }
            self.generations.deinit(gpa);
            self.ownership_forwards.deinit(gpa);
            self.ownership_edges.deinit(gpa);
            self.ownership_forward_hints.deinit(gpa);
            self.planned_cleanups.deinit(gpa);
            self.explicit_abandonments.deinit(gpa);
            for (self.boundaries.items) |*boundary| boundary.effects.deinit(gpa);
            self.boundaries.deinit(gpa);
            for (self.blocks.items) |*block_value| {
                block_value.items.deinit(gpa);
                block_value.terminator_effects.deinit(gpa);
            }
            self.blocks.deinit(gpa);
            self.loop_stack.deinit(gpa);
            self.loop_breaks.deinit(gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try emitSemanticIssue(self.ctx, self.file_id, .{ .span = span, .kind = kind });
            return error.SourceRejected;
        }

        fn typeMismatch(_: *Self, expected: structures.TypeId, found: structures.TypeId) structures.Diagnostic.TypeMismatch {
            return .{ .expected = expected, .found = found };
        }

        fn finishAnalysis(self: *Self, measurements: ?*BodyMeasurements) !structures.FunctionBodyAnalysis {
            std.debug.assert(!self.type_check_only);
            try self.resolvePendingReferenceUses();
            if (self.generations.items.len != 0) {
                try self.finishOwnershipMetadata();
                try self.analyzeLifetimes(measurements);
            }
            if (try self.emitExplicitAbandonmentDiagnostics()) return error.SourceRejected;
            try self.materializeCleanups(self.planned_cleanups.items);
            try self.validateCleanupReferenceUses();
            if (measurements) |output| {
                output.snapshots = self.states.items.len;
                var pages: std.AutoHashMap(*StateValues.Page, void) = .init(self.ctx.allocator());
                defer pages.deinit();
                for (self.states.items) |state| {
                    output.snapshot_bytes += state.values.retainedBytes() +
                        std.mem.sliceAsBytes(state.availability).len + std.mem.sliceAsBytes(state.field_availability).len +
                        std.mem.sliceAsBytes(state.initializers).len +
                        std.mem.sliceAsBytes(state.completed_consumptions).len;
                    for (state.values.retainedPages()) |page| {
                        if (!(try pages.getOrPut(page)).found_existing) output.snapshot_bytes += @sizeOf(StateValues.Page);
                    }
                }
                output.blocks = self.blocks.items.len;
                output.generations = self.generations.items.len;
            }
            return self.finish();
        }

        fn build(self: *Self, parameters: []const structures.CallableParameter, builtin_body: ?BuiltinBody) !void {
            try self.init(parameters);
            if (builtin_body) |operation| {
                switch (operation) {
                    .copy => return self.buildOwnershipMember(.copy),
                    .move => return self.buildOwnershipMember(.move),
                    .initialize_slot => return self.buildSlotInitializer(),
                    .array_filled => return self.buildArrayFilled(),
                    .array_from => return self.buildArrayFrom(),
                    .initialize_collection => return self.buildCollectionInitializer(),
                    .array_borrow => return self.buildArrayBorrow(false),
                    .array_borrow_mut => return self.buildArrayBorrow(true),
                    .literal_byte => return self.buildLiteralByte(),
                }
            }
            const result = try self.block(self.unresolved.root_block, self.expected_result_type);
            if (self.current_block == null) return;
            const root = self.unresolved.blocks[@backingInt(self.unresolved.root_block)];
            if (self.infer_return_type) {
                if (result) |value_to_return| {
                    self.return_type = value_to_return.type_id;
                    try self.returnValue(value_to_return, root.span);
                } else {
                    try self.finishFunctionExit(root.span, .return_unit);
                }
                return;
            }
            if (self.return_type == .unit) {
                try self.finishFunctionExit(root.span, .return_unit);
            } else {
                return self.reject(root.span, .{ .missing_return_value = self.return_type });
            }
        }

        fn buildLiteralByte(self: *Self) !void {
            const value_id = (try self.type_interner.resolveStatic("value")) orelse return error.Unavailable;
            const constant = try self.type_interner.lookupCompileTimeValue(value_id);
            std.debug.assert(constant == .runtime);
            std.debug.assert(constant.runtime.value == .int_literal);
            const byte = std.math.cast(u8, constant.runtime.value.int_literal) orelse return self.reject(.{ .start = 0, .end = 0 }, .integer_literal_out_of_range);
            try self.returnValue(try self.appendInstruction(.{ .const_byte = byte }), .{ .start = 0, .end = 0 });
        }

        fn buildSlotInitializer(self: *Self) !void {
            const span = self.unresolved.parameter_spans[2];
            const initializer = self.values[2].?;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            const destination = try self.appendInstruction(.{ .allocation_element = .{
                .allocation = self.local_values[0].?.id,
                .index = self.values[1].?.id,
                .type_id = initializer.type_id,
            } });
            const result = try self.constructInitializer(initializer, span, destination);
            if (self.current_block == null) return;
            try self.recordConsume(result);
            self.local_values[0].?.reference_origins = try self.mergeReferenceOrigins(
                self.local_values[0].?.reference_origins,
                try self.transformReferenceOrigins(result.reference_origins, .{ .prefix = .element }),
            );
            try self.appendBoundary(boundary);
            self.current_boundary = null;
            try self.finishFunctionExit(span, .return_unit);
        }

        fn buildCollectionInitializer(self: *Self) !void {
            const span = self.unresolved.parameter_spans[1];
            const initializer = self.values[1].?;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            const shape = (try self.type_interner.collectionLiteralType(initializer.type_id)) orelse unreachable;
            const destination = try self.appendInstruction(.{ .storage_projection = .{
                .owner = self.local_values[0].?.id,
                .type_id = try self.type_interner.internArrayType(shape),
                .projection = .allocation_array,
            } });
            const result = try self.constructInitializer(initializer, span, destination);
            if (self.current_block == null) return;
            try self.recordConsume(result);
            self.local_values[0].?.reference_origins = try self.mergeReferenceOrigins(self.local_values[0].?.reference_origins, result.reference_origins);
            try self.appendBoundary(boundary);
            self.current_boundary = null;
            try self.finishFunctionExit(span, .return_unit);
        }

        fn buildOwnershipMember(self: *Self, operation: structures.OwnershipMember) !void {
            if (self.return_type == .never) {
                self.terminate(.diverge);
                return;
            }
            const span = self.unresolved.parameter_spans[0];
            const storage = if (try self.constructsInPlace(self.return_type))
                try self.appendInstruction(.{ .result_storage = self.return_type })
            else
                null;
            const result = switch (operation) {
                .copy => try self.copyValue(self.values[0].?, span, storage),
                .move => try self.moveValue(self.local_values[0].?, span, storage),
            };
            if (storage != null) return self.returnConstructed(result, span);
            try self.returnValue(result, span);
        }

        fn buildArrayFrom(self: *Self) !void {
            const span = self.unresolved.parameter_spans[0];
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            const storage = try self.appendInstruction(.{ .result_storage = self.return_type });
            const result = try self.constructInitializer(self.values[0].?, span, storage);
            if (self.current_block != null) try self.returnConstructed(result, span);
        }

        fn buildArrayFilled(self: *Self) !void {
            std.debug.assert(!self.is_fallible);
            const span = self.unresolved.parameter_spans[0];
            const source = self.values[0].?;
            const array = (try self.type_interner.facts().arrayType(self.return_type)) orelse unreachable;
            std.debug.assert(source.type_id == array.element_type);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.copy == .none) return self.reject(span, .{ .type_not_copyable = .{
                .type_id = source.type_id,
                .is_movable = capabilities.move != .none,
            } });
            try self.recordUse(source);
            const storage = try self.appendInstruction(.{ .result_storage = self.return_type });
            if (array.length != 0) {
                const array_loop = try self.beginArrayLoop(array.length, false);
                const element = try self.arrayElement(storage, array_loop.index, array.element_type);
                _ = try self.copyValueBits(rawValue(source), element);
                try self.endArrayLoop(array_loop, false);
            }
            var result = try self.defineOwnedValue(storage, span, false);
            if (array.length != 0) {
                var origins = try self.copyResultOrigins(source);
                if (capabilities.needs_custom_copy) try self.finishOwnershipEffects(source, &origins);
                result.reference_origins = try self.transformReferenceOrigins(origins, .{ .prefix = .element });
            }
            try self.returnConstructed(result, span);
        }

        fn buildArrayBorrow(self: *Self, writable: bool) !void {
            const span = self.unresolved.parameter_spans[0];
            const source = if (writable) self.borrowLocalValue(@fromBackingInt(@intCast(0))) else self.values[0].?;
            const array = (try self.type_interner.facts().arrayType(source.type_id)) orelse unreachable;
            try self.recordUse(source);
            const element = try self.arrayElement(source, self.values[1].?, array.element_type);
            const reference = try self.appendInstruction(.{ .borrow_address = .{
                .source = element.id,
                .type_id = self.return_type,
            } });
            try self.returnValue(try self.withMutableParameterOrigin(source, reference), span);
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
        };

        const ResultRequest = struct {
            value: ValueContext = .{},
            destination: ?Destination = null,
            destination_span: ?structures.SourceSpan = null,
            discard: bool = false,
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
                    .discard, .lifetime_extend, .propagate, .bind_local, .bind_borrow => try self.completedStatement(statement),
                    .break_loop => |value_id| try self.breakLoop(value_id),
                    .continue_loop => |span| try self.continueLoop(span),
                    .return_nothing => |span| try self.returnNothing(span),
                    .return_value => |returned| try self.returnExpression(returned.value, returned.span),
                    .failure => |span| try self.failFunction(span),
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
                try self.appendBoundary(boundary);
            }
            self.unbindLocalsSince(baseline);
            return result;
        }

        fn completedStatement(self: *Self, statement: semantic.UnresolvedBody.Statement) !void {
            const span = switch (statement) {
                .discard, .lifetime_extend => |value_use| value_use.span,
                .propagate => |propagation| propagation.span,
                .bind_local => |binding| binding.span,
                .bind_borrow => |binding| binding.span,
                else => unreachable,
            };
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            switch (statement) {
                .discard, .lifetime_extend => |value_use| try self.discardValue(try self.discardedValue(value_use.value), value_use.span),
                .propagate => |propagation| try self.propagateCondition(propagation.condition, propagation.span),
                .bind_local => |binding| try self.bindLocal(binding),
                .bind_borrow => |binding| try self.bindBorrow(binding),
                else => unreachable,
            }
            if (self.current_block != null) try self.appendBoundary(boundary);
        }

        fn bindLocal(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_local")) !void {
            var bound_value = if (try self.inPlaceConditionalType(binding.value)) |type_id|
                try self.construct(binding.value, binding.span, .{ .storage = try self.localStorage(type_id), .site = .local })
            else
                try self.ownValue(try self.valueWithContext(binding.value, .{ .access = .initialize }), binding.span);
            if (bound_value.type_id == .never) return;
            bound_value.binding_identity = try self.newBindingIdentity();
            const index = @backingInt(binding.local);
            std.debug.assert(self.local_values[index] == null);
            self.local_values[index] = bound_value;
            self.locals.items(.mutable)[index] = binding.mutable;
            self.local_availability[index] = .available;
            for (self.field_places, self.field_availability) |place, *availability| {
                if (place.local == binding.local) availability.* = .available;
            }
        }

        fn bindBorrow(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_borrow")) !void {
            var alias: Alias = .{};
            var reference: Value = undefined;
            const source_index = @backingInt(binding.source);
            const source_expression = if (source_index < self.unresolved.parameter_count) null else self.unresolved.expressions[source_index - self.unresolved.parameter_count];
            if (source_expression != null and source_expression.?.operation == .dereference) {
                const handle = source_expression.?.operation.dereference;
                reference = try self.borrowValue(try self.value(handle.value), handle.span);
                if (reference.type_id == .never) return;
                const access = (try self.type_interner.facts().borrowAccess(reference.type_id)) orelse
                    return self.reject(handle.span, .{ .dereference_requires_ref = reference.type_id });
                if (binding.writable and !access.writable) return self.reject(binding.span, .reference_not_writable);
                if (reference.reference_origins == null) return self.reject(binding.span, .borrow_outlives_source);
                reference = withoutOwnershipSource(reference);
            } else {
                var fields: std.ArrayList(PlaceField) = .empty;
                defer fields.deinit(self.ctx.allocator());
                const place = (try self.resolveBorrowPlace(binding.source, &fields)) orelse
                    return self.reject(binding.span, .borrow_requires_place);
                const source = try self.borrowValue(try self.value(binding.source), binding.span);
                if (source.type_id == .never) return;
                const projected = try self.projectBorrowPlace(place, fields.items, binding.writable, binding.span);
                const root = projected.root;
                if (projected.alias != null and place.fields.start == place.fields.end) {
                    reference = root;
                } else {
                    reference = try self.appendInstruction(.{ .borrow_address = .{
                        .source = root.id,
                        .type_id = (try self.type_interner.referenceType(source.type_id, projected.writable)) orelse return error.Unavailable,
                        .fields = projected.fields,
                        .base_is_reference = projected.alias != null,
                    } });
                }
                if (projected.alias) |captured| {
                    reference.reference_origins = root.reference_origins;
                    alias = captured;
                    if (place.fields.start != place.fields.end and alias.root != null) {
                        alias.fields = try self.concatBorrowFields(alias.fields, projected.fields);
                        alias.whole_root = false;
                    }
                } else {
                    if (place.root == .parameter and try self.type_interner.facts().argumentPassing(root.type_id) == .direct) {
                        reference.reference_origins = try self.addReferenceOrigin(source.reference_origins, .{ .cleanup_value = root.id });
                    } else {
                        reference = try self.withReferenceOrigin(source, reference);
                    }
                    alias = .{ .root = place.root, .fields = projected.fields, .whole_root = place.fields.start == place.fields.end };
                }
            }
            const access = (try self.type_interner.facts().borrowAccess(reference.type_id)) orelse unreachable;
            if (!binding.writable and access.writable) {
                var read_only = try self.appendInstruction(.{ .value_copy = .{
                    .source = reference.id,
                    .type_id = (try self.type_interner.referenceType(access.element_type, false)) orelse return error.Unavailable,
                } });
                read_only.reference_origins = reference.reference_origins;
                read_only.stable_reference_root = reference.stable_reference_root;
                reference = read_only;
            }
            const index = @backingInt(binding.local);
            std.debug.assert(self.local_values[index] == null);
            self.local_values[index] = reference;
            self.locals.items(.alias)[index] = alias;
            self.local_availability[index] = .available;
        }

        fn newBindingIdentity(self: *Self) !BindingIdentity {
            const identity = self.next_binding_identity;
            self.next_binding_identity = std.math.add(u32, identity, 1) catch return error.AnalysisTooLarge;
            return .{ .fixed = identity };
        }

        fn joinBindingIdentities(self: *Self, first: BindingIdentity, second: BindingIdentity) !BindingIdentity {
            if (std.meta.eql(first, second)) return first;
            const index: u32 = @intCast(self.binding_joins.items.len);
            try self.binding_joins.append(self.ctx.allocator(), .{ .initial = first, .complete = true });
            try self.binding_joins.items[index].alternatives.append(self.ctx.allocator(), second);
            return .{ .join = index };
        }

        fn discardValue(self: *Self, value_to_discard: Value, span: structures.SourceSpan) !void {
            _ = try self.borrowValue(value_to_discard, span);
        }

        fn breakLoop(self: *Self, value_id: semantic.UnresolvedBody.ValueId) !void {
            if (self.is_initializer_region and self.loop_stack.items.len == 0) return self.reject(self.valueSpan(value_id), .initializer_exit_outside_boundary);
            const context = self.loop_stack.last().?;
            var value_to_break = try self.evaluateValue(value_id, context.result);
            if (value_to_break.type_id == .never) return;
            if (context.result.discard) value_to_break = try self.discardResult(value_to_break, self.valueSpan(value_id));
            value_to_break = try self.ownValueEscapingSince(value_to_break, context.baseline, self.unresolved.blocks[@backingInt(self.unresolved.root_block)].span);
            self.unbindLocalsSince(context.baseline);
            const state = try self.captureState();
            try self.loop_breaks.append(self.ctx.allocator(), .{ .block = self.suspendBlock(), .state = state, .constructed = value_to_break });
        }

        fn continueLoop(self: *Self, span: structures.SourceSpan) !void {
            if (self.is_initializer_region and self.loop_stack.items.len == 0) return self.reject(span, .initializer_exit_outside_boundary);
            const context = self.loop_stack.last().?;
            self.unbindLocalsSince(context.baseline);
            try self.normalizeLoopBackedge(context, span);
            try self.validateLoopBackedge(context, span);
            const branch = try self.loopBranch(context);
            self.terminate(.{ .branch = branch });
        }

        fn returnNothing(self: *Self, span: structures.SourceSpan) !void {
            if (self.is_initializer_region) return self.reject(span, .initializer_exit_outside_boundary);
            if (self.return_type == .unit) {
                try self.finishFunctionExit(span, .return_unit);
                return;
            }
            const unit = try self.appendInstruction(.const_unit);
            const use = try self.coerceValue(unit.id, .unit, self.return_type) orelse
                return self.reject(span, .{ .missing_return_value = self.return_type });
            try self.finishFunctionExit(span, .{ .return_value = use });
        }

        fn returnExpression(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan) !void {
            if (self.is_initializer_region) return self.reject(span, .initializer_exit_outside_boundary);
            if (self.infer_return_type or !try self.constructsInPlace(self.return_type))
                return self.returnValue(try self.valueWithContext(id, .{ .expected_type = self.return_type, .access = .initialize }), span);
            const storage = try self.appendInstruction(.{ .result_storage = self.return_type });
            const result = try self.construct(id, span, .{ .storage = storage, .site = .return_value });
            if (result.type_id == .never) return;
            try self.returnConstructed(result, span);
        }

        fn returnConstructed(self: *Self, result: Value, span: structures.SourceSpan) !void {
            try self.validateEscapingBorrows(result, span);
            if (self.is_initializer_region) self.returned_reference_origins = try self.mergeReferenceOrigins(self.returned_reference_origins, result.reference_origins);
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
            const returned = if (use.coerce_to) |target_type| try self.transitionOwnedType(owned, target_type, span) else owned;
            if (self.is_initializer_region) self.returned_reference_origins = try self.mergeReferenceOrigins(self.returned_reference_origins, returned.reference_origins);
            try self.recordConsume(returned);
            use.value = returned.id;
            try self.finishFunctionExit(span, if (self.return_type == .unit) .return_unit else .{ .return_value = use });
        }

        fn validateEscapingBorrows(self: *Self, candidate: Value, span: structures.SourceSpan) !void {
            if (!try self.type_interner.canStoreBorrow(candidate.type_id)) return;
            const origins = candidate.reference_origins orelse {
                if (try self.typeContainsBorrow(candidate.type_id)) return self.reject(span, .borrow_outlives_source);
                return;
            };
            var pending = false;
            const resolved = try self.resolveReferenceOrigins(origins, &pending);
            if (pending)
                try self.pending_reference_returns.append(self.ctx.allocator(), .{ .origins = origins, .span = span })
            else
                try self.validateReferenceEscape(resolved, span);
        }

        fn validateReferenceEscape(self: *Self, origins: ?u32, span: structures.SourceSpan) !void {
            var origin_id = origins orelse return self.reject(span, .borrow_outlives_source);
            while (true) {
                const origin = self.reference_origins.items[origin_id];
                if (origin.parameter == null) return self.reject(span, .borrow_outlives_source);
                origin_id = origin.next orelse break;
            }
        }

        fn propagateCondition(self: *Self, condition_id: semantic.UnresolvedBody.ConditionId, span: structures.SourceSpan) !void {
            if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
            const flow = try self.condition(condition_id);
            if (flow.failure) |failure| {
                try self.propagateFailure(failure, span);
            }
            if (flow.success) |success| {
                try self.enterFlowExit(success);
            }
        }

        fn propagateFailure(self: *Self, failure: FlowExit, span: structures.SourceSpan) !void {
            try self.enterFlowExit(failure);
            try self.finishFunctionExit(span, .return_failure);
        }

        fn failFunction(self: *Self, span: structures.SourceSpan) !void {
            if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
            try self.finishFunctionExit(span, .return_failure);
        }

        fn unbindLocalsSince(self: *Self, baseline: StateId) void {
            const initial = self.states.items[@backingInt(baseline)].availability;
            var index = self.local_availability.len;
            while (index > 0) {
                index -= 1;
                if (initial[index] == .unbound and self.local_availability[index] != .unbound) self.unbindLocal(index);
            }
        }

        fn unbindAllLocals(self: *Self) void {
            var index = self.local_availability.len;
            while (index > 0) {
                index -= 1;
                if (self.local_availability[index] != .unbound) self.unbindLocal(index);
            }
        }

        fn finishFunctionExit(self: *Self, span: structures.SourceSpan, terminator: structures.FunctionTerminator) !void {
            if (terminator == .return_value or terminator == .return_unit) {
                for (self.init_availability, 0..) |availability, parameter| {
                    if (availability == .pending and self.is_initializer_region and self.captured_values[parameter]) continue;
                    if (availability == .pending or availability == .maybe_consumed) return self.reject(span, .initializer_not_consumed);
                }
            }
            if (self.is_initializer_region and (terminator == .return_value or terminator == .return_unit or terminator == .return_failure))
                try self.ordinary_completion_states.append(self.ctx.allocator(), try self.captureState());
            const boundary = try self.newBoundary(span);
            const block_value = &self.blocks.items[@backingInt(self.current_block orelse unreachable)];
            try self.boundaries.items[@backingInt(boundary)].effects.appendSlice(
                self.ctx.allocator(),
                block_value.terminator_effects.items,
            );
            block_value.terminator_effects.clearRetainingCapacity();
            self.relocateReferenceUses(.{ .terminator = .{ .id = self.current_block.?, .effect_index = 0 } }, .{ .boundary = .{ .id = boundary, .effect_index = 0 } });
            const parent_boundary = self.current_boundary;
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            try self.writeMutParameters();
            self.unbindAllLocals();
            try self.appendBoundary(boundary);
            self.terminate(terminator);
        }

        fn ownValueEscapingSince(self: *Self, result: Value, baseline: StateId, span: structures.SourceSpan) !Value {
            const root = result.borrow_root orelse return result;
            if (self.states.items[@backingInt(baseline)].availability[@backingInt(root)] != .unbound) return result;
            if (result.borrowed_generation == null) {
                if (self.local_values[@backingInt(root)]) |owner| try self.recordUse(owner);
            }
            return self.ownValue(result, span);
        }

        fn unbindLocal(self: *Self, index: usize) void {
            self.local_values[index] = null;
            self.local_availability[index] = .unbound;
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

        fn evaluateValue(self: *Self, id: semantic.UnresolvedBody.ValueId, request: ResultRequest) anyerror!Value {
            const index = @backingInt(id);
            if (request.destination) |destination| {
                const span = request.destination_span orelse self.valueSpan(id);
                if (self.values[index]) |pending| if (pending.initializer_parameter != null) return self.constructInitializer(pending, span, destination.storage);
                if (!try self.constructsDirectly(id, destination.storage.type_id)) return self.placeEvaluated(id, span, destination);
            }
            var context: ValueContext = if (request.destination) |destination| .{ .expected_type = destination.storage.type_id, .access = .initialize, .fresh_destination = destination.storage } else request.value;
            if (context.expected_type == null and index >= self.unresolved.parameter_count) {
                const operation = self.unresolved.expressions[index - self.unresolved.parameter_count].operation;
                if (operation == .annotation) context.expected_type = operation.annotation.type_id;
            }
            if (request.destination == null and context.allow_converters) if (try self.staticConversion(id, context)) |converted| return converted;
            if (context.access == .borrow) std.debug.assert(context.expected_type != null);
            if (context.fresh_destination != null) std.debug.assert(context.access == .consume or context.access == .initialize);
            if (context.access == .consume) {
                var fields: std.ArrayList(PlaceField) = .empty;
                defer fields.deinit(self.ctx.allocator());
                if (try self.resolveBorrowPlace(id, &fields)) |place| {
                    const selected = try self.consumeOwnedPlace(place, fields.items, context.expected_type, self.valueSpan(id));
                    if (context.fresh_destination) |destination| {
                        if (self.is_initializer_region and place.root == .local and self.captured_locals[@backingInt(place.root.local)] == null) {
                            const capabilities = (try self.type_interner.facts().ownershipCapabilities(selected.type_id)) orelse return error.Unavailable;
                            if (capabilities.move == .none) return self.reject(self.valueSpan(id), .{ .type_not_movable = selected.type_id });
                            return self.moveValue(selected, self.valueSpan(id), destination);
                        }
                    }
                    return selected;
                }
            }
            if (self.values[index]) |resolved| {
                return self.contextualValue(resolved, context, self.valueSpan(id));
            }
            std.debug.assert(index >= self.unresolved.parameter_count);
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            const expected_type = context.expected_type;
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(expression.span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            const resolved: Value = switch (expression.operation) {
                .integer_literal => |integer| if (expected_type == .int_literal)
                    try self.appendInstruction(.{ .const_int_literal = integer })
                else
                    try self.appendInstruction(.{ .const_int = std.math.cast(i32, integer) orelse return self.reject(expression.span, .integer_literal_out_of_range) }),
                .integer => |integer| try self.appendInstruction(.{ .const_int = integer }),
                .byte => |byte| try self.appendInstruction(.{ .const_byte = byte }),
                .boolean => |boolean| try self.appendInstruction(.{ .const_bool = boolean }),
                .type_value => |type_id| if (self.allow_type_values)
                    try self.appendInstruction(.{ .const_type = type_id })
                else
                    return self.reject(expression.span, .type_value_used_as_runtime_value),
                .unit => try self.appendInstruction(.const_unit),
                .none => try self.appendInstruction(.const_none),
                .function_ref => |reference| try self.appendInstruction(.{ .function_ref = reference }),
                .local_read => |local| try self.readLocal(local, expression.span),
                .local_transfer => |local| explicitTransfer(if (request.destination) |destination|
                    try self.constructLocalTransfer(local, expression.span, destination)
                else if (context.fresh_destination) |destination|
                    try self.constructLocalTransfer(local, expression.span, .{ .storage = destination, .site = .argument })
                else
                    try self.transferLocal(local, expression.span, null)),
                .field_transfer => |transfer| explicitTransfer(if (request.destination) |destination|
                    try self.constructFieldTransfer(transfer, expression.span, destination)
                else if (context.fresh_destination) |destination|
                    try self.constructFieldTransfer(transfer, expression.span, .{ .storage = destination, .site = .argument })
                else
                    try self.transferField(transfer, expression.span)),
                .annotation => |annotation| if (request.destination) |destination|
                    try self.constructAnnotated(annotation, destination)
                else if ((context.access == .borrow or context.access == .consume) and expected_type != null)
                    try self.constructAnnotated(annotation, .{ .storage = context.fresh_destination orelse try self.localStorage(expected_type.?), .site = .argument })
                else
                    try self.annotate(annotation, context),
                .struct_init => if (request.destination) |destination|
                    try self.constructStruct(expression, destination)
                else if ((context.access == .borrow or context.access == .consume) and expected_type != null)
                    try self.constructStruct(expression, .{ .storage = context.fresh_destination orelse try self.localStorage(expected_type.?), .site = .argument })
                else
                    try self.structInit(expression),
                .array_init => |initializer| try self.constructArray(expression, request.destination orelse .{
                    .storage = context.fresh_destination orelse try self.localStorage(initializer.type_id),
                    .site = .local,
                }),
                .collection_literal => |elements| try self.collectionValue(id, expression, elements, context),
                .field_access => try self.fieldAccess(expression),
                .dereference => |reference| try self.dereference(reference),
                .index_snapshot => |source| blk: {
                    const index_value = try self.borrowValue(try self.valueWithType(source.value, .int), source.span);
                    if (index_value.type_id == .never) break :blk index_value;
                    if (index_value.type_id != .int) return self.reject(source.span, .{ .call_argument_type_mismatch = self.typeMismatch(.int, index_value.type_id) });
                    break :blk try self.appendInstruction(.{ .value_copy = .{ .source = index_value.id, .type_id = .int } });
                },
                .assignment => try self.assignment(expression),
                .borrow_assignment => |assignment_alias| try self.borrowAssignment(assignment_alias),
                .reference_assignment => |assignment_ref| try self.referenceAssignment(assignment_ref),
                .sequence => |operands| blk: {
                    const first = try self.value(operands.lhs.value);
                    if (first.type_id == .never) break :blk first;
                    break :blk try self.valueWithContext(operands.rhs.value, context);
                },
                .call => |call| try self.callFunction(call, expression.span, .{ .value = context, .destination = request.destination orelse if (context.access == .consume and context.fresh_destination != null) .{ .storage = context.fresh_destination.?, .site = .argument } else null }),
                .negate => |operand| try self.negate(operand),
                .add, .subtract, .multiply, .divide => try self.binary(expression),
                .if_else => |expression_if| try self.conditional(expression_if, .{ .value = context, .destination = request.destination, .discard = request.discard }),
                .loop => |body| try self.loop(body, .{ .value = context, .destination = request.destination, .discard = request.discard }),
            };
            const result = if (request.destination != null) resolved else try self.contextualValue(resolved, context, expression.span);
            if (self.current_block != null) try self.appendBoundary(boundary);
            self.values[index] = result;
            try self.rememberCleanupOrigins(result);
            return result;
        }

        fn contextualValue(self: *Self, source: Value, context: ValueContext, span: structures.SourceSpan) !Value {
            if (source.type_id == .int_literal) if (try self.literalDefaultTarget(context.expected_type)) |target| {
                var default_context = context;
                default_context.expected_type = target;
                return self.stageStaticValue(source, default_context, span);
            };
            if (context.allow_converters) if (context.expected_type) |target| {
                if (source.type_id != target and source.type_id != .never) {
                    const candidates = try self.type_interner.conversionCandidates(source.type_id, target, null);
                    defer self.ctx.allocator().free(candidates);
                    const builtin = try semantic.canWidenTo(self.type_interner, source.type_id, target);
                    if (candidates.len + @intFromBool(builtin) > 1)
                        return self.reject(span, .{ .ambiguous_conversion = self.typeMismatch(target, source.type_id) });
                    if (candidates.len == 1) return self.convertValue(source, candidates[0], context, span);
                }
            };
            if (source.initializer_parameter) |parameter| {
                if (self.init_availability[parameter] != .pending) return self.reject(span, .initializer_already_consumed);
                if (context.access == .initialize) return self.constructInitializer(source, span, null);
                if (context.access != .value) return self.reject(span, .initializer_requires_construction);
            }
            if (context.access == .value or context.access == .initialize or source.type_id == .never) return source;
            if (context.access == .borrow and source.explicit_transfer) return self.reject(span, .ownership_transfer_requires_owning_context);
            if (context.access == .consume and source.borrowed_type != null) return self.reject(span, .ownership_transfer_requires_owned_place);
            const target_type = context.expected_type orelse return source;
            if (source.type_id == target_type) return source;
            if (source.preserves_storage) return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(target_type, source.type_id) });
            const use = try self.coerceValue(source.id, source.type_id, target_type) orelse
                return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(target_type, source.type_id) });
            return self.coerceOwnedRepresentation(source, use, span, if (try self.constructsInPlace(target_type)) context.fresh_destination orelse try self.localStorage(target_type) else null);
        }

        fn convertValue(self: *Self, source: ?Value, candidate: structures.ConversionCandidate, context: ValueContext, span: structures.SourceSpan) !Value {
            if (!self.type_check_only) {
                // Validate the selected converter's constraints at its actual use.
                _ = (try self.type_interner.functionSignature(candidate.instance)) orelse return error.Unavailable;
            }
            const consuming = candidate.source_mode == .init;
            std.debug.assert((candidate.source_mode == .static) == (source == null));
            const operand = if (source) |runtime_source| if (consuming) runtime_source else try self.borrowValue(runtime_source, span) else null;
            if (consuming and operand.?.initializer_parameter != null) try self.consumeInitializer(operand.?, span);
            if (operand) |runtime_operand| try self.recordUse(runtime_operand);
            var references: std.ArrayList(Value) = .empty;
            defer references.deinit(self.ctx.allocator());
            if (!consuming) if (operand) |runtime_operand| try self.collectWritableReferences(runtime_operand, &references);
            const writable_start: u32 = @intCast(self.writable_call_references.items.len);
            try self.writable_call_references.appendSlice(self.ctx.allocator(), references.items);
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            if (operand) |runtime_operand| try self.call_arguments.append(self.ctx.allocator(), if (consuming) .{ .initializer = runtime_operand.id } else .{ .prepared = .{ .value = runtime_operand.id } });
            const origins = if (operand != null and try self.type_interner.canStoreBorrow(candidate.target_type))
                try self.transformReferenceOrigins(if (consuming or try self.type_interner.facts().borrowElement(operand.?.type_id) != null) operand.?.reference_origins else try self.sourceReferenceOrigins(operand.?), .widen)
            else
                null;
            const empty_mut: u32 = @intCast(self.pending_mut_arguments.items.len);
            const empty_consumed: u32 = @intCast(self.pending_consumed_arguments.items.len);
            const call: semantic.UnresolvedBody.Call = .{ .target = .{ .direct = candidate.instance }, .arguments = .{ .start = 0, .end = 0 }, .span = span };
            const callable: ResolvedCallable = .{
                .operation = .{ .target = .{ .direct = candidate.instance }, .arguments = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) }, .return_type = candidate.target_type },
                .behavior = .ordinary,
                .is_fallible = consuming and self.initializerCanFail(operand.?),
                .inherits_initializer_failure = consuming,
                .mut_arguments = .{ .start = empty_mut, .end = empty_mut },
                .consumed_arguments = .{ .start = empty_consumed, .end = empty_consumed },
                .writable_references = .{ .start = writable_start, .end = @intCast(self.writable_call_references.items.len) },
                .reference_origins = origins,
            };
            const result = try self.resolvedCallResult(callable, call, span, .{ .value = context, .destination = if (context.fresh_destination) |storage| .{ .storage = storage, .site = .argument } else null });
            if (result.type_id == context.expected_type.?) return result;
            const widened = (try self.coerceValue(result.id, result.type_id, context.expected_type.?)).?;
            return self.coerceOwnedRepresentation(result, widened, span, if (try self.constructsInPlace(context.expected_type.?)) try self.localStorage(context.expected_type.?) else null);
        }

        fn staticConversion(self: *Self, id: semantic.UnresolvedBody.ValueId, context: ValueContext) !?Value {
            const target = context.expected_type orelse return null;
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) {
                const source = self.values[index].?;
                if (source.initializer_parameter != null) return null;
                if (source.type_id == .int_literal and try self.literalDefaultTarget(target) != null) return null;
                if (source.type_id == target or source.type_id == .never or source.type_id == .type or try self.type_interner.facts().isRuntimeCapable(source.type_id)) return null;
                return try self.stageStaticConversion(id, source.type_id, context, self.valueSpan(id));
            }
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            if (expression.source_node == .null) return null;
            const is_literal = expression.operation == .integer_literal;
            if (is_literal and target == .int) return null;
            if (is_literal) if (try self.type_interner.facts().variantMembers(target)) |members| {
                for (members) |member| if (member == .int) return null;
            };
            const source_type: structures.TypeId = switch (expression.operation) {
                .integer_literal => .int_literal,
                .struct_init => |initializer| if (initializer.target == .concrete) initializer.target.concrete else (try self.unevaluatedType(id, null)) orelse return null,
                .array_init => |initializer| initializer.type_id,
                .annotation => |annotation| annotation.type_id,
                .local_read => |local| if (self.local_values[@backingInt(local)]) |resolved| resolved.type_id else return null,
                .call => (try self.unevaluatedType(id, null)) orelse return null,
                .field_access => |access| probe: {
                    const operand_type = (try self.unevaluatedType(access.operand.value, null)) orelse return null;
                    const definition = (try self.type_interner.structDefinition(operand_type)) orelse return null;
                    const field = definition.resolveField(access.name) orelse return null;
                    break :probe field.type_id;
                },
                else => return null,
            };
            if (source_type == .int_literal and try self.literalDefaultTarget(target) != null) return null;
            if (source_type == target or source_type == .never or source_type == .type or try self.type_interner.facts().isRuntimeCapable(source_type)) return null;
            // Inference must not execute conversions nested inside the source.
            if (self.type_check_only) return try self.stageStaticConversion(id, source_type, context, expression.span);
            if (!is_literal and (self.allow_type_values or expression.operation == .local_read)) {
                return try self.stageStaticConversion(id, source_type, context, expression.span);
            }
            const source_value = (try self.type_interner.executeComptimeWithType(expression.source_node, source_type)) orelse return error.Unavailable;
            const candidates = try self.type_interner.conversionCandidates(source_type, target, source_value);
            defer self.ctx.allocator().free(candidates);
            const builtin = try semantic.canWidenTo(self.type_interner, source_type, target);
            if (candidates.len + @intFromBool(builtin) > 1)
                return self.reject(expression.span, .{ .ambiguous_conversion = self.typeMismatch(target, source_type) });
            if (candidates.len == 0) return null;
            return try self.convertValue(null, candidates[0], context, expression.span);
        }

        fn literalDefaultTarget(self: *Self, expected_type: ?structures.TypeId) !?structures.TypeId {
            const target = expected_type orelse return .int;
            if (target == .int) return target;
            const members = (try self.type_interner.facts().variantMembers(target)) orelse return null;
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
            switch (self.local_availability[index]) {
                .unbound => unreachable,
                .available => {},
                .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
            }
            if (self.unavailableField(local, &[_]PlaceField{})) |availability|
                return self.reject(span, unavailableUse(availability));
            if (self.locals.items(.alias)[index] != null) {
                const reference = try self.aliasReference(local);
                _ = try self.borrowValue(reference, span);
                const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
                return self.readReference(reference, reference.id, element_type, span);
            }
            return self.borrowLocalValue(local);
        }

        fn aliasReference(self: *Self, local: semantic.UnresolvedBody.LocalId) !Value {
            const index = @backingInt(local);
            const stored = self.local_values[index].?;
            const alias = self.locals.items(.alias)[index].?;
            const root = alias.root orelse return stored;
            const root_value = switch (root) {
                .local => |owner| self.local_values[@backingInt(owner)].?,
                .parameter => |parameter| self.values[@backingInt(parameter)].?,
            };
            var reference = try self.appendInstruction(.{ .borrow_address = .{
                .source = root_value.id,
                .type_id = stored.type_id,
                .fields = alias.fields,
            } });
            reference.reference_origins = stored.reference_origins;
            return reference;
        }

        fn borrowLocalValue(self: *Self, local: semantic.UnresolvedBody.LocalId) Value {
            var value_to_read = self.local_values[@backingInt(local)].?;
            value_to_read.borrowed_generation = value_to_read.owned_generation;
            value_to_read.borrowed_cleanup_value = value_to_read.id;
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
            try self.validateInitializerWrite(local, span);
            const consumption_completion = try self.captureTransferParameter(local, &.{}, span);
            if (self.locals.items(.mut_parameter)[@backingInt(local)] != null and consumption_completion == null) return self.reject(span, .ownership_transfer_requires_owned_place);
            var value_to_transfer = try self.readLocal(local, span);
            value_to_transfer.consumption_completion = consumption_completion;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(value_to_transfer.type_id)) orelse return error.Unavailable;
            if (capabilities.move == .none) return self.reject(span, .{ .type_not_movable = value_to_transfer.type_id });
            self.local_availability[@backingInt(local)] = .transferred;
            return self.moveValue(ownershipSource(value_to_transfer), span, destination);
        }

        fn captureTransferParameter(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan) !?structures.FunctionValueId {
            if (!self.is_initializer_region or self.captured_locals[@backingInt(local)] == null) return null;
            for (self.capture_transfers.items) |transfer| {
                if (transfer.local != local) continue;
                if (transfer.field) |field| {
                    const path = self.field_places[field].fields;
                    if (path.len == fields.len and fieldPathContains(path, fields)) return @fromBackingInt(@intCast(transfer.parameter));
                } else if (fields.len == 0) return @fromBackingInt(@intCast(transfer.parameter));
            }
            return self.reject(span, .ownership_transfer_requires_owned_place);
        }

        fn fieldPathContains(prefix: anytype, path: anytype) bool {
            if (prefix.len > path.len) return false;
            for (prefix, path[0..prefix.len]) |left, right| {
                if (!std.mem.eql(u8, left.name, right.name)) return false;
            }
            return true;
        }

        fn unavailableField(self: *const Self, local: semantic.UnresolvedBody.LocalId, path: anytype) ?Availability {
            for (self.field_places, self.field_availability) |place, availability| {
                if (place.local != local or availability == .available) continue;
                if (fieldPathContains(place.fields, path) or fieldPathContains(path, place.fields)) return availability;
            }
            return null;
        }

        fn hasUnavailableFields(self: *const Self, local: semantic.UnresolvedBody.LocalId) bool {
            return self.unavailableField(local, &[_]PlaceField{}) != null;
        }

        fn transferField(self: *Self, transfer: @FieldType(Expression.Operation, "field_transfer"), span: structures.SourceSpan) !Value {
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const root = self.local_values[@backingInt(transfer.target)].?;
            try self.resolvePlaceFields(root.type_id, self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end], span, &fields);
            return self.transferFieldPlace(transfer.target, fields.items, span, .{ .move = null });
        }

        const FieldTransfer = union(enum) { move: ?Value, consume };

        fn transferFieldPlace(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan, transfer: FieldTransfer) !Value {
            try self.validateInitializerWrite(local, span);
            const consumption_completion = try self.captureTransferParameter(local, fields, span);
            const local_index = @backingInt(local);
            const mutable_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            switch (self.local_availability[local_index]) {
                .available => {},
                .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
                .unbound => unreachable,
            }
            if (self.unavailableField(local, fields)) |availability|
                return self.reject(span, unavailableUse(availability));
            const root = self.local_values[local_index].?;
            const field_type = fields[fields.len - 1].type_id;
            const field_capabilities = (try self.type_interner.facts().ownershipCapabilities(field_type)) orelse return error.Unavailable;
            if (transfer == .move and field_capabilities.move == .none) return self.reject(span, .{ .type_not_movable = field_type });
            const moves_owner = field_capabilities.needs_automatic_drop or field_capabilities.requires_explicit_drop;
            try self.validateMissingFieldParents(local, fields, span);
            try self.recordUse(root);
            if (moves_owner and !mutable_parameter) try self.recordConsume(root);
            var field = root;
            for (fields) |part| {
                const origins = try self.transformReferenceOrigins(field.reference_origins, .{ .select = .{ .field = part.index } });
                field = if (transfer == .consume)
                    try self.projectStorage(field, part.type_id, .{ .field = part.index })
                else
                    try self.fieldView(field, part.index, part.type_id);
                field.reference_origins = origins;
            }
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
            for (self.field_places, self.field_availability) |*place, *availability| {
                if (place.local == local and place.fields.len == fields.len and fieldPathContains(place.fields, fields)) {
                    place.moves_owner = moves_owner;
                    availability.* = .transferred;
                }
            }
            if (moves_owner and !mutable_parameter and consumption_completion == null) {
                var remaining_generation: ?GenerationId = null;
                const previous_missing = if (root.owned_generation) |previous_generation|
                    self.generations.items[@backingInt(previous_generation)].missing_fields
                else
                    &.{};
                if ((try self.remainingFieldOwnership(root.type_id, previous_missing, fields)).any()) {
                    const remaining = try self.defineOwnedValue(root, span, self.locals.items(.can_deinit)[local_index]);
                    remaining_generation = remaining.owned_generation;
                    try self.copyMissingFields(remaining_generation.?, previous_missing, fields, null);
                }
                self.local_values[local_index].?.owned_generation = remaining_generation;
            }
            self.local_values[local_index].?.binding_identity = try self.newBindingIdentity();
            self.local_values[local_index].?.storage_identity = null;
            return moved;
        }

        fn validateMissingFieldParents(self: *Self, local: semantic.UnresolvedBody.LocalId, fields: []const PlaceField, span: structures.SourceSpan) !void {
            const local_index = @backingInt(local);
            const mutable_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            var parent_type = self.local_values[local_index].?.type_id;
            for (fields, 0..) |part, depth| {
                const parent_capabilities = (try self.type_interner.facts().ownershipCapabilities(parent_type)) orelse return error.Unavailable;
                const deinit_root = depth == 0 and self.locals.items(.can_deinit)[local_index];
                if (!deinit_root and parent_capabilities.drop != .fieldwise and parent_capabilities.drop != .trivial and
                    !(mutable_parameter and parent_capabilities.drop == .custom))
                    return self.reject(span, .partial_field_transfer_not_supported);
                if (parent_capabilities.needs_custom_move and !deinit_root)
                    return self.reject(span, .partial_field_transfer_not_supported);
                parent_type = part.type_id;
            }
        }

        const RemainingOwnership = struct {
            automatic: bool = false,
            explicit: bool = false,

            fn any(self: RemainingOwnership) bool {
                return self.automatic or self.explicit;
            }
        };

        fn remainingFieldOwnership(self: *Self, type_id: structures.TypeId, missing: []const []const u32, moved: []const PlaceField) !RemainingOwnership {
            const definition = (try self.type_interner.structDefinition(type_id)) orelse unreachable;
            var remaining: RemainingOwnership = .{};
            for (definition.fields, 0..) |field, index| {
                if (moved.len == 1 and moved[0].index == index) continue;
                var nested: std.ArrayList([]const u32) = .empty;
                defer nested.deinit(self.ctx.allocator());
                var absent = false;
                for (missing) |path| {
                    std.debug.assert(path.len != 0 and path[0] < definition.fields.len);
                    if (path[0] != index) continue;
                    if (path.len == 1) {
                        absent = true;
                        break;
                    }
                    try nested.append(self.ctx.allocator(), path[1..]);
                }
                if (absent) continue;
                const field_capabilities = (try self.type_interner.facts().ownershipCapabilities(field.type_id)) orelse return error.Unavailable;
                if (!field_capabilities.needs_automatic_drop and !field_capabilities.requires_explicit_drop) continue;
                const moved_child: []const PlaceField = if (moved.len != 0 and moved[0].index == index) moved[1..] else &.{};
                const child: RemainingOwnership = if (nested.items.len == 0 and moved_child.len == 0)
                    .{ .automatic = field_capabilities.needs_automatic_drop, .explicit = field_capabilities.requires_explicit_drop }
                else
                    try self.remainingFieldOwnership(field.type_id, nested.items, moved_child);
                remaining.automatic = remaining.automatic or child.automatic;
                remaining.explicit = remaining.explicit or child.explicit;
            }
            return remaining;
        }

        fn writeMutParameters(self: *Self) !void {
            for (self.locals.items(.mut_parameter), self.local_values, 0..) |parameter_index, local_value, local_index| {
                const index = parameter_index orelse continue;
                if (self.is_initializer_region and self.captured_locals[local_index] != null and
                    (self.local_availability[local_index] == .transferred or self.local_availability[local_index] == .maybe_transferred or self.hasUnavailableFields(@fromBackingInt(@intCast(local_index))))) continue;
                if (self.local_availability[local_index] != .available) return self.reject(self.activeLifetimeSpan(), unavailableUse(self.local_availability[local_index]));
                for (self.field_places, self.field_availability) |place, availability| {
                    if (@backingInt(place.local) == local_index and availability != .available)
                        return self.reject(self.activeLifetimeSpan(), .field_not_restored_before_mut_return);
                }
                const value_to_write = local_value.?;
                try self.validateEscapingBorrows(value_to_write, self.activeLifetimeSpan());
                if (self.is_initializer_region) {
                    const previous = self.capture_output_origins.get(index) orelse null;
                    try self.capture_output_origins.put(self.ctx.allocator(), index, try self.mergeReferenceOrigins(previous, value_to_write.reference_origins));
                }
                _ = try self.appendInstruction(.{ .mut_parameter_write = .{
                    .parameter_index = index,
                    .value = value_to_write.id,
                    .type_id = value_to_write.type_id,
                } });
                try self.recordConsume(value_to_write);
            }
        }

        fn writeCapturedLocal(self: *Self, local: semantic.UnresolvedBody.LocalId) !void {
            if (!self.is_initializer_region) return;
            const parameter = self.captured_locals[@backingInt(local)] orelse return;
            const updated = self.local_values[@backingInt(local)].?;
            const previous = self.capture_output_origins.get(parameter) orelse null;
            try self.capture_output_origins.put(self.ctx.allocator(), parameter, try self.mergeReferenceOrigins(previous, updated.reference_origins));
            _ = try self.appendInstruction(.{ .mut_parameter_write = .{ .parameter_index = parameter, .value = updated.id, .type_id = updated.type_id } });
        }

        fn constructsInPlace(self: *Self, type_id: structures.TypeId) !bool {
            return try self.type_interner.facts().argumentPassing(type_id) == .indirect;
        }

        fn localStorage(self: *Self, type_id: structures.TypeId) !Value {
            return self.appendInstruction(.{ .local_storage = type_id });
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
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count or self.values[index] != null or !try self.constructsInPlace(expected_type))
                return false;
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            if (expression.operation == .struct_init or expression.operation == .array_init or expression.operation == .call) {
                if (try self.unevaluatedType(id, null)) |source_type| {
                    if (source_type != expected_type and source_type != .never) {
                        if (!try semantic.canWidenTo(self.type_interner, source_type, expected_type))
                            return false;
                        const candidates = try self.type_interner.conversionCandidates(source_type, expected_type, null);
                        defer self.ctx.allocator().free(candidates);
                        if (candidates.len != 0) return false;
                    }
                }
            }
            switch (expression.operation) {
                .struct_init, .array_init, .collection_literal, .call, .if_else, .loop, .annotation, .local_transfer, .field_transfer => return true,
                else => return false,
            }
        }

        fn placeEvaluated(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan, destination: Destination) !Value {
            const source = try self.valueWithContext(id, .{ .expected_type = destination.storage.type_id, .access = .initialize, .fresh_destination = destination.storage });
            if (source.id == destination.storage.id) return source;
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            const placed = try self.placeValue(source, span, destination);
            if (self.current_block != null) try self.appendBoundary(boundary);
            return placed;
        }

        fn placeValue(self: *Self, source: Value, span: structures.SourceSpan, destination: Destination) !Value {
            if (source.type_id == .never) return source;
            const target_type = destination.storage.type_id;
            if (!try self.constructsInPlace(source.type_id)) {
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
            const members = (try self.type_interner.facts().variantMembers(destination.type_id)) orelse return null;
            if (try self.type_interner.facts().variantMembers(source_type) != null or !containsType(members, source_type)) return null;
            return try self.projectStorage(destination, source_type, .variant);
        }

        fn memberDestination(self: *Self, destination: Destination, source_type: structures.TypeId, span: structures.SourceSpan, source: enum { fresh, existing }) !Value {
            if (try self.memberStorage(destination.storage, source_type)) |storage| return storage;
            if (!try semantic.canWidenTo(self.type_interner, source_type, destination.storage.type_id))
                return self.reject(span, self.initializationMismatch(destination.site, destination.storage.type_id, source_type));
            if (source == .existing and try self.type_interner.facts().variantMembers(source_type) != null) return destination.storage;
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

        fn constructStruct(self: *Self, expression: Expression, destination: Destination) !Value {
            const initializer = expression.operation.struct_init;
            const type_id = switch (try self.structInitType(initializer)) {
                .diverged => |diverged| return diverged,
                .type_id => |resolved| resolved,
            };
            if (try self.type_interner.collectionLiteralType(type_id) != null) return self.reject(expression.span, .{ .compile_time_only_type = type_id });
            if (!try self.constructsInPlace(type_id)) return self.placeValue(try self.structInitValue(expression, type_id), expression.span, destination);
            const storage = try self.memberDestination(destination, type_id, expression.span, .fresh);
            return self.finishMemberStorage(try self.constructFields(expression, type_id, storage), destination.storage, expression.span);
        }

        fn constructFields(self: *Self, expression: Expression, type_id: structures.TypeId, storage: Value) !Value {
            const initializer = expression.operation.struct_init;
            const definition = try self.structInitializerDefinition(initializer, type_id);
            const seen = try self.ctx.allocator().alloc(bool, definition.fields.len);
            defer self.ctx.allocator().free(seen);
            @memset(seen, false);
            var fields: std.ArrayList(Value) = .empty;
            defer fields.deinit(self.ctx.allocator());
            var reference_origins: ?u32 = null;
            for (self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |source_field| {
                const field = definition.resolveField(source_field.name).?;
                if (seen[field.index]) return self.reject(source_field.name_span, .duplicate_struct_initializer_field);
                seen[field.index] = true;
                const field_storage = try self.projectStorage(storage, field.type_id, .{ .field = field.index });
                const field_value = try self.construct(source_field.value.value, source_field.value.span, .{ .storage = field_storage, .site = .field });
                if (field_value.type_id == .never) return field_value;
                try fields.append(self.ctx.allocator(), field_value);
                if (try self.type_interner.canStoreBorrow(field.type_id))
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

        fn constructArray(self: *Self, expression: Expression, destination: Destination) !Value {
            const initializer = expression.operation.array_init;
            return self.constructArrayElements(expression, initializer.type_id, initializer.elements, destination);
        }

        fn collectionValue(self: *Self, id: semantic.UnresolvedBody.ValueId, expression: Expression, elements: structures.FunctionValueRange, context: ValueContext) !Value {
            const array_type = try self.collectionArrayType(elements, context.expected_type, expression.span);
            if (!context.allow_converters) {
                var result = try self.constructArrayElements(expression, array_type, elements, .{ .storage = context.fresh_destination orelse try self.localStorage(array_type), .site = .local });
                if (context.expected_type) |expected| if (expected != array_type and result.type_id != .never and try self.type_interner.collectionLiteralType(expected) == null) {
                    std.debug.assert(self.type_check_only);
                    const source_type = try self.type_interner.internCollectionLiteralType((try self.type_interner.arrayType(array_type)).?);
                    const candidates = try self.type_interner.conversionCandidates(source_type, expected, null);
                    defer self.ctx.allocator().free(candidates);
                    if (candidates.len == 1) result.type_id = candidates[0].target_type;
                };
                return result;
            }
            const shape = (try self.type_interner.arrayType(array_type)).?;
            const source_type = try self.type_interner.internCollectionLiteralType(shape);
            const target = context.expected_type orelse array_type;
            const candidates = try self.type_interner.conversionCandidates(source_type, target, null);
            defer self.ctx.allocator().free(candidates);
            if (candidates.len != 1) return self.reject(expression.span, if (candidates.len > 1) .{ .ambiguous_conversion = self.typeMismatch(target, source_type) } else .{ .local_type_mismatch = self.typeMismatch(target, source_type) });
            const initializer = try self.prepareInitializer(.{ .value = id, .span = expression.span }, source_type);
            var target_context = context;
            target_context.expected_type = target;
            return self.convertValue(initializer, candidates[0], target_context, expression.span);
        }

        fn collectionArrayType(self: *Self, elements: structures.FunctionValueRange, expected_type: ?structures.TypeId, span: structures.SourceSpan) !structures.TypeId {
            var element_type: ?structures.TypeId = null;
            if (expected_type) |expected| if ((try self.type_interner.facts().arrayType(expected)) orelse try self.type_interner.collectionLiteralType(expected)) |array| {
                element_type = array.element_type;
            };
            if (element_type == null and expected_type != null) element_type = try self.type_interner.contextualCollectionElement(expected_type.?, elements.end - elements.start, span);
            if (element_type == null) {
                for (self.unresolved.call_arguments[elements.start..elements.end]) |element| {
                    var inferred = try self.inferInitializerType(element, null);
                    if (inferred == .int_literal) inferred = .int;
                    element_type = if (element_type) |previous| try joinTypes(self.type_interner, previous, inferred, self.ctx.allocator()) else inferred;
                }
            }
            return self.type_interner.internArrayType(.{ .element_type = element_type orelse return self.reject(span, .expression_not_supported), .length = elements.end - elements.start });
        }

        fn constructArrayElements(self: *Self, expression: Expression, type_id: structures.TypeId, elements: structures.FunctionValueRange, destination: Destination) !Value {
            const array = (try self.type_interner.facts().arrayType(type_id)) orelse unreachable;
            const storage = try self.memberDestination(destination, type_id, expression.span, .fresh);
            var completed: std.ArrayList(Value) = .empty;
            defer completed.deinit(self.ctx.allocator());
            var origins: ?u32 = null;
            for (self.unresolved.call_arguments[elements.start..elements.end], 0..) |source, index| {
                const position = try self.appendInstruction(.{ .const_int = @intCast(index) });
                const element_storage = try self.arrayElement(storage, position, array.element_type);
                const element = try self.construct(source.value, source.span, .{ .storage = element_storage, .site = .field });
                if (element.type_id == .never) return element;
                try completed.append(self.ctx.allocator(), element);
                origins = try self.mergeReferenceOrigins(origins, try self.transformReferenceOrigins(element.reference_origins, .{ .prefix = .element }));
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

        fn constructLocalTransfer(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan, destination: Destination) !Value {
            const source_type = try self.placeRootType(.{ .local = local });
            if (!try self.constructsInPlace(source_type)) return self.placeValue(try self.transferLocal(local, span, null), span, destination);
            const storage = try self.memberDestination(destination, source_type, span, .existing);
            return self.finishMemberStorage(try self.transferLocal(local, span, storage), destination.storage, span);
        }

        fn constructFieldTransfer(self: *Self, transfer: @FieldType(Expression.Operation, "field_transfer"), span: structures.SourceSpan, destination: Destination) !Value {
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const root = self.local_values[@backingInt(transfer.target)].?;
            try self.resolvePlaceFields(root.type_id, self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end], span, &fields);
            const source_type = fields.last().?.type_id;
            if (!try self.constructsInPlace(source_type))
                return self.placeValue(try self.transferFieldPlace(transfer.target, fields.items, span, .{ .move = null }), span, destination);
            const storage = try self.memberDestination(destination, source_type, span, .existing);
            return self.finishMemberStorage(try self.transferFieldPlace(transfer.target, fields.items, span, .{ .move = storage }), destination.storage, span);
        }

        fn discardedValue(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!Value {
            return self.evaluateValue(id, .{ .discard = true });
        }

        fn discardResult(self: *Self, result: Value, span: structures.SourceSpan) !Value {
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            try self.discardValue(result, span);
            const unit = try self.appendInstruction(.const_unit);
            try self.appendBoundary(boundary);
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

        fn validateInitializerWrite(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !void {
            if (std.mem.indexOfScalar(semantic.UnresolvedBody.LocalId, self.pending_initializer_locals.items, local) != null)
                return self.reject(span, .initializer_capture_conflict);
        }

        fn validateInitializerReferenceWrite(self: *Self, reference: Value, span: structures.SourceSpan) !void {
            if (self.is_initializer_region and reference.reference_origins != null) try self.capture_reference_writes.append(self.ctx.allocator(), reference);
            if (self.pending_initializer_owners.items.len == 0) return;
            var incomplete = false;
            var origins = try self.resolveReferenceOrigins(reference.reference_origins, &incomplete);
            if (incomplete) return self.reject(span, .initializer_capture_conflict);
            while (origins) |index| {
                const origin = self.reference_origins.items[index];
                origins = origin.next;
                if (origin.root) |root| try self.validateInitializerWrite(root, span);
                for (self.pending_initializer_owners.items) |owner| {
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
            if (try self.type_interner.facts().argumentPassing(type_id) == .indirect) return true;
            if (try self.type_interner.facts().boxElement(type_id) != null) return true;
            if (try self.type_interner.facts().allocationElement(type_id) != null) return true;
            if (try self.type_interner.structDefinition(type_id)) |definition| {
                for (definition.fields) |field| if (try self.captureMayShareStorage(field.type_id)) return true;
            } else if (try self.type_interner.facts().variantMembers(type_id)) |members| {
                for (members) |member| if (try self.captureMayShareStorage(member)) return true;
            }
            return false;
        }

        fn consumeInitializer(self: *Self, value_to_consume: Value, span: structures.SourceSpan) !void {
            const parameter = value_to_consume.initializer_parameter orelse unreachable;
            if (self.init_availability[parameter] != .pending) return self.reject(span, .initializer_already_consumed);
            self.init_availability[parameter] = .consumed;
        }

        fn constructInitializer(self: *Self, initializer: Value, span: structures.SourceSpan, destination: ?Value) !Value {
            const pending_collection = try self.type_interner.collectionLiteralType(initializer.type_id);
            const result_type = if (pending_collection) |shape| try self.type_interner.internArrayType(shape) else initializer.type_id;
            if (destination) |storage| if (storage.type_id != result_type) {
                const member = try self.memberDestination(.{ .storage = storage, .site = .local }, result_type, span, .fresh);
                const constructed = try self.constructInitializer(initializer, span, member);
                return self.finishMemberStorage(constructed, storage, span);
            };
            try self.consumeInitializer(initializer, span);
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            var storage = destination;
            if (storage == null and try self.constructsInPlace(result_type)) storage = try self.localStorage(result_type);
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            const declared_fallible = self.is_fallible;
            if (self.consuming_converter) self.is_fallible = true;
            defer self.is_fallible = declared_fallible;
            const result = try self.ordinaryCallValue(.{
                .operation = .{
                    .target = .{ .initializer = initializer.id },
                    .arguments = .{ .start = argument_start, .end = argument_start },
                    .return_type = result_type,
                },
                .behavior = .ordinary,
                .is_fallible = true,
                .mut_arguments = .{ .start = 0, .end = 0 },
                .consumed_arguments = .{ .start = 0, .end = 0 },
                .writable_references = .{ .start = 0, .end = 0 },
                .reference_origins = initializer.reference_origins,
            }, span, storage);
            if (self.current_block != null) try self.appendBoundary(boundary);
            return result;
        }

        fn initializerRegion(self: *Self, return_type: structures.TypeId) Self {
            return .{
                .ctx = self.ctx,
                .type_interner = self.type_interner,
                .instance = self.instance,
                .file_id = self.file_id,
                .unresolved = self.unresolved,
                .return_type = return_type,
                .is_fallible = true,
                .is_initializer_region = true,
                .shared_initializer_types = self.shared_initializer_types orelse &self.initializer_types,
            };
        }

        fn appendRegionCapture(self: *Self, captures: *std.ArrayList(Value), capture_locals: *std.ArrayList(?semantic.UnresolvedBody.LocalId), capture: struct {
            source: Value,
            local: ?semantic.UnresolvedBody.LocalId = null,
            mode: structures.ParameterMode = .imm,
        }) !u32 {
            const gpa = self.ctx.allocator();
            const argument = try self.appendBlockArgument(capture.source.type_id, null);
            self.block_arguments.items[argument].representation = .storage;
            try self.parameter_modes.append(gpa, capture.mode);
            try captures.append(gpa, capture.source);
            try capture_locals.append(gpa, capture.local);
            return argument;
        }

        fn bindRegionCaptures(self: *Self, region: *Self, captures: *std.ArrayList(Value), capture_locals: *std.ArrayList(?semantic.UnresolvedBody.LocalId)) !void {
            const gpa = self.ctx.allocator();
            const parameters = try gpa.alloc(structures.CallableParameter, self.unresolved.parameter_count);
            defer gpa.free(parameters);
            for (parameters, self.block_arguments.items[0..parameters.len]) |*parameter, source| parameter.* = .{ .mode = if (source.representation == .initializer) .init else .imm, .type_id = source.type_id };
            try region.init(parameters);
            region.captured_values = try gpa.alloc(bool, self.values.len);
            @memset(region.captured_values, false);
            region.captured_locals = try gpa.alloc(?u32, self.local_values.len);
            @memset(region.captured_locals, null);
            for (parameters, 0..) |parameter, index| {
                const source = self.values[index] orelse Value{ .id = @fromBackingInt(@intCast(index)), .type_id = parameter.type_id };
                try captures.append(gpa, source);
                try capture_locals.append(gpa, null);
                region.block_arguments.items[index].representation = if (parameter.mode == .init) .initializer else .storage;
                if (self.values[index] != null) {
                    region.values[index] = .{
                        .id = @fromBackingInt(@intCast(index)),
                        .type_id = source.type_id,
                        .borrowed_type = if (parameter.mode == .init) null else source.type_id,
                        .initializer_parameter = source.initializer_parameter,
                        .reference_origins = region.values[index].?.reference_origins,
                    };
                    region.captured_values[index] = true;
                } else region.values[index] = null;
            }
            for (self.values[parameters.len..], parameters.len..) |maybe_source, index| {
                const source = maybe_source orelse continue;
                const argument = try region.appendRegionCapture(captures, capture_locals, .{ .source = source, .local = source.borrow_root });
                region.values[index] = .{ .id = @fromBackingInt(@intCast(argument)), .type_id = source.type_id, .borrowed_type = source.type_id, .reference_origins = if (try self.type_interner.canStoreBorrow(source.type_id)) try region.addReferenceOrigin(null, .{ .parameter = argument }) else null };
                region.captured_values[index] = true;
            }
            for (self.local_values, 0..) |maybe_source, index| {
                var source = maybe_source orelse continue;
                source.borrow_root = @fromBackingInt(@intCast(index));
                const argument = try region.appendRegionCapture(captures, capture_locals, .{ .source = source, .local = @fromBackingInt(@intCast(index)) });
                region.local_values[index] = .{ .id = @fromBackingInt(@intCast(argument)), .type_id = source.type_id, .binding_identity = try region.newBindingIdentity(), .reference_origins = if (try self.type_interner.canStoreBorrow(source.type_id)) try region.addReferenceOrigin(null, .{ .parameter = argument }) else null };
                region.local_availability[index] = self.local_availability[index];
                region.locals.items(.mutable)[index] = self.locals.items(.mutable)[index];
                region.locals.items(.can_deinit)[index] = self.locals.items(.can_deinit)[index];
                if (self.locals.items(.alias)[index] != null) region.locals.items(.alias)[index] = .{};
                region.captured_locals[index] = argument;
            }
            @memcpy(region.field_availability, self.field_availability);
            for (self.local_values, 0..) |source, index| {
                if (source == null or self.locals.items(.mut_parameter)[index] != null or self.locals.items(.alias)[index] != null) continue;
                const argument = try region.appendRegionCapture(captures, capture_locals, .{ .source = .{ .id = @fromBackingInt(@intCast(0)), .type_id = .bool }, .mode = .mut });
                try region.capture_transfers.append(gpa, .{ .local = @fromBackingInt(@intCast(index)), .parameter = argument });
            }
            for (self.field_places, 0..) |place, field| {
                const index = @backingInt(place.local);
                if (self.local_values[index] == null or self.locals.items(.mut_parameter)[index] != null or self.locals.items(.alias)[index] != null) continue;
                const argument = try region.appendRegionCapture(captures, capture_locals, .{ .source = .{ .id = @fromBackingInt(@intCast(0)), .type_id = .bool }, .mode = .mut });
                try region.capture_transfers.append(gpa, .{ .local = place.local, .parameter = argument, .field = field });
            }
            region.blocks.items[0].argument_end = @intCast(captures.items.len);
        }

        fn inferInitializerType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId) anyerror!structures.TypeId {
            return self.inferExpressionType(raw, expected_type, true);
        }

        fn inferInitializerArgumentType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId) anyerror!structures.TypeId {
            if (@backingInt(raw.value) >= self.unresolved.parameter_count) {
                const expression = self.unresolved.expressions[@backingInt(raw.value) - self.unresolved.parameter_count];
                if (expression.operation == .collection_literal and (expected_type == null or try self.type_interner.collectionLiteralType(expected_type.?) != null)) {
                    const array_type = try self.collectionArrayType(expression.operation.collection_literal, expected_type, raw.span);
                    return self.type_interner.internCollectionLiteralType((try self.type_interner.facts().arrayType(array_type)).?);
                }
            }
            return self.inferInitializerType(raw, expected_type);
        }

        fn inferArgumentType(self: *Self, raw: semantic.UnresolvedBody.ValueUse) anyerror!structures.TypeId {
            return self.inferExpressionType(raw, null, false);
        }

        fn inferExpressionType(self: *Self, raw: semantic.UnresolvedBody.ValueUse, expected_type: ?structures.TypeId, initializer_boundary: bool) anyerror!structures.TypeId {
            if (self.values[@backingInt(raw.value)]) |pending| if (pending.initializer_parameter != null) return pending.type_id;
            const types = self.shared_initializer_types orelse &self.initializer_types;
            const key: InitializerTypeKey = .{ .expression = raw.value, .expected = expected_type, .initializer_boundary = initializer_boundary };
            if (types.get(key)) |type_id| return type_id;
            var region = self.initializerRegion(if (initializer_boundary) .unit else self.return_type);
            region.is_initializer_region = initializer_boundary;
            region.is_fallible = if (initializer_boundary) true else self.is_fallible;
            region.infer_return_type = initializer_boundary or self.infer_return_type;
            region.allow_type_values = self.allow_type_values;
            region.type_check_only = true;
            defer region.deinit();
            var captures: std.ArrayList(Value) = .empty;
            defer captures.deinit(self.ctx.allocator());
            var capture_locals: std.ArrayList(?semantic.UnresolvedBody.LocalId) = .empty;
            defer capture_locals.deinit(self.ctx.allocator());
            try self.bindRegionCaptures(&region, &captures, &capture_locals);
            const boundary = try region.newBoundary(raw.span);
            region.current_boundary = boundary;
            // Type the whole expression for inference without publishing or
            // executing its IR. The specialized call then checks ownership and
            // builds the region with its actual construction destination.
            const type_id = (try region.valueWithContext(raw.value, .{ .expected_type = expected_type, .access = .initialize, .allow_converters = false })).type_id;
            try types.put(self.ctx.allocator(), key, type_id);
            return type_id;
        }

        fn prepareInitializer(self: *Self, raw: semantic.UnresolvedBody.ValueUse, type_id: structures.TypeId) !Value {
            if (self.values[@backingInt(raw.value)]) |pending| if (pending.initializer_parameter != null) {
                if (pending.type_id != type_id) return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(type_id, pending.type_id) });
                try self.consumeInitializer(pending, raw.span);
                return pending;
            };
            const collection = try self.type_interner.collectionLiteralType(type_id);
            const constructed_type = if (collection) |shape| try self.type_interner.internArrayType(shape) else type_id;
            _ = try self.inferInitializerType(raw, constructed_type);
            if (self.type_check_only) {
                return self.appendInstruction(.{ .initializer_ref = .{ .region = 0, .captures = .{ .start = 0, .end = 0 }, .type_id = type_id } });
            }
            var region = self.initializerRegion(constructed_type);
            region.publish_instruction_spans = self.publish_instruction_spans;
            defer region.deinit();
            const gpa = self.ctx.allocator();
            var captures: std.ArrayList(Value) = .empty;
            defer captures.deinit(gpa);
            var capture_locals: std.ArrayList(?semantic.UnresolvedBody.LocalId) = .empty;
            defer capture_locals.deinit(gpa);
            try self.bindRegionCaptures(&region, &captures, &capture_locals);
            if (try region.constructsInPlace(constructed_type)) {
                const storage = try region.appendInstruction(.{ .result_storage = constructed_type });
                const expression = if (@backingInt(raw.value) >= self.unresolved.parameter_count) self.unresolved.expressions[@backingInt(raw.value) - self.unresolved.parameter_count] else null;
                const constructed = if (collection != null and expression != null and expression.?.operation == .collection_literal)
                    try region.constructArrayElements(expression.?, constructed_type, expression.?.operation.collection_literal, .{ .storage = storage, .site = .return_value })
                else
                    try region.construct(raw.value, raw.span, .{ .storage = storage, .site = .return_value });
                if (region.current_block != null) try region.returnConstructed(constructed, raw.span);
            } else {
                const result = try region.valueWithType(raw.value, constructed_type);
                if (region.current_block != null) try region.returnValue(result, raw.span);
            }
            var body = try region.finishAnalysis(null);
            errdefer body.deinit(gpa);
            const kept = try pruneInitializerCaptures(&body, gpa);
            defer gpa.free(kept);
            const capture_start: u32 = @intCast(self.initializer_captures.items.len);
            for (kept) |index| {
                for (region.capture_transfers.items) |transfer| {
                    if (transfer.parameter != index) continue;
                    var fields: std.ArrayList(PlaceField) = .empty;
                    defer fields.deinit(gpa);
                    if (transfer.field) |field| try self.resolvePlaceFields(self.local_values[@backingInt(transfer.local)].?.type_id, self.field_places[field].fields, raw.span, &fields);
                    if (try self.captureTransferParameter(transfer.local, fields.items, raw.span)) |outer| {
                        captures.items[index] = .{ .id = outer, .type_id = .bool };
                    } else {
                        captures.items[index] = try self.newConsumptionCompletion(self.local_values[@backingInt(transfer.local)].?.owned_generation, transfer.field != null);
                    }
                }
                const source = captures.items[index];
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
            initializer.reference_origins = try self.importInitializerOrigins(&region, captures.items, region.returned_reference_origins, initializer.id);
            try self.prepareInitializerTransfers(&region, captures.items, kept, initializer.id, raw.span);
            var outputs = region.capture_output_origins.iterator();
            while (outputs.next()) |output| {
                const local = capture_locals.items[output.key_ptr.*] orelse continue;
                try self.validateInitializerWrite(local, raw.span);
                try self.initializer_writes.append(gpa, .{ .initializer = initializer.id, .local = local, .origins = try self.importInitializerOrigins(&region, captures.items, output.value_ptr.*, initializer.id) });
            }
            for (region.capture_reference_writes.items) |write| {
                var incomplete = false;
                var current = try region.resolveReferenceOrigins(write.reference_origins, &incomplete);
                std.debug.assert(!incomplete);
                var external: ?u32 = null;
                while (current) |index| {
                    const origin = region.reference_origins.items[index];
                    current = origin.next;
                    if (origin.parameter != null) external = try region.addReferenceOrigin(external, origin);
                }
                const origins = try self.importInitializerOrigins(&region, captures.items, external, initializer.id);
                if (origins == null) continue;
                try self.initializer_reference_writes.append(gpa, .{ .initializer = initializer.id, .reference = .{ .id = initializer.id, .type_id = write.type_id, .reference_origins = origins } });
            }
            for (kept) |index| {
                var owner = captures.items[index];
                if (owner.initializer_parameter != null) continue;
                if (capture_locals.items[index]) |local| {
                    owner.owned_generation = self.local_values[@backingInt(local)].?.owned_generation;
                    owner.borrowed_generation = null;
                    owner.borrow_root = local;
                    try self.pending_initializer_locals.append(gpa, local);
                }
                var origins = try self.sourceReferenceOrigins(owner);
                if (index < self.unresolved.parameter_count) origins = try self.addReferenceOrigin(origins, .{ .parameter = index });
                origins = try self.readReferenceOrigins(origins, null, @truncate(@backingInt(initializer.id)), true);
                owner.reference_origins = origins;
                try self.pending_initializer_owners.append(gpa, owner);
            }
            self.initializer_regions.appendAssumeCapacity(body);
            return initializer;
        }

        fn prepareInitializerTransfers(self: *Self, region: *Self, captures: []const Value, kept: []const u32, initializer: structures.FunctionValueId, span: structures.SourceSpan) !void {
            const gpa = self.ctx.allocator();
            const transfer_start = self.initializer_transfers.items.len;
            for (region.capture_transfers.items) |transfer| {
                if (std.mem.indexOfScalar(u32, kept, transfer.parameter) == null) continue;
                const local_index = @backingInt(transfer.local);
                try self.validateInitializerWrite(transfer.local, span);
                var owner = self.local_values[local_index].?;
                if (transfer.field) |field| {
                    var fields: std.ArrayList(PlaceField) = .empty;
                    defer fields.deinit(gpa);
                    try self.resolvePlaceFields(owner.type_id, self.field_places[field].fields, span, &fields);
                    try self.validateMissingFieldParents(transfer.local, fields.items, span);
                    var projected = owner;
                    for (fields.items) |part| {
                        const origins = try self.transformReferenceOrigins(projected.reference_origins, .{ .select = .{ .field = part.index } });
                        projected = try self.projectStorage(projected, part.type_id, .{ .field = part.index });
                        projected.reference_origins = origins;
                    }
                    const previous_missing = if (owner.owned_generation) |generation| self.generations.items[@backingInt(generation)].missing_fields else &.{};
                    if (owner.owned_generation != null) {
                        const ancestor_predicate = self.generations.items[@backingInt(owner.owned_generation.?)].cleanup_condition;
                        try self.recordConsume(owner);
                        const remaining = try self.defineOwnedValue(owner, span, self.locals.items(.can_deinit)[local_index]);
                        if (remaining.owned_generation) |generation| {
                            try self.copyMissingFields(generation, previous_missing, fields.items, null);
                            self.generations.items[@backingInt(generation)].cleanup_condition = ancestor_predicate;
                        }
                        self.local_values[local_index].?.owned_generation = remaining.owned_generation;
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
                var availability = if (transfer.field) |field| self.field_availability[field] else self.local_availability[local_index];
                // A receiver may handle failure after evaluation or after forwarding
                // to a callee that skips construction. Include the original state
                // and every completed region path without inspecting receiver bodies.
                for (region.ordinary_completion_states.items) |state| {
                    const snapshot = region.states.items[@backingInt(state)];
                    const current = if (transfer.field) |field| snapshot.field_availability[field] else snapshot.availability[local_index];
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
                    defer fields.deinit(gpa);
                    try self.resolvePlaceFields(self.local_values[@backingInt(child.local)].?.type_id, child_path, span, &fields);
                    const previous = self.generations.items[@backingInt(generation)].missing_fields;
                    try self.copyMissingFields(generation, previous, fields.items[parent_path.len..], null);
                    for (previous) |path| gpa.free(path);
                    gpa.free(previous);
                }
            }
        }

        fn importInitializerProjection(self: *Self, region: *Self, projection: ?u32) anyerror!?u32 {
            const index = projection orelse return null;
            const source = region.reference_projections.items[index];
            const next = try self.importInitializerProjection(region, source.next);
            const result: u32 = @intCast(self.reference_projections.items.len);
            try self.reference_projections.append(self.ctx.allocator(), .{ .step = source.step, .next = next });
            return result;
        }

        fn importInitializerTransforms(self: *Self, region: *Self, origins: ?u32, transform: ?u32) anyerror!?u32 {
            const index = transform orelse return origins;
            const transformation = region.reference_transforms.items[index];
            const previous = try self.importInitializerTransforms(region, origins, transformation.previous);
            return switch (transformation.operation) {
                .prefix => |step| self.transformReferenceOrigins(previous, .{ .prefix = step }),
                .select => |step| self.transformReferenceOrigins(previous, .{ .select = step }),
                .exclude => |step| self.transformReferenceOrigins(previous, .{ .exclude = step }),
                .widen => self.transformReferenceOrigins(previous, .widen),
                .read, .refresh => unreachable,
            };
        }

        fn importInitializerOrigins(self: *Self, region: *Self, captures: []const Value, head: ?u32, initializer: structures.FunctionValueId) !?u32 {
            var incomplete = false;
            var current = try region.resolveReferenceOrigins(head, &incomplete);
            std.debug.assert(!incomplete);
            var result: ?u32 = null;
            while (current) |index| {
                const origin = region.reference_origins.items[index];
                current = origin.next;
                const parameter = origin.parameter orelse return self.reject(self.activeLifetimeSpan(), .borrow_outlives_source);
                const capture = captures[parameter];
                var source = if (origin.root == null and try self.type_interner.canStoreBorrow(capture.type_id))
                    capture.reference_origins
                else
                    try self.sourceReferenceOrigins(capture);
                source = try self.importInitializerTransforms(region, source, origin.transform);
                while (source) |source_index| {
                    var mapped = self.reference_origins.items[source_index];
                    source = mapped.next;
                    if (origin.root != null and capture.borrow_root != null and mapped.root == capture.borrow_root)
                        mapped.initializer_owner = initializer;
                    if (origin.projection != null) mapped.projection = try self.importInitializerProjection(region, origin.projection);
                    result = try self.addReferenceOrigin(result, mapped);
                }
            }
            return result;
        }

        fn initializerOriginsOverlap(self: *Self, left: ?u32, right: ?u32) !bool {
            if (left == null or right == null) return false;
            var incomplete = false;
            var left_origin = try self.resolveReferenceOrigins(left, &incomplete);
            const right_origins = try self.resolveReferenceOrigins(right, &incomplete);
            if (incomplete) return true;
            while (left_origin) |left_index| {
                const first = self.reference_origins.items[left_index];
                left_origin = first.next;
                var right_origin = right_origins;
                while (right_origin) |right_index| {
                    const second = self.reference_origins.items[right_index];
                    right_origin = second.next;
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
                var owner = self.local_values[@backingInt(write.local)].?;
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

        fn consumeOwnedPlace(self: *Self, place: BorrowPlace, fields: []const PlaceField, expected_type: ?structures.TypeId, span: structures.SourceSpan) !Value {
            if (place.root != .local) return self.reject(span, .ownership_transfer_requires_owned_place);
            const local = place.root.local;
            try self.validateInitializerWrite(local, span);
            const local_index = @backingInt(local);
            if (self.locals.items(.alias)[local_index] != null)
                return self.reject(span, .ownership_transfer_requires_owned_place);
            const type_id = if (fields.len == 0) self.local_values[local_index].?.type_id else fields[fields.len - 1].type_id;
            if (expected_type) |expected| if (type_id != expected)
                return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(expected, type_id) });
            const field_start: u32 = @intCast(self.pending_deinit_fields.items.len);
            try self.pending_deinit_fields.appendSlice(self.ctx.allocator(), fields);
            try self.pending_deinit_places.append(self.ctx.allocator(), .{
                .local = local,
                .fields = .{ .start = field_start, .end = @intCast(self.pending_deinit_fields.items.len) },
            });
            var source: Value = undefined;
            if (fields.len != 0) {
                source = try self.transferFieldPlace(local, fields, span, .consume);
            } else {
                const consumption_completion = try self.captureTransferParameter(local, &.{}, span);
                if (self.locals.items(.mut_parameter)[local_index] != null and consumption_completion == null)
                    return self.reject(span, .ownership_transfer_requires_owned_place);
                source = try self.readLocal(local, span);
                try self.recordUse(source);
                self.local_availability[local_index] = .transferred;
                source = ownershipSource(source);
                source.consumption_completion = consumption_completion;
            }
            source.preserves_storage = true;
            return source;
        }

        fn rememberCleanupOrigins(self: *Self, source: Value) !void {
            const origins = source.reference_origins orelse return;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (!capabilities.needs_automatic_drop) return;
            const merged = try self.mergeReferenceOrigins(self.cleanup_origins.get(source.id), origins);
            try self.cleanup_origins.put(self.ctx.allocator(), source.id, merged.?);
        }

        fn allocateGeneration(
            self: *Self,
            type_id: structures.TypeId,
            span: structures.SourceSpan,
            cleanup_fields: bool,
        ) !?GenerationId {
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
            if (!capabilities.needs_automatic_drop and !capabilities.requires_explicit_drop) return null;
            return @as(?GenerationId, try self.appendGeneration(type_id, span, cleanup_fields, try self.reserveGenerationStartOrder(), capabilities));
        }

        fn appendGeneration(
            self: *Self,
            type_id: structures.TypeId,
            span: structures.SourceSpan,
            cleanup_fields: bool,
            start_order: u32,
            capabilities: structures.OwnershipCapabilities,
        ) !GenerationId {
            std.debug.assert(capabilities.needs_automatic_drop or capabilities.requires_explicit_drop);
            const id: GenerationId = @fromBackingInt(@intCast(self.generations.items.len));
            try self.generations.append(self.ctx.allocator(), .{
                .type_id = type_id,
                .start_order = start_order,
                .span = span,
                .requires_explicit_drop = capabilities.requires_explicit_drop,
                .cleanup_fields = false,
            });
            if (cleanup_fields) try self.setDeinitCleanup(id);
            return id;
        }

        fn setDeinitCleanup(self: *Self, generation: GenerationId) !void {
            const data = &self.generations.items[@backingInt(generation)];
            if ((try self.type_interner.structDefinition(data.type_id)) == null) return;
            data.requires_explicit_drop = (try self.remainingFieldOwnership(data.type_id, data.missing_fields, &.{})).explicit;
            data.cleanup_fields = true;
        }

        fn reserveGenerationStartOrder(self: *Self) !u32 {
            const order = self.next_generation_start_order;
            self.next_generation_start_order = std.math.add(u32, order, 1) catch return error.AnalysisTooLarge;
            return order;
        }

        fn defineOwnedValue(self: *Self, source: Value, span: structures.SourceSpan, cleanup_fields: bool) !Value {
            var owned = withoutOwnershipSource(source);
            owned.owned_generation = try self.allocateGeneration(owned.type_id, span, cleanup_fields);
            if (owned.owned_generation) |generation| try self.recordEffect(.{ .define = .{
                .generation = generation,
                .value = owned.id,
            } });
            return owned;
        }

        fn recordEffect(self: *Self, effect: LifetimeEffect) !void {
            if (self.current_boundary) |boundary| {
                try self.recordEffectAt(boundary, effect);
            } else {
                try self.blocks.items[@backingInt(self.current_block orelse unreachable)].terminator_effects.append(self.ctx.allocator(), effect);
            }
        }

        fn recordEffectAt(self: *Self, boundary: BoundaryId, effect: LifetimeEffect) !void {
            try self.boundaries.items[@backingInt(boundary)].effects.append(self.ctx.allocator(), effect);
        }

        fn joinGenerations(
            self: *Self,
            type_id: structures.TypeId,
            span: structures.SourceSpan,
            first: ?GenerationId,
            second: ?GenerationId,
        ) !?GenerationId {
            return self.joinGenerationGroup(type_id, span, &.{ first, second });
        }

        fn joinResultGenerations(self: *Self, type_id: structures.TypeId, span: structures.SourceSpan, incoming: []const ?GenerationId) !?GenerationId {
            const joined = try self.joinGenerationGroup(type_id, span, incoming);
            const previous = joined orelse return null;
            const metadata = self.generations.items[@backingInt(previous)];
            if (metadata.cleanup_condition == null) return joined;
            const forwarded = try self.allocateGeneration(type_id, span, metadata.cleanup_fields);
            if (forwarded) |generation| try self.copyMissingFields(generation, metadata.missing_fields, null, null);
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
            if (joined) |generation| try self.copyMissingFields(generation, first_missing, null, null);
            return joined;
        }

        fn sameMissingFields(left: []const []const u32, right: []const []const u32) bool {
            if (left.len != right.len) return false;
            for (left) |path| {
                var found = false;
                for (right) |other| if (std.mem.eql(u32, path, other)) {
                    found = true;
                    break;
                };
                if (!found) return false;
            }
            return true;
        }

        fn missingPathStartsWith(path: []const u32, fields: []const PlaceField) bool {
            if (path.len < fields.len) return false;
            for (fields, path[0..fields.len]) |field, index| {
                if (field.index != index) return false;
            }
            return true;
        }

        fn copyMissingFields(self: *Self, generation: GenerationId, previous: []const []const u32, added: ?[]const PlaceField, restored: ?[]const PlaceField) !void {
            var paths: std.ArrayList([]const u32) = .empty;
            errdefer {
                for (paths.items) |path| self.ctx.allocator().free(path);
                paths.deinit(self.ctx.allocator());
            }
            for (previous) |path| {
                if (restored) |fields| if (missingPathStartsWith(path, fields)) continue;
                try paths.ensureUnusedCapacity(self.ctx.allocator(), 1);
                paths.appendAssumeCapacity(try self.ctx.allocator().dupe(u32, path));
            }
            if (added) |fields| {
                try paths.ensureUnusedCapacity(self.ctx.allocator(), 1);
                const path = try self.ctx.allocator().alloc(u32, fields.len);
                for (fields, path) |field, *index| index.* = field.index;
                paths.appendAssumeCapacity(path);
            }
            if (paths.items.len != 0) {
                const generation_data = &self.generations.items[@backingInt(generation)];
                generation_data.requires_explicit_drop = (try self.remainingFieldOwnership(generation_data.type_id, paths.items, &.{})).explicit;
                self.generations.items[@backingInt(generation)].missing_fields = try paths.toOwnedSlice(self.ctx.allocator());
            }
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
            const effect_start = block_value.terminator_effects.items.len;
            try block_value.terminator_effects.appendSlice(self.ctx.allocator(), boundary.effects.items);
            boundary.effects.clearRetainingCapacity();
            self.relocateReferenceUses(.{ .boundary = .{ .id = self.current_boundary.?, .effect_index = 0 } }, .{ .terminator = .{ .id = self.current_block.?, .effect_index = effect_start } });
        }

        fn copyValueConditionally(
            self: *Self,
            source: Value,
            borrow_predicate: structures.FunctionValueId,
            span: structures.SourceSpan,
        ) !Value {
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            _ = try self.appendBlockArgument(source.type_id, null);
            const copy_block = try self.newBlock(argument_start, argument_start);
            const owned_block = try self.newBlock(argument_start, argument_start);
            const join = try self.newBlock(argument_start, argument_start + 1);
            const expected = try self.appendInstruction(.{ .const_bool = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = borrow_predicate, .rhs = expected.id },
                .then_branch = self.emptyBranch(copy_block),
                .else_branch = self.emptyBranch(owned_block),
            } });
            self.enterBlock(copy_block);
            const copied = try self.copyValueAcrossJoin(source, span);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{copied}) });
            self.enterBlock(owned_block);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{source}) });
            const joined_generation = try self.joinGenerations(source.type_id, span, copied.owned_generation, source.owned_generation);
            self.block_argument_generations.items[argument_start] = joined_generation;
            self.enterBlock(join);
            var result: Value = .{
                .id = @fromBackingInt(@intCast(argument_start)),
                .type_id = source.type_id,
                .owned_generation = joined_generation,
            };
            try self.mergeValueReferences(&result, copied, source);
            return result;
        }

        fn copyValueAcrossJoin(self: *Self, source: Value, span: structures.SourceSpan) !Value {
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.copy != .none) return self.copyValue(source, span, null);
            const members = (try self.type_interner.facts().variantMembers(source.type_id)) orelse unreachable;
            if (!source.materialize_on_copy) try self.recordUse(source);
            const copied_bits = try self.mapVariantMember(rawValue(source), members, .copy, null);
            return self.finishCopiedValue(source, copied_bits, span);
        }

        fn copyValue(self: *Self, source: Value, span: structures.SourceSpan, destination: ?Value) anyerror!Value {
            if (!source.materialize_on_copy) try self.recordUse(source);
            const copied_bits = try self.copyValueBits(rawValue(source), destination);
            return self.finishCopiedValue(source, copied_bits, span);
        }

        fn finishCopiedValue(self: *Self, source: Value, copied_bits: Value, span: structures.SourceSpan) !Value {
            const materialized = if (source.materialize_on_copy and copied_bits.id == source.id)
                try self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = source.type_id } })
            else
                copied_bits;
            if (source.materialize_on_copy) {
                const boundary = try self.newBoundary(span);
                const parent_boundary = self.current_boundary;
                self.current_boundary = boundary;
                defer self.current_boundary = parent_boundary;
                try self.recordUse(source);
                try self.appendBoundary(boundary);
            }
            var copied = try self.defineOwnedValue(materialized, span, false);
            copied.reference_origins = try self.copyResultOrigins(source);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.needs_custom_copy) {
                try self.finishOwnershipEffects(source, &copied.reference_origins);
            } else copied.stable_reference_root = source.stable_reference_root;
            const source_generation = source.borrowed_generation orelse source.owned_generation;
            if (source_generation != null and copied.owned_generation != null) {
                std.debug.assert(source_generation != copied.owned_generation);
            }
            return copied;
        }

        fn copyResultOrigins(self: *Self, source: Value) !?u32 {
            if (!try self.type_interner.canStoreBorrow(source.type_id)) return null;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            return if (capabilities.needs_custom_copy)
                self.transformReferenceOrigins(try self.sourceReferenceOrigins(source), .widen)
            else
                source.reference_origins;
        }

        fn copyValueBits(self: *Self, source: Value, destination: ?Value) anyerror!Value {
            if (destination) |storage| if (storage.type_id != source.type_id)
                return self.mapVariantMember(source, (try self.type_interner.facts().variantMembers(source.type_id)).?, .copy, storage);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.needs_custom_copy) {
                if (try self.type_interner.facts().arrayType(source.type_id)) |array|
                    return self.mapArrayElements(source, array, .copy, destination orelse try self.localStorage(source.type_id));
            }
            if (capabilities.needs_custom_copy) return switch (capabilities.copy) {
                .custom => self.callOwnershipHook(source, .copy, destination),
                .fieldwise => self.copyStructFields(source, destination orelse try self.inPlaceStorage(source.type_id)),
                .none, .trivial => unreachable,
            };
            std.debug.assert(capabilities.copy != .none);
            return self.copyBits(source, destination orelse try self.inPlaceStorage(source.type_id));
        }

        fn moveValue(self: *Self, source: Value, span: structures.SourceSpan, destination: ?Value) anyerror!Value {
            try self.recordConsume(source);
            var moved = try self.defineOwnedValue(try self.moveValueBits(rawValue(source), destination), span, false);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            moved.reference_origins = if (capabilities.needs_custom_move)
                try self.transformReferenceOrigins(source.reference_origins, .widen)
            else
                source.reference_origins;
            if (capabilities.needs_custom_move) {
                try self.finishOwnershipEffects(source, &moved.reference_origins);
            } else moved.stable_reference_root = source.stable_reference_root;
            try self.rememberCleanupOrigins(moved);
            return moved;
        }

        fn moveValueBits(self: *Self, source: Value, destination: ?Value) anyerror!Value {
            if (destination) |storage| if (storage.type_id != source.type_id)
                return self.mapVariantMember(source, (try self.type_interner.facts().variantMembers(source.type_id)).?, .move, storage);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.needs_custom_move) {
                if (try self.type_interner.facts().arrayType(source.type_id)) |array|
                    return self.mapArrayElements(source, array, .move, destination orelse try self.localStorage(source.type_id));
            }
            return switch (capabilities.move) {
                .trivial => self.copyBits(source, destination),
                .none => unreachable,
                .custom => self.callOwnershipHook(source, .move, destination),
                .fieldwise => if (capabilities.needs_custom_move)
                    self.moveStructFields(source, destination orelse try self.localStorage(source.type_id))
                else
                    self.copyBits(source, destination),
            };
        }

        fn copyBits(self: *Self, source: Value, destination: ?Value) !Value {
            const storage = destination orelse return source;
            _ = try self.appendInstruction(.{ .value_copy = .{ .source = source.id, .type_id = source.type_id, .destination = storage.id } });
            return storage;
        }

        fn inPlaceStorage(self: *Self, type_id: structures.TypeId) !?Value {
            return if (try self.constructsInPlace(type_id)) try self.localStorage(type_id) else null;
        }

        const OwnershipOperation = enum { copy, move, drop };

        fn callOwnershipHook(self: *Self, source: Value, operation: OwnershipOperation, destination: ?Value) !Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse unreachable;
            const hook = switch (operation) {
                .copy => definition.ownership.copy.?.hook.?,
                .move => definition.ownership.move.?.hook.?,
                .drop => definition.ownership.drop.?.hook.?,
            };
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.append(self.ctx.allocator(), if (operation == .copy) .{ .prepared = .{ .value = source.id } } else .{ .deinit = source.id });
            const result = try self.appendInstruction(.{ .call = .{
                .target = .{ .direct = hook },
                .arguments = .{ .start = argument_start, .end = argument_start + 1 },
                .return_type = if (operation == .drop) .unit else source.type_id,
                .destination = if (destination) |storage| storage.id else null,
            } });
            if (operation == .drop) try self.recordDropEffects(source, @truncate(@backingInt(result.id)));
            return destination orelse result;
        }

        fn recordDropEffects(self: *Self, source: Value, instruction: u31) !void {
            var references: std.ArrayList(Value) = .empty;
            defer references.deinit(self.ctx.allocator());
            var captured = source;
            captured.reference_origins = source.reference_origins orelse self.cleanup_origins.get(source.id);
            var visiting: std.ArrayList(structures.TypeId) = .empty;
            defer visiting.deinit(self.ctx.allocator());
            try self.collectWritableReferencesAt(captured, &references, &visiting, true);
            var writes: ?u32 = null;
            var storage_invalidations: ?u32 = null;
            for (references.items) |reference| {
                const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
                const capabilities = (try self.type_interner.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
                writes = try self.mergeReferenceOrigins(writes, reference.reference_origins);
                if (capabilities.needs_automatic_drop) storage_invalidations = try self.mergeReferenceOrigins(storage_invalidations, reference.reference_origins);
            }
            if (writes != null) try self.drop_effects.put(self.ctx.allocator(), instruction, .{ .writes = writes, .storage_invalidations = storage_invalidations });
        }

        fn finishOwnershipEffects(self: *Self, source: Value, origins: *?u32) !void {
            var references: std.ArrayList(Value) = .empty;
            defer references.deinit(self.ctx.allocator());
            try self.collectWritableReferences(source, &references);
            try self.invalidateWritableReferences(references.items, .{ .value = origins });
        }

        fn copyStructFields(self: *Self, source: Value, destination: ?Value) anyerror!Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse {
                const members = (try self.type_interner.facts().variantMembers(source.type_id)) orelse return source;
                return self.mapVariantMember(source, members, .copy, destination);
            };
            return self.mapStructFields(source, definition, .copy, destination);
        }

        fn moveStructFields(self: *Self, source: Value, destination: Value) anyerror!Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse {
                const members = (try self.type_interner.facts().variantMembers(source.type_id)).?;
                return self.mapVariantMember(source, members, .move, destination);
            };
            return self.mapStructFields(source, definition, .move, destination);
        }

        fn mapStructFields(
            self: *Self,
            source: Value,
            definition: structures.StructDefinition,
            operation: OwnershipOperation,
            destination: ?Value,
        ) anyerror!Value {
            var fields: std.ArrayList(structures.StructFieldValue) = .empty;
            defer fields.deinit(self.ctx.allocator());
            for (definition.fields, 0..) |field, index| {
                const extracted = if (destination != null)
                    try self.projectStorage(source, field.type_id, .{ .field = @intCast(index) })
                else
                    try self.appendInstruction(.{ .field_access = .{
                        .operand = source.id,
                        .field_index = @intCast(index),
                        .field_type = field.type_id,
                    } });
                const field_destination = if (destination) |storage| try self.projectStorage(storage, field.type_id, .{ .field = @intCast(index) }) else null;
                const owned = switch (operation) {
                    .copy => try self.copyValueBits(extracted, field_destination),
                    .move => try self.moveValueBits(extracted, field_destination),
                    .drop => unreachable,
                };
                if (destination == null) try fields.append(self.ctx.allocator(), .{
                    .field_index = @intCast(index),
                    .value = owned.id,
                });
            }
            if (destination) |storage| return storage;
            const field_start: u32 = @intCast(self.struct_field_values.items.len);
            try self.struct_field_values.appendSlice(self.ctx.allocator(), fields.items);
            return self.appendInstruction(.{ .struct_init = .{
                .fields = .{ .start = field_start, .end = @intCast(self.struct_field_values.items.len) },
                .type_id = source.type_id,
            } });
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
            const body = try self.newBlock(argument + 1, argument + 1);
            const exit = try self.newBlock(argument + 1, argument + 1);
            self.terminate(.{ .branch = try self.valuesBranch(header, &.{if (reverse) limit else zero}) });
            self.enterBlock(header);
            var index: Value = .{ .id = @fromBackingInt(@intCast(argument)), .type_id = .int };
            self.terminate(.{ .predicate_branch = .{
                .operation = if (reverse) .gti else .lti,
                .operands = .{ .lhs = index.id, .rhs = if (reverse) zero.id else limit.id },
                .then_branch = self.emptyBranch(body),
                .else_branch = self.emptyBranch(exit),
            } });
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

        fn mapArrayElements(self: *Self, source: Value, array: structures.ArrayType, operation: OwnershipOperation, destination: Value) anyerror!Value {
            if (array.length == 0) return destination;
            const array_loop = try self.beginArrayLoop(array.length, false);
            const element = try self.arrayElement(source, array_loop.index, array.element_type);
            const target = try self.arrayElement(destination, array_loop.index, array.element_type);
            switch (operation) {
                .copy => _ = try self.copyValueBits(element, target),
                .move => _ = try self.moveValueBits(element, target),
                .drop => unreachable,
            }
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

        fn mapVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            operation: OwnershipOperation,
            destination: ?Value,
        ) anyerror!Value {
            return (try self.operateOnVariantMember(source, members, switch (operation) {
                .copy => .copy,
                .move => .move,
                .drop => unreachable,
            }, destination)).?;
        }

        fn projectStorage(self: *Self, source: Value, type_id: structures.TypeId, projection: @FieldType(structures.StorageProjection, "projection")) !Value {
            return self.appendInstruction(.{ .storage_projection = .{ .owner = source.id, .type_id = type_id, .projection = projection } });
        }

        fn fieldView(self: *Self, owner: Value, index: u32, field_type: structures.TypeId) !Value {
            if (try self.constructsInPlace(field_type)) return self.projectStorage(owner, field_type, .{ .field = index });
            return self.appendInstruction(.{ .field_access = .{ .operand = owner.id, .field_index = index, .field_type = field_type } });
        }

        fn mapExtractedVariantMember(self: *Self, source: Value, member: structures.TypeId, operation: OwnershipOperation, destination: ?Value) anyerror!Value {
            const extracted = if (destination != null) try self.projectStorage(source, member, .variant) else try self.appendInstruction(.{ .variant_extract = .{
                .operand = source.id,
                .target_type = member,
            } });
            const member_destination = if (destination) |storage| try self.projectStorage(storage, member, .variant) else null;
            const owned = switch (operation) {
                .copy => blk: {
                    const capabilities = (try self.type_interner.facts().ownershipCapabilities(member)) orelse return error.Unavailable;
                    break :blk if (capabilities.copy == .none) extracted else try self.copyValueBits(extracted, member_destination);
                },
                .move => try self.moveValueBits(extracted, member_destination),
                .drop => unreachable,
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

        fn dropVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            can_deinit: bool,
            span: structures.SourceSpan,
        ) anyerror!void {
            _ = try self.operateOnVariantMember(source, members, .{ .drop = .{
                .can_deinit = can_deinit,
                .span = span,
            } }, null);
        }

        const VariantOwnershipOperation = union(enum) {
            copy,
            move,
            drop: struct {
                can_deinit: bool,
                span: structures.SourceSpan,
            },
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
            switch (operation) {
                .copy, .move => if (destination == null) {
                    _ = try self.appendBlockArgument(source.type_id, null);
                },
                .drop => {},
            }
            const join = try self.newBlock(argument_start, @intCast(self.block_arguments.items.len));
            const destination_members = if (destination) |storage| (try self.type_interner.facts().variantMembers(storage.type_id)).? else members;
            var remaining: usize = 0;
            for (members) |member| remaining += @intFromBool(containsType(destination_members, member));
            std.debug.assert(remaining != 0);

            for (members, 0..) |member, member_index| {
                if (!containsType(destination_members, member)) continue;
                remaining -= 1;
                const case = try self.newBlock(argument_start, argument_start);
                const next = if (remaining == 0)
                    null
                else
                    try self.newBlock(argument_start, argument_start);
                if (next) |next_block| {
                    const expected = try self.appendInstruction(.{ .const_int = @intCast(member_index) });
                    self.terminate(.{ .predicate_branch = .{
                        .operation = .eqi,
                        .operands = .{ .lhs = tag.id, .rhs = expected.id },
                        .then_branch = self.emptyBranch(case),
                        .else_branch = self.emptyBranch(next_block),
                    } });
                } else {
                    self.terminate(.{ .branch = self.emptyBranch(case) });
                }
                self.enterBlock(case);
                switch (operation) {
                    .drop => |drop| {
                        var extracted = try self.projectStorage(source, member, .variant);
                        extracted.reference_origins = try self.transformReferenceOrigins(source.reference_origins, .{ .select = .{ .variant = member } });
                        try self.dropValue(extracted, drop.can_deinit, drop.span);
                        self.terminate(.{ .branch = self.emptyBranch(join) });
                    },
                    .copy, .move => {
                        const result = try self.mapExtractedVariantMember(source, member, if (operation == .copy) .copy else .move, destination);
                        self.terminate(.{ .branch = if (destination != null) self.emptyBranch(join) else try self.valuesBranch(join, &.{result}) });
                    },
                }
                if (next) |next_block| self.enterBlock(next_block);
            }
            self.enterBlock(join);
            return switch (operation) {
                .drop => null,
                .copy, .move => destination orelse .{ .id = @fromBackingInt(@intCast(argument_start)), .type_id = source.type_id },
            };
        }

        fn dropValue(self: *Self, value_to_drop: Value, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(value_to_drop.type_id)) orelse return error.Unavailable;
            switch (capabilities.drop) {
                .trivial => {},
                .explicit => if (!can_deinit) return self.reject(span, .{ .value_requires_explicit_drop = value_to_drop.type_id }),
                .custom => _ = try self.callOwnershipHook(value_to_drop, .drop, null),
                .fieldwise => {
                    if (!capabilities.needs_automatic_drop and !capabilities.requires_explicit_drop) return;
                    if (try self.type_interner.facts().arrayType(value_to_drop.type_id)) |array|
                        return self.dropArrayElements(value_to_drop, array, can_deinit, span);
                    const definition = (try self.type_interner.structDefinition(value_to_drop.type_id)) orelse {
                        const members = (try self.type_interner.facts().variantMembers(value_to_drop.type_id)) orelse return;
                        try self.dropVariantMember(value_to_drop, members, can_deinit, span);
                        return;
                    };
                    var field_index = definition.fields.len;
                    while (field_index > 0) {
                        field_index -= 1;
                        const field = definition.fields[field_index];
                        var field_value = try self.projectStorage(value_to_drop, field.type_id, .{ .field = @intCast(field_index) });
                        field_value.reference_origins = try self.transformReferenceOrigins(value_to_drop.reference_origins, .{ .select = .{ .field = @intCast(field_index) } });
                        try self.dropValue(field_value, can_deinit, span);
                    }
                },
            }
        }

        fn nonCopyableBorrow(self: *Self, value_to_check: Value) !?structures.Diagnostic.TypeNotCopyable {
            const source_type = value_to_check.borrowed_type orelse return null;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source_type)) orelse return error.Unavailable;
            return if (capabilities.copy == .none) .{
                .type_id = source_type,
                .is_movable = capabilities.move != .none,
            } else null;
        }

        fn borrowValue(self: *Self, borrowed: Value, span: structures.SourceSpan) !Value {
            if (borrowed.initializer_parameter != null) return self.reject(span, .initializer_requires_construction);
            if (borrowed.explicit_transfer) return self.reject(span, .ownership_transfer_requires_owning_context);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(borrowed.type_id)) orelse return error.Unavailable;
            if (borrowed.borrowed_type == null and capabilities.requires_explicit_drop) {
                return self.reject(span, .{ .value_requires_explicit_drop = borrowed.type_id });
            }
            try self.recordUse(borrowed);
            return borrowed;
        }

        fn withoutOwnershipSource(resolved: Value) Value {
            return .{
                .id = resolved.id,
                .type_id = resolved.type_id,
                .owned_generation = resolved.owned_generation,
                .reference_origins = resolved.reference_origins,
                .stable_reference_root = resolved.stable_reference_root,
            };
        }

        fn ownershipSource(resolved: Value) Value {
            return .{
                .id = resolved.id,
                .type_id = resolved.type_id,
                .owned_generation = resolved.owned_generation orelse resolved.borrowed_generation,
                .reference_origins = resolved.reference_origins,
                .stable_reference_root = resolved.stable_reference_root,
                .consumption_completion = resolved.consumption_completion,
                .pending_consumption_owners = resolved.pending_consumption_owners,
            };
        }

        fn rawValue(resolved: Value) Value {
            return .{ .id = resolved.id, .type_id = resolved.type_id };
        }

        fn mergeValueReferences(self: *Self, result: *Value, first: Value, second: Value) !void {
            result.reference_origins = try self.mergeReferenceOrigins(first.reference_origins, second.reference_origins);
            result.stable_reference_root = sharedStableReferenceRoot(first.stable_reference_root, second.stable_reference_root);
        }

        fn recordUse(self: *Self, source: Value) !void {
            if (source.initializer_parameter != null) return self.reject(self.activeLifetimeSpan(), .initializer_requires_construction);
            try self.rememberCleanupOrigins(source);
            if (source.reference_origins) |origins| {
                const location: PendingReferenceUseLocation = if (self.current_boundary) |boundary|
                    .{ .boundary = .{ .id = boundary, .effect_index = self.boundaries.items[@backingInt(boundary)].effects.items.len } }
                else blk: {
                    const current_block = self.current_block orelse unreachable;
                    break :blk .{ .terminator = .{ .id = current_block, .effect_index = self.blocks.items[@backingInt(current_block)].terminator_effects.items.len } };
                };
                try self.reference_uses.append(self.ctx.allocator(), .{ .origins = origins, .span = self.activeLifetimeSpan(), .location = location });
                var pending = false;
                const resolved = try self.resolveReferenceOrigins(origins, &pending);
                var effects: std.ArrayList(LifetimeEffect) = .empty;
                defer effects.deinit(self.ctx.allocator());
                if (!pending) try self.collectReferenceUses(resolved, self.currentState(), self.activeLifetimeSpan(), &effects, &pending);
                if (pending) {
                    try self.pending_reference_uses.append(self.ctx.allocator(), .{
                        .origins = origins,
                        .state = try self.captureState(),
                        .span = self.activeLifetimeSpan(),
                        .location = location,
                    });
                } else for (effects.items) |effect| try self.recordEffect(effect);
            }
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

        fn collectReferenceUses(
            self: *Self,
            origins: ?u32,
            state: State,
            span: structures.SourceSpan,
            effects: *std.ArrayList(LifetimeEffect),
            incomplete: *bool,
        ) !void {
            var origin_id = origins;
            while (origin_id) |index| {
                const origin = self.reference_origins.items[index];
                std.debug.assert(origin.loop == null);
                var generation = origin.generation;
                var cleanup_value = origin.cleanup_value;
                if (origin.root) |root| {
                    const slot = @backingInt(root);
                    switch (state.availability[slot]) {
                        .available => {},
                        .transferred, .maybe_transferred, .replacing => |availability| return self.reject(span, unavailableUse(availability)),
                        .unbound => return self.reject(span, .borrow_outlives_source),
                    }
                    const expected = try self.resolveBindingIdentity(origin.binding_identity);
                    const actual_identity = if (origin.stable)
                        state.values.get(slot).?.storage_identity orelse state.values.get(slot).?.binding_identity
                    else
                        state.values.get(slot).?.binding_identity;
                    const actual = try self.resolveBindingIdentity(actual_identity);
                    if (expected.incomplete or actual.incomplete) {
                        incomplete.* = true;
                        origin_id = origin.next;
                        continue;
                    }
                    if (!((origin.stable or origin.deferred_capture) and std.meta.eql(origin.binding_identity, actual_identity)) and
                        (expected.conflicting or actual.conflicting or expected.value == null or expected.value != actual.value))
                        return self.reject(span, if (origin.deferred_capture) .initializer_capture_conflict else .borrow_outlives_source);
                    generation = state.values.get(slot).?.owned_generation;
                    cleanup_value = state.values.get(slot).?.id;
                }
                if (generation) |available_generation| try effects.append(self.ctx.allocator(), .{ .use = .{
                    .generation = available_generation,
                    .cleanup_value = cleanup_value.?,
                } });
                origin_id = origin.next;
            }
        }

        fn resolveBindingIdentity(self: *Self, identity: BindingIdentity) !ResolvedBindingIdentity {
            var visiting: std.ArrayList(u32) = .empty;
            defer visiting.deinit(self.ctx.allocator());
            var result: ResolvedBindingIdentity = .{};
            try self.expandBindingIdentity(identity, &result, &visiting);
            return result;
        }

        fn expandBindingIdentity(
            self: *Self,
            identity: BindingIdentity,
            result: *ResolvedBindingIdentity,
            visiting: *std.ArrayList(u32),
        ) !void {
            switch (identity) {
                .unknown => result.conflicting = true,
                .fixed => |fixed| {
                    if (result.value) |previous| {
                        if (previous != fixed) result.conflicting = true;
                    } else result.value = fixed;
                },
                .join => |index| {
                    if (std.mem.indexOfScalar(u32, visiting.items, index) != null) return;
                    try visiting.append(self.ctx.allocator(), index);
                    defer _ = visiting.pop();
                    const join = self.binding_joins.items[index];
                    if (!join.complete) result.incomplete = true;
                    try self.expandBindingIdentity(join.initial, result, visiting);
                    for (join.alternatives.items) |alternative| try self.expandBindingIdentity(alternative, result, visiting);
                },
            }
        }

        fn resolvePendingReferenceUses(self: *Self) !void {
            for (self.pending_reference_invalidations.items) |pending| {
                var incomplete = false;
                var origins = try self.resolveReferenceOrigins(pending.origins, &incomplete);
                std.debug.assert(!incomplete);
                while (origins) |index| {
                    const origin = self.reference_origins.items[index];
                    if (origin.root) |root| {
                        var known = pending.known;
                        while (known) |known_index| {
                            if (self.reference_origins.items[known_index].root == root) break;
                            known = self.reference_origins.items[known_index].next;
                        }
                        if (known == null) return self.reject(pending.span, .borrow_outlives_source);
                    }
                    origins = origin.next;
                }
            }
            for (self.pending_reference_returns.items) |pending_return| {
                var incomplete = false;
                const origins = try self.resolveReferenceOrigins(pending_return.origins, &incomplete);
                std.debug.assert(!incomplete);
                try self.validateReferenceEscape(origins, pending_return.span);
            }
            var pending_index = self.pending_reference_uses.items.len;
            while (pending_index > 0) {
                pending_index -= 1;
                const pending_use = self.pending_reference_uses.items[pending_index];
                var incomplete = false;
                const origins = try self.resolveReferenceOrigins(pending_use.origins, &incomplete);
                std.debug.assert(!incomplete);
                var effects: std.ArrayList(LifetimeEffect) = .empty;
                defer effects.deinit(self.ctx.allocator());
                try self.collectReferenceUses(origins, self.states.items[@backingInt(pending_use.state)], pending_use.span, &effects, &incomplete);
                std.debug.assert(!incomplete);
                switch (pending_use.location) {
                    .boundary => |location| try self.boundaries.items[@backingInt(location.id)].effects.insertSlice(
                        self.ctx.allocator(),
                        location.effect_index,
                        effects.items,
                    ),
                    .terminator => |location| try self.blocks.items[@backingInt(location.id)].terminator_effects.insertSlice(
                        self.ctx.allocator(),
                        location.effect_index,
                        effects.items,
                    ),
                }
            }
        }

        fn recordConsume(self: *Self, source: Value) !void {
            var owners = source.pending_consumption_owners;
            while (owners) |index| {
                const owner = self.pending_consumption_owners.items[index];
                const availability = if (owner.field) |field| self.field_availability[field] else self.local_availability[@backingInt(owner.local)];
                const place = if (owner.field) |field| self.local_values.len + field else @backingInt(owner.local);
                if (availability == .transferred) {
                    if (owner.generation) |generation| try self.recordEffect(.{ .consume = generation });
                    self.completed_consumptions[place] = true;
                } else if (owner.generation) |generation| {
                    try self.recordEffect(.{ .use = .{ .generation = generation, .cleanup_value = owner.cleanup_value } });
                }
                owners = owner.next;
            }
            if (source.consumption_completion) |completion| {
                for (self.capture_transfers.items) |transfer| {
                    if (@as(structures.FunctionValueId, @fromBackingInt(@intCast(transfer.parameter))) != completion) continue;
                    const place = if (transfer.field) |field| self.local_values.len + field else @backingInt(transfer.local);
                    self.completed_consumptions[place] = true;
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
            try self.pending_consumption_owners.append(self.ctx.allocator(), added);
            return index;
        }

        fn newConsumptionCompletion(self: *Self, owner: ?GenerationId, field_owner: bool) !Value {
            const block_id = self.current_block.?;
            const item_start = self.blocks.items[@backingInt(block_id)].items.items.len;
            const flag = try self.localStorage(.bool);
            _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = field_owner }), flag);
            const initialization = try self.ctx.allocator().dupe(lifetime.BuildItem, self.blocks.items[@backingInt(block_id)].items.items[item_start..]);
            defer self.ctx.allocator().free(initialization);
            if (owner) |generation| {
                for (self.blocks.items) |*block_value| {
                    for (block_value.items.items, 0..) |item, item_index| {
                        if (item != .boundary) continue;
                        var defines_owner = false;
                        for (self.boundaries.items[@backingInt(item.boundary)].effects.items) |effect| {
                            if (effect == .define and effect.define.generation == generation) defines_owner = true;
                        }
                        if (!defines_owner) continue;
                        self.blocks.items[@backingInt(block_id)].items.shrinkRetainingCapacity(item_start);
                        try block_value.items.insertSlice(self.ctx.allocator(), item_index, initialization);
                        _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = false }), flag);
                        return flag;
                    }
                }
            }
            self.blocks.items[@backingInt(block_id)].items.shrinkRetainingCapacity(item_start);
            try self.blocks.items[0].items.insertSlice(self.ctx.allocator(), 0, initialization);
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

        const PreparedStructInit = struct {
            type_id: structures.TypeId,
            fields: structures.FunctionValueRange,
            values: []Value,
            reference_origins: ?u32,
        };
        const StructTypeResult = union(enum) { diverged: Value, type_id: structures.TypeId };
        const StructInitResult = union(enum) { diverged: Value, prepared: PreparedStructInit };

        fn structInit(self: *Self, expression: Expression) !Value {
            const type_id = switch (try self.structInitType(expression.operation.struct_init)) {
                .diverged => |diverged| return diverged,
                .type_id => |resolved| resolved,
            };
            if (try self.type_interner.collectionLiteralType(type_id) != null) return self.reject(expression.span, .{ .compile_time_only_type = type_id });
            if (try self.constructsInPlace(type_id)) return self.constructFields(expression, type_id, try self.localStorage(type_id));
            return self.structInitValue(expression, type_id);
        }

        fn structInitValue(self: *Self, expression: Expression, type_id: structures.TypeId) !Value {
            const result = try self.prepareStructInit(expression, type_id);
            const prepared = switch (result) {
                .diverged => |diverged| return diverged,
                .prepared => |prepared_init| prepared_init,
            };
            defer self.ctx.allocator().free(prepared.values);
            for (prepared.values) |field_value| {
                try self.recordConsume(field_value);
            }
            const constructed = try self.appendInstruction(.{ .struct_init = .{
                .fields = prepared.fields,
                .type_id = prepared.type_id,
            } });
            var initialized = try self.defineOwnedValue(constructed, expression.span, false);
            initialized.reference_origins = prepared.reference_origins;
            return initialized;
        }

        fn prepareStructInit(self: *Self, expression: Expression, type_id: structures.TypeId) !StructInitResult {
            const initializer = expression.operation.struct_init;
            const source_fields = self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end];
            const definition = try self.structInitializerDefinition(initializer, type_id);
            const seen = try self.ctx.allocator().alloc(bool, definition.fields.len);
            defer self.ctx.allocator().free(seen);
            @memset(seen, false);
            var fields: std.ArrayList(structures.StructFieldValue) = .empty;
            defer fields.deinit(self.ctx.allocator());
            var field_values: std.ArrayList(Value) = .empty;
            defer field_values.deinit(self.ctx.allocator());
            var reference_origins: ?u32 = null;
            for (source_fields) |source_field| {
                const field = definition.resolveField(source_field.name).?;
                if (seen[field.index]) return self.reject(source_field.name_span, .duplicate_struct_initializer_field);
                seen[field.index] = true;
                const operand = try self.valueWithContext(source_field.value.value, .{ .expected_type = field.type_id, .access = .initialize });
                if (operand.type_id == .never) return .{ .diverged = operand };
                var use = try self.coerceValue(operand.id, operand.type_id, field.type_id) orelse
                    return self.reject(source_field.value.span, .{ .struct_initializer_field_type_mismatch = self.typeMismatch(field.type_id, operand.type_id) });
                const owned = try self.ownValue(operand, source_field.value.span);
                use.value = owned.id;
                const field_value = if (use.coerce_to != null)
                    try self.coerceOwnedRepresentation(owned, use, source_field.value.span, null)
                else
                    owned;
                try field_values.append(self.ctx.allocator(), field_value);
                if (try self.type_interner.canStoreBorrow(field_value.type_id))
                    reference_origins = try self.mergeReferenceOrigins(reference_origins, try self.transformReferenceOrigins(field_value.reference_origins, .{ .prefix = .{ .field = field.index } }));
                try fields.append(self.ctx.allocator(), .{ .field_index = field.index, .value = field_value.id });
            }
            for (seen, 0..) |was_seen, field_index| if (!was_seen) return self.reject(initializer.type_span, .{ .missing_struct_initializer_field = .{
                .type_id = type_id,
                .field_index = @intCast(field_index),
            } });
            const start: u32 = @intCast(self.struct_field_values.items.len);
            try self.struct_field_values.appendSlice(self.ctx.allocator(), fields.items);
            return .{ .prepared = .{
                .type_id = type_id,
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
                .values = try field_values.toOwnedSlice(self.ctx.allocator()),
                .reference_origins = reference_origins,
            } };
        }

        fn inPlaceStructFieldType(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId) anyerror!StructTypeResult {
            const index = @backingInt(id);
            if (index >= self.unresolved.parameter_count) {
                const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
                if (expression.operation == .struct_init) {
                    const initializer = expression.operation.struct_init;
                    const result = try self.structInitType(initializer);
                    const type_id = switch (result) {
                        .diverged => |diverged| return .{ .diverged = diverged },
                        .type_id => |resolved| resolved,
                    };
                    const capabilities = (try self.type_interner.facts().ownershipCapabilities(type_id)) orelse return error.Unavailable;
                    if (capabilities.isDirectlyMovable()) {
                        const operand = try self.valueWithType(id, expected_type);
                        return if (operand.type_id == .never) .{ .diverged = operand } else .{ .type_id = operand.type_id };
                    }
                    const definition = try self.structInitializerDefinition(initializer, type_id);
                    if (initializer.target == .concrete) {
                        for (self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end]) |field| {
                            const resolved_field = definition.resolveField(field.name).?;
                            const field_result = try self.inPlaceStructFieldType(field.value.value, resolved_field.type_id);
                            if (field_result == .diverged) return field_result;
                        }
                    }
                    return .{ .type_id = type_id };
                }
            }
            const operand = try self.valueWithType(id, expected_type);
            return if (operand.type_id == .never) .{ .diverged = operand } else .{ .type_id = operand.type_id };
        }

        fn unevaluatedType(self: *Self, id: semantic.UnresolvedBody.ValueId, expected_type: ?structures.TypeId) anyerror!?structures.TypeId {
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count) return self.values[index].?.type_id;
            if (self.values[index]) |resolved| return resolved.type_id;
            return switch (self.unresolved.expressions[index - self.unresolved.parameter_count].operation) {
                .integer_literal => if (expected_type == .int_literal) .int_literal else if (expected_type == .byte) .byte else .int,
                .integer, .negate, .add, .subtract, .multiply, .divide => .int,
                .byte => .byte,
                .boolean => .bool,
                .unit => .unit,
                .none => .none,
                .function_ref => |reference| reference.type_id,
                .annotation => |annotation| annotation.type_id,
                .array_init => |initializer| initializer.type_id,
                .collection_literal => |elements| try self.collectionArrayType(elements, expected_type, self.valueSpan(id)),
                .local_read, .local_transfer => |local| if (self.local_values[@backingInt(local)] == null) null else try self.placeRootType(.{ .local = local }),
                .field_transfer => |transfer| blk: {
                    if (self.local_values[@backingInt(transfer.target)] == null) break :blk null;
                    var type_id = try self.placeRootType(.{ .local = transfer.target });
                    for (self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end]) |field|
                        type_id = (try self.resolvePlaceField(type_id, field.name, field.span, field.span)).type_id;
                    break :blk type_id;
                },
                .field_access => |access| blk: {
                    const operand_type = (try self.unevaluatedType(access.operand.value, null)) orelse break :blk null;
                    if (operand_type == .never) break :blk .never;
                    break :blk (try self.resolvePlaceField(operand_type, access.name, access.operand.span, self.valueSpan(id))).type_id;
                },
                .dereference => |reference| blk: {
                    const reference_type = (try self.unevaluatedType(reference.value, null)) orelse break :blk null;
                    if (reference_type == .never) break :blk .never;
                    const access = (try self.type_interner.facts().borrowAccess(reference_type)) orelse
                        return self.reject(reference.span, .{ .dereference_requires_ref = reference_type });
                    break :blk access.element_type;
                },
                .index_snapshot => .int,
                .struct_init => |initializer| switch (initializer.target) {
                    .concrete => |type_id| type_id,
                    .inferred => |factory| try self.unevaluatedStructType(factory, initializer),
                },
                .call => |call| try self.unevaluatedCallType(call),
                .sequence => |operands| try self.unevaluatedType(operands.rhs.value, expected_type),
                .if_else => |branches| blk: {
                    const then_type = (try self.unevaluatedBranchType(branches.then_block)) orelse break :blk null;
                    const else_type = (try self.unevaluatedBranchType(branches.else_block)) orelse break :blk null;
                    break :blk try joinTypes(self.type_interner, then_type, else_type, self.ctx.allocator());
                },
                .type_value, .assignment, .borrow_assignment, .reference_assignment, .loop => null,
            };
        }

        fn inPlaceConditionalType(self: *Self, id: semantic.UnresolvedBody.ValueId) !?structures.TypeId {
            const index = @backingInt(id);
            if (index < self.unresolved.parameter_count or self.values[index] != null) return null;
            if (self.unresolved.expressions[index - self.unresolved.parameter_count].operation != .if_else) return null;
            const type_id = (try self.unevaluatedType(id, null)) orelse return null;
            return if (try self.constructsInPlace(type_id)) type_id else null;
        }

        fn unevaluatedBranchType(self: *Self, block_id: semantic.UnresolvedBody.BlockId) !?structures.TypeId {
            const result = self.unresolved.blocks[@backingInt(block_id)].result orelse return .never;
            return self.unevaluatedType(result, null);
        }

        fn unevaluatedStructType(self: *Self, factory: structures.InstanceId, initializer: @FieldType(Expression.Operation, "struct_init")) !?structures.TypeId {
            const fields = self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end];
            var field_types: std.ArrayList(structures.TypeId) = .empty;
            defer field_types.deinit(self.ctx.allocator());
            for (fields) |field| {
                const expected = try self.type_interner.independentStructFieldType(factory, field.name);
                try field_types.append(self.ctx.allocator(), (try self.unevaluatedType(field.value.value, expected)) orelse return null);
            }
            const arguments = switch (try self.type_interner.inferStructArguments(factory, fields, field_types.items)) {
                .arguments => |arguments| arguments,
                .missing, .conflict => return null,
            };
            defer self.ctx.allocator().free(arguments);
            return try self.type_interner.specializedStructType(try self.type_interner.specializeFunction(factory, arguments));
        }

        const MemberFunction = struct {
            instance: structures.InstanceId,
            shape: structures.FunctionShape,
            ownership: bool = false,
        };
        const MemberTarget = union(enum) {
            field: structures.TypeId,
            function: MemberFunction,
            static_callable: structures.CompileTimeValue.Runtime,
        };

        fn memberTarget(self: *Self, receiver_type: structures.TypeId, member: semantic.UnresolvedBody.MemberCall, span: structures.SourceSpan) !MemberTarget {
            if (std.meta.stringToEnum(structures.OwnershipMember, member.name)) |operation| {
                const instance = (try self.type_interner.ownershipMember(receiver_type, operation)) orelse return self.reject(span, .unknown_namespace_member);
                return .{ .function = .{ .instance = instance, .shape = (try self.type_interner.functionShape(instance.item)) orelse return error.Unavailable, .ownership = true } };
            }
            if (try self.type_interner.structDefinition(receiver_type)) |definition| {
                if (definition.resolveField(member.name) != null)
                    return .{ .field = (try self.resolvePlaceField(receiver_type, member.name, member.receiver.span, span)).type_id };
            } else if (try self.type_interner.facts().arrayType(receiver_type) == null)
                return self.reject(member.receiver.span, .{ .field_access_not_struct = receiver_type });
            const instance = (try self.type_interner.structNamespaceMember(receiver_type, member.name, span)) orelse return self.reject(span, .unknown_namespace_member);
            if (try self.type_interner.functionShape(instance.item)) |shape| return .{ .function = .{ .instance = instance, .shape = shape } };
            const value_id = (try self.type_interner.staticItem(instance)) orelse return error.Unavailable;
            const callee = try self.type_interner.lookupCompileTimeValue(value_id);
            if (callee != .runtime) return self.reject(span, .value_not_callable);
            return .{ .static_callable = callee.runtime };
        }

        fn operationTarget(self: *Self, receiver_type: structures.TypeId, name: []const u8, span: structures.SourceSpan) !CallTarget {
            const instance = (try self.type_interner.structNamespaceMember(receiver_type, name, span)) orelse return self.reject(span, .unknown_namespace_member);
            const shape = (try self.type_interner.functionShape(instance.item)) orelse return error.Unavailable;
            if (try self.type_interner.needsInheritedInference(instance)) return .{ .inferred = instance };
            for (shape.parameters) |parameter| if (parameter.mode == .static) return .{ .inferred = instance };
            return .{ .direct = instance };
        }

        fn unevaluatedTargetType(self: *Self, target: CallTarget, arguments: []const semantic.UnresolvedBody.ValueUse) !?structures.TypeId {
            const instance = switch (target) {
                .direct => |instance| instance,
                .inferred => |generic| (try self.unevaluatedSpecialization(generic, arguments, null)) orelse return null,
                .indirect => unreachable,
            };
            return ((try self.type_interner.functionSignature(instance)) orelse return error.Unavailable).return_type;
        }

        fn unevaluatedCallType(self: *Self, call: semantic.UnresolvedBody.Call) !?structures.TypeId {
            const arguments = if (call.target == .member) &.{} else self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            const target: CallTarget = switch (call.target) {
                .direct => |instance| .{ .direct = instance },
                .inferred => |generic| .{ .inferred = generic },
                .operation => |name| blk: {
                    const receiver_type = (try self.unevaluatedType(arguments[0].value, null)) orelse return null;
                    if (receiver_type == .never) return .never;
                    if (receiver_type == .int and isArithmeticOperation(name)) return .int;
                    break :blk try self.operationTarget(receiver_type, name, call.span);
                },
                .value => |callee| {
                    const callee_type = (try self.unevaluatedType(callee.value, null)) orelse return null;
                    if (callee_type == .never) return .never;
                    return (try self.callableSignature(callee_type, callee.span)).return_type;
                },
                .member => |member| return self.unevaluatedMemberCallType(call, member),
                .unknown_function => return self.reject(call.span, .unknown_function),
            };
            return self.unevaluatedTargetType(target, arguments);
        }

        fn unevaluatedMemberCallType(self: *Self, call: semantic.UnresolvedBody.Call, member: semantic.UnresolvedBody.MemberCall) !?structures.TypeId {
            const receiver_type = (try self.unevaluatedType(member.receiver.value, null)) orelse return null;
            if (receiver_type == .never) return .never;
            switch (try self.memberTarget(receiver_type, member, call.span)) {
                .field => |type_id| return (try self.callableSignature(type_id, call.span)).return_type,
                .static_callable => |callee| return (try self.callableSignature(callee.type_id, call.span)).return_type,
                .function => |function| {
                    if (function.ownership) return self.unevaluatedTargetType(.{ .direct = function.instance }, &.{});
                    var arguments: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
                    defer arguments.deinit(self.ctx.allocator());
                    try arguments.append(self.ctx.allocator(), member.receiver);
                    const target = try self.resolveMethodArguments(function.instance, function.shape, self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end], call.span, &arguments);
                    return self.unevaluatedTargetType(target, arguments.items);
                },
            }
        }

        fn callableSignature(self: *Self, type_id: structures.TypeId, span: structures.SourceSpan) !structures.CallableType {
            return (try self.type_interner.facts().callable(type_id)) orelse
                self.reject(span, .value_not_callable);
        }

        fn unevaluatedSpecialization(self: *Self, generic: structures.InstanceId, arguments: []const semantic.UnresolvedBody.ValueUse, span: ?structures.SourceSpan) !?structures.InstanceId {
            const shape = (try self.type_interner.functionShape(generic.item)) orelse return error.Unavailable;
            var argument_types: std.ArrayList(structures.TypeId) = .empty;
            defer argument_types.deinit(self.ctx.allocator());
            for (shape.parameters) |parameter| {
                if (parameter.mode == .static) continue;
                const runtime_index = argument_types.items.len;
                if (runtime_index == arguments.len) return null;
                const expected = try self.type_interner.independentParameterType(generic, runtime_index);
                const type_id = if (parameter.mode == .init)
                    try self.inferInitializerArgumentType(arguments[runtime_index], expected)
                else
                    (try self.unevaluatedType(arguments[runtime_index].value, expected)) orelse try self.inferArgumentType(arguments[runtime_index]);
                try argument_types.append(self.ctx.allocator(), if (type_id == .int_literal and expected == null) .int else type_id);
            }
            if (argument_types.items.len != arguments.len) return null;
            const inferred = switch (try self.type_interner.inferStaticArguments(generic, argument_types.items)) {
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
            defer self.ctx.allocator().free(inferred);
            return try self.type_interner.specializeFunction(generic, inferred);
        }

        fn structInitType(self: *Self, initializer: @FieldType(Expression.Operation, "struct_init")) !StructTypeResult {
            return switch (initializer.target) {
                .concrete => |concrete| .{ .type_id = concrete },
                .inferred => |factory| inferred: {
                    if (try self.unevaluatedStructType(factory, initializer)) |type_id| break :inferred .{ .type_id = type_id };
                    const fields = self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end];
                    var field_types: std.ArrayList(structures.TypeId) = .empty;
                    defer field_types.deinit(self.ctx.allocator());
                    for (fields) |field| {
                        const expected = try self.type_interner.independentStructFieldType(factory, field.name);
                        switch (try self.inPlaceStructFieldType(field.value.value, expected)) {
                            .diverged => |diverged| break :inferred .{ .diverged = diverged },
                            .type_id => |type_id| try field_types.append(self.ctx.allocator(), type_id),
                        }
                    }
                    const result = try self.type_interner.inferStructArguments(factory, fields, field_types.items);
                    const arguments = switch (result) {
                        .arguments => |arguments| arguments,
                        .missing => return self.reject(initializer.type_span, .static_argument_cannot_be_inferred),
                        .conflict => return self.reject(initializer.type_span, .static_argument_inference_conflict),
                    };
                    defer self.ctx.allocator().free(arguments);
                    const specialized = try self.type_interner.specializeFunction(factory, arguments);
                    break :inferred .{ .type_id = try self.type_interner.specializedStructType(specialized) };
                },
            };
        }

        fn fieldAccess(self: *Self, expression: Expression) !Value {
            const access = expression.operation.field_access;
            return self.accessField(access.operand, access.name, expression.span);
        }

        fn accessField(self: *Self, operand_use: semantic.UnresolvedBody.ValueUse, name: []const u8, span: structures.SourceSpan) !Value {
            var place_fields: std.ArrayList(PlaceField) = .empty;
            defer place_fields.deinit(self.ctx.allocator());
            if (try self.resolveArgumentPlace(operand_use.value, &place_fields)) |place| {
                if (self.hasUnavailableFields(place.local)) {
                    const local_index = @backingInt(place.local);
                    if (self.local_availability[local_index] != .available)
                        return self.reject(span, unavailableUse(self.local_availability[local_index]));
                    const root = self.local_values[local_index].?;
                    const parent_type = if (place_fields.items.len == 0) root.type_id else place_fields.last().?.type_id;
                    try place_fields.append(self.ctx.allocator(), try self.resolvePlaceField(parent_type, name, operand_use.span, span));
                    if (self.unavailableField(place.local, place_fields.items[place.fields.start..])) |availability|
                        return self.reject(span, unavailableUse(availability));
                    const source = try self.borrowValue(self.borrowLocalValue(place.local), operand_use.span);
                    var field = source;
                    for (place_fields.items[place.fields.start..]) |part| {
                        const origins = try self.transformReferenceOrigins(field.reference_origins, .{ .select = .{ .field = part.index } });
                        field = try self.fieldView(field, part.index, part.type_id);
                        field.reference_origins = origins;
                    }
                    field.borrowed_type = field.type_id;
                    field.borrowed_generation = source.borrowed_generation;
                    field.borrowed_cleanup_value = source.borrowed_cleanup_value;
                    field.borrow_root = place.local;
                    field.binding_identity = source.binding_identity;
                    return field;
                }
            }
            const operand = try self.borrowValue(try self.value(operand_use.value), operand_use.span);
            if (operand.type_id == .never) return operand;
            const field = try self.resolvePlaceField(operand.type_id, name, operand_use.span, span);
            var result = try self.fieldView(operand, field.index, field.type_id);
            result.reference_origins = try self.transformReferenceOrigins(operand.reference_origins, .{ .select = .{ .field = field.index } });
            result.binding_identity = operand.binding_identity;
            if (operand.borrowed_type != null) {
                result.borrowed_type = field.type_id;
                result.borrowed_generation = operand.borrowed_generation;
                result.borrowed_cleanup_value = operand.borrowed_cleanup_value;
                result.borrow_root = operand.borrow_root;
                if (operand.borrow_condition) |borrow_condition| {
                    return self.accessConditionalTemporary(operand, result, borrow_condition, span);
                }
            } else if ((try self.type_interner.facts().ownershipCapabilities(operand.type_id) orelse return error.Unavailable).needs_automatic_drop) {
                result.borrowed_type = field.type_id;
                result.borrowed_generation = operand.owned_generation;
                result.borrowed_cleanup_value = operand.id;
                result = try self.ownValue(result, span);
            }
            return result;
        }

        fn accessConditionalTemporary(
            self: *Self,
            operand: Value,
            field: Value,
            borrow_condition: structures.FunctionValueId,
            span: structures.SourceSpan,
        ) !Value {
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            _ = try self.appendBlockArgument(field.type_id, null);
            const borrowed = try self.newBlock(argument_start, argument_start);
            const owned = try self.newBlock(argument_start, argument_start);
            const join = try self.newBlock(argument_start, argument_start + 1);
            const expected = try self.appendInstruction(.{ .const_bool = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = borrow_condition, .rhs = expected.id },
                .then_branch = self.emptyBranch(borrowed),
                .else_branch = self.emptyBranch(owned),
            } });
            self.enterBlock(borrowed);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{field}) });
            self.enterBlock(owned);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(operand.type_id)) orelse return error.Unavailable;
            const owned_field = if (capabilities.needs_automatic_drop or capabilities.requires_explicit_drop) blk: {
                var borrowed_field = field;
                borrowed_field.borrowed_generation = operand.owned_generation;
                borrowed_field.borrowed_cleanup_value = operand.id;
                break :blk try self.ownValue(borrowed_field, span);
            } else withoutOwnershipSource(field);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{owned_field}) });
            const joined_generation = try self.joinGenerations(field.type_id, span, null, owned_field.owned_generation);
            self.block_argument_generations.items[argument_start] = joined_generation;
            self.enterBlock(join);
            var result: Value = .{
                .id = @fromBackingInt(@intCast(argument_start)),
                .type_id = field.type_id,
                .owned_generation = joined_generation,
                .borrowed_generation = field.borrowed_generation,
                .borrowed_cleanup_value = field.borrowed_cleanup_value,
                .borrowed_type = field.type_id,
                .borrow_condition = borrow_condition,
                .borrow_root = field.borrow_root,
            };
            try self.mergeValueReferences(&result, field, owned_field);
            return self.withCleanupCondition(result);
        }

        /// Borrow the current arrays; snapshots acquire ownership through clone.
        fn currentState(self: *Self) State {
            return .{
                .values = StateValues.borrowed(self.local_values),
                .availability = self.local_availability,
                .field_availability = self.field_availability,
                .initializers = self.init_availability,
                .completed_consumptions = self.completed_consumptions,
            };
        }

        fn captureState(self: *Self) !StateId {
            var count = self.local_values.len;
            while (count > 0 and self.local_values[count - 1] == null) count -= 1;
            var current = self.currentState();
            current.values.len = count;
            const previous = if (self.states.items.len == 0) null else self.states.items[self.states.items.len - 1].values;
            var state = try current.capture(self.ctx.allocator(), previous);
            errdefer state.deinit(self.ctx.allocator());
            return self.appendState(state);
        }

        fn appendState(self: *Self, state: State) !StateId {
            std.debug.assert(state.values.len <= state.availability.len);
            std.debug.assert(state.availability.len == self.local_values.len);
            std.debug.assert(state.field_availability.len == self.field_availability.len);
            const id: StateId = @fromBackingInt(@intCast(self.states.items.len));
            try self.states.append(self.ctx.allocator(), state);
            return id;
        }

        fn restoreState(self: *Self, id: StateId) void {
            const state = self.states.items[@backingInt(id)];
            state.values.copyTo(self.local_values[0..state.values.len]);
            @memset(self.local_values[state.values.len..], null);
            self.currentState().copyFlowFrom(state);
        }

        fn activeStateValues(self: *Self, id: StateId) !std.ArrayList(Value) {
            var values: std.ArrayList(Value) = .empty;
            errdefer values.deinit(self.ctx.allocator());
            const snapshot = self.states.items[@backingInt(id)].values;
            for (0..snapshot.len) |slot| {
                const value_in_state = snapshot.get(slot);
                if (self.locals.items(.mutable)[slot]) if (value_in_state) |value_to_append| {
                    if (!try self.constructsInPlace(value_to_append.type_id)) try values.append(self.ctx.allocator(), value_to_append);
                };
            }
            return values;
        }

        fn stateWithArguments(self: *Self, baseline: StateId, argument_start: u32, predecessor: structures.FunctionBlockId) !StateId {
            var state = try self.states.items[@backingInt(baseline)].clone(self.ctx.allocator());
            errdefer state.deinit(self.ctx.allocator());
            var argument = argument_start;
            for (0..state.values.len) |slot| {
                if (!self.locals.items(.mutable)[slot] or state.values.get(slot) == null) continue;
                const current = state.values.get(slot).?;
                const in_place = try self.constructsInPlace(current.type_id);
                const generation = if (in_place) try self.loopHeaderGeneration(current) else self.block_argument_generations.items[argument];
                try state.values.set(self.ctx.allocator(), slot, .{
                    .id = if (in_place) current.id else @fromBackingInt(@intCast(argument)),
                    .type_id = current.type_id,
                    .owned_generation = generation,
                    .binding_identity = current.binding_identity,
                    .storage_identity = current.storage_identity,
                });
                if (in_place) {
                    if (generation) |owner| try self.recordGenerationOnlyForward(predecessor, 0, current.owned_generation, owner);
                } else argument += 1;
            }
            return self.appendState(state);
        }

        fn loop(self: *Self, body: semantic.UnresolvedBody.BlockId, mode: ResultRequest) !Value {
            const baseline = try self.captureState();
            var initial_values = try self.activeStateValues(baseline);
            defer initial_values.deinit(self.ctx.allocator());
            const state_type_start: u32 = @intCast(self.block_arguments.items.len);
            for (initial_values.items) |initial| _ = try self.appendBlockArgument(initial.type_id, try self.loopHeaderGeneration(initial));
            const state_type_end: u32 = @intCast(self.block_arguments.items.len);
            const header = try self.newBlock(state_type_start, state_type_end);
            const initial_branch = try self.valuesBranch(header, initial_values.items);
            const entry_predecessor = self.current_block.?;
            self.terminate(.{ .branch = initial_branch });
            const header_state = try self.stateWithArguments(baseline, state_type_start, entry_predecessor);
            const identity_start = self.binding_joins.items.len;
            for (0..self.states.items[@backingInt(baseline)].values.len) |slot| {
                const initial = self.states.items[@backingInt(baseline)].values.get(slot);
                const mutable = self.locals.items(.mutable)[slot];
                if (!mutable or initial == null) continue;
                const index: u32 = @intCast(self.binding_joins.items.len);
                try self.binding_joins.append(self.ctx.allocator(), .{
                    .slot = @intCast(slot),
                    .initial = initial.?.binding_identity,
                });
                var header_value = self.states.items[@backingInt(header_state)].values.get(slot).?;
                header_value.binding_identity = .{ .join = index };
                const storage_index: u32 = @intCast(self.binding_joins.items.len);
                try self.binding_joins.append(self.ctx.allocator(), .{
                    .slot = @intCast(slot),
                    .storage = true,
                    .initial = initial.?.storage_identity orelse initial.?.binding_identity,
                });
                header_value.storage_identity = .{ .join = storage_index };
                try self.states.items[@backingInt(header_state)].values.set(self.ctx.allocator(), slot, header_value);
            }
            const identity_end = self.binding_joins.items.len;
            const origin_start = self.loop_reference_origins.items.len;
            for (0..self.states.items[@backingInt(baseline)].values.len) |slot| {
                const initial = self.states.items[@backingInt(baseline)].values.get(slot);
                const mutable = self.locals.items(.mutable)[slot];
                if (!mutable or initial == null or !try self.typeContainsBorrow(initial.?.type_id)) continue;
                const origin_index: u32 = @intCast(self.loop_reference_origins.items.len);
                try self.loop_reference_origins.append(self.ctx.allocator(), .{
                    .slot = @intCast(slot),
                    .origins = initial.?.reference_origins,
                });
                var header_value = self.states.items[@backingInt(header_state)].values.get(slot).?;
                header_value.reference_origins = try self.addReferenceOrigin(null, .{ .loop = origin_index });
                try self.states.items[@backingInt(header_state)].values.set(self.ctx.allocator(), slot, header_value);
            }
            const origin_end = self.loop_reference_origins.items.len;

            const break_start: u32 = @intCast(self.loop_breaks.items.len);
            const backedge_start = self.loop_backedges.items.len;
            try self.loop_stack.append(self.ctx.allocator(), .{
                .body = body,
                .header = header,
                .baseline = baseline,
                .result = mode,
            });
            self.enterBlock(header);
            self.restoreState(header_state);
            const body_value = try self.block(body, null);
            if (body_value != null) {
                try self.normalizeLoopBackedge(self.loop_stack.last().?, self.unresolved.blocks[@backingInt(body)].span);
                try self.validateLoopBackedge(self.loop_stack.last().?, self.unresolved.blocks[@backingInt(body)].span);
                const repeat = try self.loopBranch(self.loop_stack.last().?);
                self.terminate(.{ .branch = repeat });
            }
            _ = self.loop_stack.pop().?;

            try self.completeLoopGenerations(header_state, self.loop_backedges.items[backedge_start..], self.unresolved.blocks[@backingInt(body)].span);
            for (self.binding_joins.items[identity_start..identity_end]) |*join| {
                for (self.loop_backedges.items[backedge_start..]) |backedge| {
                    const value_on_edge = self.states.items[@backingInt(backedge.state)].values.get(join.slot.?).?;
                    try join.alternatives.append(self.ctx.allocator(), if (join.storage)
                        value_on_edge.storage_identity orelse value_on_edge.binding_identity
                    else
                        value_on_edge.binding_identity);
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

        fn loopHeaderGeneration(self: *Self, initial: Value) !?GenerationId {
            const previous = initial.owned_generation orelse return null;
            const metadata = self.generations.items[@backingInt(previous)];
            const generation = (try self.allocateGeneration(initial.type_id, self.activeLifetimeSpan(), metadata.cleanup_fields)).?;
            try self.copyMissingFields(generation, metadata.missing_fields, null, null);
            return generation;
        }

        fn completeLoopGenerations(self: *Self, header_state: StateId, backedges: []const LoopBackedge, span: structures.SourceSpan) !void {
            const values = self.states.items[@backingInt(header_state)].values;
            for (0..values.len) |slot| {
                if (!self.locals.items(.mutable)[slot]) continue;
                const initial = values.get(slot) orelse continue;
                const generation = initial.owned_generation orelse continue;
                const missing = self.generations.items[@backingInt(generation)].missing_fields;
                var cleanup_fields = self.generations.items[@backingInt(generation)].cleanup_fields;
                for (backedges) |backedge| {
                    const incoming = self.states.items[@backingInt(backedge.state)].values.get(slot).?.owned_generation;
                    const incoming_missing = if (incoming) |owner| self.generations.items[@backingInt(owner)].missing_fields else &.{};
                    if (!sameMissingFields(missing, incoming_missing)) return self.reject(span, .partial_field_transfer_not_supported);
                    cleanup_fields = cleanup_fields and if (incoming) |owner| self.generations.items[@backingInt(owner)].cleanup_fields else false;
                    if (try self.constructsInPlace(initial.type_id)) try self.recordGenerationOnlyForward(backedge.block, 0, incoming, generation);
                }
                if (!cleanup_fields) {
                    self.generations.items[@backingInt(generation)].cleanup_fields = false;
                    self.generations.items[@backingInt(generation)].requires_explicit_drop = ((try self.type_interner.facts().ownershipCapabilities(initial.type_id)) orelse return error.Unavailable).requires_explicit_drop;
                }
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

        fn loopBranch(self: *Self, context: LoopContext) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            for (0..self.states.items[@backingInt(context.baseline)].values.len) |slot| {
                const initial = self.states.items[@backingInt(context.baseline)].values.get(slot) orelse continue;
                if (!self.locals.items(.mutable)[slot] or try self.constructsInPlace(initial.type_id)) continue;
                const current = self.local_values[slot].?;
                try self.appendBranchArgument(.{ .value = current.id }, current.owned_generation);
            }
            try self.loop_backedges.append(self.ctx.allocator(), .{ .block = self.current_block.?, .state = try self.captureState() });
            return .{ .target = context.header, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn normalizeLoopBackedge(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            const baseline = self.states.items[@backingInt(context.baseline)];
            const previous_boundary = self.current_boundary;
            defer self.current_boundary = previous_boundary;
            var boundary: ?BoundaryId = null;
            for (baseline.field_availability, self.field_availability, self.field_places) |initial, current, place| {
                if (!place.moves_owner or baseline.availability[@backingInt(place.local)] != .available or
                    initial != .transferred or current != .available) continue;
                if (boundary == null) {
                    boundary = try self.newBoundary(span);
                    self.current_boundary = boundary;
                }
                try self.endField(place, span);
            }
            if (boundary) |end_boundary| try self.appendBoundary(end_boundary);
        }

        fn validateLoopBackedge(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            for (self.init_availability, self.states.items[@backingInt(context.baseline)].initializers) |current, initial| {
                if (current != initial) return self.reject(span, .initializer_consumed_in_loop);
            }
            const baseline = self.states.items[@backingInt(context.baseline)].availability;
            for (baseline, self.local_availability) |initial, current| {
                if (initial == .available and current != .available) {
                    return self.reject(span, .transferred_value_not_restored_before_loop_backedge);
                }
            }
            for (self.states.items[@backingInt(context.baseline)].field_availability, self.field_availability, self.field_places) |initial, current, place| {
                if (baseline[@backingInt(place.local)] == .available and initial == .available and current != .available)
                    return self.reject(span, .transferred_value_not_restored_before_loop_backedge);
            }
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation"), context: ValueContext) !Value {
            if (try self.constructsInPlace(annotation.type_id))
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
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (!capabilities.isDirectlyMovable()) return self.reject(span, .{ .relocation_requires_direct_move = source.type_id });
            var result = if (destination) |storage| blk: {
                _ = try self.appendCoercion(use, storage.id);
                break :blk storage;
            } else try self.appendCoercion(use, null);
            result.reference_origins = try self.coercedReferenceOrigins(source, use);
            if (source.borrowed_type != null) {
                result.borrowed_type = source.borrowed_type;
                result.borrowed_generation = source.borrowed_generation;
                result.borrowed_cleanup_value = source.borrowed_cleanup_value;
                result.borrow_condition = source.borrow_condition;
                result.borrow_root = source.borrow_root;
                result.owned_generation = source.owned_generation;
                result.explicit_transfer = source.explicit_transfer;
                return result;
            }
            if (source.owned_generation) |generation| {
                const cleanup_fields = self.generations.items[@backingInt(generation)].cleanup_fields;
                try self.recordConsume(source);
                return self.defineOwnedValue(result, span, cleanup_fields);
            }
            return result;
        }

        fn transitionOwnedType(self: *Self, source: Value, target_type: structures.TypeId, span: structures.SourceSpan) !Value {
            if (source.owned_generation == null) return .{ .id = source.id, .type_id = target_type };
            const cleanup_fields = self.generations.items[@backingInt(source.owned_generation.?)].cleanup_fields;
            try self.recordConsume(source);
            return self.defineOwnedValue(.{ .id = source.id, .type_id = target_type }, span, cleanup_fields);
        }

        fn coercedReferenceOrigins(self: *Self, source: Value, use: structures.FunctionValueUse) !?u32 {
            const members = (try self.type_interner.facts().variantMembers(use.coerce_to orelse return source.reference_origins)) orelse
                return source.reference_origins;
            if (try self.type_interner.facts().variantMembers(source.type_id) != null) return source.reference_origins;
            const member = members[self.variant_coercion_tags.items[use.variant_tag_mapping.?.start]];
            return self.transformReferenceOrigins(source.reference_origins, .{ .prefix = .{ .variant = member } });
        }

        fn appendCoercion(self: *Self, use: structures.FunctionValueUse, destination: ?structures.FunctionValueId) !Value {
            const target_type = use.coerce_to.?;
            const operation: structures.FunctionInstruction = if (try self.type_interner.facts().callable(target_type) != null)
                .{ .callable_coerce = .{ .operand = use.value, .target_type = target_type, .destination = destination } }
            else
                .{ .variant_coerce = .{
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
            if (actual_type == .never or !try semantic.canWidenTo(self.type_interner, actual_type, target_type)) return null;
            const target_members = try self.type_interner.facts().variantMembers(target_type) orelse
                return .{ .value = value_id, .coerce_to = target_type };
            const mapping_start: u32 = @intCast(self.variant_coercion_tags.items.len);
            if (try self.type_interner.facts().variantMembers(actual_type)) |actual_members| {
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
            const tag = (try semantic.widenedVariantTag(self.type_interner, actual_member, target_members)) orelse unreachable;
            try self.variant_coercion_tags.append(self.ctx.allocator(), tag);
        }

        fn appendExtractionTagMapping(
            self: *Self,
            source_type: structures.TypeId,
            target_type: structures.TypeId,
        ) !?structures.FunctionValueRange {
            const target_members = try self.type_interner.facts().variantMembers(target_type) orelse return null;
            const source_members = (try self.type_interner.facts().variantMembers(source_type)).?;
            const start: u32 = @intCast(self.variant_coercion_tags.items.len);
            for (source_members) |source_member| {
                const target_tag: u32 = for (target_members, 0..) |target_member, index| {
                    if (source_member == target_member) break @intCast(index);
                } else structures.invalid_variant_tag;
                try self.variant_coercion_tags.append(self.ctx.allocator(), target_tag);
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
                try fields.append(self.ctx.allocator(), field);
                target_type = field.type_id;
            }
        }

        fn resolvePlaceField(self: *Self, parent_type: structures.TypeId, name: []const u8, parent_span: structures.SourceSpan, field_span: structures.SourceSpan) !PlaceField {
            const definition = (try self.type_interner.structDefinition(parent_type)) orelse
                return self.reject(parent_span, .{ .field_access_not_struct = parent_type });
            const field = definition.resolveField(name) orelse return self.reject(field_span, .unknown_field);
            if (!definition.fields[field.index].is_public and !try self.type_interner.canAccessPrivateFields(parent_type))
                return self.reject(field_span, .{ .private_struct_field = parent_type });
            return .{ .index = field.index, .type_id = field.type_id, .name = name };
        }

        fn structInitializerDefinition(self: *Self, initializer: @FieldType(Expression.Operation, "struct_init"), type_id: structures.TypeId) !structures.StructDefinition {
            const definition = (try self.type_interner.structDefinition(type_id)) orelse
                return self.reject(initializer.type_span, .{ .struct_initializer_not_struct = type_id });
            const private_access = try self.type_interner.canAccessPrivateFields(type_id);
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
            if (self.is_initializer_region and self.captured_locals[local_index] != null) {
                const parameter_index = self.captured_locals[local_index].?;
                self.parameter_modes.items[parameter_index] = .mut;
                self.locals.items(.mut_parameter)[local_index] = parameter_index;
            }
            const replaces = assignment_value.operation == .replace;
            const mut_parameter = self.locals.items(.mut_parameter)[local_index] != null;
            const root_availability = self.local_availability[local_index];
            if (root_availability == .replacing or (root_availability != .available and (assignment_value.fields.start != assignment_value.fields.end or !replaces)))
                return self.reject(assignment_value.target_span, unavailableUse(root_availability));
            const root = self.local_values[local_index].?;
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const source_fields = self.unresolved.assignment_fields[assignment_value.fields.start..assignment_value.fields.end];
            try self.resolvePlaceFields(root.type_id, source_fields, assignment_value.target_span, &fields);
            const target_type = if (fields.items.len == 0) root.type_id else fields.last().?.type_id;
            const target_span = if (source_fields.len == 0) assignment_value.target_span else source_fields[source_fields.len - 1].span;
            const in_place = try self.constructsInPlace(root.type_id);
            if (in_place) for (self.pending_deinit_places.items) |pending| {
                if (pending.local != assignment_value.target) continue;
                const consumed_fields = self.pending_deinit_fields.items[pending.fields.start..pending.fields.end];
                if (fieldPathContains(consumed_fields, fields.items) or fieldPathContains(fields.items, consumed_fields))
                    return self.reject(target_span, .consumed_storage_in_use);
            };
            const constructs_target = in_place and replaces and try self.constructsInPlace(target_type);
            const replaced_storage = if (constructs_target) try self.fieldStorage(rawValue(root), fields.items) else null;
            const early_replaced = if (replaced_storage) |storage| try self.beginInPlaceReplacement(assignment_value.target, storage, fields.items, source_fields, target_span) else null;
            const raw_operand = if (replaced_storage) |storage|
                try self.construct(assignment_value.value.value, assignment_value.value.span, .{ .storage = storage, .site = .assignment })
            else
                try self.valueWithContext(assignment_value.value.value, .{ .expected_type = if (replaces) target_type else null, .access = if (replaces) .initialize else .value });
            const operand = raw_operand;
            if (operand.type_id == .never) return operand;
            if (fields.items.len != 0 and self.local_availability[local_index] != .available) {
                return self.reject(assignment_value.target_span, unavailableUse(self.local_availability[local_index]));
            }
            const replaced = early_replaced orelse try self.replacedFields(assignment_value.target, source_fields, fields.items.len != 0, target_span);
            if (!replaces and replaced.unavailable)
                return self.reject(target_span, .use_after_transfer);
            if (fields.items.len == 0 and mut_parameter and replaced.unavailable)
                return self.reject(target_span, .field_not_restored_before_mut_return);
            const result = if (constructs_target) operand else blk: {
                var latest_target = self.local_values[local_index].?;
                for (fields.items) |field| latest_target = try self.fieldView(latest_target, field.index, field.type_id);
                var use = try self.coerceValue(operand.id, operand.type_id, target_type) orelse
                    return self.reject(assignment_value.value.span, .{ .assignment_type_mismatch = self.typeMismatch(target_type, operand.type_id) });
                const owned = try self.ownValue(operand, assignment_value.value.span);
                use.value = owned.id;
                if (fields.items.len != 0) {
                    // Partial-place lifetimes are not modeled yet, so a replaced field ends here.
                    const target_capabilities = (try self.type_interner.facts().ownershipCapabilities(latest_target.type_id)) orelse return error.Unavailable;
                    if (self.local_availability[local_index] == .maybe_transferred and target_capabilities.needs_automatic_drop) {
                        return self.reject(target_span, .possibly_transferred);
                    }
                    if (!replaced.skip_old_drop or self.local_values[local_index].?.owned_generation != null)
                        try self.dropReplacedField(self.local_values[local_index].?, latest_target, fields.items, self.locals.items(.can_deinit)[local_index], target_span);
                }
                break :blk if (use.coerce_to == null)
                    owned
                else
                    try self.coerceOwnedRepresentation(owned, use, assignment_value.value.span, null);
            };
            if (!constructs_target and fields.items.len == 0 and mut_parameter) {
                if (!(self.is_initializer_region and self.captured_locals[local_index] != null and root_availability == .transferred))
                    try self.dropValue(root, false, target_span);
                try self.recordConsume(root);
            }
            const previous_root = self.local_values[local_index].?;
            var updated = if (fields.items.len == 0)
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
            }
            updated.binding_identity = try self.newBindingIdentity();
            updated.storage_identity = null;
            self.local_values[local_index] = updated;
            self.local_availability[local_index] = .available;
            if (replaces) {
                for (self.field_places, self.field_availability) |place, *availability| {
                    if (place.local == assignment_value.target and fieldPathContains(source_fields, place.fields))
                        availability.* = .available;
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
                const place = if (transfer.field) |field| self.local_values.len + field else @backingInt(transfer.local);
                self.completed_consumptions[place] = false;
            }
        }

        fn replacedFields(self: *Self, local: semantic.UnresolvedBody.LocalId, source_fields: []const semantic.UnresolvedBody.FieldName, has_fields: bool, span: structures.SourceSpan) !ReplacedFields {
            var replaced: ReplacedFields = .{};
            for (self.field_places, self.field_availability) |place, availability| {
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
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            const local_index = @backingInt(local);
            var replaced = try self.replacedFields(local, source_fields, fields.len != 0, span);
            if (fields.len == 0) {
                const root = self.local_values[local_index].?;
                if (self.locals.items(.mut_parameter)[local_index] != null) {
                    if (replaced.unavailable) return self.reject(span, .field_not_restored_before_mut_return);
                    try self.dropValue(root, false, span);
                    try self.recordConsume(root);
                }
                if (self.local_availability[local_index] == .available) self.local_availability[local_index] = .replacing;
            } else {
                replaced = try self.endReplacedField(local, storage, fields, replaced, span);
                for (self.field_places, self.field_availability) |place, *availability| {
                    if (place.local == local and fieldPathContains(source_fields, place.fields)) availability.* = .replacing;
                }
            }
            try self.appendBoundary(boundary);
            return replaced;
        }

        fn endReplacedField(self: *Self, local: semantic.UnresolvedBody.LocalId, storage: Value, fields: []const PlaceField, previous: ReplacedFields, span: structures.SourceSpan) !ReplacedFields {
            try self.validateMissingFieldParents(local, fields, span);
            const local_index = @backingInt(local);
            const root = self.local_values[local_index].?;
            const can_deinit = self.locals.items(.can_deinit)[local_index];
            if (!previous.skip_old_drop or root.owned_generation != null)
                try self.dropReplacedField(root, storage, fields, can_deinit, span);
            self.local_values[local_index].?.binding_identity = try self.newBindingIdentity();
            self.local_values[local_index].?.storage_identity = null;
            const generation = root.owned_generation orelse return previous;
            const field_capabilities = (try self.type_interner.facts().ownershipCapabilities(fields[fields.len - 1].type_id)) orelse return error.Unavailable;
            if (!field_capabilities.needs_automatic_drop and !field_capabilities.requires_explicit_drop) return previous;
            for (self.field_places) |*place| {
                if (place.local == local and place.fields.len == fields.len and fieldPathContains(place.fields, fields)) place.moves_owner = true;
            }
            const missing = self.generations.items[@backingInt(generation)].missing_fields;
            try self.recordConsume(root);
            self.local_values[local_index].?.owned_generation = null;
            if ((try self.remainingFieldOwnership(root.type_id, missing, fields)).any()) {
                const remaining = try self.defineOwnedValue(root, span, can_deinit);
                try self.copyMissingFields(remaining.owned_generation.?, missing, fields, fields);
                self.local_values[local_index].?.owned_generation = remaining.owned_generation;
            }
            var replaced = previous;
            replaced.unavailable = true;
            return replaced;
        }

        fn fieldStorage(self: *Self, root: Value, fields: []const PlaceField) !Value {
            var storage = root;
            for (fields) |field| storage = try self.projectStorage(storage, field.type_id, .{ .field = field.index });
            return storage;
        }

        fn fieldUpdateOrigins(self: *Self, root_origins: ?u32, fields: []const PlaceField, leaf_origins: ?u32) anyerror!?u32 {
            if (fields.len == 0) return leaf_origins;
            const step: @FieldType(ReferenceProjection, "step") = .{ .field = fields[0].index };
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
            for (self.field_places, self.field_availability) |place, availability| {
                if (place.local == local and availability != .available and
                    !fieldPathContains(source_fields, place.fields)) still_partial = true;
            }
            if (updated.owned_generation == null) {
                if (still_partial and result.owned_generation != null) {
                    var missing_paths: std.ArrayList([]const u32) = .empty;
                    defer {
                        for (missing_paths.items) |path| self.ctx.allocator().free(path);
                        missing_paths.deinit(self.ctx.allocator());
                    }
                    var path_fields: std.ArrayList(PlaceField) = .empty;
                    defer path_fields.deinit(self.ctx.allocator());
                    for (self.field_places, self.field_availability) |place, availability| {
                        if (place.local != local or !place.moves_owner or availability == .available or
                            fieldPathContains(source_fields, place.fields)) continue;
                        if (availability != .transferred) return self.reject(target_span, .possibly_transferred);
                        path_fields.clearRetainingCapacity();
                        try self.resolvePlaceFields(updated.type_id, place.fields, target_span, &path_fields);
                        try missing_paths.ensureUnusedCapacity(self.ctx.allocator(), 1);
                        const path = try self.ctx.allocator().alloc(u32, path_fields.items.len);
                        for (path_fields.items, path) |field, *index| index.* = field.index;
                        var duplicate = false;
                        for (missing_paths.items) |existing| {
                            if (std.mem.eql(u32, existing, path)) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (duplicate) self.ctx.allocator().free(path) else missing_paths.appendAssumeCapacity(path);
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
            var missing_children: std.ArrayList([]const u32) = .empty;
            defer missing_children.deinit(self.ctx.allocator());
            for (self.generations.items[@backingInt(generation)].missing_fields) |missing| {
                if (!missingPathStartsWith(missing, fields)) continue;
                if (missing.len == fields.len) return;
                try missing_children.append(self.ctx.allocator(), missing[fields.len..]);
            }
            if (missing_children.items.len == 0)
                try self.dropValue(target, can_deinit, span)
            else
                try self.dropValueExcluding(target, missing_children.items, can_deinit, span);
        }

        fn negate(self: *Self, operand_use: semantic.UnresolvedBody.ValueUse) !Value {
            const operand = try self.borrowValue(try self.value(operand_use.value), operand_use.span);
            if (operand.type_id == .never) return operand;
            if (operand.type_id != .int) return self.reject(operand_use.span, .{ .negation_operand_not_int = operand.type_id });
            return self.appendInstruction(.{ .negi = operand.id });
        }

        fn binary(self: *Self, expression: Expression) !Value {
            const raw = switch (expression.operation) {
                .add, .subtract, .multiply, .divide => |operands| operands,
                else => unreachable,
            };
            const lhs = try self.borrowValue(try self.value(raw.lhs.value), raw.lhs.span);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.borrowValue(try self.value(raw.rhs.value), raw.rhs.span);
            if (rhs.type_id == .never) return rhs;
            try self.recordUse(lhs);
            if (lhs.type_id != .int) return self.reject(raw.lhs.span, .{ .arithmetic_operand_not_int = lhs.type_id });
            if (rhs.type_id != .int) return self.reject(raw.rhs.span, .{ .arithmetic_operand_not_int = rhs.type_id });
            const operands: structures.BinaryOperands = .{ .lhs = lhs.id, .rhs = rhs.id };
            const instruction: structures.FunctionInstruction = switch (expression.operation) {
                .add => .{ .addi = operands },
                .subtract => .{ .subi = operands },
                .multiply => .{ .muli = operands },
                .divide => .{ .divsi = operands },
                else => unreachable,
            };
            return self.appendInstruction(instruction);
        }

        const ResolvedCallable = struct {
            operation: structures.FunctionCall,
            behavior: structures.CallBehavior,
            is_fallible: bool,
            mut_arguments: structures.FunctionValueRange,
            consumed_arguments: structures.FunctionValueRange,
            writable_references: structures.FunctionValueRange,
            reference_origins: ?u32,
            inherits_initializer_failure: bool = false,
        };
        const ResolvedCall = union(enum) {
            diverged: Value,
            callable: ResolvedCallable,
        };

        fn resolveArgumentPlace(
            self: *Self,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(PlaceField),
        ) !?ArgumentPlace {
            const place = (try self.resolveBorrowPlace(value_id, fields)) orelse return null;
            return switch (place.root) {
                .local => |local| .{ .local = local, .fields = place.fields },
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
            defer source_fields.deinit(self.ctx.allocator());
            const root = (try self.appendSourcePlaceFields(value_id, &source_fields)) orelse return null;
            const root_type = try self.placeRootType(root);
            const span = if (source_fields.items.len != 0) source_fields.items[0].span else self.activeLifetimeSpan();
            try self.resolvePlaceFields(root_type, source_fields.items, span, fields);
            return .{
                .root = root,
                .fields = .{ .start = start, .end = @intCast(fields.items.len) },
            };
        }

        fn publishBorrowFields(self: *Self, fields: []const PlaceField) !structures.FunctionValueRange {
            const start: u32 = @intCast(self.borrow_fields.items.len);
            for (fields) |field| {
                try self.borrow_fields.append(self.ctx.allocator(), field.index);
            }
            return .{ .start = start, .end = @intCast(self.borrow_fields.items.len) };
        }

        fn concatBorrowFields(self: *Self, first: structures.FunctionValueRange, second: structures.FunctionValueRange) !structures.FunctionValueRange {
            const start: u32 = @intCast(self.borrow_fields.items.len);
            try self.borrow_fields.ensureUnusedCapacity(self.ctx.allocator(), first.end - first.start + second.end - second.start);
            self.borrow_fields.appendSliceAssumeCapacity(self.borrow_fields.items[first.start..first.end]);
            self.borrow_fields.appendSliceAssumeCapacity(self.borrow_fields.items[second.start..second.end]);
            return .{ .start = start, .end = @intCast(self.borrow_fields.items.len) };
        }

        fn projectBorrowPlace(self: *Self, place: BorrowPlace, fields: []const PlaceField, writable: bool, span: structures.SourceSpan) !ProjectedBorrowPlace {
            const alias = if (place.root == .local) self.locals.items(.alias)[@backingInt(place.root.local)] else null;
            const root: Value = if (alias != null)
                try self.aliasReference(place.root.local)
            else switch (place.root) {
                .local => |local| blk: {
                    const index = @backingInt(local);
                    if (writable and !self.locals.items(.mutable)[index])
                        return self.reject(span, .mutable_borrow_requires_writable_place);
                    break :blk self.local_values[index].?;
                },
                .parameter => |parameter| blk: {
                    if (writable) return self.reject(span, .mutable_borrow_requires_writable_place);
                    const value_to_borrow = self.values[@backingInt(parameter)].?;
                    if (value_to_borrow.borrowed_type == null) return self.reject(span, .borrow_requires_place);
                    break :blk value_to_borrow;
                },
            };
            const access = if (alias != null) (try self.type_interner.facts().borrowAccess(root.type_id)).? else null;
            if (access) |borrow_access| if (writable and !borrow_access.writable) return self.reject(span, .reference_not_writable);
            return .{
                .root = root,
                .alias = alias,
                .fields = try self.publishBorrowFields(fields[place.fields.start..place.fields.end]),
                .writable = if (access) |borrow_access| borrow_access.writable else writable,
            };
        }

        fn placeRootType(self: *Self, root: @FieldType(BorrowPlace, "root")) !structures.TypeId {
            return switch (root) {
                .local => |local| blk: {
                    const type_id = self.local_values[@backingInt(local)].?.type_id;
                    break :blk if (self.locals.items(.alias)[@backingInt(local)] != null)
                        (try self.type_interner.facts().borrowElement(type_id)).?
                    else
                        type_id;
                },
                .parameter => |parameter| self.values[@backingInt(parameter)].?.type_id,
            };
        }

        fn appendSourcePlaceFields(
            self: *Self,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(semantic.UnresolvedBody.FieldName),
        ) !?@FieldType(BorrowPlace, "root") {
            const index = @backingInt(value_id);
            if (index < self.unresolved.parameter_count) return .{ .parameter = value_id };
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            return switch (expression.operation) {
                .local_read, .local_transfer => |local| .{ .local = local },
                .field_transfer => |transfer| blk: {
                    try fields.appendSlice(self.ctx.allocator(), self.unresolved.assignment_fields[transfer.fields.start..transfer.fields.end]);
                    break :blk .{ .local = transfer.target };
                },
                .field_access => |access| blk: {
                    const root = (try self.appendSourcePlaceFields(access.operand.value, fields)) orelse return null;
                    try fields.append(self.ctx.allocator(), .{ .name = access.name, .span = expression.span });
                    break :blk root;
                },
                else => null,
            };
        }

        fn placesOverlap(fields: []const PlaceField, left: ArgumentPlace, right: ArgumentPlace) bool {
            if (left.local != right.local) return false;
            const left_fields = fields[left.fields.start..left.fields.end];
            const right_fields = fields[right.fields.start..right.fields.end];
            const shared_length = @min(left_fields.len, right_fields.len);
            for (left_fields[0..shared_length], right_fields[0..shared_length]) |left_field, right_field| {
                if (left_field.index != right_field.index) return false;
            }
            return true;
        }

        fn resolveCall(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, requires_fallible: bool) !ResolvedCall {
            // Earlier deinit arguments retain their storage while later arguments,
            // including nested calls, are evaluated.
            const initializer_owner_start = self.pending_initializer_owners.items.len;
            const initializer_local_start = self.pending_initializer_locals.items.len;
            defer {
                self.pending_initializer_owners.shrinkRetainingCapacity(initializer_owner_start);
                self.pending_initializer_locals.shrinkRetainingCapacity(initializer_local_start);
            }
            const deinit_place_start = self.pending_deinit_places.items.len;
            const deinit_field_start = self.pending_deinit_fields.items.len;
            defer {
                self.pending_deinit_places.shrinkRetainingCapacity(deinit_place_start);
                self.pending_deinit_fields.shrinkRetainingCapacity(deinit_field_start);
            }
            var target: CallTarget = undefined;
            var signature: structures.CallableType = undefined;
            var argument_storage: std.ArrayList(semantic.UnresolvedBody.ValueUse) = .empty;
            defer argument_storage.deinit(self.ctx.allocator());
            var raw_arguments: []const semantic.UnresolvedBody.ValueUse = &.{};
            switch (call.target) {
                .unknown_function => return self.reject(span, .unknown_function),
                .operation => |name| {
                    raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    const receiver_type = (try self.unevaluatedType(raw_arguments[0].value, null)) orelse blk: {
                        const receiver = try self.value(raw_arguments[0].value);
                        if (receiver.type_id == .never) return .{ .diverged = receiver };
                        break :blk receiver.type_id;
                    };
                    target = try self.operationTarget(receiver_type, name, span);
                    if (target == .direct) signature = (try self.type_interner.functionSignature(target.direct)) orelse return error.Unavailable;
                },
                .direct => |instance| {
                    raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    target = .{ .direct = instance };
                    const shape = (try self.type_interner.functionShape(instance.item)) orelse return error.Unavailable;
                    try self.validateCallSyntax(call, shape.is_fallible, requires_fallible);
                    signature = try self.type_interner.functionSignature(instance) orelse return error.Unavailable;
                },
                .inferred => |instance| {
                    raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    target = .{ .inferred = instance };
                },
                .value => |target_use| {
                    raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                    const callee = try self.borrowValue(try self.value(target_use.value), target_use.span);
                    if (callee.type_id == .never) return .{ .diverged = callee };
                    signature = try self.callableSignature(callee.type_id, target_use.span);
                    target = .{ .indirect = callee };
                },
                .member => |member| {
                    if (try self.resolveMemberCall(call, member, requires_fallible, &argument_storage, &target, &signature)) |diverged|
                        return .{ .diverged = diverged };
                    raw_arguments = argument_storage.items;
                },
            }
            if (target == .inferred) {
                const shape = (try self.type_interner.functionShape(target.inferred.item)) orelse return error.Unavailable;
                try self.validateCallSyntax(call, shape.is_fallible, requires_fallible);
                const specialized = (try self.unevaluatedSpecialization(target.inferred, raw_arguments, span)) orelse
                    return self.reject(span, .static_argument_cannot_be_inferred);
                target = .{ .direct = specialized };
                signature = (try self.type_interner.functionSignature(specialized)) orelse return error.Unavailable;
            } else try self.validateCallSyntax(call, signature.is_fallible, requires_fallible);
            if (raw_arguments.len != signature.parameters.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(signature.parameters.len),
                .found = @intCast(raw_arguments.len),
            } });
            if (signature.return_type == .type and !self.allow_type_values) return self.reject(span, .type_value_used_as_runtime_value);
            const behavior = if (target == .direct) try self.type_interner.callBehavior(target.direct.item) else .ordinary;
            var place_fields: std.ArrayList(PlaceField) = .empty;
            defer place_fields.deinit(self.ctx.allocator());
            var argument_places: std.ArrayList(?ArgumentPlace) = .empty;
            defer argument_places.deinit(self.ctx.allocator());
            var argument_reference_origins: std.ArrayList(?u32) = .empty;
            defer argument_reference_origins.deinit(self.ctx.allocator());
            var writable_references: std.ArrayList(Value) = .empty;
            defer writable_references.deinit(self.ctx.allocator());
            var arguments_to_publish: std.ArrayList(structures.FunctionCallArgument) = .empty;
            defer arguments_to_publish.deinit(self.ctx.allocator());
            var arguments_to_consume: std.ArrayList(Value) = .empty;
            defer arguments_to_consume.deinit(self.ctx.allocator());
            var mut_arguments_to_publish: std.ArrayList(PendingMutArgument) = .empty;
            defer mut_arguments_to_publish.deinit(self.ctx.allocator());
            const borrowed_return = try self.type_interner.canStoreBorrow(signature.return_type);
            var borrowed_mut_output = false;
            for (signature.parameters) |parameter| {
                if (parameter.mode == .mut and try self.type_interner.canStoreBorrow(parameter.type_id)) borrowed_mut_output = true;
            }
            var reference_origins: ?u32 = null;
            var mut_reference_origins: ?u32 = null;
            var mut_return_origin = false;
            const extracts_box = behavior == .box_value;
            // Finish each argument before evaluating the next one. Nested copy
            // hooks may publish their own calls, so the outer operands stay in
            // local storage until their complete contiguous range is known.
            for (raw_arguments, signature.parameters, 0..) |raw, expected, argument_index| {
                if (expected.mode == .init) {
                    const initializer = try self.prepareInitializer(raw, expected.type_id);
                    try arguments_to_publish.append(self.ctx.allocator(), .{ .initializer = initializer.id });
                    try argument_places.append(self.ctx.allocator(), null);
                    try argument_reference_origins.append(self.ctx.allocator(), initializer.reference_origins);
                    if (borrowed_return)
                        reference_origins = try self.mergeReferenceOrigins(reference_origins, try self.transformReferenceOrigins(initializer.reference_origins, .widen));
                    if (borrowed_mut_output) mut_reference_origins = try self.mergeReferenceOrigins(mut_reference_origins, initializer.reference_origins);
                    continue;
                }

                const raw_operand = if (expected.mode == .deinit)
                    try self.valueWithContext(raw.value, .{ .expected_type = expected.type_id, .access = .consume })
                else if (expected.mode == .@"var" and try self.constructsInPlace(expected.type_id))
                    try self.construct(raw.value, raw.span, .{ .storage = try self.localStorage(expected.type_id), .site = .argument })
                else if (expected.mode == .imm)
                    try self.valueWithContext(raw.value, .{
                        .expected_type = expected.type_id,
                        .access = if (try self.constructsInPlace(expected.type_id) and try self.type_interner.facts().variantMembers(expected.type_id) != null) .borrow else .value,
                    })
                else
                    try self.valueWithContext(raw.value, .{ .expected_type = expected.type_id, .access = if (expected.mode == .@"var") .initialize else .value });
                if (raw_operand.type_id == .never) return .{ .diverged = raw_operand };
                var maybe_place = if (expected.mode == .imm or expected.mode == .mut)
                    try self.resolveArgumentPlace(raw.value, &place_fields)
                else
                    null;
                if (maybe_place) |place| {
                    const place_type = if (place.fields.start != place.fields.end)
                        place_fields.items[place.fields.end - 1].type_id
                    else
                        try self.placeRootType(.{ .local = place.local });
                    if (place_type != raw_operand.type_id) maybe_place = null;
                }
                try argument_places.append(self.ctx.allocator(), maybe_place);
                const operand = switch (expected.mode) {
                    .imm, .mut => try self.borrowValue(raw_operand, raw.span),
                    .@"var", .deinit => raw_operand,
                    .static, .init => unreachable,
                };
                if (expected.mode == .mut and operand.type_id != expected.type_id) {
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                }
                var argument = try self.coerceValue(operand.id, operand.type_id, expected.type_id) orelse
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                if (argument.coerce_to != null and try self.constructsInPlace(expected.type_id)) {
                    const capabilities = (try self.type_interner.facts().ownershipCapabilities(operand.type_id)) orelse return error.Unavailable;
                    if (!capabilities.isDirectlyMovable()) return self.reject(raw.span, .{ .relocation_requires_direct_move = operand.type_id });
                    std.debug.assert(expected.mode == .imm);
                    const storage = try self.localStorage(expected.type_id);
                    _ = try self.appendCoercion(argument, storage.id);
                    argument = .{ .value = storage.id };
                }
                const owned = switch (expected.mode) {
                    .@"var" => try self.ownValue(operand, raw.span),
                    .deinit => if (argument.coerce_to != null) try self.coerceOwnedRepresentation(operand, argument, raw.span, null) else operand,
                    else => null,
                };
                const argument_value = owned orelse operand;
                if (!extracts_box) try self.collectWritableReferences(argument_value, &writable_references);
                try argument_reference_origins.append(self.ctx.allocator(), argument_value.reference_origins);
                const return_origin = borrowed_return;
                const contributes_to_return = return_origin and expected.mode != .mut;
                if (return_origin and expected.mode == .mut) mut_return_origin = true;
                if (contributes_to_return or borrowed_mut_output) {
                    const origins: ?u32 = if (expected.mode == .imm and try self.type_interner.facts().borrowElement(operand.type_id) == null)
                        try self.sourceReferenceOrigins(operand)
                    else if (try self.type_interner.canStoreBorrow(argument_value.type_id))
                        argument_value.reference_origins
                    else
                        null;
                    if (contributes_to_return) {
                        const returned = if (extracts_box)
                            try self.transformReferenceOrigins(origins, .{ .select = .element })
                        else
                            try self.transformReferenceOrigins(origins, .widen);
                        reference_origins = try self.mergeReferenceOrigins(reference_origins, returned);
                    }
                    if (borrowed_mut_output) mut_reference_origins = try self.mergeReferenceOrigins(mut_reference_origins, origins);
                }
                if (owned) |owned_argument| {
                    argument.value = owned_argument.id;
                    try arguments_to_consume.append(self.ctx.allocator(), owned_argument);
                } else if (expected.mode == .mut) {
                    const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                    const field_start: u32 = @intCast(self.mut_argument_fields.items.len);
                    try self.mut_argument_fields.appendSlice(self.ctx.allocator(), place_fields.items[place.fields.start..place.fields.end]);
                    try mut_arguments_to_publish.append(self.ctx.allocator(), .{
                        .place = .{
                            .local = place.local,
                            .fields = .{ .start = field_start, .end = @intCast(self.mut_argument_fields.items.len) },
                        },
                        .argument_index = @intCast(argument_index),
                        .return_origin = return_origin,
                    });
                }
                try arguments_to_publish.append(self.ctx.allocator(), if (expected.mode == .deinit) .{ .deinit = argument.value } else .{ .prepared = argument });
            }
            for (self.pending_initializer_owners.items[initializer_owner_start..]) |owner| try self.recordUse(owner);
            for (arguments_to_publish.items) |argument| {
                if (argument != .initializer) continue;
                for (self.initializer_transfers.items) |transfer| if (transfer.initializer == argument.valueId()) try self.recordUse(transfer.owner);
                for (arguments_to_publish.items, signature.parameters, argument_places.items, argument_reference_origins.items) |input, parameter, place, origins| {
                    if (parameter.mode == .init) continue;
                    try self.validateInitializerInput(argument.valueId(), .{ .id = input.valueId(), .type_id = parameter.type_id, .borrow_root = if (place) |source| source.local else null, .reference_origins = origins }, span);
                }
                if (target == .indirect) try self.validateInitializerInput(argument.valueId(), target.indirect, span);
            }
            for (writable_references.items) |reference| try self.validateInitializerReferenceWrite(reference, span);
            if (target == .indirect) try self.recordUse(target.indirect);
            for (raw_arguments, signature.parameters, argument_places.items, 0..) |raw, parameter, maybe_place, argument_index| {
                if (parameter.mode != .mut) continue;
                const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                try self.validateInitializerWrite(place.local, raw.span);
                const local_index = @backingInt(place.local);
                if (self.is_initializer_region and self.captured_locals[local_index] != null) {
                    const parameter_index = self.captured_locals[local_index].?;
                    self.parameter_modes.items[parameter_index] = .mut;
                    self.locals.items(.mut_parameter)[local_index] = parameter_index;
                }
                if (!self.locals.items(.mutable)[local_index]) {
                    const alias = self.locals.items(.alias)[local_index];
                    const writable_alias = if (alias != null)
                        (try self.type_interner.facts().borrowAccess(self.local_values[local_index].?.type_id)).?.writable
                    else
                        false;
                    if (!writable_alias)
                        return self.reject(raw.span, .mutable_argument_requires_mutable_place);
                    if (alias.?.root == null and try self.type_interner.canStoreBorrow(parameter.type_id)) {
                        var incomplete = false;
                        var origins = try self.resolveReferenceOrigins(self.local_values[local_index].?.reference_origins, &incomplete);
                        if (incomplete) return self.reject(raw.span, .{ .borrow_write_cannot_store_borrow = parameter.type_id });
                        while (origins) |origin_index| {
                            const origin = self.reference_origins.items[origin_index];
                            if (origin.root == null) return self.reject(raw.span, .{ .borrow_write_cannot_store_borrow = parameter.type_id });
                            origins = origin.next;
                        }
                    }
                }
                switch (self.local_availability[local_index]) {
                    .unbound => unreachable,
                    .available => {},
                    .transferred, .maybe_transferred, .replacing => |availability| return self.reject(raw.span, unavailableUse(availability)),
                }
                if (self.unavailableField(place.local, place_fields.items[place.fields.start..place.fields.end])) |availability|
                    return self.reject(raw.span, unavailableUse(availability));
                for (signature.parameters, argument_places.items, 0..) |other_parameter, other_place, other_index| {
                    if (argument_index == other_index) continue;
                    if (other_place) |resolved_other| {
                        if ((other_parameter.mode == .imm or other_parameter.mode == .mut) and
                            placesOverlap(place_fields.items, place, resolved_other))
                        {
                            return self.reject(raw.span, .overlapping_mutable_arguments);
                        }
                    }
                    if (argument_reference_origins.items[other_index] == null) continue;
                    var incomplete = false;
                    var origin_id = try self.resolveReferenceOrigins(argument_reference_origins.items[other_index], &incomplete);
                    if (incomplete) return self.reject(raw.span, .overlapping_mutable_arguments);
                    while (origin_id) |index| {
                        const origin = self.reference_origins.items[index];
                        if (origin.root == place.local) return self.reject(raw.span, .overlapping_mutable_arguments);
                        origin_id = origin.next;
                    }
                }
            }
            for (raw_arguments, argument_places.items, arguments_to_publish.items, argument_reference_origins.items, signature.parameters) |raw, maybe_place, argument, origins, parameter| {
                if (parameter.mode == .imm) if (maybe_place) |place| {
                    switch (self.local_availability[@backingInt(place.local)]) {
                        .available => {},
                        .transferred, .maybe_transferred, .replacing => |availability| return self.reject(raw.span, unavailableUse(availability)),
                        .unbound => unreachable,
                    }
                    if (self.unavailableField(place.local, place_fields.items[place.fields.start..place.fields.end])) |availability|
                        return self.reject(raw.span, unavailableUse(availability));
                };
                if (origins != null) try self.recordUse(.{ .id = argument.valueId(), .type_id = parameter.type_id, .reference_origins = origins });
            }
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            const consume_start: u32 = @intCast(self.pending_consumed_arguments.items.len);
            try self.pending_consumed_arguments.appendSlice(self.ctx.allocator(), arguments_to_consume.items);
            try self.call_arguments.appendSlice(self.ctx.allocator(), arguments_to_publish.items);
            const arguments: structures.FunctionValueRange = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) };
            const consumed_arguments: structures.FunctionValueRange = .{
                .start = consume_start,
                .end = @intCast(self.pending_consumed_arguments.items.len),
            };
            if (borrowed_mut_output) for (mut_arguments_to_publish.items) |*pending| {
                if (try self.type_interner.canStoreBorrow(signature.parameters[pending.argument_index].type_id))
                    pending.reference_origins = mut_reference_origins;
            };
            const mut_argument_start: u32 = @intCast(self.pending_mut_arguments.items.len);
            try self.pending_mut_arguments.appendSlice(self.ctx.allocator(), mut_arguments_to_publish.items);
            const mut_arguments: structures.FunctionValueRange = .{
                .start = mut_argument_start,
                .end = @intCast(self.pending_mut_arguments.items.len),
            };
            const writable_start: u32 = @intCast(self.writable_call_references.items.len);
            try self.writable_call_references.appendSlice(self.ctx.allocator(), writable_references.items);
            const writable_range: structures.FunctionValueRange = .{
                .start = writable_start,
                .end = @intCast(self.writable_call_references.items.len),
            };
            if (try self.typeContainsBorrow(signature.return_type) and reference_origins == null and !mut_return_origin and
                !(behavior == .local_borrow or behavior == .box_borrow_mut))
                return self.reject(span, .borrow_outlives_source);
            const inherits_initializer_failure = target == .direct and try self.type_interner.inheritsInitializerFailure(target.direct);
            var construction_failure = false;
            if (inherits_initializer_failure) for (arguments_to_publish.items, signature.parameters) |argument, parameter| {
                if (argument == .initializer)
                    construction_failure = construction_failure or self.initializerCanFail(.{ .id = argument.initializer, .type_id = parameter.type_id });
            };
            return .{ .callable = .{
                .behavior = behavior,
                .operation = .{
                    .target = switch (target) {
                        .direct => |instance| .{ .direct = instance },
                        .indirect => |callee| .{ .indirect = callee.id },
                        .inferred => unreachable,
                    },
                    .arguments = arguments,
                    .return_type = signature.return_type,
                },
                .is_fallible = signature.is_fallible or construction_failure,
                .inherits_initializer_failure = inherits_initializer_failure,
                .mut_arguments = mut_arguments,
                .consumed_arguments = consumed_arguments,
                .writable_references = writable_range,
                .reference_origins = reference_origins,
            } };
        }

        fn resolveMemberCall(
            self: *Self,
            call: semantic.UnresolvedBody.Call,
            member: semantic.UnresolvedBody.MemberCall,
            requires_fallible: bool,
            arguments: *std.ArrayList(semantic.UnresolvedBody.ValueUse),
            target: *CallTarget,
            signature: *structures.CallableType,
        ) !?Value {
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const receiver_type = if (try self.resolveBorrowPlace(member.receiver.value, &fields)) |place|
                if (fields.items.len == 0) try self.placeRootType(place.root) else fields.last().?.type_id
            else blk: {
                const receiver = try self.value(member.receiver.value);
                if (receiver.type_id == .never) return receiver;
                break :blk receiver.type_id;
            };
            const method_arguments = self.unresolved.method_call_arguments[call.arguments.start..call.arguments.end];
            switch (try self.memberTarget(receiver_type, member, call.span)) {
                .field => {
                    const callee = try self.borrowValue(try self.accessField(member.receiver, member.name, call.span), call.span);
                    signature.* = try self.callableSignature(callee.type_id, call.span);
                    target.* = .{ .indirect = callee };
                },
                .static_callable => |callee| {
                    signature.* = try self.callableSignature(callee.type_id, call.span);
                    target.* = .{ .indirect = try self.appendInstruction(.{ .function_ref = callee.value.function_ref }) };
                    try arguments.append(self.ctx.allocator(), member.receiver);
                },
                .function => |function| {
                    try self.validateCallSyntax(call, function.shape.is_fallible, requires_fallible);
                    try arguments.append(self.ctx.allocator(), member.receiver);
                    target.* = if (function.ownership) .{ .direct = function.instance } else try self.resolveMethodArguments(function.instance, function.shape, method_arguments, call.span, arguments);
                    if (target.* == .direct) signature.* = (try self.type_interner.functionSignature(target.direct)) orelse return error.Unavailable;
                    if (!function.ownership) return null;
                },
            }
            for (method_arguments) |argument| try arguments.append(self.ctx.allocator(), argument.value);
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
                for (method_arguments) |argument| try arguments.append(self.ctx.allocator(), argument.value);
                return .{ .inferred = instance };
            }
            if (method_arguments.len + 1 != shape.parameters.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(shape.parameters.len - 1),
                .found = @intCast(method_arguments.len),
            } });
            var static_arguments: std.ArrayList(structures.CompileTimeValueId) = .empty;
            defer static_arguments.deinit(self.ctx.allocator());
            for (method_arguments, shape.parameters[1..], 1..) |argument, parameter, parameter_index| {
                if (parameter.mode != .static) {
                    try arguments.append(self.ctx.allocator(), argument.value);
                    continue;
                }
                if (argument.runtime_reference) |reference_span|
                    return self.reject(reference_span, .comptime_runtime_capture);
                const expected_type = if (parameter.is_meta_type) null else try self.type_interner.staticParameterType(instance, parameter_index, static_arguments.items);
                const value_id = (try self.type_interner.staticCallArgument(argument.node, parameter.is_meta_type, expected_type)) orelse return error.Unavailable;
                const compile_time_value = try self.type_interner.lookupCompileTimeValue(value_id);
                if (compile_time_value == .runtime and compile_time_value.runtime.value == .function_ref)
                    return self.reject(argument.value.span, .static_argument_not_supported);
                try static_arguments.append(self.ctx.allocator(), value_id);
            }
            return .{ .direct = try self.type_interner.specializeFunction(instance, static_arguments.items) };
        }

        fn callFunction(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, mode: ResultRequest) !Value {
            if (call.target == .operation) {
                const arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
                const receiver_type = (try self.unevaluatedType(arguments[0].value, null)) orelse (try self.value(arguments[0].value)).type_id;
                if (receiver_type.isPrimitive() and isArithmeticOperation(call.target.operation)) return self.primitiveArithmetic(call, span);
            }
            const resolved = try self.resolveCall(call, span, false);
            switch (resolved) {
                .diverged => |value_to_return| return value_to_return,
                .callable => |callable| return self.resolvedCallResult(callable, call, span, mode),
            }
        }

        fn isArithmeticOperation(name: []const u8) bool {
            return std.mem.eql(u8, name, "+") or std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "neg");
        }

        fn primitiveArithmetic(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !Value {
            const arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            const name = call.target.operation;
            if (std.mem.eql(u8, name, "neg")) return self.negate(arguments[0]);
            const operands: semantic.UnresolvedBody.BinaryOperands = .{ .lhs = arguments[0], .rhs = arguments[1] };
            const operation: Expression.Operation = if (std.mem.eql(u8, name, "+")) .{ .add = operands } else if (std.mem.eql(u8, name, "-")) .{ .subtract = operands } else if (std.mem.eql(u8, name, "*")) .{ .multiply = operands } else if (std.mem.eql(u8, name, "/")) .{ .divide = operands } else unreachable;
            return self.binary(.{ .operation = operation, .span = span });
        }

        fn invokeOperation(self: *Self, name: []const u8, arguments: []const semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan, mode: ResultRequest) !Value {
            const original = self.unresolved.call_arguments;
            const storage = try self.ctx.allocator().alloc(semantic.UnresolvedBody.ValueUse, original.len + arguments.len);
            defer self.ctx.allocator().free(storage);
            @memcpy(storage[0..original.len], original);
            @memcpy(storage[original.len..], arguments);
            self.unresolved.call_arguments = storage;
            defer self.unresolved.call_arguments = original;
            return self.callFunction(.{
                .target = .{ .operation = name },
                .arguments = .{ .start = @intCast(original.len), .end = @intCast(storage.len) },
                .span = span,
            }, span, mode);
        }

        fn resolvedCallResult(self: *Self, callable: ResolvedCallable, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, request: ResultRequest) !Value {
            if (request.destination == null and request.value.access != .borrow and request.value.access != .consume)
                return self.resolvedCallValue(callable, call, span, null);
            const return_type = callable.operation.return_type;
            if (!lowersToCall(callable.behavior) or !try self.constructsInPlace(return_type)) {
                const result = try self.resolvedCallValue(callable, call, span, null);
                return if (request.destination) |destination| self.placeValue(result, span, destination) else result;
            }
            const target = request.destination orelse Destination{ .storage = try self.localStorage(request.value.expected_type orelse return_type), .site = .argument };
            const storage = try self.memberDestination(target, return_type, span, .fresh);
            return self.finishMemberStorage(try self.resolvedCallValue(callable, call, span, storage), target.storage, span);
        }

        fn lowersToCall(behavior: structures.CallBehavior) bool {
            return switch (behavior) {
                .box_borrow, .box_borrow_mut, .local_borrow, .allocation_element_borrow, .reference_read, .reference_write, .reference_attenuate, .allocation_destroy, .allocation_read => false,
                .ordinary, .box_new, .box_value, .box_destroy, .buffer_new, .buffer_append, .buffer_reserve => true,
            };
        }

        fn resolvedCallValue(self: *Self, resolved: ResolvedCallable, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan, destination: ?Value) !Value {
            if (!lowersToCall(resolved.behavior)) {
                std.debug.assert(destination == null);
                return switch (resolved.behavior) {
                    .box_borrow, .box_borrow_mut => self.boxBorrowOperation(resolved.operation, call),
                    .local_borrow => self.localBorrowOperation(resolved.operation, call, span),
                    .allocation_element_borrow => self.allocationBorrowOperation(resolved.operation, call),
                    .reference_read => self.borrowReadOperation(resolved.operation, call),
                    .reference_write => self.borrowWriteOperation(resolved.operation, call, span, resolved.consumed_arguments),
                    .reference_attenuate => self.attenuateRefOperation(resolved.operation, call),
                    .allocation_destroy, .allocation_read => self.indexedAllocationOperation(resolved.operation, call, span, resolved.mut_arguments),
                    else => unreachable,
                };
            }
            return self.ordinaryCallValue(resolved, span, destination);
        }

        fn ordinaryCallValue(self: *Self, resolved: ResolvedCallable, span: structures.SourceSpan, destination: ?Value) !Value {
            var callable = resolved;
            if (callable.is_fallible) {
                if (!self.is_fallible and !(self.consuming_converter and callable.inherits_initializer_failure))
                    return self.reject(span, .fallible_expression_outside_fallible_function);
                try self.recordCallArgumentConsumes(callable.consumed_arguments);
                const storage = destination orelse try self.inPlaceStorage(callable.operation.return_type);
                if (storage) |result_storage| callable.operation.destination = result_storage.id;
                var flow = try self.lowerFallibleCall(callable.operation, span);
                try self.finishCallExits(&flow, callable, span);
                try self.propagateFailure(flow.failure.?, span);
                try self.enterFlowExit(flow.success.?);
                if (flow.success.?.constructed) |constructed| return constructed;
                const success_block = self.blocks.items[@backingInt(flow.success.?.block)];
                const value_to_return: Value = .{
                    .id = @fromBackingInt(@intCast(success_block.argument_start)),
                    .type_id = callable.operation.return_type,
                    .owned_generation = self.block_argument_generations.items[success_block.argument_start],
                    .reference_origins = flow.success.?.reference_origins,
                };
                if (value_to_return.type_id == .never) self.terminate(.diverge);
                return value_to_return;
            }
            try self.recordCallArgumentConsumes(callable.consumed_arguments);
            if (destination) |storage| callable.operation.destination = storage.id;
            var value_to_return = try self.appendCall(callable.operation, span);
            if (value_to_return.type_id == .never) {
                try self.moveCurrentBoundaryEffectsToTerminator();
                self.terminate(.diverge);
            } else {
                value_to_return = try self.defineOwnedValue(destination orelse value_to_return, span, false);
                value_to_return.reference_origins = try self.finishCallEffects(callable, true);
            }
            return value_to_return;
        }

        fn finishCallEffects(self: *Self, callable: ResolvedCallable, succeeded: bool) !?u32 {
            var returned_origins = callable.reference_origins;
            if (callable.operation.target == .initializer)
                try self.finishInitializerEffects(callable.operation.target.initializer, succeeded, &returned_origins, callable.mut_arguments);
            for (self.call_arguments.items[callable.operation.arguments.start..callable.operation.arguments.end]) |argument| {
                if (argument == .initializer) try self.finishInitializerEffects(argument.initializer, succeeded, &returned_origins, callable.mut_arguments);
            }
            try self.applyCallMutArguments(callable.operation, callable.mut_arguments);
            returned_origins = try self.mergeReferenceOrigins(returned_origins, try self.mutReturnOrigins(callable.mut_arguments));
            try self.invalidateWritableReferences(
                self.writable_call_references.items[callable.writable_references.start..callable.writable_references.end],
                .{ .slots = &returned_origins },
            );
            return returned_origins;
        }

        fn finishInitializerEffects(self: *Self, initializer: structures.FunctionValueId, succeeded: bool, returned_origins: *?u32, mut_arguments: structures.FunctionValueRange) !void {
            for (self.initializer_transfers.items) |transfer| {
                if (transfer.initializer != initializer) continue;
                const availability = if (succeeded) transfer.call_availability else .maybe_transferred;
                if (transfer.field) |field| {
                    self.field_availability[field] = availability;
                } else self.local_availability[@backingInt(transfer.local)] = availability;
            }
            if (succeeded) for (self.initializer_transfers.items) |transfer| {
                if (transfer.initializer != initializer or transfer.call_availability != .available) continue;
                const local_index = @backingInt(transfer.local);
                if (self.local_availability[local_index] != .available) continue;
                if (self.is_initializer_region and self.captured_locals[local_index] != null) continue;
                const owner = self.local_values[local_index].?;
                const previous = if (owner.owned_generation) |generation| self.generations.items[@backingInt(generation)].missing_fields else &.{};
                var fields: std.ArrayList(PlaceField) = .empty;
                defer fields.deinit(self.ctx.allocator());
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
                self.local_values[local_index].?.owned_generation = retained.owned_generation;
            };
            for (self.initializer_writes.items) |write| {
                if (write.initializer != initializer) continue;
                const local = &self.local_values[@backingInt(write.local)].?;
                local.reference_origins = try self.mergeReferenceOrigins(local.reference_origins, write.origins);
                try self.rememberCleanupOrigins(local.*);
                try self.advanceReferenceRoot(write.local, null, null);
                const identity = self.local_values[@backingInt(write.local)].?.binding_identity;
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

        fn finishCallExits(
            self: *Self,
            flow: *ConditionFlow,
            callable: ResolvedCallable,
            span: structures.SourceSpan,
        ) !void {
            if (flow.success) |*success| try self.finishCallExit(success, callable, span, callable.operation.destination, true);
            if (flow.failure) |*failure| try self.finishCallExit(failure, callable, span, null, false);
        }

        fn retireGuardedOwner(self: *Self, owner: Value) !void {
            const generation = owner.owned_generation orelse return;
            const predicate = self.generations.items[@backingInt(generation)].cleanup_condition orelse return;
            _ = try self.copyBits(try self.appendInstruction(.{ .const_bool = true }), .{ .id = predicate, .type_id = .bool });
        }

        fn finishCallExit(
            self: *Self,
            flow_exit: *FlowExit,
            callable: ResolvedCallable,
            span: structures.SourceSpan,
            constructed: ?structures.FunctionValueId,
            succeeded: bool,
        ) !void {
            try self.enterFlowExit(flow_exit.*);
            const parent_boundary = self.current_boundary;
            const boundary = try self.newBoundary(span);
            self.current_boundary = boundary;
            defer self.current_boundary = parent_boundary;
            const returned_origins = try self.finishCallEffects(callable, succeeded);
            if (constructed) |storage| {
                var result = try self.defineOwnedValue(.{ .id = storage, .type_id = callable.operation.return_type }, span, false);
                result.reference_origins = returned_origins;
                flow_exit.constructed = result;
            }
            try self.appendBoundary(boundary);
            flow_exit.state = try self.captureState();
            const source = self.blocks.items[@backingInt(flow_exit.block)];
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            var values: std.ArrayList(Value) = .empty;
            defer values.deinit(self.ctx.allocator());
            for (source.argument_start..source.argument_end) |argument_index| {
                const type_id = self.block_arguments.items[argument_index].type_id;
                const generation = self.block_argument_generations.items[argument_index];
                _ = try self.appendBlockArgument(type_id, generation);
                self.block_arguments.items[self.block_arguments.items.len - 1].representation = self.block_arguments.items[argument_index].representation;
                try values.append(self.ctx.allocator(), .{
                    .id = @fromBackingInt(@intCast(argument_index)),
                    .type_id = type_id,
                    .owned_generation = generation,
                    .reference_origins = returned_origins,
                });
            }
            const continuation = try self.newBlock(argument_start, @intCast(self.block_arguments.items.len));
            self.terminate(.{ .branch = try self.valuesBranch(continuation, values.items) });
            flow_exit.block = continuation;
            flow_exit.binding = null;
            flow_exit.reference_origins = returned_origins;
        }

        fn appendCall(self: *Self, call: structures.FunctionCall, span: structures.SourceSpan) !Value {
            if (call.target == .direct and (try self.type_interner.callBehavior(call.target.direct.item)) == .box_destroy) {
                std.debug.assert(call.arguments.end == call.arguments.start + 1);
                const owner = self.call_arguments.items[call.arguments.start].valueId();
                const signature = (try self.type_interner.functionSignature(call.target.direct)) orelse unreachable;
                const element_type = (try self.type_interner.facts().boxElement(signature.parameters[0].type_id)) orelse unreachable;
                const value_to_drop = try self.appendInstruction(.{ .storage_projection = .{
                    .owner = owner,
                    .type_id = element_type,
                    .projection = .box_element,
                } });
                try self.dropValue(value_to_drop, false, span);
                return self.appendInstruction(.const_unit);
            }
            return self.appendInstruction(.{ .call = call });
        }

        fn indexedAllocationOperation(
            self: *Self,
            operation: structures.FunctionCall,
            call: semantic.UnresolvedBody.Call,
            span: structures.SourceSpan,
            mut_arguments: structures.FunctionValueRange,
        ) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 2);
            const arguments = self.call_arguments.items[operation.arguments.start..operation.arguments.end];
            const original = try self.value(self.unresolved.call_arguments[call.arguments.start].value);
            const element_type = (try self.type_interner.facts().allocationElement(original.type_id)) orelse unreachable;
            const element = try self.appendInstruction(.{ .allocation_element = .{
                .allocation = arguments[0].valueId(),
                .index = arguments[1].valueId(),
                .type_id = element_type,
            } });
            if ((try self.type_interner.callBehavior(operation.target.direct.item)) == .allocation_destroy) {
                try self.dropValue(element, true, span);
                for (self.pending_mut_arguments.items[mut_arguments.start..mut_arguments.end]) |pending| {
                    self.local_values[@backingInt(pending.place.local)].?.binding_identity = try self.newBindingIdentity();
                }
                return self.appendInstruction(.const_unit);
            }
            std.debug.assert(operation.return_type == element_type);
            var borrowed = element;
            borrowed.borrowed_type = element_type;
            borrowed.borrowed_generation = original.borrowed_generation orelse original.owned_generation;
            borrowed.borrowed_cleanup_value = original.borrowed_cleanup_value orelse original.id;
            borrowed.materialize_on_copy = true;
            return self.withReferenceOrigin(original, borrowed);
        }

        fn boxBorrowOperation(self: *Self, operation: structures.FunctionCall, call: semantic.UnresolvedBody.Call) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 1);
            const owner_value = switch (call.target) {
                .member => |member| member.receiver.value,
                else => self.unresolved.call_arguments[call.arguments.start].value,
            };
            const owner = try self.value(owner_value);
            const argument = self.call_arguments.items[operation.arguments.start];
            const reference = try self.appendInstruction(.{ .borrow_box = .{ .source = argument.valueId(), .type_id = operation.return_type } });
            var borrowed = try self.withMutableParameterOrigin(owner, reference);
            if (owner.borrow_root) |root| {
                if (owner.id == self.local_values[@backingInt(root)].?.id) {
                    borrowed.stable_reference_root = root;
                } else if (@backingInt(owner_value) >= self.unresolved.parameter_count) {
                    const receiver = self.unresolved.expressions[@backingInt(owner_value) - self.unresolved.parameter_count];
                    if (receiver.operation == .local_read) {
                        const alias = self.locals.items(.alias)[@backingInt(receiver.operation.local_read)];
                        if (alias) |captured| if (captured.root) |place_root| {
                            if (captured.whole_root and place_root == .local and place_root.local == root)
                                borrowed.stable_reference_root = root;
                        };
                    }
                }
            }
            if (borrowed.stable_reference_root) |root| {
                var origins: ?u32 = null;
                var current = borrowed.reference_origins;
                while (current) |index| {
                    var origin = self.reference_origins.items[index];
                    if (origin.root == root) {
                        origin.stable = true;
                        const owner_value_at_root = self.local_values[@backingInt(root)].?;
                        origin.binding_identity = owner_value_at_root.storage_identity orelse owner_value_at_root.binding_identity;
                    }
                    origins = try self.addReferenceOrigin(origins, origin);
                    current = origin.next;
                }
                borrowed.reference_origins = origins;
            }
            return borrowed;
        }

        fn addReferenceOrigin(self: *Self, head: ?u32, origin: ReferenceOrigin) !?u32 {
            var cursor = head;
            while (cursor) |index| {
                const existing = self.reference_origins.items[index];
                if (existing.generation == origin.generation and existing.cleanup_value == origin.cleanup_value and
                    existing.root == origin.root and std.meta.eql(existing.binding_identity, origin.binding_identity) and
                    existing.parameter == origin.parameter and existing.loop == origin.loop and
                    existing.stable == origin.stable and existing.read == origin.read and
                    existing.deferred_capture == origin.deferred_capture and
                    existing.initializer_owner == origin.initializer_owner and
                    self.sameReferenceProjection(existing.projection, origin.projection) and
                    self.sameReferenceTransform(existing.transform, origin.transform)) return head;
                cursor = existing.next;
            }
            const index: u32 = @intCast(self.reference_origins.items.len);
            var added = origin;
            added.next = head;
            try self.reference_origins.append(self.ctx.allocator(), added);
            return index;
        }

        fn sameReferenceProjection(self: *const Self, left: ?u32, right: ?u32) bool {
            var first = left;
            var second = right;
            while (first != null and second != null) {
                const first_projection = self.reference_projections.items[first.?];
                const second_projection = self.reference_projections.items[second.?];
                if (!std.meta.eql(first_projection.step, second_projection.step)) return false;
                first = first_projection.next;
                second = second_projection.next;
            }
            return first == null and second == null;
        }

        fn sameReferenceTransform(self: *const Self, left: ?u32, right: ?u32) bool {
            var first = left;
            var second = right;
            while (first != null and second != null) {
                const first_transform = self.reference_transforms.items[first.?];
                const second_transform = self.reference_transforms.items[second.?];
                if (!std.meta.eql(first_transform.operation, second_transform.operation)) return false;
                first = first_transform.previous;
                second = second_transform.previous;
            }
            return first == null and second == null;
        }

        fn deferReferenceTransform(self: *Self, origin: *ReferenceOrigin, operation: @FieldType(ReferenceTransform, "operation")) !void {
            const index: u32 = @intCast(self.reference_transforms.items.len);
            try self.reference_transforms.append(self.ctx.allocator(), .{ .operation = operation, .previous = origin.transform });
            origin.transform = index;
        }

        fn applyReferenceTransforms(self: *Self, origins: ?u32, transform: ?u32) anyerror!?u32 {
            const index = transform orelse return origins;
            const transformation = self.reference_transforms.items[index];
            const previous = try self.applyReferenceTransforms(origins, transformation.previous);
            return switch (transformation.operation) {
                .read => |read| self.readReferenceOrigins(previous, read.state, read.instruction, false),
                else => self.transformReferenceOrigins(previous, transformation.operation),
            };
        }

        fn transformReferenceOrigins(self: *Self, origins: ?u32, operation: @FieldType(ReferenceTransform, "operation")) !?u32 {
            std.debug.assert(operation != .read);
            var result: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_origins.items[index];
                current = origin.next;
                const symbolic_parameter = self.is_initializer_region and origin.parameter != null and origin.root == null;
                if (origin.loop != null or (operation != .refresh and symbolic_parameter)) {
                    try self.deferReferenceTransform(&origin, operation);
                } else switch (operation) {
                    .prefix => |step| {
                        const projection: u32 = @intCast(self.reference_projections.items.len);
                        try self.reference_projections.append(self.ctx.allocator(), .{ .step = step, .next = origin.projection });
                        origin.projection = projection;
                    },
                    .select => |step| if (origin.projection) |projection_index| {
                        const projection = self.reference_projections.items[projection_index];
                        if (!std.meta.eql(projection.step, step)) continue;
                        origin.projection = projection.next;
                    },
                    .exclude => |step| if (origin.projection) |projection| {
                        if (std.meta.eql(self.reference_projections.items[projection].step, step)) continue;
                    },
                    .refresh => |refresh| if (origin.root == refresh.root and origin.stable and std.meta.eql(origin.binding_identity, refresh.previous)) {
                        origin.binding_identity = refresh.replacement;
                    },
                    .widen => {},
                    .read => unreachable,
                }
                if (operation == .widen) {
                    origin.projection = null;
                    origin.stable = false;
                }
                result = try self.addReferenceOrigin(result, origin);
            }
            return result;
        }

        fn replaceProjectedOrigins(self: *Self, origins: ?u32, step: @FieldType(ReferenceProjection, "step"), replacement: ?u32) !?u32 {
            return self.mergeReferenceOrigins(try self.transformReferenceOrigins(origins, .{ .exclude = step }), try self.transformReferenceOrigins(replacement, .{ .prefix = step }));
        }

        fn collectWritableReferences(self: *Self, value_to_check: Value, references: *std.ArrayList(Value)) anyerror!void {
            var visiting: std.ArrayList(structures.TypeId) = .empty;
            defer visiting.deinit(self.ctx.allocator());
            try self.collectWritableReferencesAt(value_to_check, references, &visiting, false);
        }

        fn collectWritableReferencesAt(self: *Self, value_to_check: Value, references: *std.ArrayList(Value), visiting: *std.ArrayList(structures.TypeId), dropping: bool) anyerror!void {
            if (value_to_check.reference_origins == null) return;
            if (std.mem.indexOfScalar(structures.TypeId, visiting.items, value_to_check.type_id) != null) return;
            var drop_fields = dropping;
            if (dropping) {
                const capabilities = (try self.type_interner.facts().ownershipCapabilities(value_to_check.type_id)) orelse return error.Unavailable;
                switch (capabilities.drop) {
                    .trivial, .explicit => return,
                    .fieldwise => {},
                    .custom => drop_fields = try self.type_interner.facts().boxElement(value_to_check.type_id) != null,
                }
            }
            try visiting.append(self.ctx.allocator(), value_to_check.type_id);
            defer _ = visiting.pop();
            if (try self.type_interner.facts().borrowAccess(value_to_check.type_id)) |access| {
                if (access.writable) try references.append(self.ctx.allocator(), value_to_check);
                if (try self.type_interner.canStoreBorrow(access.element_type)) {
                    var element = value_to_check;
                    element.type_id = access.element_type;
                    element.reference_origins = try self.transformReferenceOrigins(value_to_check.reference_origins, .{ .select = .element });
                    try self.collectWritableReferencesAt(element, references, visiting, drop_fields);
                }
                return;
            }
            if (try self.type_interner.facts().boxElement(value_to_check.type_id)) |element_type| {
                var element = value_to_check;
                element.type_id = element_type;
                element.reference_origins = try self.transformReferenceOrigins(value_to_check.reference_origins, .{ .select = .element });
                return self.collectWritableReferencesAt(element, references, visiting, drop_fields);
            }
            if (try self.type_interner.facts().allocationElement(value_to_check.type_id)) |element_type| {
                var element = value_to_check;
                element.type_id = element_type;
                return self.collectWritableReferencesAt(element, references, visiting, drop_fields);
            }
            if (try self.type_interner.facts().arrayType(value_to_check.type_id)) |array| {
                if (array.length == 0) return;
                var element = value_to_check;
                element.type_id = array.element_type;
                element.reference_origins = try self.transformReferenceOrigins(value_to_check.reference_origins, .{ .select = .element });
                return self.collectWritableReferencesAt(element, references, visiting, drop_fields);
            }
            if (try self.type_interner.structDefinition(value_to_check.type_id)) |definition| {
                for (definition.fields, 0..) |field, index| {
                    var projected = value_to_check;
                    projected.type_id = field.type_id;
                    projected.reference_origins = try self.transformReferenceOrigins(value_to_check.reference_origins, .{ .select = .{ .field = @intCast(index) } });
                    try self.collectWritableReferencesAt(projected, references, visiting, drop_fields);
                }
            } else if (try self.type_interner.facts().variantMembers(value_to_check.type_id)) |members| {
                for (members) |member| {
                    var projected = value_to_check;
                    projected.type_id = member;
                    projected.reference_origins = try self.transformReferenceOrigins(value_to_check.reference_origins, .{ .select = .{ .variant = member } });
                    try self.collectWritableReferencesAt(projected, references, visiting, drop_fields);
                }
            }
        }

        fn resolveReferenceOrigins(self: *Self, origins: ?u32, incomplete: *bool) !?u32 {
            var visiting: std.ArrayList(u32) = .empty;
            defer visiting.deinit(self.ctx.allocator());
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
            var origin_id = origins;
            while (origin_id) |index| {
                const origin = self.reference_origins.items[index];
                if (origin.loop) |loop_index| {
                    if (std.mem.indexOfScalar(u32, visiting.items, loop_index) == null) {
                        try visiting.append(self.ctx.allocator(), loop_index);
                        const loop_origins = self.loop_reference_origins.items[loop_index];
                        if (!loop_origins.complete) incomplete.* = true;
                        var expanded: ?u32 = null;
                        try self.expandReferenceOrigins(loop_origins.origins, &expanded, visiting, incomplete);
                        resolved.* = try self.mergeReferenceOrigins(resolved.*, try self.applyReferenceTransforms(expanded, origin.transform));
                        _ = visiting.pop();
                    }
                } else {
                    resolved.* = try self.addReferenceOrigin(resolved.*, origin);
                }
                origin_id = origin.next;
            }
        }

        fn typeContainsBorrow(self: *Self, type_id: structures.TypeId) !bool {
            return self.type_interner.containsBorrow(type_id);
        }

        fn mergeReferenceOrigins(self: *Self, first: ?u32, second: ?u32) !?u32 {
            var merged = first;
            var cursor = second;
            while (cursor) |index| {
                const origin = self.reference_origins.items[index];
                merged = try self.addReferenceOrigin(merged, origin);
                cursor = origin.next;
            }
            return merged;
        }

        fn sourceReferenceOrigins(self: *Self, source: Value) !?u32 {
            const generation = source.borrowed_generation orelse source.owned_generation;
            if (source.binding_identity == .unknown and source.reference_origins != null) return source.reference_origins;
            if (generation == null and source.borrow_root == null) return source.reference_origins;
            return self.addReferenceOrigin(source.reference_origins, .{
                .generation = generation,
                .cleanup_value = source.borrowed_cleanup_value orelse source.id,
                .root = source.borrow_root,
                .binding_identity = source.binding_identity,
                .parameter = if (self.is_initializer_region and source.borrow_root != null) self.captured_locals[@backingInt(source.borrow_root.?)] else null,
            });
        }

        fn withReferenceOrigin(self: *Self, source: Value, reference: Value) !Value {
            var result = reference;
            result.reference_origins = try self.sourceReferenceOrigins(source);
            return result;
        }

        fn withMutableParameterOrigin(self: *Self, source: Value, reference: Value) !Value {
            if (source.borrow_root) |root| {
                if (self.locals.items(.mut_parameter)[@backingInt(root)]) |parameter| {
                    var result = reference;
                    result.reference_origins = try self.addReferenceOrigin(source.reference_origins, .{
                        .generation = source.borrowed_generation orelse source.owned_generation,
                        .cleanup_value = source.borrowed_cleanup_value orelse source.id,
                        .root = root,
                        .binding_identity = source.binding_identity,
                        .parameter = parameter,
                    });
                    return result;
                }
            }
            return self.withReferenceOrigin(source, reference);
        }

        fn localBorrowOperation(self: *Self, operation: structures.FunctionCall, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 1);
            const raw = self.unresolved.call_arguments[call.arguments.start].value;
            var place_fields: std.ArrayList(PlaceField) = .empty;
            defer place_fields.deinit(self.ctx.allocator());
            const place = (try self.resolveBorrowPlace(raw, &place_fields)) orelse return self.reject(span, .borrow_requires_place);
            const projected = try self.projectBorrowPlace(place, place_fields.items, false, span);
            var root = projected.root;
            const source = try self.value(raw);
            if (self.is_initializer_region and place.root == .local and projected.alias == null) {
                if (self.captured_locals[@backingInt(place.root.local)]) |parameter| root.id = @fromBackingInt(@intCast(parameter));
            }
            const reference = try self.appendInstruction(.{ .borrow_address = .{
                .source = root.id,
                .type_id = operation.return_type,
                .fields = projected.fields,
                .base_is_reference = projected.alias != null,
            } });
            if (projected.alias != null) {
                var captured = reference;
                captured.reference_origins = root.reference_origins;
                return captured;
            }
            if (place.root == .parameter and try self.type_interner.facts().argumentPassing(root.type_id) == .direct) {
                var local_reference = reference;
                local_reference.reference_origins = try self.addReferenceOrigin(source.reference_origins, .{
                    .cleanup_value = root.id,
                });
                return local_reference;
            }
            return self.withReferenceOrigin(source, reference);
        }

        fn allocationBorrowOperation(self: *Self, operation: structures.FunctionCall, call: semantic.UnresolvedBody.Call) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 2);
            const arguments = self.call_arguments.items[operation.arguments.start..operation.arguments.end];
            const allocation = try self.value(self.unresolved.call_arguments[call.arguments.start].value);
            const element_type = (try self.type_interner.facts().allocationElement(allocation.type_id)) orelse unreachable;
            const element = try self.appendInstruction(.{ .allocation_element = .{
                .allocation = arguments[0].valueId(),
                .index = arguments[1].valueId(),
                .type_id = element_type,
            } });
            const reference = try self.appendInstruction(.{ .borrow_address = .{ .source = element.id, .type_id = operation.return_type } });
            return self.withMutableParameterOrigin(allocation, reference);
        }

        fn borrowReadOperation(self: *Self, operation: structures.FunctionCall, call: semantic.UnresolvedBody.Call) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 1);
            const reference = try self.value(self.unresolved.call_arguments[call.arguments.start].value);
            const argument = self.call_arguments.items[operation.arguments.start];
            return self.readReference(reference, argument.valueId(), operation.return_type, call.span);
        }

        fn dereference(self: *Self, source: semantic.UnresolvedBody.ValueUse) !Value {
            const reference = try self.borrowValue(try self.value(source.value), source.span);
            if (reference.type_id == .never) return reference;
            const element_type = (try self.type_interner.facts().borrowAccess(reference.type_id) orelse
                return self.reject(source.span, .{ .dereference_requires_ref = reference.type_id })).element_type;
            return self.readReference(reference, reference.id, element_type, source.span);
        }

        fn readReference(self: *Self, reference: Value, source: structures.FunctionValueId, element_type: structures.TypeId, span: structures.SourceSpan) !Value {
            const source_origins = reference.reference_origins orelse return self.reject(span, .borrow_outlives_source);
            var incomplete = false;
            var origin_id = try self.resolveReferenceOrigins(source_origins, &incomplete);
            var borrow_root: ?semantic.UnresolvedBody.LocalId = null;
            while (origin_id) |index| {
                const origin = self.reference_origins.items[index];
                borrow_root = laterBorrowRoot(borrow_root, origin.root);
                origin_id = origin.next;
            }
            var result = try self.appendInstruction(.{ .borrow_read = .{ .source = source, .type_id = element_type } });
            result.borrowed_type = element_type;
            result.borrow_root = borrow_root;
            result.reference_origins = try self.readReferenceOrigins(reference.reference_origins, null, @truncate(@backingInt(result.id)), false);
            result.materialize_on_copy = true;
            return result;
        }

        fn readReferenceOrigins(self: *Self, source_origins: ?u32, state: ?StateId, instruction: u31, deferred_capture: bool) !?u32 {
            var origins: ?u32 = null;
            var current = source_origins;
            while (current) |index| {
                var origin = self.reference_origins.items[index];
                current = origin.next;
                origin.deferred_capture = origin.deferred_capture or deferred_capture;
                if (origin.loop != null) {
                    try self.deferReferenceTransform(&origin, .{ .read = .{ .state = state orelse try self.captureState(), .instruction = instruction } });
                } else if (origin.projection) |projection_index| {
                    const projection = self.reference_projections.items[projection_index];
                    if (projection.step == .element) origin.projection = projection.next;
                } else if (origin.stable) {
                    if (origin.root) |root| {
                        const values_at_read = if (state) |state_id| self.states.items[@backingInt(state_id)].values else StateValues.borrowed(self.local_values);
                        if (@backingInt(root) < values_at_read.len) {
                            if (values_at_read.get(@backingInt(root))) |value_at_read| origin.binding_identity = value_at_read.binding_identity;
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
            if (try referenceReplacementIssue(self.type_interner, element_type)) |issue| return self.reject(span, issue);
        }

        fn referenceAssignment(self: *Self, assignment_ref: @FieldType(Expression.Operation, "reference_assignment")) !Value {
            const reference = try self.value(assignment_ref.reference.value);
            if (reference.type_id == .never) return reference;
            var result = try self.assignReference(reference, assignment_ref.value, assignment_ref.reference.span);
            if (result.type_id != .never) try self.advanceOwnedReferenceOrigins(reference, reference.id, .{ .value = &result.reference_origins });
            return result;
        }

        fn borrowAssignment(self: *Self, assignment_alias: @FieldType(Expression.Operation, "borrow_assignment")) !Value {
            const local_index = @backingInt(assignment_alias.target);
            var reference = try self.aliasReference(assignment_alias.target);
            _ = try self.borrowValue(reference, assignment_alias.target_span);
            const source_fields = self.unresolved.assignment_fields[assignment_alias.fields.start..assignment_alias.fields.end];
            if (source_fields.len != 0) {
                const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
                var fields: std.ArrayList(PlaceField) = .empty;
                defer fields.deinit(self.ctx.allocator());
                try self.resolvePlaceFields(element_type, source_fields, assignment_alias.target_span, &fields);
                const field_reference = try self.appendInstruction(.{ .borrow_address = .{
                    .source = reference.id,
                    .type_id = (try self.type_interner.referenceType(fields.last().?.type_id, true)) orelse return error.Unavailable,
                    .fields = try self.publishBorrowFields(fields.items),
                    .base_is_reference = true,
                } });
                reference = field_reference;
                reference.reference_origins = self.local_values[local_index].?.reference_origins;
            }
            var result = try self.assignReference(reference, assignment_alias.value, assignment_alias.target_span);
            if (result.type_id == .never) return result;
            const alias = self.locals.items(.alias)[local_index].?;
            const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
            if (alias.root) |root| if (root == .local and
                ((alias.whole_root and source_fields.len == 0) or capabilities.needs_automatic_drop))
            {
                const owner_index = @backingInt(root.local);
                var owner = self.local_values[owner_index].?;
                try self.recordConsume(owner);
                owner.owned_generation = try self.allocateGeneration(owner.type_id, assignment_alias.value.span, self.locals.items(.can_deinit)[owner_index]);
                if (owner.owned_generation) |generation| try self.recordEffect(.{ .define = .{
                    .generation = generation,
                    .value = owner.id,
                } });
                self.local_values[owner_index] = owner;
                if (capabilities.needs_automatic_drop) try self.advanceReferenceRoot(root.local, null, .{ .value = &result.reference_origins });
            };
            if (alias.root == null) try self.advanceOwnedReferenceOrigins(reference, self.local_values[local_index].?.id, .{ .value = &result.reference_origins });
            return result;
        }

        fn invalidateWritableReferences(self: *Self, references: []const Value, refresh: ReferenceRefresh) !void {
            for (references) |reference| {
                try self.validateInitializerReferenceWrite(reference, self.activeLifetimeSpan());
                try self.advanceOwnedReferenceOrigins(reference, reference.id, refresh);
            }
        }

        fn advanceOwnedReferenceOrigins(self: *Self, reference: Value, captured_handle: structures.FunctionValueId, fresh_result_origins: ?ReferenceRefresh) !void {
            const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(element_type)) orelse return error.Unavailable;
            if (!capabilities.needs_automatic_drop) return;
            var incomplete = false;
            var origins = try self.resolveReferenceOrigins(reference.reference_origins, &incomplete);
            var refreshed = origins;
            if (incomplete) try self.pending_reference_invalidations.append(self.ctx.allocator(), .{
                .origins = reference.reference_origins.?,
                .known = origins,
                .span = self.activeLifetimeSpan(),
            });
            while (origins) |origin_index| {
                const origin = self.reference_origins.items[origin_index];
                if (origin.root) |root| {
                    try self.advanceReferenceRoot(root, captured_handle, fresh_result_origins);
                    refreshed = try self.updatedRootOrigin(refreshed, root, self.local_values[@backingInt(root)].?.binding_identity);
                }
                origins = origin.next;
            }
            if (incomplete) for (self.local_values, self.local_availability) |*stored, availability| {
                if (availability == .available and stored.* != null and stored.*.?.id == captured_handle and
                    try self.type_interner.facts().borrowElement(stored.*.?.type_id) != null)
                    stored.*.?.reference_origins = refreshed;
            };
        }

        fn advanceReferenceRoot(self: *Self, root: semantic.UnresolvedBody.LocalId, captured_handle: ?structures.FunctionValueId, fresh_result_origins: ?ReferenceRefresh) !void {
            const owner_index = @backingInt(root);
            var owner = self.local_values[owner_index].?;
            const previous_identity = owner.binding_identity;
            owner.storage_identity = if (captured_handle != null) owner.storage_identity orelse previous_identity else null;
            owner.binding_identity = try self.newBindingIdentity();
            self.local_values[owner_index] = owner;
            for (self.locals.items(.alias), self.local_values, self.local_availability) |other_alias, *other_value, availability| {
                if (availability != .available or other_value.* == null) continue;
                const names_root = if (other_alias) |alias| if (alias.root) |alias_root|
                    alias_root == .local and alias_root.local == root
                else
                    false else false;
                if (names_root or (captured_handle != null and
                    ((other_value.*.?.id == captured_handle.? and try self.type_interner.facts().borrowElement(other_value.*.?.type_id) != null) or
                        other_value.*.?.stable_reference_root == root)))
                {
                    if (try self.hasCurrentRootOrigin(other_value.*.?.reference_origins, root, previous_identity))
                        other_value.*.?.reference_origins = try self.updatedRootOrigin(other_value.*.?.reference_origins, root, owner.binding_identity);
                }
                if (captured_handle != null)
                    other_value.*.?.reference_origins = try self.transformReferenceOrigins(other_value.*.?.reference_origins, .{ .refresh = .{ .root = root, .previous = previous_identity, .replacement = owner.storage_identity orelse owner.binding_identity } });
            }
            if (fresh_result_origins) |refresh| switch (refresh) {
                .value => |origins| origins.* = try self.updatedRootOrigin(origins.*, root, owner.binding_identity),
                .slots => |origins| origins.* = try self.transformReferenceOrigins(origins.*, .{ .refresh = .{ .root = root, .previous = previous_identity, .replacement = owner.storage_identity orelse owner.binding_identity } }),
            };
        }

        fn hasCurrentRootOrigin(self: *Self, origins: ?u32, root: semantic.UnresolvedBody.LocalId, identity: BindingIdentity) !bool {
            const actual = try self.resolveBindingIdentity(identity);
            if (actual.incomplete or actual.conflicting or actual.value == null) return false;
            var incomplete = false;
            var current = try self.resolveReferenceOrigins(origins, &incomplete);
            if (incomplete) return false;
            var found = false;
            while (current) |index| {
                const origin = self.reference_origins.items[index];
                if (origin.root == root) {
                    const expected = try self.resolveBindingIdentity(origin.binding_identity);
                    if (expected.incomplete or expected.conflicting or expected.value != actual.value) return false;
                    found = true;
                }
                current = origin.next;
            }
            return found;
        }

        fn updatedRootOrigin(self: *Self, origins: ?u32, root: semantic.UnresolvedBody.LocalId, identity: BindingIdentity) !?u32 {
            var updated: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_origins.items[index];
                if (origin.root == root) origin.binding_identity = if (origin.stable)
                    self.local_values[@backingInt(root)].?.storage_identity orelse identity
                else
                    identity;
                updated = try self.addReferenceOrigin(updated, origin);
                current = origin.next;
            }
            return updated;
        }

        fn refreshInitializerOwnerOrigins(self: *Self, origins: ?u32, initializer: structures.FunctionValueId, root: semantic.UnresolvedBody.LocalId, identity: BindingIdentity) !?u32 {
            var updated: ?u32 = null;
            var current = origins;
            while (current) |index| {
                var origin = self.reference_origins.items[index];
                if (origin.root == root and origin.initializer_owner == initializer) origin.binding_identity = identity;
                updated = try self.addReferenceOrigin(updated, origin);
                current = origin.next;
            }
            return updated;
        }

        fn assignReference(self: *Self, reference: Value, value_use: semantic.UnresolvedBody.ValueUse, span: structures.SourceSpan) !Value {
            const access = (try self.type_interner.facts().borrowAccess(reference.type_id)) orelse
                return self.reject(span, .{ .dereference_requires_ref = reference.type_id });
            if (!access.writable) return self.reject(span, .reference_not_writable);
            try self.validateReferenceReplacement(access.element_type, value_use.span);
            const raw_value = try self.valueWithContext(value_use.value, .{ .expected_type = access.element_type, .access = .initialize });
            if (raw_value.type_id == .never) return raw_value;
            const use = try self.coerceValue(raw_value.id, raw_value.type_id, access.element_type) orelse
                return self.reject(value_use.span, .{ .assignment_type_mismatch = self.typeMismatch(access.element_type, raw_value.type_id) });
            const owned = try self.ownValue(raw_value, value_use.span);
            const operand = if (use.coerce_to) |_| try self.coerceOwnedRepresentation(owned, use, value_use.span, null) else owned;
            try self.recordConsume(operand);
            _ = try self.replaceReference(reference, reference.id, operand.id, span);
            return self.readReference(reference, reference.id, access.element_type, span);
        }

        fn borrowWriteOperation(
            self: *Self,
            operation: structures.FunctionCall,
            call: semantic.UnresolvedBody.Call,
            span: structures.SourceSpan,
            consumed_arguments: structures.FunctionValueRange,
        ) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 2);
            const arguments = self.call_arguments.items[operation.arguments.start..operation.arguments.end];
            const reference_id = switch (call.target) {
                .member => |member| member.receiver.value,
                else => self.unresolved.call_arguments[call.arguments.start].value,
            };
            const reference = try self.value(reference_id);
            try self.recordCallArgumentConsumes(consumed_arguments);
            const result = try self.replaceReference(reference, arguments[0].valueId(), arguments[1].valueId(), span);
            try self.advanceOwnedReferenceOrigins(reference, reference.id, null);
            return result;
        }

        fn replaceReference(self: *Self, reference: Value, reference_id: structures.FunctionValueId, item_id: structures.FunctionValueId, span: structures.SourceSpan) !Value {
            try self.validateInitializerReferenceWrite(reference, span);
            try self.recordUse(reference);
            const pinned = try self.appendInstruction(.{ .value_copy = .{ .source = reference_id, .type_id = reference.type_id } });
            const element_type = (try self.type_interner.facts().borrowElement(reference.type_id)) orelse unreachable;
            const old_value = try self.appendInstruction(.{ .borrow_read = .{ .source = pinned.id, .type_id = element_type } });
            try self.dropValue(old_value, false, span);
            return self.appendInstruction(.{ .borrow_write = .{
                .reference = pinned.id,
                .value = item_id,
                .type_id = element_type,
            } });
        }

        fn attenuateRefOperation(self: *Self, operation: structures.FunctionCall, call: semantic.UnresolvedBody.Call) !Value {
            std.debug.assert(operation.arguments.end == operation.arguments.start + 1);
            const reference_value = switch (call.target) {
                .member => |member| member.receiver.value,
                else => self.unresolved.call_arguments[call.arguments.start].value,
            };
            const reference = try self.value(reference_value);
            var result = try self.appendInstruction(.{ .value_copy = .{
                .source = self.call_arguments.items[operation.arguments.start].valueId(),
                .type_id = operation.return_type,
            } });
            result.reference_origins = reference.reference_origins;
            result.stable_reference_root = reference.stable_reference_root;
            return result;
        }

        fn applyCallMutArguments(self: *Self, call: structures.FunctionCall, range: structures.FunctionValueRange) !void {
            for (self.pending_mut_arguments.items[range.start..range.end]) |pending| {
                const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
                const root = self.local_values[@backingInt(pending.place.local)].?;
                const alias = self.locals.items(.alias)[@backingInt(pending.place.local)];
                const root_type = try self.placeRootType(.{ .local = pending.place.local });
                const leaf_type = if (fields.len == 0) root_type else fields[fields.len - 1].type_id;
                const leaf_origins = try self.mergeReferenceOrigins(root.reference_origins, pending.reference_origins);
                const updated_argument: structures.CallMutArgument = .{
                    .arguments = call.arguments,
                    .return_type = call.return_type,
                    .argument_index = pending.argument_index,
                    .type_id = leaf_type,
                };
                if (alias != null) {
                    var reference = try self.aliasReference(pending.place.local);
                    if (fields.len != 0) {
                        var projected = try self.appendInstruction(.{ .borrow_address = .{
                            .source = reference.id,
                            .type_id = (try self.type_interner.referenceType(leaf_type, true)) orelse return error.Unavailable,
                            .fields = try self.publishBorrowFields(fields),
                            .base_is_reference = true,
                        } });
                        projected.reference_origins = reference.reference_origins;
                        reference = projected;
                    }
                    if (try self.constructsInPlace(leaf_type)) {
                        var in_place = updated_argument;
                        in_place.destination = self.call_arguments.items[call.arguments.start + pending.argument_index].valueId();
                        _ = try self.appendInstruction(.{ .call_mut_argument = in_place });
                    } else {
                        const updated = try self.appendInstruction(.{ .call_mut_argument = updated_argument });
                        _ = try self.appendInstruction(.{ .borrow_write = .{ .reference = reference.id, .value = updated.id, .type_id = leaf_type } });
                    }
                    if (alias.?.root) |owner_root| if (owner_root == .local) {
                        try self.mergeMutOwnerOrigins(owner_root.local, pending.reference_origins);
                    };
                    if (alias.?.root == null and try self.type_interner.canStoreBorrow(leaf_type)) {
                        var incomplete = false;
                        var origins = try self.resolveReferenceOrigins(reference.reference_origins, &incomplete);
                        std.debug.assert(!incomplete);
                        while (origins) |origin_index| {
                            const origin = self.reference_origins.items[origin_index];
                            if (origin.root) |owner| try self.mergeMutOwnerOrigins(owner, pending.reference_origins);
                            origins = origin.next;
                        }
                    }
                    try self.advanceOwnedReferenceOrigins(reference, root.id, null);
                    continue;
                }
                var updated_root = root;
                if (try self.constructsInPlace(root.type_id)) {
                    var in_place = updated_argument;
                    in_place.destination = if (try self.constructsInPlace(leaf_type))
                        self.call_arguments.items[call.arguments.start + pending.argument_index].valueId()
                    else
                        (try self.fieldStorage(rawValue(root), fields)).id;
                    _ = try self.appendInstruction(.{ .call_mut_argument = in_place });
                    updated_root.reference_origins = try self.fieldUpdateOrigins(root.reference_origins, fields, leaf_origins);
                } else {
                    var updated_leaf = try self.appendInstruction(.{ .call_mut_argument = updated_argument });
                    updated_leaf.reference_origins = leaf_origins;
                    updated_root = try self.updateFields(root, fields, updated_leaf);
                }
                var updated = try self.updateOwnedValue(root, updated_root);
                updated.binding_identity = try self.newBindingIdentity();
                updated.storage_identity = null;
                self.local_values[@backingInt(pending.place.local)] = updated;
                try self.writeCapturedLocal(pending.place.local);
            }
        }

        fn mergeMutOwnerOrigins(self: *Self, local: semantic.UnresolvedBody.LocalId, origins: ?u32) !void {
            const owner_index = @backingInt(local);
            var owner = self.local_values[owner_index].?;
            if (!try self.type_interner.canStoreBorrow(owner.type_id)) return;
            owner.reference_origins = try self.mergeReferenceOrigins(owner.reference_origins, try self.transformReferenceOrigins(origins, .widen));
            self.local_values[owner_index] = owner;
            try self.writeCapturedLocal(local);
        }

        fn mutReturnOrigins(self: *Self, range: structures.FunctionValueRange) !?u32 {
            var origins: ?u32 = null;
            for (self.pending_mut_arguments.items[range.start..range.end]) |pending| {
                if (!pending.return_origin) continue;
                const updated = self.borrowLocalValue(pending.place.local);
                const source_origins = if (try self.type_interner.facts().borrowElement(updated.type_id) != null)
                    updated.reference_origins
                else
                    (try self.withMutableParameterOrigin(updated, updated)).reference_origins;
                origins = try self.mergeReferenceOrigins(origins, source_origins);
            }
            return origins;
        }

        fn recordCallArgumentConsumes(self: *Self, range: structures.FunctionValueRange) !void {
            for (self.pending_consumed_arguments.items[range.start..range.end]) |argument| try self.recordConsume(argument);
        }

        fn updateOwnedValue(self: *Self, previous: Value, updated: Value) !Value {
            var result = withoutOwnershipSource(updated);
            result.owned_generation = previous.owned_generation;
            if (result.owned_generation) |generation| try self.recordEffect(.{ .update = .{
                .generation = generation,
                .cleanup_value = result.id,
            } });
            std.debug.assert(result.owned_generation == previous.owned_generation);
            return result;
        }

        fn updateFields(self: *Self, root: Value, fields: []const PlaceField, updated_leaf: Value) !Value {
            if (fields.len == 0) return updated_leaf;

            var parents: std.ArrayList(Value) = .empty;
            defer parents.deinit(self.ctx.allocator());
            var current = root;
            for (fields) |field| {
                try parents.append(self.ctx.allocator(), current);
                const origins = try self.transformReferenceOrigins(current.reference_origins, .{ .select = .{ .field = field.index } });
                current = try self.appendInstruction(.{ .field_access = .{
                    .operand = current.id,
                    .field_index = field.index,
                    .field_type = field.type_id,
                } });
                current.reference_origins = origins;
            }
            var updated = updated_leaf;
            var field_index = fields.len;
            while (field_index > 0) {
                field_index -= 1;
                const previous = parents.items[field_index];
                const updated_origins = try self.replaceProjectedOrigins(previous.reference_origins, .{ .field = fields[field_index].index }, updated.reference_origins);
                updated = try self.appendInstruction(.{ .field_update = .{
                    .operand = previous.id,
                    .value = updated.id,
                    .field_index = fields[field_index].index,
                    .type_id = previous.type_id,
                } });
                updated.reference_origins = updated_origins;
            }
            return updated;
        }

        fn lowerFallibleCall(self: *Self, call: structures.FunctionCall, span: structures.SourceSpan) !ConditionFlow {
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            const produced_generation = if (call.destination == null) try self.allocateGeneration(call.return_type, span, false) else null;
            _ = try self.appendBlockArgument(if (call.destination == null) call.return_type else .unit, produced_generation);
            const success = try self.newBlock(argument_start, argument_start + 1);
            const failure = try self.newBlock(argument_start + 1, argument_start + 1);
            try self.moveCurrentBoundaryEffectsToTerminator();
            self.terminate(.{ .fallible_call = .{ .call = call, .success = success, .failure = failure } });
            const state = try self.captureState();
            return .{
                .success = .{ .block = success, .state = state },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn condition(self: *Self, id: semantic.UnresolvedBody.ConditionId) anyerror!ConditionFlow {
            const condition_data = self.unresolved.conditions[@backingInt(id)];
            return switch (condition_data) {
                .boolean => |operand| self.booleanCondition(try self.value(operand.value), operand.span, false),
                .operation_not => |operand| self.operationNotCondition(operand),
                .comparison => |comparison| self.comparisonCondition(comparison),
                .static_membership => |membership| self.staticMembershipCondition(membership),
                .variant_membership => |membership| self.variantMembershipCondition(membership),
                .conjunction => |logical| self.conjunctionCondition(logical),
                .disjunction => |logical| self.disjunctionCondition(logical),
                .negation => |operand| self.negatedCondition(operand),
                .call => |call| self.callCondition(call.target, call.binding, call.allow_infallible),
                .initialization => |initialization| self.initializationCondition(initialization),
            };
        }

        fn booleanCondition(self: *Self, operand: Value, span: structures.SourceSpan, invert: bool) !ConditionFlow {
            if (operand.type_id == .never) return .{ .success = null, .failure = null, .diverged = operand };
            if (operand.type_id != .bool) return self.reject(span, .if_condition_not_fallible);
            try self.recordUse(operand);
            const expected = try self.appendInstruction(.{ .const_bool = !invert });
            const start: u32 = @intCast(self.block_arguments.items.len);
            const success = try self.newBlock(start, start);
            const failure = try self.newBlock(start, start);
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = operand.id, .rhs = expected.id },
                .then_branch = self.emptyBranch(success),
                .else_branch = self.emptyBranch(failure),
            } });
            const state = try self.captureState();
            return .{ .success = .{ .block = success, .state = state }, .failure = .{ .block = failure, .state = state } };
        }

        fn operationNotCondition(self: *Self, operand: semantic.UnresolvedBody.ValueUse) !ConditionFlow {
            const index = @backingInt(operand.value);
            if (index >= self.unresolved.parameter_count) {
                const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
                if (expression.operation == .call and self.values[index] == null) {
                    const call = expression.operation.call;
                    const resolved = try self.resolveCall(call, call.span, true);
                    switch (resolved) {
                        .diverged => |diverged| return .{ .success = null, .failure = null, .diverged = diverged },
                        .callable => |callable| {
                            if (callable.is_fallible) {
                                const flow = try self.fallibleCallCondition(callable, call.span, null);
                                return .{ .success = flow.failure, .failure = flow.success, .diverged = flow.diverged };
                            }
                            self.values[index] = try self.resolvedCallValue(callable, call, call.span, null);
                        },
                    }
                }
            }
            const value_to_test = try self.value(operand.value);
            if (value_to_test.type_id == .bool or value_to_test.type_id == .never)
                return self.booleanCondition(value_to_test, operand.span, true);
            if (value_to_test.type_id.isPrimitive()) return self.reject(operand.span, .if_condition_not_fallible);
            return self.booleanCondition(try self.invokeOperation("not", &.{operand}, operand.span, .{}), operand.span, false);
        }

        fn initializerCanFail(self: *Self, initializer: Value) bool {
            if (self.type_check_only or initializer.initializer_parameter != null or @backingInt(initializer.id) & (@as(u32, 1) << 31) == 0) return true;
            const instruction_id = @backingInt(initializer.id) & ~(@as(u32, 1) << 31);
            for (self.blocks.items) |block_value| for (block_value.items.items) |item| {
                if (item != .instruction or item.instruction.id != instruction_id) continue;
                const reference = item.instruction.operation.initializer_ref;
                return self.initializer_regions.items[reference.region].hasFailureExit();
            };
            unreachable;
        }

        fn initializationCondition(self: *Self, initialization: @FieldType(semantic.UnresolvedBody.Condition, "initialization")) !ConditionFlow {
            const expected = if (initialization.binding) |binding| binding.annotation_type else null;
            const type_id = expected orelse try self.inferInitializerType(initialization.value, null);
            const initializer = try self.prepareInitializer(initialization.value, type_id);
            if (!self.initializerCanFail(initializer)) return self.reject(initialization.value.span, .if_condition_not_fallible);
            const start: u32 = @intCast(self.call_arguments.items.len);
            var callable: ResolvedCallable = .{
                .operation = .{ .target = .{ .initializer = initializer.id }, .arguments = .{ .start = start, .end = start }, .return_type = type_id },
                .behavior = .ordinary,
                .is_fallible = true,
                .mut_arguments = .{ .start = 0, .end = 0 },
                .consumed_arguments = .{ .start = 0, .end = 0 },
                .writable_references = .{ .start = 0, .end = 0 },
                .reference_origins = initializer.reference_origins,
            };
            if (try self.inPlaceStorage(type_id)) |storage| callable.operation.destination = storage.id;
            var flow = try self.lowerFallibleCall(callable.operation, initialization.value.span);
            try self.finishCallExits(&flow, callable, initialization.value.span);
            if (initialization.binding) |binding| flow.success.?.binding = .{ .call = binding };
            return flow;
        }

        fn staticMembershipCondition(self: *Self, membership: @FieldType(semantic.UnresolvedBody.Condition, "static_membership")) !ConditionFlow {
            const matches = (try self.type_interner.evaluateWhereMembership(membership.operand, membership.target_type)) orelse return error.Unavailable;
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            const next = try self.newBlock(argument_start, argument_start);
            self.terminate(.{ .branch = self.emptyBranch(next) });
            const exit: FlowExit = .{ .block = next, .state = try self.captureState() };
            return if (matches) .{ .success = exit, .failure = null } else .{ .success = null, .failure = exit };
        }

        fn callCondition(self: *Self, call: semantic.UnresolvedBody.Call, binding: ?semantic.UnresolvedBody.ConditionBinding, allow_infallible: bool) !ConditionFlow {
            const resolved = try self.resolveCall(call, call.span, true);
            return switch (resolved) {
                .diverged => |value_to_return| .{ .success = null, .failure = null, .diverged = value_to_return },
                .callable => |resolved_callable| if (resolved_callable.is_fallible)
                    self.fallibleCallCondition(resolved_callable, call.span, binding)
                else if (allow_infallible)
                    self.infallibleBindingCondition(resolved_callable, call, binding.?)
                else if (binding == null and resolved_callable.operation.return_type == .bool)
                    self.booleanCondition(try self.resolvedCallValue(resolved_callable, call, call.span, null), call.span, false)
                else
                    self.reject(call.span, .if_condition_not_fallible),
            };
        }

        fn infallibleBindingCondition(self: *Self, callable: ResolvedCallable, call: semantic.UnresolvedBody.Call, binding: semantic.UnresolvedBody.ConditionBinding) !ConditionFlow {
            const constructed = try self.resolvedCallValue(callable, call, call.span, null);
            const start: u32 = @intCast(self.block_arguments.items.len);
            const next = try self.newBlock(start, start);
            self.terminate(.{ .branch = self.emptyBranch(next) });
            return .{
                .success = .{ .block = next, .state = try self.captureState(), .binding = .{ .call = binding }, .constructed = constructed },
                .failure = null,
            };
        }

        fn fallibleCallCondition(self: *Self, resolved: ResolvedCallable, span: structures.SourceSpan, binding: ?semantic.UnresolvedBody.ConditionBinding) !ConditionFlow {
            var callable = resolved;
            try self.recordCallArgumentConsumes(callable.consumed_arguments);
            if (try self.inPlaceStorage(callable.operation.return_type)) |storage| callable.operation.destination = storage.id;
            var flow = try self.lowerFallibleCall(callable.operation, span);
            try self.finishCallExits(&flow, callable, span);
            if (binding) |success_binding| flow.success.?.binding = .{ .call = success_binding };
            return flow;
        }

        fn validateCallSyntax(self: *Self, call: semantic.UnresolvedBody.Call, is_fallible: bool, requires_fallible: bool) !void {
            if (call.target == .operation) return;
            if (semantic.callSyntaxIssue(call.fallible_syntax, is_fallible, requires_fallible)) |kind|
                return self.reject(call.span, kind);
        }

        fn comparisonCondition(self: *Self, comparison: @FieldType(semantic.UnresolvedBody.Condition, "comparison")) !ConditionFlow {
            const context: ValueContext = .{ .expected_type = if (self.allow_type_values) .int_literal else null, .allow_converters = false };
            const lhs = try self.borrowValue(try self.valueWithContext(comparison.operands.lhs.value, context), comparison.operands.lhs.span);
            if (lhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = lhs };
            if (!lhs.type_id.isPrimitive()) {
                const name: []const u8 = switch (comparison.operation) {
                    .eq => "==",
                    .ne => "<>",
                    .lt => "<",
                    .gt => ">",
                    .le => "<=",
                    .ge => ">=",
                };
                return self.booleanCondition(try self.invokeOperation(name, &.{ comparison.operands.lhs, comparison.operands.rhs }, comparison.operands.lhs.span, .{}), comparison.operands.lhs.span, false);
            }
            const rhs = try self.borrowValue(try self.valueWithContext(comparison.operands.rhs.value, context), comparison.operands.rhs.span);
            if (rhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = rhs };
            try self.recordUse(lhs);
            const operation: structures.PredicateOperation = switch (comparison.operation) {
                .lt, .gt, .le, .ge => blk: {
                    if (lhs.type_id != .int and lhs.type_id != .int_literal) return self.reject(comparison.operands.lhs.span, .{ .comparison_operand_not_int = lhs.type_id });
                    if (rhs.type_id != .int and rhs.type_id != .int_literal) return self.reject(comparison.operands.rhs.span, .{ .comparison_operand_not_int = rhs.type_id });
                    break :blk switch (comparison.operation) {
                        .lt => .lti,
                        .gt => .gti,
                        .le => .lei,
                        .ge => .gei,
                        .eq, .ne => unreachable,
                    };
                },
                .eq, .ne => blk: {
                    if (lhs.type_id != .int and lhs.type_id != .int_literal and lhs.type_id != .bool and lhs.type_id != .type) {
                        return self.reject(comparison.operands.lhs.span, .{ .equality_operand_not_supported = lhs.type_id });
                    }
                    const integers = (lhs.type_id == .int or lhs.type_id == .int_literal) and (rhs.type_id == .int or rhs.type_id == .int_literal);
                    if (rhs.type_id != lhs.type_id and !integers) {
                        return self.reject(comparison.operands.rhs.span, .{ .equality_operand_type_mismatch = self.typeMismatch(lhs.type_id, rhs.type_id) });
                    }
                    break :blk switch (lhs.type_id) {
                        .int, .int_literal => if (comparison.operation == .eq) .eqi else .nei,
                        .bool => if (comparison.operation == .eq) .eqb else .neb,
                        .type => if (comparison.operation == .eq) .eqt else .net,
                        else => unreachable,
                    };
                },
            };
            const branch_argument_start: u32 = @intCast(self.block_arguments.items.len);
            const success = try self.newBlock(branch_argument_start, branch_argument_start);
            const failure = try self.newBlock(branch_argument_start, branch_argument_start);
            self.terminate(.{ .predicate_branch = .{
                .operation = operation,
                .operands = .{ .lhs = lhs.id, .rhs = rhs.id },
                .then_branch = self.emptyBranch(success),
                .else_branch = self.emptyBranch(failure),
            } });
            const state = try self.captureState();
            return .{
                .success = .{ .block = success, .state = state },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn variantMembershipCondition(
            self: *Self,
            membership: @FieldType(semantic.UnresolvedBody.Condition, "variant_membership"),
        ) !ConditionFlow {
            const operand = try self.borrowValue(try self.value(membership.operand.value), membership.operand.span);
            if (operand.type_id == .never) return .{ .success = null, .failure = null, .diverged = operand };
            const source_members = try self.type_interner.facts().variantMembers(operand.type_id) orelse {
                return self.reject(membership.operand.span, .{ .variant_inspection_operand_not_variant = operand.type_id });
            };
            const target_members = try self.type_interner.facts().variantMembers(membership.target_type);
            var matching_count: usize = 0;
            for (source_members) |member| {
                if (includesType(membership.target_type, target_members, member)) matching_count += 1;
            }
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            const success = try self.newBlock(argument_start, argument_start);
            const failure = try self.newBlock(argument_start, argument_start);
            if (matching_count == 0 or matching_count == source_members.len) {
                self.terminate(.{ .branch = self.emptyBranch(if (matching_count == 0) failure else success) });
            } else {
                const tag = try self.appendInstruction(.{ .variant_tag = operand.id });
                var remaining = matching_count;
                for (source_members, 0..) |member, member_index| {
                    if (!includesType(membership.target_type, target_members, member)) continue;
                    remaining -= 1;
                    const next_failure = if (remaining == 0)
                        failure
                    else
                        try self.newBlock(argument_start, argument_start);
                    const expected = try self.appendInstruction(.{ .const_int = @intCast(member_index) });
                    self.terminate(.{ .predicate_branch = .{
                        .operation = .eqi,
                        .operands = .{ .lhs = tag.id, .rhs = expected.id },
                        .then_branch = self.emptyBranch(success),
                        .else_branch = self.emptyBranch(next_failure),
                    } });
                    if (remaining != 0) self.enterBlock(next_failure);
                }
            }
            const state = try self.captureState();
            const extraction: ?PendingExtraction = if (membership.binding) |binding| .{
                .binding = binding,
                .operand = operand,
                .target_type = try intersectTypes(self.type_interner, source_members, membership.target_type, self.ctx.allocator()),
            } else null;
            return .{
                .success = .{ .block = success, .state = state, .binding = if (extraction) |pending_extraction| .{ .variant = pending_extraction } else null },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn conjunctionCondition(
            self: *Self,
            logical: @FieldType(semantic.UnresolvedBody.Condition, "conjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            var rhs = if (lhs.success) |success| blk: {
                try self.enterFlowExit(success);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .success = null, .failure = null };
            if (logical.temporary) |local| {
                if (rhs.success) |*success| {
                    self.restoreState(success.state);
                    self.unbindLocal(@backingInt(local));
                    success.state = try self.captureState();
                }
                if (rhs.failure) |*failure| {
                    self.restoreState(failure.state);
                    self.unbindLocal(@backingInt(local));
                    failure.state = try self.captureState();
                }
            }
            return .{
                .success = rhs.success,
                .failure = try self.mergeFlowExits(lhs.failure, rhs.failure),
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn disjunctionCondition(
            self: *Self,
            logical: @FieldType(semantic.UnresolvedBody.Condition, "disjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            const rhs = if (lhs.failure) |failure| blk: {
                try self.enterFlowExit(failure);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .success = null, .failure = null };
            return .{
                .success = try self.mergeFlowExits(lhs.success, rhs.success),
                .failure = rhs.failure,
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn negatedCondition(self: *Self, operand: semantic.UnresolvedBody.ConditionId) !ConditionFlow {
            const flow = try self.condition(operand);
            return .{ .success = flow.failure, .failure = flow.success, .diverged = flow.diverged };
        }

        fn enterFlowExit(self: *Self, exit: FlowExit) !void {
            self.enterBlock(exit.block);
            self.restoreState(exit.state);
            if (exit.binding) |pending| {
                const binding = pending.conditionBinding();
                var bound: Value = switch (pending) {
                    .variant => |extraction| try self.extractVariantBinding(extraction, binding.span),
                    .call => blk: {
                        if (exit.constructed) |constructed| break :blk constructed;
                        const success_block = self.blocks.items[@backingInt(exit.block)];
                        std.debug.assert(success_block.argument_end == success_block.argument_start + 1);
                        break :blk .{
                            .id = @fromBackingInt(@intCast(success_block.argument_start)),
                            .type_id = self.block_arguments.items[success_block.argument_start].type_id,
                            .owned_generation = self.block_argument_generations.items[success_block.argument_start],
                            .reference_origins = exit.reference_origins,
                        };
                    },
                };
                if (bound.type_id != .never) if (binding.annotation_type) |expected| {
                    const use = try self.coerceValue(bound.id, bound.type_id, expected) orelse
                        return self.reject(binding.span, .{ .local_type_mismatch = self.typeMismatch(expected, bound.type_id) });
                    if (use.coerce_to != null) {
                        bound = try self.coerceOwnedRepresentation(bound, use, binding.span, null);
                    }
                };
                const index = @backingInt(binding.local);
                std.debug.assert(self.local_values[index] == null);
                bound.binding_identity = try self.newBindingIdentity();
                self.local_values[index] = bound;
                self.locals.items(.mutable)[index] = false;
                self.local_availability[index] = .available;
                if (bound.type_id == .never) self.terminate(.diverge);
            }
        }

        fn extractVariantBinding(self: *Self, extraction: PendingExtraction, span: structures.SourceSpan) !Value {
            const target_type = extraction.target_type;
            const in_place = target_type != .never and try self.constructsInPlace(target_type);
            if (in_place and try self.type_interner.facts().variantMembers(target_type) != null) {
                var narrowed = extraction.operand;
                narrowed.borrowed_type = target_type;
                if (try self.nonCopyableBorrow(narrowed)) |details| return self.reject(span, .{ .type_not_copyable = details });
                return self.copyValue(extraction.operand, span, try self.localStorage(target_type));
            }
            var extracted = if (in_place) try self.projectStorage(extraction.operand, target_type, .variant) else try self.appendInstruction(.{ .variant_extract = .{
                .operand = extraction.operand.id,
                .target_type = target_type,
                .tag_mapping = try self.appendExtractionTagMapping(extraction.operand.type_id, target_type),
            } });
            if (target_type == .never) return extracted;
            if (try self.type_interner.canStoreBorrow(target_type)) {
                extracted.reference_origins = if (try self.type_interner.facts().variantMembers(target_type) != null)
                    extraction.operand.reference_origins
                else
                    try self.transformReferenceOrigins(extraction.operand.reference_origins, .{ .select = .{ .variant = target_type } });
            }
            extracted.borrowed_type = target_type;
            extracted.borrowed_generation = extraction.operand.borrowed_generation orelse extraction.operand.owned_generation;
            extracted.borrowed_cleanup_value = extraction.operand.borrowed_cleanup_value orelse extraction.operand.id;
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
            const span = self.activeLifetimeSpan();
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            if (exits.len == 0) {
                _ = try self.appendBlockArgument(.never, null);
                const block_id = try self.newBlock(argument_start, argument_start + 1);
                return .{ .block = block_id, .state = baseline, .constructed = .{ .id = @fromBackingInt(argument_start), .type_id = .never } };
            }
            for (exits) |exit| std.debug.assert(exit.binding == null);
            try self.normalizeJoinFields(exits, policy);
            const incoming = try self.ctx.allocator().alloc(?GenerationId, exits.len);
            defer self.ctx.allocator().free(incoming);
            const destination = if (mode) |request| if (request.destination) |target| target.storage else null else null;
            var result: ?Value = null;
            var borrow_argument: ?u32 = null;
            var completion_argument: ?u32 = null;
            if (mode != null) {
                var joined_type = if (destination) |storage| storage.type_id else exits[0].constructed.?.type_id;
                if (destination == null) for (exits[1..]) |exit| {
                    joined_type = try joinTypes(self.type_interner, joined_type, exit.constructed.?.type_id, self.ctx.allocator());
                };
                var joined: Value = .{ .id = if (destination) |storage| storage.id else @fromBackingInt(argument_start), .type_id = joined_type, .stable_reference_root = exits[0].constructed.?.stable_reference_root };
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
                    joined.reference_origins = try self.mergeReferenceOrigins(joined.reference_origins, value_on_edge.reference_origins);
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
                    if (destination == null and !self.type_check_only and try self.constructsInPlace(joined_type) and value_on_edge.type_id != joined_type)
                        return self.reject(span, .{ .relocation_requires_direct_move = value_on_edge.type_id });
                    if (joined.preserves_storage and value_on_edge.type_id != joined_type)
                        return self.reject(span, .{ .call_argument_type_mismatch = self.typeMismatch(joined_type, value_on_edge.type_id) });
                }
                joined.owned_generation = try self.joinResultGenerations(joined_type, span, incoming);
                joined.borrowed_generation = borrowed_generation orelse null;
                joined.borrowed_cleanup_value = borrowed_cleanup orelse null;
                if (destination == null) {
                    const argument = try self.appendBlockArgument(joined_type, joined.owned_generation);
                    self.block_arguments.items[argument].representation = if (joined.preserves_storage) .storage else .value;
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

            var state = try self.states.items[@backingInt(baseline)].clone(self.ctx.allocator());
            errdefer state.deinit(self.ctx.allocator());
            state.copyFlowFrom(self.states.items[@backingInt(exits[0].state)]);
            for (exits[1..]) |exit| state.joinFlow(self.states.items[@backingInt(exit.state)]);
            for (state.availability, self.states.items[@backingInt(baseline)].availability) |*availability, initial| {
                if (initial == .unbound) availability.* = .unbound;
            }
            var changed_slots: std.ArrayList(u32) = .empty;
            defer changed_slots.deinit(self.ctx.allocator());
            var generation_only: std.ArrayList(GenerationOnlyJoin) = .empty;
            defer generation_only.deinit(self.ctx.allocator());
            const state_argument_start: u32 = @intCast(self.block_arguments.items.len);
            for (0..state.values.len) |slot| {
                if (state.values.get(slot) == null) continue;
                if (policy == .loop and !self.locals.items(.mutable)[slot]) continue;
                var output = self.states.items[@backingInt(exits[0].state)].values.get(slot).?;
                var changed = false;
                const original_identity = output.binding_identity;
                for (exits, incoming, 0..) |exit, *generation, index| {
                    const current = self.states.items[@backingInt(exit.state)].values.get(slot).?;
                    std.debug.assert(output.type_id == current.type_id);
                    generation.* = current.owned_generation;
                    changed = changed or output.id != current.id;
                    if (index == 0) continue;
                    try self.mergeValueReferences(&output, output, current);
                    output.storage_identity = try self.joinBindingIdentities(output.storage_identity orelse output.binding_identity, current.storage_identity orelse current.binding_identity);
                    output.binding_identity = try self.joinBindingIdentities(output.binding_identity, current.binding_identity);
                }
                if (policy == .branch and !std.meta.eql(original_identity, output.binding_identity)) output.binding_identity = try self.newBindingIdentity();
                const generation = try self.joinGenerationGroup(output.type_id, span, incoming);
                if (changed) {
                    const argument = try self.appendBlockArgument(output.type_id, generation);
                    try changed_slots.append(self.ctx.allocator(), @intCast(slot));
                    output = .{ .id = @fromBackingInt(argument), .type_id = output.type_id, .owned_generation = generation, .reference_origins = output.reference_origins, .stable_reference_root = output.stable_reference_root, .binding_identity = output.binding_identity, .storage_identity = output.storage_identity };
                } else if (generation != output.owned_generation) {
                    try generation_only.append(self.ctx.allocator(), .{ .slot = @intCast(slot), .destination = generation.? });
                    output.owned_generation = generation;
                }
                try state.values.set(self.ctx.allocator(), slot, output);
            }
            const merged = try self.newBlock(argument_start, @intCast(self.block_arguments.items.len));
            for (exits) |exit| {
                const predecessor = try self.setJoinTerminator(merged, exit, if (result != null and destination == null) result.?.type_id else null, changed_slots.items, borrow_argument != null, completion_argument != null);
                if (destination != null) if (result.?.owned_generation) |generation| {
                    try self.recordGenerationOnlyForward(predecessor, 0, exit.constructed.?.owned_generation, generation);
                };
                for (generation_only.items) |join| try self.recordGenerationOnlyForward(predecessor, 0, self.states.items[@backingInt(exit.state)].values.get(join.slot).?.owned_generation, join.destination);
            }
            std.debug.assert(state_argument_start + changed_slots.items.len == self.block_arguments.items.len);
            return .{ .block = merged, .state = try self.appendState(state), .constructed = result };
        }

        fn joinBorrowedFact(comptime Fact: type, joined: *??Fact, candidate: ?Fact, include_unknown: bool) void {
            if (candidate == null and !include_unknown) return;
            if (joined.*) |previous| {
                if (previous != candidate) joined.* = @as(?Fact, null);
            } else joined.* = candidate;
        }

        fn conditional(self: *Self, expression: @FieldType(Expression.Operation, "if_else"), mode: ResultRequest) anyerror!Value {
            const baseline = try self.captureState();
            const flow = try self.condition(expression.condition);
            if (flow.success == null and flow.failure == null) {
                std.debug.assert(flow.diverged != null);
                return flow.diverged.?;
            }

            const then_exit = if (flow.success) |success| blk: {
                try self.enterFlowExit(success);
                const result = try self.blockWithResult(expression.then_block, mode);
                if (self.current_block != null) if (success.binding) |binding|
                    self.unbindLocal(@backingInt(binding.conditionBinding().local));
                break :blk try self.valueExit(result);
            } else null;
            const else_exit = if (flow.failure) |failure| blk: {
                try self.enterFlowExit(failure);
                break :blk try self.valueExit(try self.blockWithResult(expression.else_block, mode));
            } else null;

            var exits: std.ArrayList(FlowExit) = .empty;
            defer exits.deinit(self.ctx.allocator());
            if (then_exit) |exit| try exits.append(self.ctx.allocator(), exit);
            if (else_exit) |exit| try exits.append(self.ctx.allocator(), exit);
            const merged = try self.mergeExits(baseline, exits.items, mode, .branch);
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
            for (self.field_places, 0..) |place, index| {
                if (self.is_initializer_region and self.captured_locals[@backingInt(place.local)] != null) continue;
                if (!place.moves_owner) continue;
                const local_index = @backingInt(place.local);
                var transferred = false;
                var available = false;
                var all_bound = true;
                var first: ?Availability = null;
                var different = false;
                var unsupported = false;
                for (exits) |exit| {
                    const state = self.states.items[@backingInt(exit.state)];
                    all_bound = all_bound and state.availability[local_index] == .available;
                    if (state.availability[local_index] != .available) continue;
                    const field = state.field_availability[index];
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
                    if (state.availability[local_index] != .available) continue;
                    if (state.field_availability[index] == .available) exit.* = try self.endFieldBeforeJoin(exit.*, place);
                }
            }
        }

        fn endFieldBeforeJoin(self: *Self, exit: anytype, place: FieldPlace) !@TypeOf(exit) {
            const span = self.activeLifetimeSpan();
            self.enterPendingBlock(exit.block);
            self.restoreState(exit.state);
            const boundary = try self.newBoundary(span);
            const previous_boundary = self.current_boundary;
            self.current_boundary = boundary;
            defer self.current_boundary = previous_boundary;
            try self.endField(place, span);
            try self.appendBoundary(boundary);
            var result = exit;
            result.state = try self.captureState();
            result.block = self.suspendBlock();
            return result;
        }

        fn endField(self: *Self, place: FieldPlace, span: structures.SourceSpan) !void {
            const field_type = self.local_values[@backingInt(place.local)].?.type_id;
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            try self.resolvePlaceFields(field_type, place.fields, span, &fields);
            const capabilities = (try self.type_interner.facts().ownershipCapabilities(fields.last().?.type_id)) orelse return error.Unavailable;
            if (capabilities.requires_explicit_drop) return self.reject(span, .explicit_drop_field_cannot_be_implicitly_ended);
            const field = try self.transferFieldPlace(place.local, fields.items, span, .consume);
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
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            const edge = try self.newBlock(argument_start, argument_start);
            self.terminate(.{ .branch = self.emptyBranch(edge) });
            self.enterBlock(edge);
            const borrowed_on_path = if (include_borrow_condition) exit.constructed.?.borrow_condition orelse (try self.appendInstruction(.{
                .const_bool = hasNonowningPath(exit.constructed.?),
            })).id else null;
            var completion: ?structures.FunctionValueId = null;
            if (include_consumption_completion) {
                if (exit.constructed.?.consumption_completion) |selected| {
                    completion = selected;
                } else {
                    const flag = try self.localStorage(.bool);
                    const completed = try self.appendInstruction(.{ .const_bool = true });
                    _ = try self.copyBits(completed, flag);
                    completion = flag.id;
                }
            }
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
            try self.blocks.items[@backingInt(self.current_block.?)].items.append(self.ctx.allocator(), .{
                .instruction = .{
                    .id = instruction_id,
                    .operation = instruction,
                    .span = if (self.publish_instruction_spans)
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
            try self.block_arguments.ensureUnusedCapacity(self.ctx.allocator(), 1);
            try self.block_argument_generations.ensureUnusedCapacity(self.ctx.allocator(), 1);
            const index: u32 = @intCast(self.block_arguments.items.len);
            self.block_arguments.appendAssumeCapacity(.{ .type_id = type_id });
            self.block_argument_generations.appendAssumeCapacity(generation);
            return index;
        }

        fn appendBranchArgument(self: *Self, value_use: structures.FunctionValueUse, generation: ?GenerationId) !void {
            std.debug.assert(self.branch_arguments.items.len == self.branch_argument_generations.items.len);
            try self.branch_arguments.ensureUnusedCapacity(self.ctx.allocator(), 1);
            try self.branch_argument_generations.ensureUnusedCapacity(self.ctx.allocator(), 1);
            self.branch_arguments.appendAssumeCapacity(value_use);
            self.branch_argument_generations.appendAssumeCapacity(generation);
        }

        fn finishOwnershipMetadata(self: *Self) !void {
            std.debug.assert(self.ownership_forwards.items.len == 0);
            std.debug.assert(self.ownership_edges.items.len == 0);
            std.sort.block(OwnershipForwardHint, self.ownership_forward_hints.items, {}, ownershipHintLessThan);
            const start_orders = try self.ctx.allocator().alloc(bool, self.next_generation_start_order);
            defer self.ctx.allocator().free(start_orders);
            @memset(start_orders, false);
            for (self.generations.items) |generation| {
                std.debug.assert(generation.start_order < start_orders.len);
                std.debug.assert(!start_orders[generation.start_order]);
                start_orders[generation.start_order] = true;
            }
            for (self.boundaries.items) |boundary| {
                for (boundary.effects.items) |effect| self.validateEffect(effect);
            }
            for (self.blocks.items, 0..) |block_value, block_index| {
                for (block_value.terminator_effects.items) |effect| self.validateEffect(effect);
                const predecessor: structures.FunctionBlockId = @fromBackingInt(@intCast(block_index));
                switch (block_value.terminator orelse unreachable) {
                    .branch => |branch| try self.appendOwnershipBranch(predecessor, 0, branch),
                    .predicate_branch => |branch| {
                        try self.appendOwnershipBranch(predecessor, 0, branch.then_branch);
                        try self.appendOwnershipBranch(predecessor, 1, branch.else_branch);
                    },
                    .fallible_call => |call| {
                        var terminator: structures.FunctionTerminator = .{ .fallible_call = call };
                        for (terminator.successors(), 0..) |target, ordinal| {
                            if (target) |successor| try self.appendProducedOwnershipEdge(predecessor, @intCast(ordinal), successor.*);
                        }
                    },
                    .return_unit, .return_value, .return_failure, .diverge => {},
                }
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
            try self.validateGenerationOrigins();
        }

        fn analyzeLifetimes(self: *Self, measurements: ?*BodyMeasurements) !void {
            var solver = try LifetimeSolver.init(
                self.ctx.allocator(),
                self.generations.items,
                self.boundaries.items,
                self.blocks.items,
                self.block_argument_generations.items,
                self.ownership_forwards.items,
                self.ownership_edges.items,
                @fromBackingInt(@intCast(0)),
            );
            defer solver.deinit();
            if (measurements) |result| {
                result.lifetime_table_bytes = 2 * std.mem.sliceAsBytes(solver.representations_in).len +
                    4 * std.mem.sliceAsBytes(solver.available_in).len;
            }
            try solver.solve(&self.planned_cleanups, &self.explicit_abandonments);
        }

        fn emitExplicitAbandonmentDiagnostics(self: *Self) !bool {
            if (self.explicit_abandonments.items.len == 0) return false;
            const abandonment = self.explicit_abandonments.items[0];
            const generation = self.generations.items[@backingInt(abandonment.generation)];
            try emitSemanticIssue(self.ctx, self.file_id, .{
                .span = generation.span,
                .kind = .{ .value_requires_explicit_drop = generation.type_id },
            });
            return true;
        }

        fn materializeCleanups(self: *Self, cleanups: []const PlannedCleanup) !void {
            std.debug.assert(self.current_block == null);
            const LocationTag = std.meta.Tag(CleanupLocation);
            inline for ([_]LocationTag{ .edge, .boundary, .block_entry }) |location_tag| {
                var cleanup_start: usize = 0;
                while (cleanup_start < cleanups.len) {
                    var cleanup_end = cleanup_start + 1;
                    while (cleanup_end < cleanups.len and std.meta.eql(cleanups[cleanup_start].location, cleanups[cleanup_end].location)) {
                        cleanup_end += 1;
                    }
                    const location_cleanups = cleanups[cleanup_start..cleanup_end];
                    if (std.meta.activeTag(location_cleanups[0].location) == location_tag) switch (location_cleanups[0].location) {
                        .boundary => |boundary| {
                            const location = self.findBoundary(boundary);
                            try self.materializeBlockCleanups(location.block, location.item_index + 1, location_cleanups);
                        },
                        .edge => |location| try self.materializeEdgeCleanups(location.predecessor, location.successor_ordinal, location_cleanups),
                        .block_entry => |block_id| try self.materializeBlockCleanups(block_id, 0, location_cleanups),
                    };
                    cleanup_start = cleanup_end;
                }
            }
        }

        fn materializeBlockCleanups(
            self: *Self,
            block_id: structures.FunctionBlockId,
            suffix_item_start: usize,
            cleanups: []const PlannedCleanup,
        ) !void {
            const suffix = try self.splitCompletedBlock(block_id, suffix_item_start);
            self.resumeBlock(block_id);
            try self.emitCleanupGroup(cleanups);
            self.terminate(.{ .branch = self.emptyBranch(suffix) });
            self.assignBlockLayout(suffix);
        }

        fn materializeEdgeCleanups(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            cleanups: []const PlannedCleanup,
        ) !void {
            const target = self.edgeTarget(predecessor, successor_ordinal);
            const pass_through = try self.newPassThroughBlock(target);
            self.retargetEdge(predecessor, successor_ordinal, pass_through.block);
            self.enterBlock(pass_through.block);
            try self.emitCleanupGroup(cleanups);
            self.terminate(.{ .branch = pass_through.branch });
        }

        fn emitCleanupGroup(self: *Self, cleanups: []const PlannedCleanup) !void {
            for (cleanups) |cleanup| try self.emitConditionalCleanup(cleanup);
        }

        fn emitConditionalCleanup(self: *Self, cleanup: PlannedCleanup) !void {
            const cleanup_condition = cleanup.cleanup_condition orelse return self.emitDropCleanup(cleanup);
            const argument_index: u32 = @intCast(self.block_arguments.items.len);
            const borrowed = try self.newBlock(argument_index, argument_index);
            const owned = try self.newBlock(argument_index, argument_index);
            const join = try self.newBlock(argument_index, argument_index);
            const expected = try self.appendInstruction(.{ .const_bool = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = cleanup_condition, .rhs = expected.id },
                .then_branch = self.emptyBranch(borrowed),
                .else_branch = self.emptyBranch(owned),
            } });
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
                    const argument_start: u32 = @intCast(self.block_arguments.items.len);
                    const retained = try self.newBlock(argument_start, argument_start);
                    self.terminate(.{ .predicate_branch = .{ .operation = .eqb, .operands = .{ .lhs = ancestor_predicate, .rhs = expected.id }, .then_branch = self.emptyBranch(join), .else_branch = self.emptyBranch(retained) } });
                    self.enterBlock(retained);
                }
            }
            try self.emitDropCleanup(cleanup);
            self.terminate(.{ .branch = self.emptyBranch(join) });
            self.enterBlock(join);
        }

        fn emitDropCleanup(self: *Self, cleanup: PlannedCleanup) !void {
            const generation = self.generations.items[@backingInt(cleanup.generation)];
            const value_to_drop: Value = .{
                .id = cleanup.cleanup_value,
                .type_id = generation.type_id,
                .reference_origins = self.cleanup_origins.get(cleanup.cleanup_value),
            };
            if (generation.cleanup_fields or generation.missing_fields.len != 0)
                try self.dropValueExcluding(value_to_drop, generation.missing_fields, false, generation.span)
            else
                try self.dropValue(value_to_drop, false, generation.span);
        }

        fn dropValueExcluding(self: *Self, value_to_drop: Value, missing: []const []const u32, can_deinit: bool, span: structures.SourceSpan) !void {
            const definition = (try self.type_interner.structDefinition(value_to_drop.type_id)) orelse unreachable;
            var field_index = definition.fields.len;
            while (field_index > 0) {
                field_index -= 1;
                var nested: std.ArrayList([]const u32) = .empty;
                defer nested.deinit(self.ctx.allocator());
                var absent = false;
                for (missing) |path| {
                    std.debug.assert(path.len != 0 and path[0] < definition.fields.len);
                    if (path[0] != field_index) continue;
                    if (path.len == 1) {
                        absent = true;
                        break;
                    }
                    try nested.append(self.ctx.allocator(), path[1..]);
                }
                if (absent) continue;
                const field = definition.fields[field_index];
                var child = try self.projectStorage(value_to_drop, field.type_id, .{ .field = @intCast(field_index) });
                child.reference_origins = try self.transformReferenceOrigins(value_to_drop.reference_origins, .{ .select = .{ .field = @intCast(field_index) } });
                if (nested.items.len != 0)
                    try self.dropValueExcluding(child, nested.items, can_deinit, span)
                else
                    try self.dropValue(child, can_deinit, span);
            }
        }

        const BoundaryLocation = struct {
            block: structures.FunctionBlockId,
            item_index: usize,
        };

        fn findBoundary(self: *const Self, boundary: BoundaryId) BoundaryLocation {
            var result: ?BoundaryLocation = null;
            for (self.blocks.items, 0..) |block_value, block_index| {
                for (block_value.items.items, 0..) |item, item_index| switch (item) {
                    .instruction => {},
                    .boundary => |candidate| if (candidate == boundary) {
                        std.debug.assert(result == null);
                        result = .{ .block = @fromBackingInt(@intCast(block_index)), .item_index = item_index };
                    },
                };
            }
            return result orelse unreachable;
        }

        fn splitCompletedBlock(self: *Self, block_id: structures.FunctionBlockId, suffix_item_start: usize) !structures.FunctionBlockId {
            const block_index = @backingInt(block_id);
            const original = self.blocks.items[block_index];
            std.debug.assert(original.layout_index != null);
            std.debug.assert(original.terminator != null);
            std.debug.assert(suffix_item_start <= original.items.items.len);
            const argument_index: u32 = @intCast(self.block_arguments.items.len);
            const suffix = try self.newBlock(argument_index, argument_index);
            const suffix_index = @backingInt(suffix);
            try self.blocks.items[suffix_index].items.appendSlice(
                self.ctx.allocator(),
                self.blocks.items[block_index].items.items[suffix_item_start..],
            );
            try self.blocks.items[suffix_index].terminator_effects.appendSlice(
                self.ctx.allocator(),
                self.blocks.items[block_index].terminator_effects.items,
            );
            self.blocks.items[suffix_index].terminator = self.blocks.items[block_index].terminator;
            self.blocks.items[suffix_index].terminator_span = self.blocks.items[block_index].terminator_span;
            self.blocks.items[block_index].items.shrinkRetainingCapacity(suffix_item_start);
            self.blocks.items[block_index].terminator_effects.clearRetainingCapacity();
            self.blocks.items[block_index].terminator = null;
            self.blocks.items[block_index].terminator_span = null;
            self.relocateReferenceUses(.{ .terminator = .{ .id = block_id, .effect_index = 0 } }, .{ .terminator = .{ .id = suffix, .effect_index = 0 } });
            return suffix;
        }

        fn relocateReferenceUses(self: *Self, from: PendingReferenceUseLocation, to: PendingReferenceUseLocation) void {
            for (self.reference_uses.items) |*use| use.location = relocatedReferenceUseLocation(use.location, from, to);
            for (self.pending_reference_uses.items) |*use| use.location = relocatedReferenceUseLocation(use.location, from, to);
        }

        fn relocatedReferenceUseLocation(location: PendingReferenceUseLocation, from: PendingReferenceUseLocation, to: PendingReferenceUseLocation) PendingReferenceUseLocation {
            var relative_index: usize = undefined;
            switch (from) {
                .boundary => |source| {
                    if (location != .boundary or location.boundary.id != source.id) return location;
                    relative_index = location.boundary.effect_index - source.effect_index;
                },
                .terminator => |source| {
                    if (location != .terminator or location.terminator.id != source.id) return location;
                    relative_index = location.terminator.effect_index - source.effect_index;
                },
            }
            var destination = to;
            switch (destination) {
                .boundary => |*target| target.effect_index += relative_index,
                .terminator => |*target| target.effect_index += relative_index,
            }
            return destination;
        }

        fn validateCleanupReferenceUses(self: *Self) !void {
            if (self.drop_effects.count() == 0 or self.reference_uses.items.len == 0) return;
            var edges: std.ArrayList(control_flow.Edge) = .empty;
            defer edges.deinit(self.ctx.allocator());
            for (self.blocks.items, 0..) |block_value, predecessor| {
                var terminator = block_value.terminator orelse unreachable;
                for (terminator.successors(), 0..) |target, ordinal| if (target) |successor| {
                    try edges.append(self.ctx.allocator(), .{ .predecessor = @fromBackingInt(@intCast(predecessor)), .successor = successor.*, .successor_ordinal = @intCast(ordinal) });
                };
            }
            const graph = try control_flow.Index.init(self.ctx.allocator(), self.blocks.items.len, edges.items);
            defer graph.deinit(self.ctx.allocator());
            for (self.reference_uses.items) |use| {
                var incomplete = false;
                var origins = try self.resolveReferenceOrigins(use.origins, &incomplete);
                std.debug.assert(!incomplete);
                while (origins) |index| {
                    const origin = self.reference_origins.items[index];
                    origins = origin.next;
                    if (origin.read == null) continue;
                    if (try self.referenceCrossesDrop(origin, use.location, graph, edges.items)) return self.reject(use.span, if (origin.deferred_capture) .initializer_capture_conflict else .borrow_outlives_source);
                }
            }
        }

        fn dropAffectsOrigin(self: *Self, instruction: u31, source: ReferenceOrigin) !bool {
            const effects = self.drop_effects.get(instruction) orelse return false;
            const affected = if (source.deferred_capture) effects.writes else effects.storage_invalidations;
            var incomplete = false;
            var origins = try self.resolveReferenceOrigins(affected, &incomplete);
            std.debug.assert(!incomplete);
            while (origins) |index| {
                const origin = self.reference_origins.items[index];
                if (source.root != null and source.root == origin.root) return true;
                if (source.generation != null and source.generation == origin.generation) return true;
                if (source.parameter != null and source.parameter == origin.parameter) return true;
                if (source.deferred_capture and origin.parameter != null and source.root == null and source.generation == null) {
                    if (source.parameter) |parameter| {
                        std.debug.assert(parameter < self.parameter_modes.items.len);
                        if (self.parameter_modes.items[parameter] == .imm and
                            try self.captureMayShareStorage(self.block_arguments.items[parameter].type_id)) return true;
                    }
                }
                origins = origin.next;
            }
            return false;
        }

        fn referenceCrossesDrop(self: *Self, origin: ReferenceOrigin, use: PendingReferenceUseLocation, graph: control_flow.Index, edges: []const control_flow.Edge) !bool {
            const Cursor = struct { block: structures.FunctionBlockId, end: usize, invalidated: bool = false };
            const start: Cursor = switch (use) {
                .boundary => |location| blk: {
                    const boundary = self.findBoundary(location.id);
                    break :blk .{ .block = boundary.block, .end = boundary.item_index };
                },
                .terminator => |location| .{ .block = location.id, .end = self.blocks.items[@backingInt(location.id)].items.items.len },
            };
            var worklist: std.ArrayList(Cursor) = .empty;
            defer worklist.deinit(self.ctx.allocator());
            try worklist.append(self.ctx.allocator(), start);
            const visited = try self.ctx.allocator().alloc([2]bool, self.blocks.items.len);
            defer self.ctx.allocator().free(visited);
            @memset(visited, .{ false, false });
            while (worklist.pop()) |cursor| {
                const block_index = @backingInt(cursor.block);
                const block_value = self.blocks.items[block_index];
                if (cursor.end == block_value.items.items.len) {
                    if (visited[block_index][@intFromBool(cursor.invalidated)]) continue;
                    visited[block_index][@intFromBool(cursor.invalidated)] = true;
                }
                var invalidated = cursor.invalidated;
                var item_index = cursor.end;
                var reached_read = false;
                while (item_index > 0) {
                    item_index -= 1;
                    const item = block_value.items.items[item_index];
                    if (item != .instruction) continue;
                    if (item.instruction.id == origin.read.?) {
                        if (invalidated) return true;
                        reached_read = true;
                        break;
                    }
                    invalidated = invalidated or try self.dropAffectsOrigin(item.instruction.id, origin);
                }
                if (reached_read) continue;
                var incoming = graph.blocks[block_index].first_incoming;
                while (incoming) |edge| : (incoming = graph.previous_incoming[edge]) {
                    const predecessor = edges[edge].predecessor;
                    try worklist.append(self.ctx.allocator(), .{ .block = predecessor, .end = self.blocks.items[@backingInt(predecessor)].items.items.len, .invalidated = invalidated });
                }
            }
            return false;
        }

        const PassThroughBlock = struct {
            block: structures.FunctionBlockId,
            branch: structures.FunctionBranch,
        };

        fn newPassThroughBlock(self: *Self, target: structures.FunctionBlockId) !PassThroughBlock {
            const target_block = self.blocks.items[@backingInt(target)];
            const argument_start: u32 = @intCast(self.block_arguments.items.len);
            for (target_block.argument_start..target_block.argument_end) |target_argument| {
                const argument = try self.appendBlockArgument(
                    self.block_arguments.items[target_argument].type_id,
                    self.block_argument_generations.items[target_argument],
                );
                self.block_arguments.items[argument].representation = self.block_arguments.items[target_argument].representation;
            }
            const argument_end: u32 = @intCast(self.block_arguments.items.len);
            const pass_through_block = try self.newBlock(argument_start, argument_end);
            const branch_start: u32 = @intCast(self.branch_arguments.items.len);
            for (argument_start..argument_end) |argument| {
                try self.appendBranchArgument(
                    .{ .value = @fromBackingInt(@intCast(argument)) },
                    self.block_argument_generations.items[argument],
                );
            }
            return .{
                .block = pass_through_block,
                .branch = .{
                    .target = target,
                    .arguments = .{ .start = branch_start, .end = @intCast(self.branch_arguments.items.len) },
                },
            };
        }

        fn edgeTarget(self: *const Self, predecessor: structures.FunctionBlockId, successor_ordinal: u2) structures.FunctionBlockId {
            var terminator = self.blocks.items[@backingInt(predecessor)].terminator orelse unreachable;
            return (terminator.successors()[successor_ordinal] orelse unreachable).*;
        }

        fn retargetEdge(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            target: structures.FunctionBlockId,
        ) void {
            const terminator = &self.blocks.items[@backingInt(predecessor)].terminator.?;
            (terminator.successors()[successor_ordinal] orelse unreachable).* = target;
        }

        fn validateGenerationOrigins(self: *Self) !void {
            const origins = try self.ctx.allocator().alloc(GenerationOrigin, self.generations.items.len);
            defer self.ctx.allocator().free(origins);
            @memset(origins, .none);
            for (self.boundaries.items) |boundary| {
                for (boundary.effects.items) |effect| switch (effect) {
                    .define => |definition| markGenerationOrigin(origins, definition.generation, .define),
                    else => {},
                };
            }
            for (self.blocks.items) |block_value| {
                for (block_value.terminator_effects.items) |effect| switch (effect) {
                    .define => |definition| markGenerationOrigin(origins, definition.generation, .define),
                    else => {},
                };
            }
            for (self.ownership_forwards.items) |mapping| switch (mapping) {
                .produce => |generation| markGenerationOrigin(origins, generation, .produce),
                .forward => |forward| {
                    const origin = &origins[@backingInt(forward.destination)];
                    if (origin.* == .none) origin.* = .phi else std.debug.assert(origin.* == .phi);
                },
                .unowned => {},
            };
            for (origins) |origin| std.debug.assert(origin != .none);
        }

        fn markGenerationOrigin(origins: []GenerationOrigin, generation: GenerationId, origin: GenerationOrigin) void {
            const existing = &origins[@backingInt(generation)];
            std.debug.assert(existing.* == .none);
            existing.* = origin;
        }

        fn validateEffect(self: *const Self, effect: LifetimeEffect) void {
            const generation = switch (effect) {
                .define => |definition| definition.generation,
                .use => |use| use.generation,
                .update => |update| update.generation,
                .consume => |consumed| consumed,
            };
            std.debug.assert(@backingInt(generation) < self.generations.items.len);
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
                if (self.branch_argument_generations.items[source_index]) |source| {
                    if (source == destination) continue;
                    try self.ownership_forwards.append(self.ctx.allocator(), .{ .forward = .{
                        .source = source,
                        .destination = destination,
                    } });
                } else {
                    try self.ownership_forwards.append(self.ctx.allocator(), .{ .unowned = destination });
                }
            }
            for (self.ownershipHints(predecessor, successor_ordinal)) |hint| {
                if (hint.source) |source| {
                    try self.ownership_forwards.append(self.ctx.allocator(), .{ .forward = .{
                        .source = source,
                        .destination = hint.destination,
                    } });
                } else {
                    try self.ownership_forwards.append(self.ctx.allocator(), .{ .unowned = hint.destination });
                }
            }
            try self.ownership_edges.append(self.ctx.allocator(), .{
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
            try self.ownership_forward_hints.append(self.ctx.allocator(), .{
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
            const key = ownershipEdgeKey(predecessor, ordinal);
            var start: usize = 0;
            var end = hints.len;
            while (start < end) {
                const middle = start + (end - start) / 2;
                if (ownershipEdgeKey(hints[middle].predecessor, hints[middle].successor_ordinal) < key) {
                    start = middle + 1;
                } else end = middle;
            }
            end = start;
            while (end < hints.len and ownershipEdgeKey(hints[end].predecessor, hints[end].successor_ordinal) == key) : (end += 1) {}
            return hints[start..end];
        }

        fn appendProducedOwnershipEdge(
            self: *Self,
            predecessor: structures.FunctionBlockId,
            successor_ordinal: u2,
            target_id: structures.FunctionBlockId,
        ) !void {
            const mapping_start: u32 = @intCast(self.ownership_forwards.items.len);
            const target = self.blocks.items[@backingInt(target_id)];
            for (target.argument_start..target.argument_end) |argument| {
                const generation = self.block_argument_generations.items[argument] orelse continue;
                try self.ownership_forwards.append(self.ctx.allocator(), .{ .produce = generation });
            }
            try self.ownership_edges.append(self.ctx.allocator(), .{
                .predecessor = predecessor,
                .successor_ordinal = successor_ordinal,
                .successor = target_id,
                .mappings = .{ .start = mapping_start, .end = @intCast(self.ownership_forwards.items.len) },
            });
        }

        fn newBoundary(self: *Self, span: structures.SourceSpan) !BoundaryId {
            const id: BoundaryId = @fromBackingInt(@intCast(self.boundaries.items.len));
            try self.boundaries.append(self.ctx.allocator(), .{ .span = span });
            return id;
        }

        fn appendBoundary(self: *Self, boundary: BoundaryId) !void {
            std.debug.assert(self.current_block != null);
            try self.blocks.items[@backingInt(self.current_block.?)].items.append(self.ctx.allocator(), .{ .boundary = boundary });
        }

        fn newBlock(self: *Self, argument_start: u32, argument_end: u32) !structures.FunctionBlockId {
            std.debug.assert(self.block_arguments.items.len == self.block_argument_generations.items.len);
            const id: structures.FunctionBlockId = @fromBackingInt(@intCast(self.blocks.items.len));
            try self.blocks.append(self.ctx.allocator(), .{
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
            block_value.terminator_span = if (self.publish_instruction_spans)
                self.activeLifetimeSpan()
            else
                .{ .start = 0, .end = 0 };
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
        }

        fn finish(self: *Self) !structures.FunctionBodyAnalysis {
            std.debug.assert(self.current_block == null);
            std.debug.assert(self.block_arguments.items.len == self.block_argument_generations.items.len);
            std.debug.assert(self.branch_arguments.items.len == self.branch_argument_generations.items.len);
            const gpa = self.ctx.allocator();
            const argument_count: u32 = @intCast(std.math.cast(u31, self.block_arguments.items.len) orelse return error.AnalysisTooLarge);
            const instruction_values = try gpa.alloc(structures.FunctionValueId, self.instruction_count);
            defer gpa.free(instruction_values);
            const block_layout = try gpa.alloc(structures.FunctionBlockId, self.blocks.items.len);
            defer gpa.free(block_layout);
            std.debug.assert(self.block_layout_count == self.blocks.items.len);
            for (self.blocks.items, 0..) |block_value, block_index| {
                const layout_index = block_value.layout_index orelse unreachable;
                block_layout[layout_index] = @fromBackingInt(@intCast(block_index));
            }
            const instructions = try gpa.alloc(structures.FunctionInstruction, self.instruction_count);
            errdefer gpa.free(instructions);
            const instruction_spans = try gpa.alloc(
                structures.SourceSpan,
                if (self.publish_instruction_spans) self.instruction_count else 0,
            );
            errdefer gpa.free(instruction_spans);
            const terminator_spans = try gpa.alloc(
                structures.SourceSpan,
                if (self.publish_instruction_spans) self.blocks.items.len else 0,
            );
            errdefer gpa.free(terminator_spans);
            const blocks = try gpa.alloc(structures.FunctionBlock, self.blocks.items.len);
            errdefer gpa.free(blocks);
            var instruction_index: u32 = 0;
            for (block_layout) |block_id| {
                const block_index = @backingInt(block_id);
                const build_block = self.blocks.items[block_index];
                const instruction_start = instruction_index;
                for (build_block.items.items) |item| switch (item) {
                    .instruction => |build_instruction| {
                        instructions[instruction_index] = build_instruction.operation;
                        if (self.publish_instruction_spans) instruction_spans[instruction_index] = build_instruction.span;
                        instruction_values[build_instruction.id] = @fromBackingInt(@intCast(argument_count + instruction_index));
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
                if (self.publish_instruction_spans) terminator_spans[block_index] = build_block.terminator_span orelse unreachable;
            }
            std.debug.assert(instruction_index == self.instruction_count);
            const block_arguments = try self.block_arguments.toOwnedSlice(gpa);
            errdefer gpa.free(block_arguments);
            const parameter_modes = try self.parameter_modes.toOwnedSlice(gpa);
            errdefer gpa.free(parameter_modes);
            const variant_coercion_tags = try self.variant_coercion_tags.toOwnedSlice(gpa);
            errdefer gpa.free(variant_coercion_tags);
            const struct_field_values = try self.struct_field_values.toOwnedSlice(gpa);
            errdefer gpa.free(struct_field_values);
            const borrow_fields = try self.borrow_fields.toOwnedSlice(gpa);
            errdefer gpa.free(borrow_fields);
            const call_arguments = try self.call_arguments.toOwnedSlice(gpa);
            errdefer gpa.free(call_arguments);
            const initializer_regions = try self.initializer_regions.toOwnedSlice(gpa);
            errdefer {
                for (initializer_regions) |*region| region.deinit(gpa);
                gpa.free(initializer_regions);
            }
            const initializer_captures = try self.initializer_captures.toOwnedSlice(gpa);
            errdefer gpa.free(initializer_captures);
            const branches = try self.branch_arguments.toOwnedSlice(gpa);
            const body: structures.FunctionBodyAnalysis = .{
                .return_type = self.return_type,
                .is_fallible = self.is_fallible or self.consuming_converter,
                .is_initializer_region = self.is_initializer_region,
                .initializer_regions = initializer_regions,
                .initializer_captures = initializer_captures,
                .parameter_modes = parameter_modes,
                .block_arguments = block_arguments,
                .variant_coercion_tags = variant_coercion_tags,
                .struct_field_values = struct_field_values,
                .borrow_fields = borrow_fields,
                .call_arguments = call_arguments,
                .branch_arguments = branches,
                .instructions = instructions,
                .instruction_spans = instruction_spans,
                .terminator_spans = terminator_spans,
                .blocks = blocks,
                .entry = @fromBackingInt(@intCast(0)),
            };
            body.visitValueReferences(instruction_values, normalizeValueReference);
            return body;
        }
    };
}

/// Only actual reads capture caller storage. Preparing unused captures would
/// otherwise extend unrelated lifetimes and change observable drop ordering.
fn pruneInitializerCaptures(body: *structures.FunctionBodyAnalysis, gpa: std.mem.Allocator) ![]u32 {
    const entry = &body.blocks[@backingInt(body.entry)];
    std.debug.assert(entry.argument_start == 0);
    const capture_count = entry.argument_end;
    const used = try gpa.alloc(bool, body.valueCount());
    defer gpa.free(used);
    @memset(used, false);
    body.visitValueReferences(used, markValueUsed);
    for (body.instructions) |instruction| if (instruction == .mut_parameter_write) {
        used[instruction.mut_parameter_write.parameter_index] = true;
    };
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(gpa);
    for (used[0..capture_count], 0..) |is_used, index| if (is_used) {
        try kept.append(gpa, @intCast(index));
    };
    const removed: u32 = capture_count - @as(u32, @intCast(kept.items.len));
    const arguments = try gpa.alloc(structures.FunctionBlockArgument, body.block_arguments.len - removed);
    errdefer gpa.free(arguments);
    const modes = try gpa.alloc(structures.ParameterMode, kept.items.len);
    errdefer gpa.free(modes);
    const remap = try gpa.alloc(structures.FunctionValueId, body.valueCount());
    defer gpa.free(remap);
    const kept_captures = try kept.toOwnedSlice(gpa);
    @memset(remap, @fromBackingInt(@intCast(std.math.maxInt(u32))));
    for (kept_captures, 0..) |old, index| {
        arguments[index] = body.block_arguments[old];
        modes[index] = body.parameter_modes[old];
        remap[old] = @fromBackingInt(@intCast(index));
    }
    @memcpy(arguments[kept_captures.len..], body.block_arguments[capture_count..]);
    for (capture_count..remap.len) |index| remap[index] = @fromBackingInt(@intCast(index - removed));
    body.visitValueReferences(remap, remapValueReference);
    for (body.instructions) |*instruction| if (instruction.* == .mut_parameter_write) {
        const write = &instruction.mut_parameter_write;
        write.parameter_index = @backingInt(remap[write.parameter_index]);
    };
    for (body.blocks, 0..) |*block, index| {
        if (index != @backingInt(body.entry)) block.argument_start -= removed;
        block.argument_end -= removed;
    }
    gpa.free(body.block_arguments);
    gpa.free(body.parameter_modes);
    body.block_arguments = arguments;
    body.parameter_modes = modes;
    return kept_captures;
}

fn markValueUsed(used: []bool, value: *structures.FunctionValueId) void {
    used[@backingInt(value.*)] = true;
}

fn remapValueReference(mapping: []const structures.FunctionValueId, value: *structures.FunctionValueId) void {
    value.* = mapping[@backingInt(value.*)];
}

fn normalizeValueReference(mapping: []const structures.FunctionValueId, value: *structures.FunctionValueId) void {
    const instruction_mask: u32 = 1 << 31;
    const raw = @backingInt(value.*);
    if (raw & instruction_mask != 0) value.* = mapping[raw & ~instruction_mask];
}

fn intersectTypes(
    type_interner: anytype,
    source_members: []const structures.TypeId,
    target_type: structures.TypeId,
    gpa: std.mem.Allocator,
) !structures.TypeId {
    const target_members = try type_interner.facts().variantMembers(target_type);
    var intersection: std.ArrayList(structures.TypeId) = .empty;
    defer intersection.deinit(gpa);
    for (source_members) |member| {
        if (includesType(target_type, target_members, member)) try intersection.append(gpa, member);
    }
    return switch (intersection.items.len) {
        0 => .never,
        1 => intersection.items[0],
        else => switch (try type_interner.facts().internVariant(intersection.items)) {
            .type_id => |type_id| type_id,
            .duplicate => unreachable,
        },
    };
}

fn includesType(container: structures.TypeId, members: ?[]const structures.TypeId, member: structures.TypeId) bool {
    return if (members) |variant_members| containsType(variant_members, member) else container == member;
}

fn joinTypes(type_interner: anytype, left: structures.TypeId, right: structures.TypeId, gpa: std.mem.Allocator) !structures.TypeId {
    if (left == .never) return right;
    if (right == .never) return left;
    if (left == right) return left;
    if (try semantic.canWidenTo(type_interner, left, right)) return right;
    if (try semantic.canWidenTo(type_interner, right, left)) return left;

    const left_members = (try type_interner.facts().variantMembers(left)) orelse &.{left};
    const right_members = (try type_interner.facts().variantMembers(right)) orelse &.{right};
    var members: std.ArrayList(structures.TypeId) = .empty;
    defer members.deinit(gpa);
    try members.appendSlice(gpa, left_members);
    // Shared members are one inferred alternative, not duplicate source syntax.
    for (right_members) |member| {
        if (!containsType(left_members, member)) try members.append(gpa, member);
    }
    return switch (try type_interner.facts().internVariant(members.items)) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
}

fn containsType(types: []const structures.TypeId, needle: structures.TypeId) bool {
    for (types) |type_id| {
        if (type_id == needle) return true;
    }
    return false;
}

const TestMaterializerContext = struct {
    gpa: std.mem.Allocator,

    fn allocator(self: *@This()) std.mem.Allocator {
        return self.gpa;
    }

    fn emit(_: *@This(), comptime Accumulator: type, _: Accumulator) !void {
        unreachable;
    }
};

const TestMaterializerTypes = struct {
    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn arrayType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
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

    pub fn boxElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn allocationElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn canStoreBorrow(_: @This(), _: structures.TypeId) !bool {
        return false;
    }

    const custom_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(0)));
    const variant_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(1)));
    const second_custom_type = structures.TypeId.fromInterned(@fromBackingInt(@intCast(2)));
    const custom_drop_hook: structures.ItemId = @fromBackingInt(@intCast(1));
    const second_custom_drop_hook: structures.ItemId = @fromBackingInt(@intCast(2));
    const span: structures.SourceSpan = .{ .start = 0, .end = 0 };
    const variant_members = [_]structures.TypeId{ custom_type, .int };

    fn ownershipCapabilities(_: @This(), type_id: structures.TypeId) !?structures.OwnershipCapabilities {
        if (type_id == custom_type or type_id == second_custom_type or type_id == variant_type) return .{
            .move = .none,
            .copy = .none,
            .drop = if (type_id == variant_type) .fieldwise else .custom,
            .needs_automatic_drop = true,
        };
        return .{ .move = .trivial, .copy = .trivial, .drop = .trivial };
    }

    fn structDefinition(_: @This(), type_id: structures.TypeId) !?structures.StructDefinition {
        if (type_id != custom_type and type_id != second_custom_type) return null;
        return .{
            .fields = &.{},
            .ownership = .{ .drop = .{
                .capability = .custom,
                .hook = .{ .item = if (type_id == custom_type) custom_drop_hook else second_custom_drop_hook },
                .span = span,
            } },
        };
    }

    pub fn variantMembers(_: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
        return if (type_id == variant_type) &variant_members else null;
    }

    pub fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }
};

const TestMaterializerBuilder = BodyBuilder(*TestMaterializerContext, TestMaterializerTypes);

fn testInitMaterializerBuilder(context: *TestMaterializerContext) TestMaterializerBuilder {
    return .{
        .ctx = context,
        .type_interner = .{},
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
            .call_arguments = &.{},
            .method_call_arguments = &.{},
            .struct_field_values = &.{},
            .assignment_fields = &.{},
            .root_block = @fromBackingInt(@intCast(0)),
        },
        .return_type = .unit,
        .is_fallible = false,
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

test "cleanup materializer inserts ordered custom drops at an interior boundary" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

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

    var body = try builder.finish();
    defer body.deinit(context.gpa);
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

test "cleanup materializer finds boundaries after earlier splits" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const first = try builder.appendInstruction(.{ .const_int = 40 });
    const first_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(first_boundary);
    const second = try builder.appendInstruction(.{ .const_int = 41 });
    const second_boundary = try builder.newBoundary(TestMaterializerTypes.span);
    try builder.appendBoundary(second_boundary);
    _ = try builder.appendInstruction(.{ .const_int = 42 });
    builder.terminate(.return_unit);
    const first_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);
    const second_generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.second_custom_type, 1);

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

    var body = try builder.finish();
    defer body.deinit(context.gpa);
    try std.testing.expectEqual(@as(usize, 3), body.blocks.len);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[1].call.target.direct.item);
    try std.testing.expectEqual(TestMaterializerTypes.second_custom_drop_hook, body.instructions[3].call.target.direct.item);
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[2].terminator);
}

test "cleanup materializer emits produced cleanup at block entry" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

    const argument = try builder.appendBlockArgument(TestMaterializerTypes.custom_type, null);
    const entry = try builder.newBlock(0, 0);
    const target = try builder.newBlock(argument, argument + 1);
    builder.enterBlock(entry);
    const source = try builder.appendInstruction(.{ .const_int = 42 });
    try builder.appendBranchArgument(.{ .value = source.id }, null);
    builder.terminate(.{ .branch = .{ .target = target, .arguments = .{ .start = 0, .end = 1 } } });
    builder.enterBlock(target);
    builder.terminate(.return_unit);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = @fromBackingInt(@intCast(argument)),
        .location = .{ .block_entry = target },
    }});

    var body = try builder.finish();
    defer body.deinit(context.gpa);
    const target_block = body.blocks[@backingInt(target)];
    try std.testing.expectEqual(@as(u32, 1), target_block.argument_end - target_block.argument_start);
    try std.testing.expectEqual(@as(u32, 1), target_block.instruction_end - target_block.instruction_start);
    try std.testing.expectEqual(TestMaterializerTypes.custom_drop_hook, body.instructions[target_block.instruction_start].call.target.direct.item);
    const suffix = target_block.terminator.branch.target;
    try std.testing.expectEqual(structures.FunctionTerminator.return_unit, body.blocks[@backingInt(suffix)].terminator);
}

test "cleanup materializer interposes only one predicate edge" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

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

    var body = try builder.finish();
    defer body.deinit(context.gpa);
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

test "cleanup materializer forwards fallible success payloads" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

    const entry = try builder.newBlock(0, 0);
    builder.enterBlock(entry);
    const value = try builder.appendInstruction(.{ .const_int = 42 });
    _ = try builder.appendBlockArgument(.int, null);
    const success = try builder.newBlock(0, 1);
    const failure = try builder.newBlock(1, 1);
    builder.terminate(.{ .fallible_call = .{
        .call = .{ .target = .{ .direct = .{ .item = @fromBackingInt(@intCast(3)) } }, .arguments = .{ .start = 0, .end = 0 }, .return_type = .int },
        .success = success,
        .failure = failure,
    } });
    builder.enterBlock(success);
    builder.terminate(.{ .return_value = .{ .value = @fromBackingInt(@intCast(0)) } });
    builder.enterBlock(failure);
    builder.terminate(.return_failure);
    const generation = try testAppendMaterializerGeneration(&builder, TestMaterializerTypes.custom_type, 0);

    try builder.materializeCleanups(&.{.{
        .generation = generation,
        .cleanup_value = value.id,
        .location = .{ .edge = .{ .predecessor = entry, .successor_ordinal = 0 } },
    }});

    var body = try builder.finish();
    defer body.deinit(context.gpa);
    const cleanup_block = body.blocks[@backingInt(entry)].terminator.fallible_call.success;
    const cleanup = body.blocks[@backingInt(cleanup_block)];
    try std.testing.expectEqual(@as(u32, 1), cleanup.argument_end - cleanup.argument_start);
    try std.testing.expectEqual(success, cleanup.terminator.branch.target);
    const forwarded = cleanup.terminator.branch.arguments;
    try std.testing.expectEqual(@as(u32, 1), forwarded.end - forwarded.start);
    try std.testing.expectEqual(@as(structures.FunctionValueId, @fromBackingInt(@intCast(cleanup.argument_start))), body.branch_arguments[forwarded.start].value);
    try std.testing.expectEqual(failure, body.blocks[@backingInt(entry)].terminator.fallible_call.failure);
}

test "cleanup materializer guards conditional ownership" {
    var context: TestMaterializerContext = .{ .gpa = std.testing.allocator };
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

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

    var body = try builder.finish();
    defer body.deinit(context.gpa);
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
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();

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

    var body = try builder.finish();
    defer body.deinit(context.gpa);
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
    var builder = testInitMaterializerBuilder(&context);
    defer builder.deinit();
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
    var body = try builder.finish();
    defer body.deinit(gpa);
}

test "cleanup materializer releases partial CFG mutations on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCleanupMaterializerAllocationFailures, .{});
}
