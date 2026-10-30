const std = @import("std");
const profiling = @import("../profiling.zig");
const text_literal = @import("text_literal.zig");
const structures = @import("../structures.zig");

pub const Issue = struct {
    span: structures.SourceSpan,
    kind: structures.Diagnostic.Kind,
};

fn SemanticResult(comptime Success: type) type {
    return union(enum) {
        success: Success,
        unsupported: Issue,
    };
}

pub fn analyzer(ast: *const structures.Ast, source: []const u8, analysis_context: anytype, gpa: std.mem.Allocator) Analyzer(@TypeOf(analysis_context)) {
    return .{ .ast = ast, .source = source, .analysis_context = analysis_context, .gpa = gpa };
}

fn Analyzer(comptime AnalysisServices: type) type {
    return struct {
        ast: *const structures.Ast,
        source: []const u8,
        analysis_context: AnalysisServices,
        gpa: std.mem.Allocator,
        issue: ?Issue = null,

        pub inline fn run(self: @This(), comptime operation: []const u8, arguments: anytype) anyerror!SemanticResult(@typeInfo(@typeInfo(@TypeOf(@field(@This(), operation))).@"fn".return_type.?).error_union.payload) {
            var analysis = self;
            const value = @call(.auto, @field(@This(), operation), .{&analysis} ++ arguments) catch |err| switch (err) {
                error.SourceRejected => return .{ .unsupported = analysis.issue.? },
                else => return err,
            };
            return .{ .success = value };
        }

        fn reject(self: *@This(), node: structures.Node.Index, kind: structures.Diagnostic.Kind) error{SourceRejected} {
            return self.rejectIssue(issueAt(self.ast, node.index(), kind));
        }

        fn rejectIssue(self: *@This(), issue: Issue) error{SourceRejected} {
            self.issue = issue;
            return error.SourceRejected;
        }

        pub fn buildUnresolvedBody(self: *const @This(), root: BodySource) !SemanticResult(UnresolvedBody) {
            var phase: profiling.Scope = .{};
            phase.beginCurrent(.body_build);
            defer phase.end();
            var builder: ExpressionBuilder(@TypeOf(self.analysis_context)) = .{
                .ast = self.ast,
                .source = self.source,
                .parameters = switch (root) {
                    .function => |function| function.parameters,
                    else => &.{},
                },
                .analysis_context = self.analysis_context,
                .gpa = self.gpa,
            };
            defer builder.deinit();
            builder.build(root) catch |err| switch (err) {
                error.SourceRejected => return .{ .unsupported = builder.issue.? },
                else => return err,
            };
            return .{ .success = try builder.finish() };
        }

        pub fn analyzeStaticTypeCall(self: *const @This(), expression: structures.Node.Index) !SemanticResult(?structures.InstanceId) {
            const node = self.ast.nodes[expression.index()];
            if (node.tag != .call) return .{ .success = null };
            const callee = node.data.node_node.a;
            const resolved = resolveNamedExpressionWithOperands(self.ast, self.source, callee, self.analysis_context, self.ast.nodeList(node.data.node_node.b).len) catch |err|
                return .{ .unsupported = issueAt(self.ast, callee.index(), nameResolutionIssue(err) orelse return err) };
            const reference = resolved orelse return .{ .success = null };
            if (reference != .declaration) return .{ .success = null };
            const shape = (try self.analysis_context.functionShape(reference.declaration.item)) orelse return .{ .success = null };
            if (!shape.returns_type) return .{ .success = null };
            for (shape.parameters) |parameter| if (parameter.mode != .static) return .{ .success = null };
            if (try self.analysis_context.needsInheritedInference(reference.declaration)) return .{ .success = null };
            if (self.ast.nodeList(node.data.node_node.b).len != shape.parameters.len) return .{ .success = null };
            var builder: ExpressionBuilder(@TypeOf(self.analysis_context)) = .{
                .ast = self.ast,
                .source = self.source,
                .parameters = &.{},
                .analysis_context = self.analysis_context,
                .gpa = self.gpa,
            };
            defer builder.deinit();
            const call = builder.buildCall(expression) catch |err| switch (err) {
                error.SourceRejected => return .{ .unsupported = builder.issue.? },
                else => return err,
            };
            std.debug.assert(call.target == .direct);
            std.debug.assert(call.arguments.start == call.arguments.end);
            return .{ .success = call.target.direct };
        }

        pub fn analyzeFunctionSignature(self: *@This(), declaration: u32) !structures.FunctionSignature {
            var shape = switch (try analyzeFunctionShape(self.ast, self.source, declaration, self.gpa)) {
                .success => |shape| shape,
                .unsupported => |issue| return self.rejectIssue(issue),
            };
            defer shape.deinit(self.gpa);
            return self.analyzeShapedFunctionSignature(declaration, &.{}, shape);
        }

        pub fn inferStaticArguments(self: *const @This(), declaration: u32, argument_types: []const structures.TypeId, inherited_from: ?u32) !StaticInference {
            const parameters = functionParameters(self.ast, declaration);
            var inferred: std.ArrayList(InferredParameter) = .empty;
            defer inferred.deinit(self.gpa);
            if (inherited_from) |owner| try appendInferredStaticParameters(self.ast, self.source, functionParameters(self.ast, owner), &inferred, self.gpa);
            try appendInferredStaticParameters(self.ast, self.source, parameters, &inferred, self.gpa);

            var runtime_index: usize = 0;
            for (parameters) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                if (parameterMode(self.ast, parameter).? == .static) continue;
                const actual_type = argument_types[runtime_index];
                runtime_index += 1;
                const annotation = parameter.data.parameter.annotation.unwrap().?;
                if (!try self.bindInferredType(inferred.items, annotation, actual_type)) return .conflict;
            }
            std.debug.assert(runtime_index == argument_types.len);
            return finishStaticInference(inferred.items, self.gpa);
        }

        pub fn inferStructArguments(self: *const @This(), declaration: u32, fields: []const UnresolvedBody.StructFieldValue, field_types: []const structures.TypeId) !StaticInference {
            std.debug.assert(fields.len == field_types.len);
            var inferred: std.ArrayList(InferredParameter) = .empty;
            defer inferred.deinit(self.gpa);
            try appendInferredStaticParameters(self.ast, self.source, functionParameters(self.ast, declaration), &inferred, self.gpa);
            for (fields, field_types) |field, actual_type| {
                const annotation = structFactoryFieldAnnotation(self.ast, self.source, declaration, field.name) orelse continue;
                if (!try self.bindInferredType(inferred.items, annotation, actual_type)) return .conflict;
            }
            return finishStaticInference(inferred.items, self.gpa);
        }

        pub fn inferConverterArguments(self: *const @This(), declaration: u32, source_type: ?structures.TypeId, target_type: structures.TypeId, source_value: ?structures.CompileTimeValueId, collection_length: ?u32) !StaticInference {
            const signature = functionParts(self.ast, declaration).signature;
            const parameters = self.ast.nodeList(signature.parameters);
            var inferred: std.ArrayList(InferredParameter) = .empty;
            defer inferred.deinit(self.gpa);
            try appendInferredStaticParameters(self.ast, self.source, parameters, &inferred, self.gpa);
            var value_count: usize = 0;
            for (parameters) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                if (parameterMode(self.ast, parameter).? == .static) continue;
                value_count += 1;
                const annotation = parameter.data.parameter.annotation.unwrap().?;
                if (source_type) |actual_type| {
                    if (!try self.bindInferredType(inferred.items, annotation, actual_type)) return .conflict;
                } else if (parameterMode(self.ast, parameter).? == .init and self.ast.nodes[annotation.index()].tag == .call) {
                    const arguments = self.ast.nodeList(self.ast.nodes[annotation.index()].data.node_node.b);
                    if (arguments.len == 2) if (inferredParameter(self.ast, self.source, inferred.items, arguments[1], false)) |count| {
                        const value = try self.analysis_context.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(collection_length.?) } } });
                        if (!count.bind(value)) return .conflict;
                    };
                }
            }
            const target = signature.return_type.unwrap() orelse return .missing;
            if (!try self.bindInferredType(inferred.items, target, target_type)) return .conflict;
            if (value_count == 0) {
                const value = source_value orelse return .missing;
                var source_parameter: ?*InferredParameter = null;
                for (parameters) |parameter_index| {
                    const candidate = self.ast.nodes[parameter_index.index()];
                    const annotation = candidate.data.parameter.annotation.unwrap().?;
                    const name = tokenText(self.ast, self.source, candidate.token_index);
                    if (parameterMode(self.ast, candidate).? != .static or isMetaTypeAnnotation(self.ast, self.source, annotation)) continue;
                    if (!try self.analysis_context.isStaticConverterAnnotation(annotation) and
                        (!converterAnnotationDependsOnStaticParameters(self.ast, self.source, declaration, annotation) or annotationInfersParameter(self.ast, self.source, target, name))) continue;
                    if (source_parameter != null) return .missing;
                    for (inferred.items) |*parameter| {
                        if (std.mem.eql(u8, name, parameter.name)) source_parameter = parameter;
                    }
                    if (!try self.bindInferredType(inferred.items, annotation, source_type.?)) return .conflict;
                }
                const parameter = source_parameter orelse return .missing;
                if (!parameter.bind(value)) return .conflict;
            } else if (value_count != 1) return .missing;
            return finishStaticInference(inferred.items, self.gpa);
        }

        pub fn analyzeIndependentStructFieldType(self: *@This(), declaration: u32, name: []const u8) !?structures.TypeId {
            const annotation = structFactoryFieldAnnotation(self.ast, self.source, declaration, name) orelse return null;
            return self.analyzeIndependentAnnotation(annotation, functionParameters(self.ast, declaration), .struct_field_type_not_supported);
        }

        fn bindInferredType(self: *const @This(), inferred: []InferredParameter, annotation: structures.Node.Index, actual_type: structures.TypeId) anyerror!bool {
            const annotated = self.ast.nodes[annotation.index()];
            if (inferredParameter(self.ast, self.source, inferred, annotation, true)) |target| {
                const value = try self.analysis_context.internCompileTimeValue(.{ .type = actual_type });
                return target.bind(value);
            }
            if (annotated.tag == .reference_type)
                return self.bindInferredType(inferred, annotated.data.node, (try self.analysis_context.facts().borrowElement(actual_type)) orelse actual_type);
            if (annotated.tag == .type_tuple) {
                const actual_members = (try self.analysis_context.facts().tupleMembers(actual_type)) orelse return true;
                const patterns = self.ast.nodeList(annotation);
                if (patterns.len != actual_members.len) return true;
                for (patterns, actual_members) |pattern, actual| {
                    const expected_kind: structures.MemberKind = if (self.ast.nodes[pattern.index()].tag == .reference_type) .reference else .owned;
                    if (expected_kind != actual.kind) return false;
                    if (!try self.bindInferredType(inferred, logicalTypeNode(self.ast, pattern), actual.type_id)) return false;
                }
                return true;
            }
            if (annotated.tag == .type_variant) return self.bindInferredVariant(inferred, annotation, actual_type);
            if (annotated.tag != .call) return true;
            const factory = (try resolveNamedExpression(self.ast, self.source, annotated.data.node_node.a, self.analysis_context)) orelse return true;
            if (factory != .declaration) return true;
            const values = (try self.analysis_context.structFactoryArguments(factory.declaration, actual_type)) orelse return true;
            const factory_arguments = self.ast.nodeList(annotated.data.node_node.b);
            if (factory_arguments.len != values.len) return true;
            for (factory_arguments, values) |argument, value| {
                const target = inferredParameter(self.ast, self.source, inferred, argument, false) orelse continue;
                if (!target.bind(value)) return false;
            }
            return true;
        }

        fn bindInferredVariant(self: *const @This(), inferred: []InferredParameter, annotation: structures.Node.Index, actual_type: structures.TypeId) !bool {
            // Only one dependent arm can receive the unmatched members. With two,
            // partitioning the source would require guessing between type parameters.
            var dependent: ?structures.Node.Index = null;
            for (self.ast.nodeList(annotation)) |member| {
                if (!annotationReferencesInferred(self.ast, self.source, inferred, member)) continue;
                if (dependent != null) return true;
                dependent = member;
            }
            const target = dependent orelse return true;
            const source_members = (try self.analysis_context.facts().variantMembers(actual_type)) orelse &.{actual_type};
            var remaining: std.ArrayList(structures.TypeId) = .empty;
            defer remaining.deinit(self.gpa);
            try remaining.appendSlice(self.gpa, source_members);
            for (self.ast.nodeList(annotation)) |member| {
                if (member == target) continue;
                const fixed_logical_type = switch (try self.run("typeValue", .{ logicalTypeNode(self.ast, member), structures.Diagnostic.Kind.parameter_type_not_supported })) {
                    .success => |type_id| type_id,
                    .unsupported => return true,
                };
                const fixed_type = try self.analysis_context.facts().memberStorageType(.{ .type_id = fixed_logical_type, .kind = if (self.ast.nodes[member.index()].tag == .reference_type) .reference else .owned });
                const fixed_members = (try self.analysis_context.facts().variantMembers(fixed_type)) orelse &.{fixed_type};
                var index = remaining.items.len;
                while (index > 0) {
                    index -= 1;
                    if (std.mem.indexOfScalar(structures.TypeId, fixed_members, remaining.items[index]) != null)
                        _ = remaining.orderedRemove(index);
                }
            }
            // A source entirely covered by fixed arms, including bare none, supplies
            // no evidence for the dependent arm. Never likewise supplies no payload.
            if (remaining.items.len == 0 or actual_type == .never) return true;
            const payload_type = try self.analysis_context.facts().internVariant(remaining.items);
            return self.bindInferredType(inferred, target, payload_type);
        }

        pub fn analyzeIndependentConverterTypes(self: *const @This(), declaration: u32) !IndependentConverterTypes {
            var result: IndependentConverterTypes = .{};
            const signature = functionParts(self.ast, declaration).signature;
            if (signature.return_type.unwrap()) |annotation| {
                const return_type = try self.run("analyzeIndependentAnnotation", .{ annotation, self.ast.nodeList(signature.parameters), structures.Diagnostic.Kind.return_type_not_supported });
                if (return_type == .success) result.return_type = return_type.success;
            }
            var runtime_count: usize = 0;
            for (self.ast.nodeList(signature.parameters)) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                const mode = parameterMode(self.ast, parameter) orelse return result;
                if (mode == .static) continue;
                if (parameter.data.parameter.annotation.unwrap() == null) return result;
                runtime_count += 1;
            }
            if (runtime_count == 1) {
                const input_type = try self.run("analyzeIndependentParameterType", .{ declaration, @as(usize, 0) });
                if (input_type == .success) result.input_type = input_type.success;
            }
            return result;
        }

        fn analyzeIndependentAnnotation(self: *@This(), annotation: structures.Node.Index, parameters: []const structures.Node.Index, unsupported: structures.Diagnostic.Kind) !?structures.TypeId {
            const static_parameters: ParameterScope = .{ .ast = self.ast, .source = self.source, .parameters = parameters, .static_only = true };
            if (runtimeReference(self.ast, self.source, annotation, static_parameters) != null or self.ast.nodes[annotation.index()].tag == .call)
                return null;
            return try self.typeValue(annotation, unsupported);
        }

        pub fn analyzeIndependentParameterType(self: *@This(), declaration: u32, runtime_index: usize) !?structures.TypeId {
            const parameters = functionParameters(self.ast, declaration);
            var current: usize = 0;
            for (parameters) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                if (parameterMode(self.ast, parameter).? == .static) continue;
                if (current == runtime_index) {
                    const annotation = parameter.data.parameter.annotation.unwrap().?;
                    return self.analyzeIndependentAnnotation(annotation, parameters, .parameter_type_not_supported);
                }
                current += 1;
            }
            unreachable;
        }

        pub fn analyzeStaticParameterType(self: *@This(), declaration: u32, parameter_index: usize) !structures.TypeId {
            const parameters = functionParameters(self.ast, declaration);
            std.debug.assert(parameter_index < parameters.len);
            const parameter = self.ast.nodes[parameters[parameter_index].index()];
            std.debug.assert(parameterMode(self.ast, parameter).? == .static);
            const annotation = parameter.data.parameter.annotation.unwrap() orelse unreachable;
            const runtime_parameters: ParameterScope = .{ .ast = self.ast, .source = self.source, .parameters = parameters };
            if (runtimeReference(self.ast, self.source, annotation, runtime_parameters)) |reference|
                return self.reject(reference, .value_used_as_type);
            return self.typeValue(annotation, .parameter_type_not_supported);
        }

        pub fn analyzeShapedFunctionSignature(self: *@This(), declaration: u32, specialization: []const structures.CompileTimeValueId, shape: structures.FunctionShape) !structures.FunctionSignature {
            const binding = self.ast.nodes[declaration];
            const parts = functionParts(self.ast, declaration);

            var parameters: std.ArrayList(structures.CallableParameter) = .empty;
            defer parameters.deinit(self.gpa);
            const runtime_parameters: ParameterScope = .{ .ast = self.ast, .source = self.source, .parameters = self.ast.nodeList(parts.signature.parameters) };
            var specialization_index: usize = 0;
            for (runtime_parameters.parameters, shape.parameters) |parameter_index, parameter_shape| {
                const parameter = self.ast.nodes[parameter_index.index()];
                std.debug.assert(parameter.tag == .param);
                const mode = parameter_shape.mode;
                const name_span = tokenSpan(self.ast, parameter.token_index);
                const name = self.source[name_span.start..name_span.end];
                if (try self.analysis_context.resolveLocalConflict(name) != null)
                    return self.rejectIssue(.{ .span = name_span, .kind = .duplicate_parameter });
                const annotation = parameter.data.parameter.annotation.unwrap().?;
                if (runtimeReference(self.ast, self.source, annotation, runtime_parameters)) |reference|
                    return self.reject(reference, .value_used_as_type);
                if (mode == .static) {
                    if (specialization_index >= specialization.len)
                        return self.rejectIssue(.{ .span = name_span, .kind = .static_parameter_requires_specialization });
                    const argument = try self.analysis_context.lookupCompileTimeValue(specialization[specialization_index]);
                    specialization_index += 1;
                    const matches = if (parameter_shape.is_meta_type) argument == .type else matches: {
                        const expected = try self.typeValue(annotation, .parameter_type_not_supported);
                        break :matches expected != .never and expected != .type and argument == .runtime and argument.runtime.type_id == expected;
                    };
                    if (!matches) return self.rejectIssue(.{ .span = name_span, .kind = .static_argument_type_mismatch });
                    continue;
                }
                const parameter_type = try self.typeValue(annotation, .parameter_type_not_supported);
                if (parameter_type == .type) return self.reject(annotation, .parameter_type_not_supported);
                try parameters.append(self.gpa, .{ .mode = mode, .type_id = parameter_type });
            }
            std.debug.assert(specialization_index == specialization.len);

            for (self.ast.nodeList(parts.signature.where_clauses)) |condition| {
                if (runtimeReference(self.ast, self.source, condition, runtime_parameters)) |reference|
                    return self.reject(reference, .comptime_runtime_capture);
            }

            const return_annotation = parts.signature.return_type;
            if (runtimeReference(self.ast, self.source, return_annotation, runtime_parameters)) |reference|
                return self.reject(reference, .value_used_as_type);
            var signature: structures.FunctionSignature = .{ .parameters = parameters.items, .return_type = .unit };
            if (return_annotation.unwrap()) |return_type_index| {
                const result = try self.typeMember(return_type_index, .return_type_not_supported);
                signature.return_type = result.type_id;
                signature.result_mode = if (result.kind == .reference) .reference else .owned;
            }

            const annotation = if (binding.tag == .static_binding) binding.data.node_node.a.unwrap() else null;
            if (annotation) |annotation_index| {
                const expected = try self.typeValue(annotation_index, .function_annotation_not_supported);
                const actual = try self.analysis_context.facts().internCallable(signature);
                if (expected != actual) return self.rejectIssue(.{
                    .span = nodeFocusSpan(self.ast, parts.function),
                    .kind = .{ .static_initializer_type_mismatch = .{ .expected = expected, .found = actual } },
                });
            }
            signature.parameters = try parameters.toOwnedSlice(self.gpa);
            return signature;
        }

        fn typeMember(self: *@This(), node_index: structures.Node.Index, unsupported_kind: structures.Diagnostic.Kind) anyerror!structures.MemberSpec {
            const type_id = try self.typeValue(logicalTypeNode(self.ast, node_index), unsupported_kind);
            if (self.ast.nodes[node_index.index()].tag == .reference_type) return .{ .type_id = type_id, .kind = .reference };
            return self.analysis_context.facts().memberSpec(type_id);
        }

        fn typeValue(self: *@This(), node_index: structures.Node.Index, unsupported_kind: structures.Diagnostic.Kind) anyerror!structures.TypeId {
            const node = self.ast.nodes[node_index.index()];
            if (node.tag == .reference_type) return self.reject(node_index, unsupported_kind);
            if (node.tag == .implicit_type) return .type;
            if (node.tag == .unit_literal) return .unit;
            if (node.tag == .none_literal) return .none;
            if (node.tag == .call) {
                const value_id = self.analysis_context.executeComptime(node_index) catch |err| switch (err) {
                    error.QueryCycle => return self.reject(node_index, .declaration_cycle),
                    else => return err,
                } orelse return error.Unavailable;
                return switch (try self.analysis_context.lookupCompileTimeValue(value_id)) {
                    .type => |type_id| type_id,
                    .runtime => self.reject(node_index, .value_used_as_type),
                };
            }
            if (node.tag == .type or node.tag == .identifier) {
                const span = tokenSpan(self.ast, node.token_index);
                const name = self.source[span.start..span.end];
                if (std.meta.stringToEnum(structures.TypeId, name)) |type_id| return type_id;
                if (std.mem.eql(u8, name, "float")) return self.rejectIssue(.{ .span = span, .kind = .float_type_not_supported });
            }
            if (node.tag == .type or node.tag == .identifier or node.tag == .field_access) {
                const reference = resolveNamedExpression(self.ast, self.source, node_index, self.analysis_context) catch |err|
                    return self.reject(node_index, nameResolutionIssue(err) orelse return err);
                const target = reference orelse return self.reject(node_index, .unknown_type);
                const value_id = switch (target) {
                    .namespace => return self.reject(node_index, .namespace_used_as_value),
                    .overloaded_function => return self.reject(node_index, .value_used_as_type),
                    .constant => |value| value,
                    .declaration => |item| (self.analysis_context.staticItem(item) catch |err| switch (err) {
                        error.QueryCycle => return self.reject(node_index, .declaration_cycle),
                        else => return err,
                    }) orelse {
                        const shape = try self.analysis_context.functionShape(item.item);
                        if (shape != null and shape.?.returns_type) return self.reject(node_index, if (try self.analysis_context.isGenericStruct(item.item)) .generic_struct_requires_specialization else .type_factory_requires_call);
                        return self.reject(node_index, .value_used_as_type);
                    },
                };
                return switch (try self.analysis_context.lookupCompileTimeValue(value_id)) {
                    .type => |type_id| type_id,
                    .runtime => self.reject(node_index, .value_used_as_type),
                };
            }
            if (node.tag == .type_func) {
                var parameters: std.ArrayList(structures.CallableParameter) = .empty;
                defer parameters.deinit(self.gpa);
                for (self.ast.nodeList(node.data.node_node.a)) |parameter_index| {
                    const parameter = self.ast.nodes[parameter_index.index()];
                    const explicit_mode = parameter.tag == .param;
                    const type_index = if (explicit_mode) parameter.data.parameter.annotation else parameter_index;
                    const parameter_type = try self.typeValue(type_index, unsupported_kind);
                    if (parameter_type == .type) return self.reject(parameter_index, unsupported_kind);
                    try parameters.append(self.gpa, .{ .mode = if (explicit_mode) parameterMode(self.ast, parameter).? else .imm, .type_id = parameter_type });
                }
                const result = try self.typeMember(node.data.node_node.b, unsupported_kind);
                return self.analysis_context.facts().internCallable(.{
                    .parameters = parameters.items,
                    .return_type = result.type_id,
                    .result_mode = if (result.kind == .reference) .reference else .owned,
                });
            }
            if (node.tag != .type_variant and node.tag != .type_tuple and node.tag != .tuple_literal) return self.reject(node_index, unsupported_kind);

            var members: std.ArrayList(structures.MemberSpec) = .empty;
            defer members.deinit(self.gpa);
            for (self.ast.nodeList(node_index)) |member_index| {
                const member = try self.typeMember(member_index, unsupported_kind);
                if (member.type_id == .type) return self.reject(member_index, unsupported_kind);
                try members.append(self.gpa, member);
            }
            std.debug.assert(members.items.len >= 1);
            if (node.tag == .type_tuple or node.tag == .tuple_literal) return self.analysis_context.facts().internTuple(members.items);

            return self.analysis_context.facts().internVariantMembers(members.items);
        }

        pub fn analyzeStaticDeclaration(self: *@This(), declaration: u32) !StaticInitializerPlan {
            const binding = self.ast.nodes[declaration];
            std.debug.assert(binding.tag == .static_binding);
            const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
            const annotation = binding.data.node_node.a.unwrap() orelse return .{ .interpret = null };
            if (isMetaTypeAnnotation(self.ast, self.source, annotation)) {
                return .{ .type_value = try self.typeValue(initializer, .static_initializer_not_supported) };
            }
            const expected = try self.typeValue(annotation, .static_initializer_not_supported);
            if (expected == .type) return self.rejectIssue(issueAt(self.ast, annotation.index(), .static_initializer_not_supported));
            return .{ .interpret = expected };
        }

        pub fn analyzeStructDefinition(self: *@This(), item_id: structures.ItemId, declaration: u32) !structures.StructDefinition {
            const binding = self.ast.nodes[declaration];
            std.debug.assert(binding.tag == .static_binding);
            const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
            if (binding.data.node_node.a.unwrap()) |annotation| {
                if (!isMetaTypeAnnotation(self.ast, self.source, annotation))
                    return self.reject(annotation, .static_initializer_not_supported);
            }
            return self.analyzeStructMembers(initializer, .{ .declared = item_id });
        }

        pub fn analyzeGeneratedStructDefinition(self: *@This(), struct_index: structures.Node.Index, identity: structures.GeneratedStructIdentity) !structures.StructDefinition {
            return self.analyzeStructMembers(struct_index, .{ .generated = identity });
        }

        fn analyzeStructMembers(self: *@This(), struct_index: structures.Node.Index, identity: structures.StructIdentity) !structures.StructDefinition {
            const struct_node = self.ast.nodes[struct_index.index()];
            std.debug.assert(struct_node.tag == .@"struct");

            var fields: std.ArrayList(structures.StructField) = .empty;
            defer {
                for (fields.items) |field| self.gpa.free(field.name);
                fields.deinit(self.gpa);
            }
            if (try validateStructNamespace(self.ast, self.source, struct_index, self.gpa)) |issue| return self.rejectIssue(issue);
            var ownership: structures.StructOwnershipProperties = .{};
            var error_mark: ?bool = null;

            for (self.ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
                const item = self.ast.nodes[member_index.index()];
                const member = if (item.tag == .@"pub") self.ast.nodes[item.data.node.index()] else item;
                if (member.tag == .struct_property) {
                    const property_span = tokenSpan(self.ast, member.token_index);
                    const property_name = self.source[property_span.start..property_span.end];
                    if (std.mem.eql(u8, property_name, "error")) {
                        if (error_mark != null) return self.rejectIssue(.{ .span = property_span, .kind = .duplicate_struct_property });
                        const value = self.ast.nodes[member.data.node.index()];
                        if (value.tag != .bool_literal) return self.reject(member.data.node, .invalid_error_property);
                        error_mark = self.ast.tokens[value.token_index].tag == .keyword_true;
                        continue;
                    }
                    const operation = std.meta.stringToEnum(StructOwnershipOperation, property_name) orelse
                        return self.rejectIssue(.{ .span = property_span, .kind = .unknown_struct_property });
                    if (operation.isDefined(ownership))
                        return self.rejectIssue(.{ .span = property_span, .kind = .duplicate_struct_property });
                    const value = self.ast.nodes[member.data.node.index()];
                    const value_span = tokenSpan(self.ast, value.token_index);
                    var hook: ?structures.InstanceId = null;
                    if (value.tag == .func) {
                        const self_type = try self.analysis_context.structIdentityType(identity);
                        const mode: structures.ParameterMode, const return_type: structures.TypeId = switch (operation) {
                            .copy => .{ .imm, self_type },
                            .move => .{ .deinit, self_type },
                            .drop => .{ .deinit, .unit },
                        };
                        hook = (try self.analysis_context.ownedFunction(identity, property_name)) orelse return error.Unavailable;
                        const actual = (try self.analysis_context.functionSignature(hook.?)) orelse return error.Unavailable;
                        const expected_parameter = [_]structures.CallableParameter{.{ .mode = mode, .type_id = self_type }};
                        const expected_type = try self.analysis_context.facts().internCallable(.{
                            .parameters = &expected_parameter,
                            .return_type = return_type,
                        });
                        const actual_type = try self.analysis_context.facts().internCallable(actual);
                        if (actual_type != expected_type) return self.rejectIssue(.{
                            .span = value_span,
                            .kind = .{ .struct_ownership_hook_signature_mismatch = .{ .expected = expected_type, .found = actual_type } },
                        });
                    }
                    // A hook defines a custom capability; named capabilities cannot be custom.
                    const spelling = switch (value.tag) {
                        .func => "custom",
                        .none_literal => "none",
                        .identifier => self.source[value_span.start..value_span.end],
                        else => "",
                    };
                    switch (operation) {
                        inline else => |kind| {
                            const Capability = @FieldType(structures.OwnershipCapabilities, @tagName(kind));
                            const capability = std.meta.stringToEnum(Capability, spelling) orelse .custom;
                            if (capability == .custom and hook == null) return self.rejectIssue(.{
                                .span = value_span,
                                .kind = .{ .invalid_struct_property_value = @field(structures.Diagnostic.InvalidStructPropertyValue, @tagName(kind)) },
                            });
                            @field(ownership, @tagName(kind)) = .{ .capability = capability, .hook = hook, .span = property_span };
                        },
                    }
                    continue;
                }
                if (member.tag == .static_binding) continue;
                std.debug.assert(member.tag == .struct_field);

                const name_span = tokenSpan(self.ast, member.token_index);
                const name = self.source[name_span.start..name_span.end];
                const field_type = field: {
                    const public_annotation = self.analysis_context.public_annotation;
                    self.analysis_context.public_annotation = item.tag == .@"pub";
                    defer self.analysis_context.public_annotation = public_annotation;
                    break :field try self.typeValue(member.data.field.type_annotation, .struct_field_type_not_supported);
                };
                const field_member: structures.MemberSpec = if (member.data.field.kind == .reference)
                    .{ .type_id = field_type, .kind = .reference }
                else
                    try self.analysis_context.facts().memberSpec(field_type);
                if (field_member.type_id == .type) return self.reject(member.data.field.type_annotation, .struct_field_type_not_supported);
                if (item.tag == .@"pub" and !try self.analysis_context.isPublicFieldType(field_member.type_id))
                    return self.reject(member.data.field.type_annotation, .public_field_private_type);
                try fields.ensureUnusedCapacity(self.gpa, 1);
                const owned_name = try self.gpa.dupe(u8, name);
                fields.appendAssumeCapacity(.{
                    .name = owned_name,
                    .kind = field_member.kind,
                    .type_id = field_member.type_id,
                    .span = name_span,
                    .is_public = item.tag == .@"pub",
                });
            }

            return .{ .fields = try fields.toOwnedSlice(self.gpa), .ownership = ownership, .is_static = struct_node.is_static_struct, .is_error = error_mark orelse false };
        }

        pub fn analyzeStaticTypeArgument(self: *@This(), argument: structures.Node.Index) !structures.CompileTimeValue {
            return .{ .type = try self.typeValue(argument, .static_argument_not_supported) };
        }
    };
}

/// Query-local source graph after syntax and lexical validation. Parameters
/// precede expressions in the value namespace. Blocks and statements preserve
/// evaluation order. Immutable references reuse their value; mutable references
/// retain a stable local identity whose current SSA value is owned by typing.
/// Source names are borrowed only until typing finishes. Control-flow edges
/// remain structural until typing; CFG blocks belong to typed IR.
pub const UnresolvedBody = struct {
    parameter_count: u32,
    static_expression_count: u32 = 0,
    parameter_spans: []structures.SourceSpan = &.{},
    local_count: u32,
    expressions: []Expression = &.{},
    blocks: []Block = &.{},
    statements: []Statement = &.{},
    call_arguments: []ValueUse = &.{},
    method_call_arguments: []MethodCallArgument = &.{},
    struct_field_values: []StructFieldValue = &.{},
    assignment_fields: []FieldName = &.{},
    binding_patterns: []BindingPattern = &.{},
    binding_pattern_children: []u32 = &.{},
    match_patterns: []MatchPattern = &.{},
    match_pattern_children: []u32 = &.{},
    match_arms: []MatchArm = &.{},
    root_block: BlockId,

    pub const ValueId = enum(u32) { _ };
    pub const LocalId = enum(u32) { _ };
    pub const BlockId = enum(u32) { _ };
    pub const ValueUse = struct { value: ValueId, span: structures.SourceSpan };
    pub const BinaryOperands = struct { lhs: ValueUse, rhs: ValueUse };
    pub const StructFieldValue = struct {
        name: []const u8,
        name_span: structures.SourceSpan,
        value: ValueUse,
    };
    pub const FieldName = struct {
        name: []const u8,
        span: structures.SourceSpan,
    };
    pub const MethodCallArgument = struct {
        node: structures.Node.Index,
        value: ValueUse,
        runtime_reference: ?structures.SourceSpan,
    };
    pub const Capture = struct {
        local: LocalId,
        span: structures.SourceSpan,
        mode: BindingMode = .owned,
        mutable: bool = false,
    };
    pub const StatementRange = struct { start: u32, end: u32 };
    pub const BindingMode = enum { owned, reference, inferred };
    pub const Block = struct {
        statements: StatementRange,
        result: ?ValueId,
        span: structures.SourceSpan,
    };
    pub const BindingPattern = struct {
        carrier: LocalId,
        read: ValueId,
        span: structures.SourceSpan,
        annotation_type: ?structures.TypeId = null,
        position: ?ValueId = null,
        shape: union(enum) {
            name: Name,
            tuple: structures.FunctionValueRange,
            sequence: Sequence,
        },

        pub const Name = struct { local: ?LocalId, mode: BindingMode, mutable: bool };
        pub const Sequence = struct { children: structures.FunctionValueRange, storage: LocalId, storage_read: ValueId };
    };
    pub const PatternBinding = struct { pattern: u32, value: ValueId, span: structures.SourceSpan };
    pub const MatchInterval = struct { first: i64, last: i64 };
    pub const MatchPattern = struct {
        shape: union(enum) { any, type: structures.TypeId, literal: ValueUse, range: MatchInterval, tuple: structures.FunctionValueRange },
        binding: ?Capture = null,
        carrier: LocalId,
        read: ValueId,
        span: structures.SourceSpan,
    };
    pub const MatchArm = struct {
        pattern: u32,
        condition: ?ValueUse = null,
        body: BlockId,
        span: structures.SourceSpan,
    };
    pub const Statement = union(enum) {
        discard: ValueUse,
        lifetime_extend: ValueUse,
        bind_local: struct {
            local: LocalId,
            value: ValueId,
            span: structures.SourceSpan,
            mutable: bool,
            mode: BindingMode = .owned,
        },
        bind_pattern: PatternBinding,
        break_loop: ValueId,
        continue_loop: structures.SourceSpan,
        return_nothing: structures.SourceSpan,
        return_value: struct { value: ValueUse, implicit: bool },
        bind_conditional: struct { condition: ValueUse, otherwise: BlockId, span: structures.SourceSpan },
    };
    pub const Call = struct {
        target: Target,
        arguments: structures.FunctionValueRange,
        span: structures.SourceSpan,

        pub const Target = union(enum) {
            direct: structures.InstanceId,
            inferred: structures.InstanceId,
            overloaded: structures.FunctionOverloadId,
            operation: structures.Operation,
            unknown_function,
            value: ValueUse,
            member: MemberCall,
            membership: BinaryOperands,
        };
    };
    pub const MemberCall = struct {
        receiver: ValueUse,
        name: []const u8,
    };
    pub const StructInitTarget = union(enum) { concrete: structures.TypeId, inferred: structures.InstanceId };
    pub const Expression = struct {
        operation: Operation,
        span: structures.SourceSpan,
        source_node: structures.Node.Index = .null,

        pub const Operation = union(enum) {
            comparison: struct {
                operation: structures.Operation,
                operands: BinaryOperands,
            },
            static_membership: struct {
                operand: structures.Node.Index,
                target_type: structures.TypeId,
            },
            variant_membership: struct {
                operand: ValueUse,
                target_type: structures.TypeId,
            },
            iterator_membership: struct { operand: ValueUse, end_type: structures.TypeId },
            conjunction: BinaryOperands,
            disjunction: BinaryOperands,
            negation: ValueUse,
            pattern_test: PatternBinding,
            integer_literal: i64,
            int_literal_value: i64,
            string_literal: structures.ByteStringId,
            storage_cursor: structures.StaticStorageCursor,
            integer: i32,
            byte: u8,
            boolean: bool,
            type_value: structures.TypeId,
            unit,
            none,
            function_ref: structures.FunctionReference,
            overloaded_function: structures.FunctionOverloadId,
            local_read: LocalId,
            local_transfer: LocalId,
            field_transfer: struct { target: LocalId, fields: structures.FunctionValueRange },
            annotation: struct { value: ValueUse, type_id: structures.TypeId, explicit: bool = false },
            struct_init: struct {
                canonical: bool = false,
                target: StructInitTarget,
                type_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
            },
            array_init: struct { type_id: structures.TypeId, elements: structures.FunctionValueRange },
            collection_literal: struct { elements: structures.FunctionValueRange, sink: LocalId, sink_reads: structures.FunctionValueRange },
            collection_spread: struct { source: ValueUse, iteration: ValueUse },
            collection_comprehension: ValueUse,
            collection_emit: struct { element: ValueUse, sink: ValueUse },
            collection_iteration: struct { source: ValueUse, body: ValueUse },
            tuple_literal: structures.FunctionValueRange,
            field_access: struct { operand: ValueUse, name: []const u8 },
            index_snapshot: ValueUse,
            assignment: struct {
                target: LocalId,
                target_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
                value: ValueUse,
                replaces: bool,
            },
            reference_assignment: struct { reference: ValueUse, fields: structures.FunctionValueRange, value: ValueUse },
            discard: ValueUse,
            sequence: BinaryOperands,
            call: Call,
            if_else: struct {
                condition: ValueUse,
                then_block: BlockId,
                else_block: BlockId,
            },
            match: struct {
                subject: ValueUse,
                carrier: LocalId,
                read: ValueId,
                arms: structures.FunctionValueRange,
            },
            error_handler: struct {
                operand: ValueUse,
                carrier: LocalId,
                binding: ?Capture,
                annotation: ?structures.TypeId,
                handler: ?BlockId,
            },
            loop: BlockId,
            scope: BlockId,
            iterator: struct { source: ValueUse, acquisition: ValueId, structural_array: bool },
            iterator_item: struct {
                carrier: LocalId,
                operand: ValueUse,
                end_type: structures.TypeId,
                binding: Capture,
            },
        };
    };

    /// Frees every table; their elements only borrow source names.
    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        const info = @typeInfo(UnresolvedBody).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            if (@typeInfo(Field) == .pointer) gpa.free(@field(self, name));
        }
        self.* = undefined;
    }
};

/// Source roots carry the context each form can use. Only functions have
/// runtime parameters and a return continuation; thunks infer their result.
pub const BodySource = union(enum) {
    entry: u32,
    function: struct { declaration: u32, parameters: []const structures.CallableParameter = &.{} },
    comptime_expression: structures.Node.Index,
    static_iteration: structures.Node.Index,
    where_condition: structures.Node.Index,
};

fn ExpressionBuilder(comptime AnalysisServices: type) type {
    return struct {
        const Self = @This();
        const ValueId = UnresolvedBody.ValueId;
        const Local = union(enum) {
            value: ValueId,
            static_value: structures.CompileTimeValueId,
            runtime_capture,
            type_value: structures.TypeId,
            place: struct {
                id: UnresolvedBody.LocalId,
                mutable: bool,
            },
        };

        ast: *const structures.Ast,
        source: []const u8,
        parameters: []const structures.CallableParameter,
        analysis_context: AnalysisServices,
        gpa: std.mem.Allocator,
        where_condition: bool = false,
        static_expression_count: u32 = 0,
        local_count: u32 = 0,
        static_bindings: std.ArrayList(structures.StaticBinding) = .empty,
        collection_sink: ?UnresolvedBody.LocalId = null,
        static_iteration: bool = false,
        locals: std.StringHashMapUnmanaged(Local) = .empty,
        local_names: std.ArrayList([]const u8) = .empty,
        parameter_spans: std.ArrayList(structures.SourceSpan) = .empty,
        expressions: std.ArrayList(UnresolvedBody.Expression) = .empty,
        blocks: std.ArrayList(UnresolvedBody.Block) = .empty,
        statements: std.ArrayList(UnresolvedBody.Statement) = .empty,
        call_arguments: std.ArrayList(UnresolvedBody.ValueUse) = .empty,
        method_call_arguments: std.ArrayList(UnresolvedBody.MethodCallArgument) = .empty,
        struct_field_values: std.ArrayList(UnresolvedBody.StructFieldValue) = .empty,
        assignment_fields: std.ArrayList(UnresolvedBody.FieldName) = .empty,
        binding_patterns: std.ArrayList(UnresolvedBody.BindingPattern) = .empty,
        binding_pattern_children: std.ArrayList(u32) = .empty,
        match_patterns: std.ArrayList(UnresolvedBody.MatchPattern) = .empty,
        match_pattern_children: std.ArrayList(u32) = .empty,
        match_arms: std.ArrayList(UnresolvedBody.MatchArm) = .empty,
        loop_depth: u32 = 0,
        can_return: bool = false,
        returns_type: bool = false,
        scratch: std.ArrayList(UnresolvedBody.ValueUse) = .empty,
        root_block: ?UnresolvedBody.BlockId = null,
        issue: ?Issue = null,

        // Each table of the unresolved body accumulates in the builder list of the same name.
        const body_info = @typeInfo(UnresolvedBody).@"struct";

        fn deinit(self: *Self) void {
            inline for (body_info.field_names, body_info.field_types) |name, Field| {
                if (@typeInfo(Field) == .pointer) @field(self, name).deinit(self.gpa);
            }
            self.static_bindings.deinit(self.gpa);
            self.locals.deinit(self.gpa);
            self.local_names.deinit(self.gpa);
            self.scratch.deinit(self.gpa);
        }

        fn reject(self: *Self, node: structures.Node.Index, kind: structures.Diagnostic.Kind) error{SourceRejected} {
            return self.rejectIssue(issueAt(self.ast, node.index(), kind));
        }

        fn rejectIssue(self: *Self, issue: Issue) error{SourceRejected} {
            std.debug.assert(self.issue == null);
            self.issue = issue;
            return error.SourceRejected;
        }

        fn analyzeTypeOrReject(self: *Self, node: structures.Node.Index, unsupported_kind: structures.Diagnostic.Kind) !structures.TypeId {
            return switch (try analyzer(self.ast, self.source, self.analysis_context, self.gpa).run("typeValue", .{ node, unsupported_kind })) {
                .success => |type_id| type_id,
                .unsupported => |issue| self.rejectIssue(issue),
            };
        }

        fn declare(self: *Self, name: []const u8, local: Local) !void {
            try self.locals.put(self.gpa, name, local);
            try self.local_names.append(self.gpa, name);
        }

        fn build(self: *Self, root: BodySource) anyerror!void {
            for (try self.analysis_context.staticBindings()) |binding| {
                try self.declare(binding.name, if (binding.value) |value| .{ .static_value = value } else .runtime_capture);
                try self.static_bindings.append(self.gpa, binding);
            }
            switch (root) {
                .entry => |declaration| {
                    self.can_return = true;
                    try self.buildEntry(declaration);
                },
                .function => |function| {
                    self.can_return = true;
                    try self.buildFunction(function.declaration);
                },
                .comptime_expression => |expression| try self.buildComptimeThunk(expression),
                .static_iteration => |index| {
                    self.static_iteration = true;
                    const parts = self.ast.nodeList(index);
                    const traversal = try self.appendForParts(index, parts[0], parts[1], null);
                    self.root_block = try self.finishBlock(&.{.{ .discard = .{ .value = traversal, .span = nodeFocusSpan(self.ast, index) } }}, try self.appendExpression(index, .unit), nodeFocusSpan(self.ast, index));
                },
                .where_condition => |condition| try self.buildWhereCondition(condition),
            }
        }

        fn buildComptimeThunk(self: *Self, expression: structures.Node.Index) !void {
            const node = self.ast.nodes[expression.index()];
            const body = if (node.tag == .comptime_expr) node.data.node else expression;
            self.root_block = try self.buildBranch(body, false);
        }

        fn buildWhereCondition(self: *Self, expression: structures.Node.Index) !void {
            self.where_condition = true;
            const span = nodeFocusSpan(self.ast, expression);
            const value = try self.append(expression, false);
            self.root_block = try self.finishBlock(&.{.{ .return_value = .{ .value = .{ .value = value, .span = span }, .implicit = true } }}, null, span);
        }

        fn buildEntry(self: *Self, declaration: u32) !void {
            const root = self.ast.nodes[declaration];
            std.debug.assert(root.tag == .block);
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            for (self.ast.node_refs[root.data.ref.start..root.data.ref.end]) |child| {
                const child_node = self.ast.nodes[child.index()];
                const inner = if (child_node.tag == .@"pub") self.ast.nodes[child_node.data.node.index()] else child_node;
                if (inner.tag == .static_binding or inner.tag == .namespace_declaration or inner.tag == .import or inner.tag == .selective_import) continue;
                try body_statements.append(self.gpa, try self.buildStatement(child, false));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, root.token_index));
        }

        fn buildFunction(self: *Self, declaration: u32) !void {
            const span = tokenSpan(self.ast, self.ast.nodes[declaration].token_index);
            const parts = functionParts(self.ast, declaration);
            self.returns_type = if (parts.signature.return_type.unwrap()) |return_type|
                isMetaTypeAnnotation(self.ast, self.source, return_type)
            else
                false;
            try self.bindFunctionParameters(self.ast.nodeList(parts.signature.parameters));

            // External functions have no body.
            const body = parts.body.unwrap() orelse {
                self.root_block = try self.finishBlock(&.{}, null, span);
                return;
            };
            const statements: []const structures.Node.Index = if (self.ast.nodes[body.index()].tag == .block) self.ast.nodeList(body) else &.{body};
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            for (statements) |statement| try body_statements.append(self.gpa, try self.buildStatement(statement, false));
            self.root_block = try self.finishBlock(body_statements.items, null, span);
        }

        fn bindFunctionParameters(self: *Self, parameters: []const structures.Node.Index) !void {
            var runtime_index: usize = 0;
            for (parameters) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                const span = tokenSpan(self.ast, parameter.token_index);
                const name = self.source[span.start..span.end];
                if (parameterMode(self.ast, parameter).? == .static) {
                    const value_id = (try self.analysis_context.resolveStatic(name)) orelse unreachable;
                    try self.declare(name, switch (try self.analysis_context.lookupCompileTimeValue(value_id)) {
                        .type => |type_id| .{ .type_value = type_id },
                        .runtime => .{ .static_value = value_id },
                    });
                    continue;
                }
                std.debug.assert(runtime_index < self.parameters.len);
                try self.parameter_spans.append(self.gpa, span);
                try self.declare(name, switch (self.parameters[runtime_index].mode) {
                    .imm, .init => .{ .value = @fromBackingInt(@intCast(runtime_index)) },
                    .ref, .mut, .@"var", .deinit => .{ .place = .{ .id = self.newLocal(), .mutable = true } },
                    .static => unreachable,
                });
                runtime_index += 1;
            }
            std.debug.assert(runtime_index == self.parameters.len);
            self.static_expression_count = @intCast(self.expressions.items.len);
        }

        fn buildStatement(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            if ((node.tag == .return_nothing or node.tag == .return_expr) and !self.can_return) return self.reject(index, .top_level_return);
            return switch (node.tag) {
                .const_binding, .var_binding, .ref_binding => try self.buildBinding(index),
                .destructure_binding => try self.buildPatternBinding(index, false),
                .@"pub" => return self.reject(index, .misplaced_pub),
                .import, .selective_import => return self.reject(index, .import_outside_top_level),
                .return_nothing => .{ .return_nothing = span },
                .return_expr => .{ .return_value = .{
                    .value = try self.appendUse(node.data.node, self.returns_type),
                    .implicit = self.ast.tokens[node.token_index].tag != .keyword_return,
                } },
                .binding_else => try self.buildConditionalBinding(index),
                .break_nothing, .break_expr => try self.buildBreak(index, result_is_type),
                .continue_expr => try self.buildContinue(index),
                .assign => if (self.isDiscardAssignment(index))
                    .{ .lifetime_extend = try self.appendUse(node.data.node_node.b, false) }
                else
                    .{ .lifetime_extend = try self.appendUse(index, false) },
                else => .{ .discard = try self.appendUse(index, false) },
            };
        }

        fn isDiscardAssignment(self: *const Self, index: structures.Node.Index) bool {
            const target_index = self.ast.nodes[index.index()].data.node_node.a;
            const target = self.ast.nodes[target_index.index()];
            return target.tag == .identifier and std.mem.eql(u8, tokenText(self.ast, self.source, target.token_index), "_");
        }

        fn buildBreak(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .break_outside_loop);
            const node = self.ast.nodes[index.index()];
            const value = if (node.tag == .break_expr)
                try self.append(node.data.node, result_is_type)
            else
                try self.appendExpression(index, .unit);
            return .{ .break_loop = value };
        }

        fn buildContinue(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .continue_outside_loop);
            return .{ .continue_loop = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index) };
        }

        fn nameIsVisible(self: *Self, name: []const u8) !bool {
            return self.locals.contains(name) or try self.analysis_context.resolveLocalConflict(name) != null;
        }

        fn buildBinding(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const annotation = node.data.node_node.a.unwrap();
            const expected = if (annotation) |type_node| try self.bindingType(type_node) else null;
            var value = try self.append(node.data.node_node.b, false);
            if (expected) |type_id| {
                value = try self.appendExpression(annotation.?, .{ .annotation = .{ .value = .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                }, .type_id = type_id } });
            }
            const local = self.newLocal();
            try self.declare(name, .{ .place = .{ .id = local, .mutable = node.tag == .var_binding or node.tag == .ref_binding } });
            return .{ .bind_local = .{
                .local = local,
                .value = value,
                .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                .mutable = node.tag == .var_binding,
                .mode = if (node.tag == .ref_binding) .reference else .owned,
            } };
        }

        fn buildPatternBinding(self: *Self, index: structures.Node.Index, conditional: bool) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const source_index = node.data.node_node.b;
            var value = try self.append(source_index, false);
            const pattern = try self.buildBindingPattern(node.data.node_node.a, null);
            if (!conditional) if (self.binding_patterns.items[pattern].annotation_type) |type_id| {
                value = try self.appendExpression(index, .{ .annotation = .{ .value = .{ .value = value, .span = nodeFocusSpan(self.ast, node.data.node_node.b) }, .type_id = type_id } });
            };
            return .{ .bind_pattern = .{ .pattern = pattern, .value = value, .span = nodeFocusSpan(self.ast, node.data.node_node.b) } };
        }

        fn buildBindingPattern(self: *Self, index: structures.Node.Index, existing_carrier: ?UnresolvedBody.LocalId) anyerror!u32 {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .binding_annotation) {
                const pattern = try self.buildBindingPattern(node.data.node_node.a, existing_carrier);
                const expected = try self.bindingType(node.data.node_node.b);
                if (self.binding_patterns.items[pattern].annotation_type) |inner| if (inner != expected)
                    return self.reject(index, .{ .local_type_mismatch = .{ .expected = expected, .found = inner } });
                self.binding_patterns.items[pattern].annotation_type = expected;
                return pattern;
            }
            const carrier = existing_carrier orelse self.newLocal();
            var pattern: UnresolvedBody.BindingPattern = .{
                .carrier = carrier,
                .read = try self.appendExpression(index, .{ .local_read = carrier }),
                .span = nodeFocusSpan(self.ast, index),
                .shape = undefined,
            };
            if (node.tag == .param) {
                const mode = node.data.parameter.access;
                const name = tokenText(self.ast, self.source, node.token_index);
                const local: ?UnresolvedBody.LocalId = if (std.mem.eql(u8, name, "_")) null else self.newLocal();
                if (local) |output| {
                    if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
                    try self.declare(name, .{ .place = .{ .id = output, .mutable = mode == .keyword_var or mode == .keyword_ref } });
                }
                pattern.annotation_type = if (node.data.parameter.annotation.unwrap()) |annotation| try self.bindingType(annotation) else null;
                pattern.shape = .{ .name = .{ .local = local, .mode = if (mode == .keyword_ref) .reference else if (mode == null) .inferred else .owned, .mutable = mode == .keyword_var } };
            } else {
                std.debug.assert(node.tag == .binding_tuple or node.tag == .binding_sequence);
                var children: std.ArrayList(u32) = .empty;
                defer children.deinit(self.gpa);
                for (self.ast.nodeList(index), 0..) |child, position| {
                    const child_id = try self.buildBindingPattern(child, null);
                    if (node.tag == .binding_sequence) self.binding_patterns.items[child_id].position = try self.appendExpression(child, .{ .integer = @intCast(position) });
                    try children.append(self.gpa, child_id);
                }
                const start: u32 = @intCast(self.binding_pattern_children.items.len);
                try self.binding_pattern_children.appendSlice(self.gpa, children.items);
                const range: structures.FunctionValueRange = .{ .start = start, .end = @intCast(self.binding_pattern_children.items.len) };
                if (node.tag == .binding_tuple) {
                    pattern.shape = .{ .tuple = range };
                } else {
                    const storage = self.newLocal();
                    pattern.shape = .{ .sequence = .{ .children = range, .storage = storage, .storage_read = try self.appendExpression(index, .{ .local_read = storage }) } };
                }
            }
            const result: u32 = @intCast(self.binding_patterns.items.len);
            try self.binding_patterns.append(self.gpa, pattern);
            return result;
        }

        fn bindingType(self: *Self, node: structures.Node.Index) !structures.TypeId {
            if (runtimeReference(self.ast, self.source, node, self)) |reference| return self.reject(reference, .value_used_as_type);
            const type_id = try self.analyzeTypeOrReject(node, .local_type_not_supported);
            if (type_id == .type) return self.reject(node, .local_type_not_supported);
            return type_id;
        }

        fn appendCompileTimeValue(self: *Self, index: structures.Node.Index, runtime: structures.CompileTimeValue.Runtime) !ValueId {
            const primitive = try switch (runtime.value) {
                .int => |integer| self.appendExpression(index, .{ .integer = integer }),
                .int_literal => |integer| self.appendExpression(index, .{ .int_literal_value = integer }),
                .string_literal => |data| self.appendExpression(index, .{ .string_literal = data }),
                .storage_cursor => |cursor| self.appendExpression(index, .{ .storage_cursor = cursor }),
                .byte => |byte| self.appendExpression(index, .{ .byte = byte }),
                .bool => |boolean| self.appendExpression(index, .{ .boolean = boolean }),
                .unit => self.appendExpression(index, .unit),
                .none => self.appendExpression(index, .none),
                .function_ref => |reference| self.appendExpression(index, .{ .function_ref = reference }),
                .structure => |tuple_id| if (try self.analysis_context.facts().arrayType(runtime.type_id)) |array|
                    self.appendCompileTimeArray(index, runtime.type_id, array, tuple_id)
                else
                    self.appendCompileTimeStruct(index, runtime.type_id, tuple_id),
                .variant => |variant| variant: {
                    const payload = (try self.analysis_context.lookupCompileTimeValue(variant.payload)).runtime;
                    break :variant self.appendAnnotated(index, try self.appendCompileTimeValue(index, payload), payload.type_id, variant.member_type);
                },
            };
            const representation_type = runtime.value.scalarTypeId() orelse switch (runtime.value) {
                .structure => runtime.type_id,
                .variant => |variant| variant.member_type,
                else => unreachable,
            };
            return self.appendAnnotated(index, primitive, representation_type, runtime.type_id);
        }

        /// Annotates `value` with `target_type` unless it already has that type.
        fn appendAnnotated(self: *Self, index: structures.Node.Index, value: ValueId, value_type: structures.TypeId, target_type: structures.TypeId) !ValueId {
            if (value_type == target_type) return value;
            return self.appendExpression(index, .{ .annotation = .{ .value = .{ .value = value, .span = nodeFocusSpan(self.ast, index) }, .type_id = target_type } });
        }

        fn appendCompileTimeStruct(self: *Self, index: structures.Node.Index, type_id: structures.TypeId, tuple_id: structures.CompileTimeValueTupleId) anyerror!ValueId {
            const definition = (try self.analysis_context.facts().structDefinition(type_id)) orelse return error.Unavailable;
            const values = try self.analysis_context.lookupCompileTimeTuple(tuple_id);
            std.debug.assert(values.len == definition.fields.len);
            var fields: std.ArrayList(UnresolvedBody.StructFieldValue) = .empty;
            defer fields.deinit(self.gpa);
            for (definition.fields, values) |field, value_id| {
                const value = (try self.analysis_context.lookupCompileTimeValue(value_id)).runtime;
                try fields.append(self.gpa, .{
                    .name = field.name,
                    .name_span = field.span,
                    .value = .{ .value = try self.appendCompileTimeValue(index, value), .span = nodeFocusSpan(self.ast, index) },
                });
            }
            const start: u32 = @intCast(self.struct_field_values.items.len);
            try self.struct_field_values.appendSlice(self.gpa, fields.items);
            return self.appendExpression(index, .{ .struct_init = .{
                .canonical = true,
                .target = .{ .concrete = type_id },
                .type_span = nodeFocusSpan(self.ast, index),
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
            } });
        }

        fn appendTypeValue(self: *Self, index: structures.Node.Index) !ValueId {
            return self.appendExpression(index, .{ .type_value = try self.analyzeTypeOrReject(index, .type_value_used_as_runtime_value) });
        }

        fn appendCompileTimeArray(self: *Self, index: structures.Node.Index, type_id: structures.TypeId, array: structures.ArrayType, tuple_id: structures.CompileTimeValueTupleId) anyerror!ValueId {
            const values = try self.analysis_context.lookupCompileTimeTuple(tuple_id);
            std.debug.assert(values.len == array.length);
            var elements: std.ArrayList(UnresolvedBody.ValueUse) = .empty;
            defer elements.deinit(self.gpa);
            for (values) |value_id| {
                const value = (try self.analysis_context.lookupCompileTimeValue(value_id)).runtime;
                std.debug.assert(value.type_id == array.element_type);
                try elements.append(self.gpa, .{ .value = try self.appendCompileTimeValue(index, value), .span = nodeFocusSpan(self.ast, index) });
            }
            return self.appendExpression(index, .{ .array_init = .{ .type_id = type_id, .elements = try self.appendArguments(elements.items) } });
        }

        fn collectionExpression(self: *Self, index: structures.Node.Index, elements: structures.FunctionValueRange, sink: UnresolvedBody.LocalId) !ValueId {
            if (self.ast.nodes[index.index()].tag == .tuple_literal) return self.appendExpression(index, .{ .tuple_literal = elements });
            const reads: u32 = @intCast(self.call_arguments.items.len);
            for (elements.start..elements.end) |_| {
                const read = try self.appendExpression(index, .{ .local_read = sink });
                try self.call_arguments.append(self.gpa, .{ .value = read, .span = nodeFocusSpan(self.ast, index) });
            }
            return self.appendExpression(index, .{ .collection_literal = .{ .elements = elements, .sink = sink, .sink_reads = .{ .start = reads, .end = @intCast(self.call_arguments.items.len) } } });
        }

        fn appendCollectionLiteral(self: *Self, index: structures.Node.Index) !ValueId {
            const sink = self.newLocal();
            const previous_sink = self.collection_sink;
            self.collection_sink = sink;
            defer self.collection_sink = previous_sink;
            var elements: std.ArrayList(UnresolvedBody.ValueUse) = .empty;
            defer elements.deinit(self.gpa);
            for (self.ast.nodeList(index)) |element| try self.appendCollectionEntries(element, &elements);
            return self.collectionExpression(index, try self.appendArguments(elements.items), sink);
        }

        fn appendCollectionEntries(self: *Self, index: structures.Node.Index, elements: *std.ArrayList(UnresolvedBody.ValueUse)) anyerror!void {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .collection_for and self.ast.tokens[node.token_index].tag == .keyword_static) {
                const parts = self.ast.nodeList(index);
                var names: std.StringHashMapUnmanaged(void) = .empty;
                defer names.deinit(self.gpa);
                try self.validateStaticPattern(parts[0], &names);
                var bindings = try self.staticClauseBindings();
                defer bindings.deinit(self.gpa);
                const values = (try self.analysis_context.withStaticBindings(bindings.items).staticIteration(index)) orelse return error.Unavailable;
                const mark = self.local_names.items.len;
                const static_mark = self.static_bindings.items.len;
                defer self.restoreStaticScope(mark, static_mark);
                for (values) |value| {
                    try self.bindStaticPattern(parts[0], value);
                    self.analysis_context = self.analysis_context.withStaticBindings(self.static_bindings.items);
                    try self.appendCollectionEntries(parts[2], elements);
                    self.restoreStaticScope(mark, static_mark);
                }
                return;
            }
            if (node.tag == .collection_if and self.ast.tokens[node.token_index].tag == .keyword_static) {
                var bindings = try self.staticClauseBindings();
                defer bindings.deinit(self.gpa);
                const selected = (try self.analysis_context.withStaticBindings(bindings.items).staticCondition(node.data.node_node.a)) orelse return error.Unavailable;
                if (selected) try self.appendCollectionEntries(node.data.node_node.b, elements);
                return;
            }
            const value = switch (node.tag) {
                .collection_for, .collection_if => try self.appendExpression(index, .{ .collection_comprehension = .{ .value = try self.appendCollectionRuntime(index), .span = nodeFocusSpan(self.ast, index) } }),
                .collection_spread => try self.appendExpression(index, .{ .collection_spread = .{
                    .source = try self.appendUse(node.data.node, false),
                    .iteration = .{ .value = try self.appendForParts(index, null, node.data.node, null), .span = nodeFocusSpan(self.ast, index) },
                } }),
                else => try self.append(index, false),
            };
            try elements.append(self.gpa, .{ .value = value, .span = nodeFocusSpan(self.ast, index) });
        }

        fn validateStaticPattern(self: *Self, index: structures.Node.Index, names: *std.StringHashMapUnmanaged(void)) anyerror!void {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .binding_annotation) {
                _ = try self.bindingType(node.data.node_node.b); // Validate the header even when traversal is empty.
                return self.validateStaticPattern(node.data.node_node.a, names);
            }
            if (node.tag == .binding_tuple or node.tag == .binding_sequence) {
                for (self.ast.nodeList(index)) |child| try self.validateStaticPattern(child, names);
                return;
            }
            std.debug.assert(node.tag == .param);
            if (node.data.parameter.access) |mode| {
                if (mode == .keyword_var or mode == .keyword_ref) return self.reject(index, .static_iteration_binding_mode);
            }
            if (node.data.parameter.annotation.unwrap()) |annotation| _ = try self.bindingType(annotation); // Validate the header's annotation.
            const name = tokenText(self.ast, self.source, node.token_index);
            if (std.mem.eql(u8, name, "_")) return;
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            if ((try names.getOrPut(self.gpa, name)).found_existing) return self.reject(index, .duplicate_local_binding);
        }

        fn bindStaticPattern(self: *Self, index: structures.Node.Index, value_id: structures.CompileTimeValueId) anyerror!void {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .binding_annotation) {
                try self.validateStaticPatternType(node.data.node_node.b, value_id);
                return self.bindStaticPattern(node.data.node_node.a, value_id);
            }
            if (node.tag == .param) {
                if (node.data.parameter.annotation.unwrap()) |annotation| try self.validateStaticPatternType(annotation, value_id);
                const name = tokenText(self.ast, self.source, node.token_index);
                if (std.mem.eql(u8, name, "_")) return;
                try self.declare(name, .{ .static_value = value_id });
                try self.static_bindings.append(self.gpa, .{ .name = name, .value = value_id });
                return;
            }
            const value = try self.analysis_context.lookupCompileTimeValue(value_id);
            const tuple = node.tag == .binding_tuple;
            if (tuple and value == .runtime and value.runtime.type_id == .unit and self.ast.nodeList(index).len == 0) return;
            if (value != .runtime) return self.reject(index, if (tuple) .destructure_requires_tuple else .destructure_requires_sequence);
            const valid = if (tuple)
                try self.analysis_context.facts().tupleMembers(value.runtime.type_id) != null
            else
                try self.analysis_context.facts().arrayType(value.runtime.type_id) != null;
            if (!valid) return self.reject(index, if (tuple) .destructure_requires_tuple else .destructure_requires_sequence);
            const children = self.ast.nodeList(index);
            const elements = try self.analysis_context.lookupCompileTimeTuple(value.runtime.value.structure);
            if (elements.len != children.len) return self.reject(index, .{ .destructure_length_mismatch = .{ .expected = @intCast(children.len), .found = @intCast(elements.len) } });
            for (children, elements) |child, element| try self.bindStaticPattern(child, element);
        }

        fn validateStaticPatternType(self: *Self, annotation: structures.Node.Index, value_id: structures.CompileTimeValueId) !void {
            const expected = try self.bindingType(annotation);
            const value = try self.analysis_context.lookupCompileTimeValue(value_id);
            const actual = if (value == .type) structures.TypeId.type else value.runtime.type_id;
            if (!try canWidenTo(self.analysis_context, actual, expected)) return self.reject(annotation, .{ .local_type_mismatch = .{ .expected = expected, .found = actual } });
        }

        fn staticClauseBindings(self: *Self) !std.ArrayList(structures.StaticBinding) {
            var bindings: std.ArrayList(structures.StaticBinding) = .empty;
            errdefer bindings.deinit(self.gpa);
            try bindings.appendSlice(self.gpa, self.static_bindings.items);
            for (self.local_names.items) |name| {
                const local = self.locals.get(name).?;
                if (local == .value or local == .place) try bindings.append(self.gpa, .{ .name = name, .value = null });
            }
            return bindings;
        }

        fn appendCollectionRuntime(self: *Self, index: structures.Node.Index) anyerror!ValueId {
            const node = self.ast.nodes[index.index()];
            if (self.ast.tokens[node.token_index].tag != .keyword_static) switch (node.tag) {
                .collection_for => return self.appendFor(index),
                .collection_if => {
                    const condition = try self.buildBindingCondition(node.data.node_node.a, true);
                    const body = try self.appendCollectionRuntime(node.data.node_node.b);
                    return self.appendExpression(index, .{ .if_else = .{
                        .condition = condition,
                        .then_block = try self.finishBlock(&.{.{ .discard = .{ .value = body, .span = nodeFocusSpan(self.ast, index) } }}, try self.appendExpression(index, .unit), nodeFocusSpan(self.ast, index)),
                        .else_block = try self.buildUnitBranch(index),
                    } });
                },
                else => {},
            };
            var elements: std.ArrayList(UnresolvedBody.ValueUse) = .empty;
            defer elements.deinit(self.gpa);
            try self.appendCollectionEntries(index, &elements);
            var statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer statements.deinit(self.gpa);
            for (elements.items) |element| {
                // Nested comprehensions and spreads emit their own elements.
                const emits = if (self.producer(element.value)) |expression| expression.operation == .collection_comprehension or expression.operation == .collection_spread else false;
                const value = if (emits)
                    element.value
                else
                    try self.appendExpression(index, .{ .collection_emit = .{ .element = element, .sink = .{ .value = try self.appendExpression(index, .{ .local_read = self.collection_sink.? }), .span = element.span } } });
                try statements.append(self.gpa, .{ .discard = .{ .value = value, .span = element.span } });
            }
            return self.appendExpression(index, .{ .scope = try self.finishBlock(statements.items, try self.appendExpression(index, .unit), nodeFocusSpan(self.ast, index)) });
        }

        fn append(self: *Self, index: structures.Node.Index, result_is_type: bool) anyerror!ValueId {
            const node = self.ast.nodes[index.index()];
            switch (node.tag) {
                .number_literal => return self.appendInteger(index, index, false),
                .string_literal => return self.appendString(index),
                .bool_literal => return self.appendExpression(index, .{ .boolean = self.ast.tokens[node.token_index].tag == .keyword_true }),
                .unit_literal => return self.appendExpression(index, if (result_is_type) .{ .type_value = .unit } else .unit),
                .none_literal => return self.appendExpression(index, if (result_is_type) .{ .type_value = .none } else .none),
                .type, .implicit_type, .type_func, .type_variant, .type_tuple, .reference_type => return self.appendTypeValue(index),
                .comptime_expr => return self.appendComptime(index),
                .call => return self.appendCall(index),
                .panic_expr => return self.appendPanic(index),
                .struct_init => return self.appendStructInit(index),
                .collection_literal => return self.appendCollectionLiteral(index),
                .tuple_literal => return if (result_is_type) self.appendTypeValue(index) else self.appendCollectionLiteral(index),
                .field_access => return self.appendFieldAccess(index),
                .index_access => return self.appendExpression(index, .{ .call = try self.buildIndexCall(index) }),
                .@"struct" => return self.appendExpression(index, .{ .type_value = try self.analysis_context.generatedStructType(index) }),
                .identifier => return self.appendIdentifier(index, result_is_type),
                .neg => return self.appendNegation(index),
                .from_end => return self.appendFromEnd(index),
                .add, .sub, .mul, .div, .rem, .shift_left, .shift_right => return self.appendBinary(index),
                .range, .range_inclusive => return self.appendRange(index),
                .eq, .ne, .lt, .gt, .le, .ge, .not, .@"and", .@"or", .is, .membership => return self.appendPredicate(index),
                .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .rem_assign, .shift_left_assign, .shift_right_assign => return self.appendAssignment(index),
                .@"if", .if_else => return self.appendIf(index, result_is_type),
                .match_expr => return self.appendMatch(index, result_is_type),
                .catch_expr, .propagate_expr => return self.appendErrorHandler(index, result_is_type),
                .loop => return self.appendLoop(index, result_is_type),
                .for_loop => return self.appendFor(index),
                .static_binding, .namespace_declaration => return self.reject(index, .nested_declaration_not_supported),
                .move_expr => return self.appendTransfer(index),
                else => return self.reject(index, .expression_not_supported),
            }
        }

        fn appendErrorHandler(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const node = self.ast.nodes[index.index()];
            const parts = if (node.tag == .catch_expr) self.ast.nodeList(index) else &.{node.data.node};
            const operand = try self.appendUse(parts[0], false);
            const carrier = self.newLocal();
            var binding: ?UnresolvedBody.Capture = null;
            var annotation: ?structures.TypeId = null;
            var handler: ?UnresolvedBody.BlockId = null;
            if (node.tag == .catch_expr) {
                const scope_mark = self.local_names.items.len;
                defer self.restoreScope(scope_mark);
                const parameter = self.ast.nodes[parts[1].index()];
                const span = tokenSpan(self.ast, parameter.token_index);
                const name = self.source[span.start..span.end];
                if (parameter.data.parameter.annotation != .null)
                    annotation = try self.analyzeTypeOrReject(parameter.data.parameter.annotation, .local_type_not_supported);
                binding = .{ .local = self.newLocal(), .span = span, .mode = .inferred };
                if (!std.mem.eql(u8, name, "_")) {
                    if (try self.nameIsVisible(name)) return self.rejectIssue(.{ .span = span, .kind = .duplicate_local_binding });
                    try self.declare(name, .{ .place = .{ .id = binding.?.local, .mutable = false } });
                }
                handler = try self.buildBranch(parts[2], result_is_type);
            }
            return self.appendExpression(index, .{ .error_handler = .{
                .operand = operand,
                .carrier = carrier,
                .binding = binding,
                .annotation = annotation,
                .handler = handler,
            } });
        }

        fn appendComptime(self: *Self, index: structures.Node.Index) !ValueId {
            try self.rejectRuntimeCapture(index);
            const value_id = self.analysis_context.executeComptime(index) catch |err| switch (err) {
                error.QueryCycle => return self.reject(index, .declaration_cycle),
                else => return err,
            } orelse return error.Unavailable;
            return self.appendConstant(index, value_id);
        }

        fn appendNegation(self: *Self, index: structures.Node.Index) !ValueId {
            const operand = self.ast.nodes[index.index()].data.node;
            if (self.ast.nodes[operand.index()].tag == .number_literal) return self.appendInteger(index, operand, true);
            return self.appendOperationCall(index, .unary_minus, &.{try self.appendUse(operand, false)});
        }

        fn appendIdentifier(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const name = tokenText(self.ast, self.source, self.ast.nodes[index.index()].token_index);
            for ([_]structures.TypeId{ .int, .byte, .bool, .never, .type }) |primitive| {
                if (std.mem.eql(u8, name, @tagName(primitive))) return self.appendExpression(index, .{ .type_value = primitive });
            }
            if (self.locals.get(name)) |local| return switch (local) {
                .value => |value| value,
                .static_value => |value| self.appendConstant(index, value),
                .runtime_capture => self.reject(index, .comptime_runtime_capture),
                .type_value => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                .place => |place| self.appendExpression(index, .{ .local_read = place.id }),
            };
            if (std.mem.eql(u8, name, "unit")) return self.appendExpression(index, if (result_is_type) .{ .type_value = .unit } else .unit);
            const reference = (try self.namedExpression(index)) orelse return self.reject(index, .unknown_value);
            return self.appendNamedReference(index, reference);
        }

        const FieldPath = struct { root: structures.Node.Index, fields: structures.FunctionValueRange };

        /// Records the fields selected from a place, outermost first, and returns its root.
        fn appendFieldPath(self: *Self, place: structures.Node.Index) !FieldPath {
            const start: u32 = @intCast(self.assignment_fields.items.len);
            var root = place;
            while (self.ast.nodes[root.index()].tag == .field_access) {
                const field = self.ast.nodes[root.index()];
                const span = tokenSpan(self.ast, field.token_index);
                try self.assignment_fields.append(self.gpa, .{ .name = self.source[span.start..span.end], .span = span });
                root = field.data.node;
            }
            std.mem.reverse(UnresolvedBody.FieldName, self.assignment_fields.items[start..]);
            return .{ .root = root, .fields = .{ .start = start, .end = @intCast(self.assignment_fields.items.len) } };
        }

        fn appendTransfer(self: *Self, index: structures.Node.Index) !ValueId {
            const path = try self.appendFieldPath(self.ast.nodes[index.index()].data.node);
            const root = self.ast.nodes[path.root.index()];
            if (root.tag != .identifier) return self.reject(index, .ownership_transfer_requires_place);
            const local = self.locals.get(tokenText(self.ast, self.source, root.token_index)) orelse return self.reject(path.root, .unknown_value);
            return switch (local) {
                .runtime_capture => self.reject(path.root, .comptime_runtime_capture),
                .value, .static_value, .type_value => self.reject(index, .ownership_transfer_requires_owned_place),
                .place => |place| self.appendExpression(index, if (path.fields.start == path.fields.end)
                    .{ .local_transfer = place.id }
                else
                    .{ .field_transfer = .{ .target = place.id, .fields = path.fields } }),
            };
        }

        fn appendStructInit(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const parts = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
            std.debug.assert(parts.len >= 1);
            if (runtimeReference(self.ast, self.source, parts[0], self)) |reference| return self.reject(reference, .value_used_as_type);
            const target: UnresolvedBody.StructInitTarget = target_blk: {
                if (try self.namedExpression(parts[0])) |reference| {
                    if (reference == .declaration and try self.analysis_context.isGenericStruct(reference.declaration.item))
                        break :target_blk .{ .inferred = reference.declaration };
                }
                break :target_blk .{ .concrete = try self.analyzeTypeOrReject(parts[0], .local_type_not_supported) };
            };
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            for (parts[1..]) |field_index| {
                const field = self.ast.nodes[field_index.index()];
                std.debug.assert(field.tag == .struct_init_field);
                try self.scratch.append(self.gpa, try self.appendUse(field.data.node, false));
            }
            const start: u32 = @intCast(self.struct_field_values.items.len);
            for (parts[1..], self.scratch.items[scratch_start..]) |field_index, value| {
                const name_span = tokenSpan(self.ast, self.ast.nodes[field_index.index()].token_index);
                try self.struct_field_values.append(self.gpa, .{ .name = self.source[name_span.start..name_span.end], .name_span = name_span, .value = value });
            }
            return self.appendExpression(index, .{ .struct_init = .{
                .target = target,
                .type_span = nodeFocusSpan(self.ast, parts[0]),
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
            } });
        }

        fn namedExpression(self: *Self, index: structures.Node.Index) !?structures.NameReference {
            return self.namedExpressionWithOperands(index, null);
        }

        fn namedExpressionWithOperands(self: *Self, index: structures.Node.Index, operands: ?usize) !?structures.NameReference {
            if (runtimeReference(self.ast, self.source, index, self) != null) return null;
            return resolveNamedExpressionWithOperands(self.ast, self.source, index, self.analysis_context, operands) catch |err|
                return self.reject(index, nameResolutionIssue(err) orelse return err);
        }

        fn runtimeName(self: *Self, name: []const u8) bool {
            const local = self.locals.get(name) orelse return false;
            return local == .value or local == .place or local == .runtime_capture;
        }

        fn rejectRuntimeCapture(self: *Self, index: structures.Node.Index) !void {
            if (runtimeReference(self.ast, self.source, index, self)) |reference|
                return self.reject(reference, .comptime_runtime_capture);
        }

        fn appendNamedReference(self: *Self, index: structures.Node.Index, reference: structures.NameReference) !ValueId {
            switch (reference) {
                .namespace => return self.reject(index, .namespace_used_as_value),
                .constant => |value| return self.appendConstant(index, value),
                .declaration => |instance| return self.appendDeclarationReference(index, instance),
                .overloaded_function => |choices| return self.appendExpression(index, .{ .overloaded_function = choices }),
            }
        }

        fn appendDeclarationReference(self: *Self, index: structures.Node.Index, instance: structures.InstanceId) !ValueId {
            if (try self.analysis_context.functionShape(instance.item)) |shape| {
                for (shape.parameters) |parameter| {
                    if (parameter.mode == .static) return self.reject(index, .static_parameter_requires_specialization);
                }
                const function = (try self.analysis_context.functionItemReference(instance)) orelse return self.reject(index, .unknown_value);
                return self.appendExpression(index, .{ .function_ref = function });
            }
            const value = (self.analysis_context.staticItem(instance) catch |err| switch (err) {
                error.QueryCycle => return self.reject(index, .declaration_cycle),
                else => return err,
            }) orelse return self.reject(index, .unknown_value);
            return self.appendConstant(index, value);
        }

        fn appendConstant(self: *Self, index: structures.Node.Index, value: structures.CompileTimeValueId) !ValueId {
            return switch (try self.analysis_context.lookupCompileTimeValue(value)) {
                .type => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                .runtime => |runtime| self.appendCompileTimeValue(index, runtime),
            };
        }

        fn appendFieldAccess(self: *Self, index: structures.Node.Index) !ValueId {
            if (try self.namedExpression(index)) |reference| return self.appendNamedReference(index, reference);
            const node = self.ast.nodes[index.index()];
            return self.appendExpression(index, .{ .field_access = .{
                .operand = try self.appendUse(node.data.node, false),
                .name = tokenText(self.ast, self.source, node.token_index),
            } });
        }

        fn appendUse(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.ValueUse {
            return .{
                .value = try self.append(index, result_is_type),
                .span = nodeFocusSpan(self.ast, index),
            };
        }

        fn appendLoop(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const node = self.ast.nodes[index.index()];
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            const body = try self.buildBranch(node.data.node, result_is_type);
            return self.appendExpression(index, .{ .loop = body });
        }

        fn appendFor(self: *Self, index: structures.Node.Index) !ValueId {
            const parts = self.ast.nodeList(index);
            std.debug.assert(parts.len == 3);
            return self.appendForParts(index, parts[0], parts[1], parts[2]);
        }

        fn appendForParts(self: *Self, index: structures.Node.Index, binding_index: ?structures.Node.Index, source_index: structures.Node.Index, body_index: ?structures.Node.Index) !ValueId {
            const binding = if (binding_index) |item| self.ast.nodes[item.index()] else structures.Node{ .tag = .param, .token_index = self.ast.nodes[index.index()].token_index, .data = .{ .parameter = .{} } };
            const pattern_binding = binding.tag != .param;
            const destructuring = pattern_binding and !(self.static_iteration and body_index == null);
            const mode = if (pattern_binding) null else binding.data.parameter.access;
            const name_span = tokenSpan(self.ast, binding.token_index);
            const name = if (pattern_binding or binding_index == null) "$spread" else self.source[name_span.start..name_span.end];
            if (!std.mem.eql(u8, name, "_") and try self.nameIsVisible(name)) return self.reject(binding_index.?, .duplicate_local_binding);
            const scope_mark = self.local_names.items.len;
            defer self.restoreScope(scope_mark);
            const span = nodeFocusSpan(self.ast, index);
            const source = try self.appendUse(source_index, false);
            const source_local = self.newLocal();
            const source_read = try self.appendExpression(index, .{ .local_read = source_local });
            const cursor = try self.appendExpression(index, .{ .iterator = .{ .source = .{ .value = source_read, .span = source.span }, .acquisition = source.value, .structural_array = self.ast.nodes[index.index()].tag == .collection_spread } });
            const cursor_local = self.newLocal();
            const cursor_read = try self.appendExpression(index, .{ .local_read = cursor_local });
            const receiver: UnresolvedBody.ValueUse = .{ .value = cursor_read, .span = source.span };
            const end_type = try self.analysis_context.iterationEndType();
            const next = try self.appendProtocolCall(index, receiver, "next");
            const next_local = self.newLocal();
            const next_read = try self.appendExpression(index, .{ .local_read = next_local });
            const poll: UnresolvedBody.ValueUse = .{ .value = next_read, .span = span };
            const condition = try self.appendExpression(index, .{ .iterator_membership = .{ .operand = poll, .end_type = end_type } });
            const item_local = self.newLocal();
            const item_mode: UnresolvedBody.BindingMode = if (mode == .keyword_ref) .reference else if (mode == null) .inferred else .owned;
            var item = try self.appendExpression(index, .{ .iterator_item = .{
                .carrier = next_local,
                .operand = poll,
                .end_type = end_type,
                .binding = .{ .local = item_local, .span = name_span, .mode = item_mode },
            } });
            if (!pattern_binding and binding.data.parameter.annotation != .null) {
                const annotation = binding.data.parameter.annotation;
                item = try self.appendExpression(annotation, .{ .annotation = .{
                    .value = .{ .value = item, .span = span },
                    .type_id = try self.bindingType(annotation),
                } });
            }
            const pattern = if (destructuring) try self.buildBindingPattern(binding_index.?, item_local) else null;
            if (!pattern_binding and !std.mem.eql(u8, name, "_"))
                try self.declare(name, .{ .place = .{ .id = item_local, .mutable = mode == .keyword_var or mode == .keyword_ref } });
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            const user_body = if (body_index) |body|
                if (self.ast.nodes[index.index()].tag == .collection_for)
                    try self.finishBlock(&.{.{ .discard = .{ .value = try self.appendCollectionRuntime(body), .span = span } }}, try self.appendExpression(index, .unit), span)
                else
                    try self.buildBranch(body, false)
            else
                try self.collectionPollBody(index, item_local, span);
            self.restoreScope(scope_mark);
            const body_value = try self.appendExpression(index, .{ .scope = user_body });
            const success_unit = try self.appendExpression(index, .unit);
            const success = try self.finishBlock(&.{
                if (pattern) |pattern_id|
                    .{ .bind_pattern = .{ .pattern = pattern_id, .value = item, .span = name_span } }
                else
                    .{ .bind_local = .{
                        .local = item_local,
                        .value = item,
                        .span = name_span,
                        .mutable = mode == .keyword_var,
                        .mode = item_mode,
                    } },
                .{ .discard = .{ .value = body_value, .span = span } },
            }, success_unit, span);
            const unit = try self.appendExpression(index, .unit);
            const exhausted = try self.finishBlock(&.{.{ .break_loop = unit }}, null, span);
            const dispatch = try self.appendExpression(index, .{ .if_else = .{ .condition = .{ .value = condition, .span = span }, .then_block = success, .else_block = exhausted } });
            const body_unit = try self.appendExpression(index, .unit);
            const body = try self.finishBlock(&.{
                .{ .bind_local = .{ .local = next_local, .value = next, .span = span, .mutable = true, .mode = .inferred } },
                .{ .discard = .{ .value = dispatch, .span = span } },
            }, body_unit, span);
            const loop_value = try self.appendExpression(index, .{ .loop = body });
            const setup = try self.finishBlock(&.{
                .{ .bind_local = .{ .local = source_local, .value = source.value, .span = source.span, .mutable = true, .mode = .inferred } },
                .{ .bind_local = .{ .local = cursor_local, .value = cursor, .span = source.span, .mutable = true, .mode = .inferred } },
            }, loop_value, span);
            const setup_value = try self.appendExpression(index, .{ .scope = setup });
            if (!self.static_iteration and (self.ast.nodes[index.index()].tag == .collection_for or self.ast.nodes[index.index()].tag == .collection_spread))
                return self.appendExpression(index, .{ .collection_iteration = .{ .source = source, .body = .{ .value = setup_value, .span = span } } });
            return setup_value;
        }

        fn collectionPollBody(self: *Self, index: structures.Node.Index, item_local: UnresolvedBody.LocalId, span: structures.SourceSpan) !UnresolvedBody.BlockId {
            const item = try self.appendExpression(index, .{ .local_read = item_local });
            var output: ValueId = undefined;
            if (self.static_iteration) {
                const capture = (try self.analysis_context.stdMemoryFunction("static_iteration_item")) orelse return error.Unavailable;
                const arguments = try self.appendArguments(&.{.{ .value = item, .span = span }});
                output = try self.appendExpression(index, .{ .call = .{ .target = .{ .inferred = .{ .item = capture } }, .arguments = arguments, .span = span } });
            } else {
                const sink = try self.appendExpression(index, .{ .local_read = self.collection_sink.? });
                output = try self.appendExpression(index, .{ .collection_emit = .{ .element = .{ .value = item, .span = span }, .sink = .{ .value = sink, .span = span } } });
            }
            return self.finishBlock(&.{.{ .discard = .{ .value = output, .span = span } }}, try self.appendExpression(index, .unit), span);
        }

        fn newLocal(self: *Self) UnresolvedBody.LocalId {
            const local: UnresolvedBody.LocalId = @fromBackingInt(self.local_count);
            self.local_count += 1;
            return local;
        }

        fn appendArguments(self: *Self, arguments: []const UnresolvedBody.ValueUse) !structures.FunctionValueRange {
            const start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.appendSlice(self.gpa, arguments);
            return .{ .start = start, .end = @intCast(self.call_arguments.items.len) };
        }

        /// The expression producing `value`, or null for a parameter value.
        fn producer(self: *Self, value: ValueId) ?*UnresolvedBody.Expression {
            const index = @backingInt(value);
            if (index < self.parameters.len) return null;
            return &self.expressions.items[index - self.parameters.len];
        }

        fn appendProtocolCall(self: *Self, index: structures.Node.Index, receiver: UnresolvedBody.ValueUse, name: []const u8) !ValueId {
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .member = .{ .receiver = receiver, .name = name } },
                .arguments = .{ .start = 0, .end = 0 },
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn appendString(self: *Self, index: structures.Node.Index) !ValueId {
            const span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index);
            switch (try text_literal.decode(self.gpa, self.source[span.start..span.end])) {
                .bytes => |bytes| {
                    defer self.gpa.free(bytes);
                    return self.appendExpression(index, .{ .string_literal = try self.analysis_context.internByteString(bytes) });
                },
                .invalid => |issue| return self.rejectIssue(.{ .span = .{ .start = span.start + issue.offset, .end = span.start + issue.offset + 1 }, .kind = issue.kind }),
            }
        }

        fn appendInteger(self: *Self, index: structures.Node.Index, literal: structures.Node.Index, negative: bool) !ValueId {
            return switch (parseIntegerLiteral(tokenText(self.ast, self.source, self.ast.nodes[literal.index()].token_index), negative)) {
                .value => |value| self.appendExpression(index, .{ .integer_literal = value }),
                .unsupported => |kind| self.reject(index, kind),
            };
        }

        fn appendBinary(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const lhs = try self.appendUse(node.data.node_node.a, false);
            const rhs = try self.appendUse(node.data.node_node.b, false);
            return self.appendOperationCall(index, arithmeticOperation(node.tag), &.{ lhs, rhs });
        }

        fn appendRange(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const constructor = (try self.analysis_context.rangeConstructor(node.tag == .range_inclusive)) orelse return error.Unavailable;
            const first = try self.appendUse(node.data.node_node.a, false);
            const limit = try self.appendUse(node.data.node_node.b, false);
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .direct = .{ .item = constructor } },
                .arguments = try self.appendArguments(&.{ first, limit }),
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn appendFromEnd(self: *Self, index: structures.Node.Index) !ValueId {
            const constructor = (try self.analysis_context.fromEndConstructor()) orelse return error.Unavailable;
            const distance = try self.appendUse(self.ast.nodes[index.index()].data.node, false);
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .direct = .{ .item = constructor } },
                .arguments = try self.appendArguments(&.{distance}),
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn appendPanic(self: *Self, index: structures.Node.Index) !ValueId {
            const message_node = self.ast.nodes[index.index()].data.node;
            const message = if (message_node != .null)
                try self.appendUse(message_node, false)
            else
                UnresolvedBody.ValueUse{ .value = try self.appendExpression(index, .{ .string_literal = try self.analysis_context.internByteString("") }), .span = nodeFocusSpan(self.ast, index) };
            const target = (try self.analysis_context.panicFunction()) orelse return error.Unavailable;
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .direct = .{ .item = target } },
                .arguments = try self.appendArguments(&.{message}),
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn appendOperationCall(self: *Self, index: structures.Node.Index, name: structures.Operation, operands: []const UnresolvedBody.ValueUse) !ValueId {
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .operation = name },
                .arguments = try self.appendArguments(operands),
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn buildIndexCall(self: *Self, index: structures.Node.Index) !UnresolvedBody.Call {
            const node = self.ast.nodes[index.index()];
            const receiver = try self.appendUse(node.data.node_node.a, false);
            const offset = try self.appendIndexOffset(node.data.node_node.b);
            return .{ .target = .{ .operation = .@"[]" }, .arguments = try self.appendArguments(&.{ receiver, offset }), .span = nodeFocusSpan(self.ast, index) };
        }

        fn appendIndexOffset(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            return .{ .value = try self.appendExpression(index, .{ .index_snapshot = try self.appendUse(index, false) }), .span = nodeFocusSpan(self.ast, index) };
        }

        fn appendAssignment(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .assign and self.isDiscardAssignment(index))
                return self.appendExpression(index, .{ .discard = try self.appendUse(node.data.node_node.b, false) });
            const target_node_value = self.ast.nodes[node.data.node_node.a.index()];
            if (target_node_value.tag == .index_access) {
                const receiver = try self.appendUse(target_node_value.data.node_node.a, false);
                const offset = try self.appendIndexOffset(target_node_value.data.node_node.b);
                var value = try self.appendUse(node.data.node_node.b, false);
                var old: ?UnresolvedBody.ValueUse = null;
                if (node.tag != .assign) {
                    old = .{ .value = try self.appendOperationCall(index, .@"[]", &.{ receiver, offset }), .span = nodeFocusSpan(self.ast, index) };
                    value.value = try self.appendOperationCall(index, arithmeticOperation(node.tag), &.{ old.?, value });
                }
                const setter = try self.appendOperationCall(index, .@"[]=", &.{ receiver, offset, value });
                return if (old) |previous| self.appendExpression(index, .{ .sequence = .{
                    .lhs = previous,
                    .rhs = .{ .value = setter, .span = nodeFocusSpan(self.ast, index) },
                } }) else setter;
            }
            const path = try self.appendFieldPath(node.data.node_node.a);
            const target_node = self.ast.nodes[path.root.index()];
            if (target_node.tag != .identifier) return self.appendReferenceAssignment(index);
            const span = tokenSpan(self.ast, target_node.token_index);
            const local = self.locals.get(self.source[span.start..span.end]) orelse return self.reject(path.root, .unknown_value);
            const writable: ?UnresolvedBody.LocalId = switch (local) {
                .runtime_capture => return self.reject(path.root, .comptime_runtime_capture),
                .static_value, .type_value => return self.reject(path.root, .assignment_to_immutable),
                .value => null,
                .place => |place| if (place.mutable) place.id else null,
            };
            // Fields of immutable bindings may still be assigned through references.
            const target = writable orelse return if (path.fields.start != path.fields.end)
                self.appendReferenceAssignment(index)
            else
                self.reject(path.root, .assignment_to_immutable);
            const value = try self.assignmentOperand(index);
            return self.appendExpression(index, .{ .assignment = .{
                .target = target,
                .target_span = span,
                .fields = path.fields,
                .value = value,
                .replaces = node.tag == .assign,
            } });
        }

        fn appendReferenceAssignment(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const reference = try self.appendUse(node.data.node_node.a, false);
            var value = try self.appendUse(node.data.node_node.b, false);
            if (node.tag != .assign) value.value = try self.appendOperationCall(index, arithmeticOperation(node.tag), &.{ reference, value });
            const fields: u32 = @intCast(self.assignment_fields.items.len);
            return self.appendExpression(index, .{ .reference_assignment = .{
                .reference = reference,
                .fields = .{ .start = fields, .end = fields },
                .value = value,
            } });
        }

        fn arithmeticOperation(tag: structures.Node.Tag) structures.Operation {
            return switch (tag) {
                .add, .add_assign => .@"+",
                .sub, .sub_assign => .@"-",
                .mul, .mul_assign => .@"*",
                .div, .div_assign => .@"/",
                .rem, .rem_assign => .@"%",
                .shift_left, .shift_left_assign => .@"<<",
                .shift_right, .shift_right_assign => .@">>",
                else => unreachable,
            };
        }

        fn assignmentOperand(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            const node = self.ast.nodes[index.index()];
            var value = try self.appendUse(node.data.node_node.b, false);
            if (node.tag != .assign) value.value = try self.appendOperationCall(index, arithmeticOperation(node.tag), &.{
                try self.appendUse(node.data.node_node.a, false), value,
            });
            return value;
        }

        fn appendIf(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const node = self.ast.nodes[index.index()];
            const condition_index, const then_index, const else_index = switch (node.tag) {
                .@"if" => .{ node.data.node_node.a, node.data.node_node.b, @as(?structures.Node.Index, null) },
                .if_else => blk: {
                    const parts = self.ast.nodeList(index);
                    std.debug.assert(parts.len == 3);
                    break :blk .{ parts[0], parts[1], parts[2] };
                },
                else => unreachable,
            };
            const condition_scope = self.local_names.items.len;
            defer self.restoreScope(condition_scope);
            const condition = try self.buildIfCondition(condition_index);
            const then_block = try self.buildBranch(then_index, result_is_type);
            self.restoreScope(condition_scope);
            const else_block = if (else_index) |explicit_else|
                try self.buildBranch(explicit_else, result_is_type)
            else
                try self.buildUnitBranch(index);
            return self.appendExpression(index, .{ .if_else = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            } });
        }

        fn buildConditionalBinding(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            // The mismatch branch cannot see names introduced by the pattern.
            const otherwise = try self.buildBranch(node.data.node_node.b, false);
            const condition = try self.buildBindingCondition(node.data.node_node.a, true);
            return .{ .bind_conditional = .{ .condition = condition, .otherwise = otherwise, .span = nodeFocusSpan(self.ast, index) } };
        }

        fn buildIfCondition(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            return self.buildBindingCondition(index, false);
        }

        fn buildBindingCondition(self: *Self, index: structures.Node.Index, allow_mutable: bool) !UnresolvedBody.ValueUse {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .destructure_binding) {
                const first_pattern = self.binding_patterns.items.len;
                const statement = try self.buildPatternBinding(index, true);
                for (self.binding_patterns.items[first_pattern..]) |pattern| {
                    if (!allow_mutable and pattern.shape == .name and pattern.shape.name.mutable) return self.reject(index, .condition_binding_must_be_immutable);
                }
                return .{ .value = try self.appendExpression(index, .{ .pattern_test = statement.bind_pattern }), .span = nodeFocusSpan(self.ast, index) };
            }
            return self.appendUse(index, false);
        }

        fn appendMatch(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const parts = self.ast.nodeList(index);
            std.debug.assert(parts.len >= 2);
            const subject = try self.appendUse(parts[0], false);
            const carrier = self.newLocal();
            const read = try self.appendExpression(index, .{ .local_read = carrier });
            var arms: std.ArrayList(UnresolvedBody.MatchArm) = .empty;
            defer arms.deinit(self.gpa);
            const scope = self.local_names.items.len;
            defer self.restoreScope(scope);
            for (parts[1..]) |arm_index| {
                const arm = self.ast.nodes[arm_index.index()];
                var pattern_index = arm.data.node_node.a;
                var condition_index: ?structures.Node.Index = null;
                if (self.ast.nodes[pattern_index.index()].tag == .match_guard) {
                    const header = self.ast.nodes[pattern_index.index()];
                    pattern_index = header.data.node_node.a;
                    condition_index = header.data.node_node.b;
                }
                const pattern = try self.buildMatchPattern(pattern_index);
                try self.declareMatchCaptures(pattern);
                const condition = if (condition_index) |guard| try self.appendUse(guard, false) else null;
                try arms.append(self.gpa, .{
                    .pattern = pattern,
                    .condition = condition,
                    .body = try self.buildBranch(arm.data.node_node.b, result_is_type),
                    .span = nodeFocusSpan(self.ast, arm_index),
                });
                self.restoreScope(scope);
            }
            const start: u32 = @intCast(self.match_arms.items.len);
            try self.match_arms.appendSlice(self.gpa, arms.items);
            return self.appendExpression(index, .{ .match = .{
                .subject = subject,
                .carrier = carrier,
                .read = read,
                .arms = .{ .start = start, .end = @intCast(self.match_arms.items.len) },
            } });
        }

        fn buildMatchPattern(self: *Self, index: structures.Node.Index) anyerror!u32 {
            const node = self.ast.nodes[index.index()];
            const carrier = self.newLocal();
            var pattern: UnresolvedBody.MatchPattern = .{
                .shape = undefined,
                .carrier = carrier,
                .read = try self.appendExpression(index, .{ .local_read = carrier }),
                .span = nodeFocusSpan(self.ast, index),
            };
            switch (node.tag) {
                .type => {
                    if (try self.matchNameIsType(index)) {
                        pattern.shape = .{ .type = try self.bindingType(index) };
                    } else self.buildMatchCapture(index, &pattern);
                },
                .param => {
                    self.buildMatchCapture(index, &pattern);
                    std.debug.assert(node.data.parameter.annotation == .null);
                },
                .field_access, .call, .type_variant, .type_func => pattern.shape = .{ .type = try self.bindingType(index) },
                .range, .range_inclusive => pattern.shape = .{ .range = try self.buildMatchRange(index) },
                .match_tuple => pattern.shape = .{ .tuple = try self.buildMatchTuple(index) },
                else => pattern.shape = .{ .literal = try self.appendUse(index, false) },
            }
            const result: u32 = @intCast(self.match_patterns.items.len);
            try self.match_patterns.append(self.gpa, pattern);
            return result;
        }

        fn buildMatchRange(self: *Self, index: structures.Node.Index) !UnresolvedBody.MatchInterval {
            const node = self.ast.nodes[index.index()];
            const first = (try self.matchRangeBound(node.data.node_node.a)) orelse std.math.minInt(i64);
            const limit = try self.matchRangeBound(node.data.node_node.b);
            var last = limit orelse std.math.maxInt(i64);
            if (node.tag == .range and limit != null) {
                if (last == std.math.minInt(i64)) return self.reject(index, .match_range_empty);
                last -= 1;
            }
            if (first > last) return self.reject(index, .match_range_empty);
            return .{ .first = first, .last = last };
        }

        fn matchRangeBound(self: *Self, index: structures.Node.Index) !?i64 {
            if (self.ast.nodes[index.index()].tag == .none_literal) return null;
            if (integerLiteralValue(self.ast, self.source, index)) |integer| return integer;
            try self.rejectRuntimeCapture(index);
            const value_id = self.analysis_context.executeComptime(index) catch |err| switch (err) {
                error.QueryCycle => return self.reject(index, .declaration_cycle),
                else => return err,
            } orelse return error.Unavailable;
            const constant = try self.analysis_context.lookupCompileTimeValue(value_id);
            if (constant == .runtime) switch (constant.runtime.value) {
                .int => |integer| return integer,
                .int_literal => |integer| return integer,
                .byte => |byte| return byte,
                .none => return null,
                else => {},
            };
            return self.reject(index, .match_range_bound_not_integer);
        }

        fn matchNameIsType(self: *Self, index: structures.Node.Index) !bool {
            const name = tokenText(self.ast, self.source, self.ast.nodes[index.index()].token_index);
            if (std.mem.eql(u8, name, "_")) return false;
            if (self.locals.get(name)) |local| return switch (local) {
                .type_value => true,
                .static_value => |value| (try self.analysis_context.lookupCompileTimeValue(value)) == .type,
                .value, .place, .runtime_capture => false,
            };
            const reference = (try self.namedExpression(index)) orelse return false;
            const value = switch (reference) {
                .constant => |value| value,
                .declaration => |instance| (self.analysis_context.staticItem(instance) catch |err| switch (err) {
                    error.QueryCycle => return self.reject(index, .declaration_cycle),
                    else => return err,
                }) orelse return false,
                .namespace, .overloaded_function => return false,
            };
            return (try self.analysis_context.lookupCompileTimeValue(value)) == .type;
        }

        fn buildMatchCapture(self: *Self, index: structures.Node.Index, pattern: *UnresolvedBody.MatchPattern) void {
            const node = self.ast.nodes[index.index()];
            const name = tokenText(self.ast, self.source, node.token_index);
            pattern.shape = .any;
            if (std.mem.eql(u8, name, "_")) return;
            const reference = node.tag == .param and node.data.parameter.access == .keyword_ref;
            pattern.binding = .{ .local = self.newLocal(), .span = tokenSpan(self.ast, node.token_index), .mode = if (reference) .reference else .owned };
        }

        fn declareMatchCaptures(self: *Self, id: u32) anyerror!void {
            const pattern = self.match_patterns.items[id];
            if (pattern.binding) |binding| {
                const name = self.source[binding.span.start..binding.span.end];
                if (try self.nameIsVisible(name)) return self.rejectIssue(.{ .span = binding.span, .kind = .duplicate_local_binding });
                try self.declare(name, .{ .place = .{ .id = binding.local, .mutable = binding.mode == .reference } });
            }
            if (pattern.shape == .tuple) for (self.match_pattern_children.items[pattern.shape.tuple.start..pattern.shape.tuple.end]) |child|
                try self.declareMatchCaptures(child);
        }

        fn buildMatchTuple(self: *Self, index: structures.Node.Index) anyerror!structures.FunctionValueRange {
            var children: std.ArrayList(u32) = .empty;
            defer children.deinit(self.gpa);
            for (self.ast.nodeList(index)) |child|
                try children.append(self.gpa, try self.buildMatchPattern(child));
            const start: u32 = @intCast(self.match_pattern_children.items.len);
            try self.match_pattern_children.appendSlice(self.gpa, children.items);
            return .{ .start = start, .end = @intCast(self.match_pattern_children.items.len) };
        }

        fn appendPredicate(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueId {
            const node = self.ast.nodes[index.index()];
            return switch (node.tag) {
                .lt, .gt, .le, .ge, .eq, .ne => self.appendExpression(index, .{ .comparison = .{
                    .operation = comparisonOperation(node.tag),
                    .operands = .{
                        .lhs = try self.appendUse(node.data.node_node.a, false),
                        .rhs = try self.appendUse(node.data.node_node.b, false),
                    },
                } }),
                .membership => self.appendExpression(index, .{ .call = .{
                    .target = .{ .membership = .{
                        .lhs = try self.appendUse(node.data.node_node.a, false),
                        .rhs = try self.appendUse(node.data.node_node.b, false),
                    } },
                    .arguments = .{ .start = 0, .end = 0 },
                    .span = nodeFocusSpan(self.ast, index),
                } }),
                .is => self.buildVariantMembership(index),
                .@"and", .@"or" => {
                    const lhs = try self.appendUse(node.data.node_node.a, false);
                    const rhs = try self.appendUse(node.data.node_node.b, false);
                    return self.appendExpression(index, if (node.tag == .@"and")
                        .{ .conjunction = .{ .lhs = lhs, .rhs = rhs } }
                    else
                        .{ .disjunction = .{ .lhs = lhs, .rhs = rhs } });
                },
                .not => self.appendExpression(index, .{ .negation = try self.appendUse(node.data.node, false) }),
                else => unreachable,
            };
        }

        fn buildVariantMembership(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueId {
            const node = self.ast.nodes[index.index()];
            const target_type = try self.analyzeTypeOrReject(node.data.node_node.b, .inspection_type_not_supported);
            if (self.where_condition and node.tag == .is) return self.appendExpression(index, .{ .static_membership = .{
                .operand = node.data.node_node.a,
                .target_type = target_type,
            } });
            return self.appendExpression(index, .{ .variant_membership = .{
                .operand = try self.appendUse(node.data.node_node.a, false),
                .target_type = target_type,
            } });
        }

        fn comparisonOperation(tag: structures.Node.Tag) structures.Operation {
            return switch (tag) {
                .eq => .@"==",
                .ne => .@"<>",
                .lt => .@"<",
                .gt => .@">",
                .le => .@"<=",
                .ge => .@">=",
                else => unreachable,
            };
        }

        fn buildBranch(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.BlockId {
            const scope_mark = self.local_names.items.len;
            defer self.restoreScope(scope_mark);

            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            if (node.tag != .block) {
                if (isTerminator(node.tag)) return self.finishBlock(&.{try self.buildStatement(index, result_is_type)}, null, span);
                return self.finishBlock(&.{}, try self.append(index, result_is_type), span);
            }

            const children = self.ast.nodeList(index);
            if (children.len == 0) return self.buildUnitBranch(index);

            var statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer statements.deinit(self.gpa);
            for (children[0 .. children.len - 1]) |statement| try statements.append(self.gpa, try self.buildStatement(statement, false));
            const last = children[children.len - 1];
            const last_tag = self.ast.nodes[last.index()].tag;
            if (last_tag != .const_binding and last_tag != .var_binding and last_tag != .ref_binding and last_tag != .destructure_binding and last_tag != .binding_else and !isTerminator(last_tag))
                return self.finishBlock(statements.items, try self.append(last, result_is_type), span);
            try statements.append(self.gpa, try self.buildStatement(last, result_is_type));
            // A trailing binding yields unit; a terminator leaves the block without a result.
            const result = if (isTerminator(last_tag)) null else try self.appendExpression(index, .unit);
            return self.finishBlock(statements.items, result, span);
        }

        fn buildUnitBranch(self: *Self, index: structures.Node.Index) !UnresolvedBody.BlockId {
            return self.finishBlock(&.{}, try self.appendExpression(index, .unit), tokenSpan(self.ast, self.ast.nodes[index.index()].token_index));
        }

        fn finishBlock(
            self: *Self,
            pending: []const UnresolvedBody.Statement,
            result: ?ValueId,
            span: structures.SourceSpan,
        ) !UnresolvedBody.BlockId {
            const start: u32 = @intCast(self.statements.items.len);
            try self.statements.appendSlice(self.gpa, pending);
            const id: UnresolvedBody.BlockId = @fromBackingInt(@intCast(self.blocks.items.len));
            try self.blocks.append(self.gpa, .{
                .statements = .{ .start = start, .end = @intCast(self.statements.items.len) },
                .result = result,
                .span = span,
            });
            return id;
        }

        fn restoreScope(self: *Self, mark: usize) void {
            while (self.local_names.items.len > mark) {
                const name = self.local_names.pop().?;
                std.debug.assert(self.locals.remove(name));
            }
        }

        fn restoreStaticScope(self: *Self, mark: usize, static_mark: usize) void {
            self.restoreScope(mark);
            self.static_bindings.shrinkRetainingCapacity(static_mark);
            self.analysis_context = self.analysis_context.withStaticBindings(self.static_bindings.items);
        }

        fn appendCall(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const operation: UnresolvedBody.Expression.Operation = if (try self.conversionTarget(node.data.node_node.a)) |target| operation: {
                const arguments = self.ast.nodeList(node.data.node_node.b);
                if (arguments.len != 1) return self.reject(index, .{ .call_argument_count_mismatch = .{ .expected = 1, .found = @intCast(arguments.len) } });
                break :operation .{ .annotation = .{ .value = try self.appendUse(arguments[0], false), .type_id = target, .explicit = true } };
            } else .{ .call = try self.buildCall(index) };
            const result = try self.appendExpression(node.data.node_node.a, operation);
            self.producer(result).?.source_node = index;
            return result;
        }

        fn conversionTarget(self: *Self, index: structures.Node.Index) !?structures.TypeId {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .identifier) {
                const name = tokenText(self.ast, self.source, node.token_index);
                if (std.meta.stringToEnum(structures.TypeId, name)) |primitive| return primitive;
                if (self.locals.get(name)) |local| {
                    return if (local == .type_value) local.type_value else null;
                }
            }
            const reference = (try self.namedExpression(index)) orelse return null;
            const value_id = switch (reference) {
                .namespace, .overloaded_function => return null,
                .constant => |value| value,
                .declaration => |instance| blk: {
                    if (try self.analysis_context.functionShape(instance.item) != null) return null;
                    break :blk (try self.analysis_context.staticItem(instance)) orelse return null;
                },
            };
            const value = try self.analysis_context.lookupCompileTimeValue(value_id);
            return if (value == .type) value.type else null;
        }

        fn buildCall(self: *Self, index: structures.Node.Index) !UnresolvedBody.Call {
            const node = self.ast.nodes[index.index()];
            const callee_index = node.data.node_node.a;
            const callee = self.ast.nodes[callee_index.index()];
            const argument_nodes = self.ast.nodeList(node.data.node_node.b);
            const span = nodeFocusSpan(self.ast, callee_index);
            const PendingTarget = union(enum) {
                direct: struct { instance: structures.InstanceId, shape: structures.FunctionShape },
                resolved: UnresolvedBody.Call.Target,
            };
            const pending_target: PendingTarget = target: {
                if (try self.namedExpressionWithOperands(callee_index, argument_nodes.len)) |reference| {
                    if (reference == .overloaded_function) return .{
                        .target = .{ .overloaded = reference.overloaded_function },
                        .arguments = try self.buildMethodArguments(argument_nodes),
                        .span = span,
                    };
                    if (reference == .declaration) {
                        if (try self.analysis_context.functionShape(reference.declaration.item)) |shape|
                            break :target .{ .direct = .{ .instance = reference.declaration, .shape = shape } };
                    }
                    const value = try self.appendNamedReference(callee_index, reference);
                    break :target .{ .resolved = .{ .value = .{ .value = value, .span = span } } };
                }
                if (callee.tag == .field_access) return self.buildMemberCall(node, callee);
                if (callee.tag == .identifier and !self.runtimeName(self.source[span.start..span.end]))
                    break :target .{ .resolved = .unknown_function };
                break :target .{ .resolved = .{ .value = try self.appendUse(callee_index, false) } };
            };
            // Only direct targets have static parameters; other arguments are runtime values.
            var parameters: []const structures.FunctionParameterShape = &.{};
            var infer_static = false;
            if (pending_target == .direct) {
                const direct = pending_target.direct;
                parameters = direct.shape.parameters;
                infer_static = try self.analysis_context.needsInheritedInference(direct.instance);
                var runtime_count: usize = 0;
                for (parameters) |parameter| runtime_count += @intFromBool(parameter.mode != .static);
                if (argument_nodes.len == runtime_count and runtime_count != parameters.len) {
                    infer_static = true;
                } else if (infer_static and argument_nodes.len != runtime_count) {
                    return self.reject(callee_index, .static_argument_cannot_be_inferred);
                } else if (argument_nodes.len != parameters.len and runtime_count != parameters.len) {
                    return self.reject(callee_index, .{ .call_argument_count_mismatch = .{
                        .expected = @intCast(parameters.len),
                        .found = @intCast(argument_nodes.len),
                    } });
                }
            }
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            var static_arguments: std.ArrayList(structures.CompileTimeValueId) = .empty;
            defer static_arguments.deinit(self.gpa);
            for (argument_nodes, 0..) |argument, argument_index| {
                if (!infer_static and argument_index < parameters.len and parameters[argument_index].mode == .static) {
                    const value = try self.staticArgument(pending_target.direct.instance, parameters[argument_index], argument_index, argument, static_arguments.items);
                    try static_arguments.append(self.gpa, value);
                } else {
                    try self.scratch.append(self.gpa, try self.appendUse(argument, false));
                }
            }
            const arguments = try self.appendArguments(self.scratch.items[scratch_start..]);
            const target: UnresolvedBody.Call.Target = switch (pending_target) {
                .resolved => |target| target,
                .direct => |direct| if (infer_static)
                    .{ .inferred = direct.instance }
                else
                    .{ .direct = try self.analysis_context.specializeFunction(direct.instance, static_arguments.items) },
            };
            return .{ .target = target, .arguments = arguments, .span = span };
        }

        fn staticArgument(
            self: *Self,
            instance: structures.InstanceId,
            parameter: structures.FunctionParameterShape,
            argument_index: usize,
            argument: structures.Node.Index,
            previous: []const structures.CompileTimeValueId,
        ) !structures.CompileTimeValueId {
            try self.rejectRuntimeCapture(argument);
            const value: structures.CompileTimeValue = if (parameter.is_meta_type) switch (try analyzer(self.ast, self.source, self.analysis_context, self.gpa).run("analyzeStaticTypeArgument", .{argument})) {
                .success => |value| value,
                .unsupported => |issue| return self.reject(argument, issue.kind),
            } else value: {
                const expected_type = try self.analysis_context.staticParameterType(instance, argument_index, previous);
                const value_id = self.analysis_context.executeComptimeWithType(argument, expected_type) catch |err| switch (err) {
                    error.QueryCycle => return self.reject(argument, .declaration_cycle),
                    else => return err,
                } orelse return error.Unavailable;
                break :value try self.analysis_context.lookupCompileTimeValue(value_id);
            };
            if (value == .runtime and value.runtime.value == .function_ref) return self.reject(argument, .static_argument_not_supported);
            return self.analysis_context.internCompileTimeValue(value);
        }

        fn buildMemberCall(self: *Self, call: structures.Node, callee: structures.Node) !UnresolvedBody.Call {
            const receiver = try self.appendUse(callee.data.node, false);
            const arguments = try self.buildMethodArguments(self.ast.nodeList(call.data.node_node.b));
            const name_span = tokenSpan(self.ast, callee.token_index);
            return .{
                .target = .{ .member = .{
                    .receiver = receiver,
                    .name = self.source[name_span.start..name_span.end],
                } },
                .arguments = arguments,
                .span = name_span,
            };
        }

        fn buildMethodArguments(self: *Self, argument_nodes: []const structures.Node.Index) !structures.FunctionValueRange {
            var arguments: std.ArrayList(UnresolvedBody.MethodCallArgument) = .empty;
            defer arguments.deinit(self.gpa);
            for (argument_nodes) |argument| {
                try arguments.append(self.gpa, .{
                    .node = argument,
                    .value = try self.appendUse(argument, false),
                    .runtime_reference = if (runtimeReference(self.ast, self.source, argument, self)) |reference|
                        nodeFocusSpan(self.ast, reference)
                    else
                        null,
                });
            }
            const start: u32 = @intCast(self.method_call_arguments.items.len);
            try self.method_call_arguments.appendSlice(self.gpa, arguments.items);
            return .{ .start = start, .end = @intCast(self.method_call_arguments.items.len) };
        }

        fn appendExpression(self: *Self, index: structures.Node.Index, operation: UnresolvedBody.Expression.Operation) !ValueId {
            const value: ValueId = @fromBackingInt(@intCast(self.parameters.len + self.expressions.items.len));
            try self.expressions.append(self.gpa, .{ .operation = operation, .span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index), .source_node = index });
            return value;
        }

        fn finish(self: *Self) !UnresolvedBody {
            var body: UnresolvedBody = .{
                .parameter_count = @intCast(self.parameters.len),
                .static_expression_count = self.static_expression_count,
                .local_count = self.local_count,
                .root_block = self.root_block.?,
            };
            errdefer body.deinit(self.gpa);
            inline for (body_info.field_names, body_info.field_types) |name, Field| {
                if (@typeInfo(Field) == .pointer) @field(body, name) = try @field(self, name).toOwnedSlice(self.gpa);
            }
            return body;
        }
    };
}

const FunctionParts = struct {
    function: structures.Node.Index,
    signature: @FieldType(structures.Node.Data, "signature"),
    body: structures.Node.Index,
};

pub fn isExternalFunction(ast: *const structures.Ast, declaration: u32) bool {
    return functionParts(ast, declaration).body == .null;
}

/// The signature of an unspecialized function.
pub fn analyzeFunctionShape(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.FunctionShape) {
    const parts = functionParts(ast, declaration);
    var parameters: std.ArrayList(structures.FunctionParameterShape) = .empty;
    defer parameters.deinit(gpa);
    var static_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (static_names.items) |name| gpa.free(name);
        static_names.deinit(gpa);
    }
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    for (ast.nodeList(parts.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        const mode = parameterMode(ast, parameter) orelse
            return .{ .unsupported = issueAt(ast, parameter_index.index(), .parameter_mode_not_supported) };
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        if ((try names.getOrPut(name)).found_existing)
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_parameter } };
        const annotation = parameter.data.parameter.annotation.unwrap() orelse {
            return .{ .unsupported = .{ .span = name_span, .kind = .parameter_type_missing } };
        };
        try parameters.append(gpa, .{
            .mode = mode,
            .is_meta_type = mode == .static and isMetaTypeAnnotation(ast, source, annotation),
        });
        if (mode == .static) {
            const owned_name = try gpa.dupe(u8, name);
            errdefer gpa.free(owned_name);
            try static_names.append(gpa, owned_name);
        }
    }
    var shape: structures.FunctionShape = .{
        .parameters = try parameters.toOwnedSlice(gpa),
        .returns_type = if (parts.signature.return_type.unwrap()) |annotation| isMetaTypeAnnotation(ast, source, annotation) else false,
    };
    errdefer shape.deinit(gpa);
    shape.static_names = try static_names.toOwnedSlice(gpa);
    return .{ .success = shape };
}

pub fn parameterizedStructSite(ast: *const structures.Ast, declaration: u32) ?i64 {
    const binding = ast.nodes[declaration];
    if (binding.tag != .static_binding) return null;
    const function = ast.nodes[binding.data.node_node.b.index()];
    if (function.tag != .func) return null;
    const signature = ast.nodes[function.data.node_node.a.index()];
    if (ast.nodes[signature.data.signature.return_type.index()].tag != .implicit_type) return null;
    const body = ast.nodes[function.data.node_node.b.index()];
    if (body.tag != .return_expr or ast.nodes[body.data.node.index()].tag != .@"struct") return null;
    return @as(i64, body.data.node.index()) - @as(i64, declaration);
}

pub fn isDirectlyReturnedStructSite(ast: *const structures.Ast, declaration: u32, node_offset: i64) bool {
    const binding = ast.nodes[declaration];
    if (binding.tag != .static_binding) return false;
    const function = ast.nodes[binding.data.node_node.b.index()];
    if (function.tag != .func) return false;
    const body = ast.nodes[function.data.node_node.b.index()];
    const statements: []const structures.Node.Index = if (body.tag == .block)
        ast.node_refs[body.data.ref.start..body.data.ref.end]
    else
        &.{function.data.node_node.b};
    for (statements) |statement_index| {
        const statement = ast.nodes[statement_index.index()];
        if (statement.tag != .return_expr) continue;
        const value = statement.data.node;
        if (ast.nodes[value.index()].tag == .@"struct" and
            @as(i64, value.index()) - @as(i64, declaration) == node_offset) return true;
    }
    return false;
}

pub const StaticInference = union(enum) {
    arguments: []structures.CompileTimeValueId,
    missing,
    conflict,
};

const InferredParameter = struct {
    name: []const u8,
    is_meta_type: bool,
    value: ?structures.CompileTimeValueId = null,

    fn bind(self: *@This(), value: structures.CompileTimeValueId) bool {
        if (self.value) |existing| return existing == value;
        self.value = value;
        return true;
    }
};

pub fn validateConverterDeclaration(ast: *const structures.Ast, source: []const u8, declaration: u32, analysis_context: anytype) !SemanticResult(void) {
    const signature = functionParts(ast, declaration).signature;
    const target = signature.return_type.unwrap() orelse return .{ .unsupported = issueAt(ast, declaration, .invalid_converter) };
    var value_annotation: ?structures.Node.Index = null;
    for (ast.nodeList(signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        const annotation = parameter.data.parameter.annotation.unwrap() orelse return .{ .unsupported = issueAt(ast, parameter_index.index(), .parameter_type_missing) };
        const mode = parameterMode(ast, parameter).?;
        if (mode == .static and isMetaTypeAnnotation(ast, source, annotation)) continue;
        const collection_source = try analysis_context.isCollectionConverterAnnotation(annotation);
        if (mode == .init) {
            if (!collection_source or value_annotation != null) return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
            value_annotation = annotation;
            continue;
        }
        if (collection_source) return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
        const static_source = try analysis_context.isStaticConverterAnnotation(annotation);
        const dependent = converterAnnotationDependsOnStaticParameters(ast, source, declaration, annotation);
        const inferred_from_target = annotationInfersParameter(ast, source, target, tokenText(ast, source, parameter.token_index));
        if (mode == .static and !static_source and (!dependent or inferred_from_target)) continue;
        if ((!dependent and static_source and mode != .static) or (!dependent and !static_source and mode != .imm) or
            (dependent and mode != .static and mode != .imm) or value_annotation != null)
            return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
        value_annotation = annotation;
    }
    const value = value_annotation orelse return .{ .unsupported = issueAt(ast, declaration, .invalid_converter) };
    for (ast.nodeList(signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? != .static or parameter.data.parameter.annotation == value) continue;
        const name = tokenText(ast, source, parameter.token_index);
        if (!annotationInfersParameter(ast, source, value, name) and !annotationInfersParameter(ast, source, target, name))
            return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
    }
    const module = try analysis_context.currentModule();
    if (try analysis_context.converterAnnotationOwner(value) != module and try analysis_context.converterAnnotationOwner(target) != module)
        return .{ .unsupported = issueAt(ast, declaration, .invalid_converter_owner) };
    return .{ .success = {} };
}

pub fn converterAnnotationDependsOnStaticParameters(ast: *const structures.Ast, source: []const u8, declaration: u32, annotation: structures.Node.Index) bool {
    const scope: ParameterScope = .{ .ast = ast, .source = source, .parameters = functionParameters(ast, declaration), .static_only = true };
    return runtimeReference(ast, source, annotation, scope) != null;
}

fn annotationInfersParameter(ast: *const structures.Ast, source: []const u8, annotation: structures.Node.Index, name: []const u8) bool {
    const node = ast.nodes[annotation.index()];
    if (node.tag == .identifier or node.tag == .type) return std.mem.eql(u8, tokenText(ast, source, node.token_index), name);
    if (node.tag == .reference_type) return annotationInfersParameter(ast, source, node.data.node, name);
    const parts = switch (node.tag) {
        .type_variant, .type_tuple => ast.nodeList(annotation),
        .call => ast.nodeList(node.data.node_node.b),
        else => return false,
    };
    for (parts) |part| {
        if (annotationInfersParameter(ast, source, part, name)) return true;
    }
    return false;
}

fn structFactoryFieldAnnotation(ast: *const structures.Ast, source: []const u8, declaration: u32, name: []const u8) ?structures.Node.Index {
    std.debug.assert(parameterizedStructSite(ast, declaration) != null);
    const body = ast.nodes[functionParts(ast, declaration).body.index()];
    for (ast.nodeList(body.data.node)) |member_index| {
        const item = ast.nodes[member_index.index()];
        const member = if (item.tag == .@"pub") ast.nodes[item.data.node.index()] else item;
        if (member.tag == .struct_field and std.mem.eql(u8, name, tokenText(ast, source, member.token_index))) return member.data.field.type_annotation;
    }
    return null;
}

fn appendInferredStaticParameters(ast: *const structures.Ast, source: []const u8, parameters: []const structures.Node.Index, inferred: *std.ArrayList(InferredParameter), gpa: std.mem.Allocator) !void {
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? != .static) continue;
        try inferred.append(gpa, .{
            .name = tokenText(ast, source, parameter.token_index),
            .is_meta_type = isMetaTypeAnnotation(ast, source, parameter.data.parameter.annotation.unwrap().?),
        });
    }
}

fn annotationReferencesInferred(ast: *const structures.Ast, source: []const u8, inferred: []InferredParameter, annotation: structures.Node.Index) bool {
    if (inferredParameter(ast, source, inferred, annotation, false) != null) return true;
    var children = ast.nodes[annotation.index()].children(ast.node_refs);
    for (children.slice()) |child| {
        if (child.unwrap()) |index| if (annotationReferencesInferred(ast, source, inferred, index)) return true;
    }
    return false;
}

fn finishStaticInference(inferred: []const InferredParameter, gpa: std.mem.Allocator) !StaticInference {
    for (inferred) |parameter| {
        if (parameter.value == null) return .missing;
    }
    const arguments = try gpa.alloc(structures.CompileTimeValueId, inferred.len);
    for (inferred, arguments) |parameter, *argument| {
        argument.* = parameter.value.?;
    }
    return .{ .arguments = arguments };
}

fn inferredParameter(
    ast: *const structures.Ast,
    source: []const u8,
    parameters: []InferredParameter,
    name_index: structures.Node.Index,
    type_only: bool,
) ?*InferredParameter {
    const node = ast.nodes[name_index.index()];
    if (node.tag != .identifier and node.tag != .type) return null;
    const name = tokenText(ast, source, node.token_index);
    for (parameters) |*parameter| {
        if ((!type_only or parameter.is_meta_type) and std.mem.eql(u8, name, parameter.name)) return parameter;
    }
    return null;
}

pub const IndependentConverterTypes = struct {
    input_type: ?structures.TypeId = null,
    return_type: ?structures.TypeId = null,
};

/// A conservative source annotation for indexing, without evaluating types.
/// Init carriers match several source families, so their source stays broad.
pub fn converterIndexSource(ast: *const structures.Ast, source: []const u8, declaration: u32) ?structures.Node.Index {
    const parameters = functionParameters(ast, declaration);
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        const mode = parameterMode(ast, parameter) orelse return null;
        if (mode == .init) return null;
        if (mode != .static) return parameter.data.parameter.annotation.unwrap();
    }
    var result: ?structures.Node.Index = null;
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        const annotation = parameter.data.parameter.annotation.unwrap() orelse return null;
        if (isMetaTypeAnnotation(ast, source, annotation)) continue;
        // Multiple static value parameters need ordinary inference to identify
        // the converted source; the index must not guess between them.
        if (result != null) return null;
        result = annotation;
    }
    return result;
}

pub fn functionReturnTypeNode(ast: *const structures.Ast, declaration: u32) ?structures.Node.Index {
    return functionParts(ast, declaration).signature.return_type.unwrap();
}

pub fn functionHasParameter(ast: *const structures.Ast, source: []const u8, declaration: u32, name: []const u8) bool {
    for (functionParameters(ast, declaration)) |parameter_index| {
        if (std.mem.eql(u8, name, tokenText(ast, source, ast.nodes[parameter_index.index()].token_index))) return true;
    }
    return false;
}

fn parameterMode(ast: *const structures.Ast, parameter: structures.Node) ?structures.ParameterMode {
    _ = ast;
    return switch (parameter.data.parameter.access orelse return .imm) {
        .keyword_imm => .imm,
        .keyword_ref => .ref,
        .keyword_static => .static,
        .keyword_mut => .mut,
        .keyword_var => .@"var",
        .keyword_deinit => .deinit,
        .keyword_init => .init,
        else => null,
    };
}

fn isTerminator(tag: structures.Node.Tag) bool {
    return switch (tag) {
        .return_nothing, .return_expr, .break_nothing, .break_expr, .continue_expr => true,
        else => false,
    };
}

fn runtimeReference(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, scope: anytype) ?structures.Node.Index {
    const present = index.unwrap() orelse return null;
    const node = ast.nodes[present.index()];
    if (node.tag == .identifier or node.tag == .type) return if (scope.runtimeName(tokenText(ast, source, node.token_index))) present else null;
    var children = node.children(ast.node_refs);
    for (children.slice()) |child| {
        if (runtimeReference(ast, source, child, scope)) |reference| return reference;
    }
    return null;
}

const ParameterScope = struct {
    ast: *const structures.Ast,
    source: []const u8,
    parameters: []const structures.Node.Index,
    static_only: bool = false,

    fn runtimeName(self: @This(), name: []const u8) bool {
        for (self.parameters) |index| {
            const parameter = self.ast.nodes[index.index()];
            if ((parameterMode(self.ast, parameter) == .static) != self.static_only) continue;
            if (std.mem.eql(u8, name, tokenText(self.ast, self.source, parameter.token_index))) return true;
        }
        return false;
    }
};

pub fn resolveNamedExpression(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, analysis_context: anytype) anyerror!?structures.NameReference {
    return resolveNamedExpressionWithOperands(ast, source, index, analysis_context, null);
}

fn resolveNamedExpressionWithOperands(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, analysis_context: anytype, operands: ?usize) anyerror!?structures.NameReference {
    const node = ast.nodes[index.index()];
    const span = tokenSpan(ast, node.token_index);
    switch (node.tag) {
        .identifier, .type => return annotationReference(try analysis_context.resolveName(source[span.start..span.end]), analysis_context),
        .@"struct" => return .{ .constant = try analysis_context.internCompileTimeValue(.{ .type = try analysis_context.generatedStructType(index) }) },
        .field_access => {
            const left = (try resolveNamedExpression(ast, source, node.data.node, analysis_context)) orelse return null;
            return annotationReference(try analysis_context.resolveMemberWithOperands(left, source[span.start..span.end], span, operands), analysis_context);
        },
        .call => {
            const callee = (try resolveNamedExpressionWithOperands(ast, source, node.data.node_node.a, analysis_context, ast.nodeList(node.data.node_node.b).len)) orelse return null;
            if (callee == .overloaded_function) {
                if (!try analysis_context.overloadCallReturnsType(callee.overloaded_function, index)) return null;
            } else {
                if (callee != .declaration) return null;
                const shape = (try analysis_context.functionShape(callee.declaration.item)) orelse return null;
                if (!shape.returns_type) return null;
            }
            const value = (try analysis_context.executeComptime(index)) orelse return error.Unavailable;
            return .{ .constant = value };
        },
        else => return null,
    }
}

/// Name resolution failures that are source errors at the resolved expression.
fn nameResolutionIssue(err: anyerror) ?structures.Diagnostic.Kind {
    return switch (err) {
        error.QueryCycle => .declaration_cycle,
        error.PublicFieldPrivateType => .public_field_private_type,
        else => null,
    };
}

fn annotationReference(reference: ?structures.NameReference, analysis_context: anytype) !?structures.NameReference {
    if (reference) |resolved| {
        if (analysis_context.public_annotation and !try analysis_context.isPublicAnnotationReference(resolved))
            return error.PublicFieldPrivateType;
    }
    return reference;
}

fn logicalTypeNode(ast: *const structures.Ast, node_index: structures.Node.Index) structures.Node.Index {
    const node = ast.nodes[node_index.index()];
    return if (node.tag == .reference_type) node.data.node else node_index;
}

pub const StaticInitializerPlan = union(enum) {
    type_value: structures.TypeId,
    interpret: ?structures.TypeId,
};

pub fn validateStructNamespace(ast: *const structures.Ast, source: []const u8, struct_index: structures.Node.Index, gpa: std.mem.Allocator) !?Issue {
    var names = structures.Name.Set.init(gpa);
    defer names.deinit();
    const node = ast.nodes[struct_index.index()];
    std.debug.assert(node.tag == .@"struct");
    for (ast.node_refs[node.data.ref.start..node.data.ref.end]) |index| {
        const item = ast.nodes[index.index()];
        const member_index = if (item.tag == .@"pub") item.data.node else index;
        const member = ast.nodes[member_index.index()];
        if (member.tag == .struct_property) continue;
        if (member.tag != .struct_field and member.tag != .static_binding)
            return issueAt(ast, index.index(), .struct_member_not_supported);
        const span = tokenSpan(ast, member.token_index);
        if (std.meta.stringToEnum(structures.OwnershipMember, source[span.start..span.end]) != null)
            return .{ .span = span, .kind = .reserved_ownership_member };
        if ((try names.getOrPut(declarationName(ast, source[span.start..span.end], member_index.index()))).found_existing)
            return .{ .span = span, .kind = .duplicate_struct_member };
    }
    return null;
}

const StructOwnershipOperation = enum {
    move,
    copy,
    drop,

    fn isDefined(operation: StructOwnershipOperation, ownership: structures.StructOwnershipProperties) bool {
        return switch (operation) {
            inline else => |kind| @field(ownership, @tagName(kind)) != null,
        };
    }
};

fn isMetaTypeAnnotation(ast: *const structures.Ast, source: []const u8, annotation: structures.Node.Index) bool {
    const node = ast.nodes[annotation.index()];
    return node.tag == .implicit_type or (node.tag == .type and std.mem.eql(u8, tokenText(ast, source, node.token_index), "type"));
}

const IntegerLiteralResult = union(enum) {
    value: i64,
    unsupported: structures.Diagnostic.Kind,
};

pub fn integerLiteralValue(ast: *const structures.Ast, source: []const u8, expression: structures.Node.Index) ?i64 {
    const node = ast.nodes[expression.index()];
    const negative = node.tag == .neg;
    const literal = if (negative) ast.nodes[node.data.node.index()] else node;
    if (literal.tag != .number_literal) return null;
    return switch (parseIntegerLiteral(tokenText(ast, source, literal.token_index), negative)) {
        .value => |value| value,
        .unsupported => null,
    };
}

fn parseIntegerLiteral(literal: []const u8, negative: bool) IntegerLiteralResult {
    const prefix = if (literal.len >= 2) literal[0..2] else "";
    const is_hex = std.ascii.eqlIgnoreCase(prefix, "0x");
    const is_other_base = std.ascii.eqlIgnoreCase(prefix, "0b") or std.ascii.eqlIgnoreCase(prefix, "0o");
    for (literal) |byte| {
        if (byte == '.' or (is_hex and (byte == 'p' or byte == 'P')) or
            (!is_hex and !is_other_base and (byte == 'e' or byte == 'E')))
        {
            return .{ .unsupported = .float_literal_not_supported };
        }
    }
    for (literal) |byte| {
        if (!std.ascii.isDigit(byte)) return .{ .unsupported = .integer_literal_not_decimal };
    }
    const magnitude = std.fmt.parseInt(u64, literal, 10) catch return .{ .unsupported = .integer_literal_out_of_range };
    if (negative and magnitude == @as(u64, std.math.maxInt(i64)) + 1) return .{ .value = std.math.minInt(i64) };
    const value = std.math.cast(i64, magnitude) orelse return .{ .unsupported = .integer_literal_out_of_range };
    return .{ .value = if (negative) -value else value };
}

pub fn canWidenTo(analysis_context: anytype, actual: structures.TypeId, expected: structures.TypeId) !bool {
    if (actual == expected or actual == .never) return true;
    const expected_members = try analysis_context.facts().variantMembers(expected) orelse return false;
    const actual_members = try analysis_context.facts().variantMembers(actual) orelse &.{actual};
    for (actual_members) |member| {
        if (try widenedVariantTag(analysis_context, member, expected_members) == null) return false;
    }
    return true;
}

pub fn widenedVariantTag(_: anytype, actual: structures.TypeId, members: []const structures.TypeId) !?u32 {
    return if (std.mem.indexOfScalar(structures.TypeId, members, actual)) |index| @intCast(index) else null;
}

fn functionParts(ast: *const structures.Ast, declaration: u32) FunctionParts {
    std.debug.assert(declaration < ast.nodes.len);
    const declaration_node = ast.nodes[declaration];
    const function_index: structures.Node.Index = if (declaration_node.tag == .static_binding) declaration_node.data.node_node.b else @fromBackingInt(@intCast(declaration));
    const function = ast.nodes[(function_index.unwrap() orelse unreachable).index()];
    std.debug.assert(function.tag == .func);
    const signature = ast.nodes[(function.data.node_node.a.unwrap() orelse unreachable).index()];
    std.debug.assert(signature.tag == .signature);
    return .{ .function = function_index, .signature = signature.data.signature, .body = function.data.node_node.b };
}

fn functionParameters(ast: *const structures.Ast, declaration: u32) []const structures.Node.Index {
    return ast.nodeList(functionParts(ast, declaration).signature.parameters);
}

pub fn functionWhereConditions(ast: *const structures.Ast, declaration: u32) []const structures.Node.Index {
    return ast.nodeList(functionParts(ast, declaration).signature.where_clauses);
}

fn issueAt(ast: *const structures.Ast, node_index: u32, kind: structures.Diagnostic.Kind) Issue {
    return .{ .span = tokenSpan(ast, ast.nodes[node_index].token_index), .kind = kind };
}

fn tokenSpan(ast: *const structures.Ast, token_index: u32) structures.SourceSpan {
    return ast.tokenSpan(token_index);
}

fn tokenText(ast: *const structures.Ast, source: []const u8, token_index: u32) []const u8 {
    const span = tokenSpan(ast, token_index);
    return source[span.start..span.end];
}

fn nodeFocusSpan(ast: *const structures.Ast, node_index: structures.Node.Index) structures.SourceSpan {
    const node = ast.nodes[node_index.index()];
    if (node.tag == .call) return nodeFocusSpan(ast, node.data.node_node.a);
    return tokenSpan(ast, node.token_index);
}

pub fn collectImports(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8) !structures.ImportDeclarations {
    var imports: std.ArrayList(structures.ImportDeclaration) = .empty;
    errdefer {
        for (imports.items) |*entry| entry.deinit(gpa);
        imports.deinit(gpa);
    }
    const root = ast.nodes[0];
    std.debug.assert(root.tag == .block);
    for (ast.node_refs[root.data.ref.start..root.data.ref.end]) |statement| {
        const node = ast.nodes[statement.index()];
        const is_public = node.tag == .@"pub";
        const target = if (is_public) node.data.node else statement;
        const tag = ast.nodes[target.index()].tag;
        if (tag != .import and tag != .selective_import) continue;
        var entry = try collectImport(gpa, ast, source, target, is_public);
        errdefer entry.deinit(gpa);
        try imports.append(gpa, entry);
    }
    return .{ .entries = try imports.toOwnedSlice(gpa) };
}

fn ownedImportName(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, node: structures.Node.Index) !structures.ImportName {
    const token_index = ast.nodes[node.index()].token_index;
    return .{ .spelling = try gpa.dupe(u8, tokenText(ast, source, token_index)), .span = tokenSpan(ast, token_index) };
}

fn collectImport(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, is_public: bool) !structures.ImportDeclaration {
    const node = ast.nodes[index.index()];
    const parts = ast.node_refs[node.data.ref.start..node.data.ref.end];
    var cursor = parts[0];
    var alias: ?structures.ImportName = null;
    errdefer if (alias) |name| gpa.free(name.spelling);
    if (ast.nodes[cursor.index()].tag == .as) {
        const target = ast.nodes[cursor.index()];
        alias = try ownedImportName(gpa, ast, source, target.data.node_node.b);
        cursor = target.data.node_node.a;
    }
    const path = try qualifiedName(gpa, ast, source, cursor);
    errdefer gpa.free(path);
    var root = cursor;
    while (ast.nodes[root.index()].tag == .field_access) root = ast.nodes[root.index()].data.node;
    const path_span: structures.SourceSpan = .{
        .start = tokenSpan(ast, ast.nodes[root.index()].token_index).start,
        .end = tokenSpan(ast, ast.nodes[cursor.index()].token_index).end,
    };
    var selections: std.ArrayList(structures.ImportDeclaration.Selection) = .empty;
    errdefer {
        for (selections.items) |item| {
            gpa.free(item.original.spelling);
            gpa.free(item.bound.spelling);
        }
        selections.deinit(gpa);
    }
    for (parts[1..]) |item_index| {
        const item = ast.nodes[item_index.index()];
        const original = try ownedImportName(gpa, ast, source, if (item.tag == .as) item.data.node_node.a else item_index);
        errdefer gpa.free(original.spelling);
        const bound = try ownedImportName(gpa, ast, source, if (item.tag == .as) item.data.node_node.b else item_index);
        errdefer gpa.free(bound.spelling);
        try selections.append(gpa, .{ .original = original, .bound = bound });
    }
    return .{
        .path = .{ .spelling = path, .span = path_span },
        .alias = alias,
        .selective = if (node.tag == .selective_import) try selections.toOwnedSlice(gpa) else null,
        .is_public = is_public,
    };
}

pub fn discoverItems(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, module: structures.ModuleId) !structures.ItemTree {
    var items: std.ArrayList(structures.DiscoveredItem) = .empty;
    errdefer {
        for (items.items) |*item| {
            item.loc.name.deinit(gpa);
            if (item.qualified_owner) |owner| gpa.free(owner);
        }
        items.deinit(gpa);
    }

    const root = ast.nodes[0];
    std.debug.assert(root.tag == .block);
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const declaration = ast.node_refs[ref_index];
        const node = ast.nodes[declaration.index()];
        var target = if (node.tag == .@"pub") node.data.node else declaration;
        var target_node = ast.nodes[target.index()];
        const namespace = if (target_node.tag == .namespace_declaration) target_node.data.node_node.a else .null;
        if (namespace != .null) {
            target = target_node.data.node_node.b;
            target_node = ast.nodes[target.index()];
        }

        if (target_node.tag != .static_binding) continue;
        const value = target_node.data.node_node.b.unwrap() orelse unreachable;
        const kind = itemKind(ast, value);

        const name: structures.Name = if (ast.nodes[value.index()].is_converter)
            .{ .converter = .{ .file_id = ast.file_id, .ordinal = @intCast(items.items.len) } }
        else
            declarationName(ast, tokenText(ast, source, target_node.token_index), target.index());
        const parent = try appendItem(gpa, &items, kind, ast.file_id, module, name, target.index(), node.tag == .@"pub", null, null);
        if (namespace != .null) items.items[parent].qualified_owner = try qualifiedName(gpa, ast, source, namespace);
        if (kind == .structure) {
            try discoverStructItems(gpa, &items, ast, source, module, value, parent, null);
        } else {
            try discoverGeneratedStructItems(gpa, &items, ast, source, module, target, parent);
        }
    }

    const entry = try appendItem(gpa, &items, .top_level_entry, ast.file_id, module, .{ .identifier = "$entry" }, 0, false, null, null);
    try discoverGeneratedStructItems(gpa, &items, ast, source, module, @fromBackingInt(0), entry);
    return .{ .file_id = ast.file_id, .items = try items.toOwnedSlice(gpa) };
}

fn itemKind(ast: *const structures.Ast, value: structures.Node.Index) structures.ItemKind {
    return switch (ast.nodes[value.index()].tag) {
        .func => .function,
        .overload => .overload,
        .@"struct" => .structure,
        else => .static,
    };
}

fn qualifiedName(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, index: structures.Node.Index) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var current = index;
    while (true) {
        const node = ast.nodes[current.index()];
        const token = ast.tokens[node.token_index];
        try segments.append(gpa, source[token.loc.start..token.loc.end]);
        if (node.tag == .identifier) break;
        std.debug.assert(node.tag == .field_access);
        current = node.data.node;
    }
    std.mem.reverse([]const u8, segments.items);
    return std.mem.join(gpa, ".", segments.items);
}

fn discoverGeneratedStructItems(gpa: std.mem.Allocator, items: *std.ArrayList(structures.DiscoveredItem), ast: *const structures.Ast, source: []const u8, module: structures.ModuleId, declaration: structures.Node.Index, parent: u32) anyerror!void {
    // Traverse only this declaration, stopping at structs whose member
    // declarations establish their own owners and source-relative sites.
    var pending: std.ArrayList(structures.Node.Index) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, declaration);
    while (pending.pop()) |index| {
        const node = ast.nodes[index.index()];
        // Other declarations have their own discovery roots. In particular,
        // entry traversal must not claim members inside module declarations.
        if (index != declaration and node.tag == .static_binding) continue;
        if (node.tag == .@"struct") {
            const site = @as(i64, index.index()) - @as(i64, declaration.index());
            try discoverStructItems(gpa, items, ast, source, module, index, parent, site);
            continue;
        }
        var children = node.children(ast.node_refs);
        const nodes = children.slice();
        var end = nodes.len;
        while (end > 0) {
            end -= 1;
            if (nodes[end].unwrap()) |child| try pending.append(gpa, child);
        }
    }
}

fn discoverStructItems(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    ast: *const structures.Ast,
    source: []const u8,
    module: structures.ModuleId,
    struct_index: structures.Node.Index,
    parent: u32,
    source_site: ?i64,
) !void {
    const struct_node = ast.nodes[struct_index.index()];
    std.debug.assert(struct_node.tag == .@"struct");
    var hook_names = std.StringHashMap(void).init(gpa);
    defer hook_names.deinit();
    var declaration_names = structures.Name.Set.init(gpa);
    defer declaration_names.deinit();
    for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |item_index| {
        const item = ast.nodes[item_index.index()];
        const member_index = if (item.tag == .@"pub") item.data.node else item_index;
        const member = ast.nodes[member_index.index()];
        const name = tokenText(ast, source, member.token_index);
        if (member.tag == .struct_property and ast.nodes[member.data.node.index()].tag == .func) {
            // Semantic analysis diagnoses duplicates; discovery remains indexable.
            if ((try hook_names.getOrPut(name)).found_existing) continue;
            const child = try appendItem(gpa, items, .function, ast.file_id, module, .{ .identifier = name }, member.data.node.index(), false, parent, source_site);
            items.items[child].loc.is_hook = true;
            try discoverGeneratedStructItems(gpa, items, ast, source, module, member.data.node, child);
        } else if (member.tag == .static_binding) {
            const member_name = declarationName(ast, name, member_index.index());
            if ((try declaration_names.getOrPut(member_name)).found_existing) continue;
            const value = member.data.node_node.b;
            const kind = itemKind(ast, value);
            const child = try appendItem(gpa, items, kind, ast.file_id, module, member_name, member_index.index(), item.tag == .@"pub", parent, source_site);
            if (kind == .structure) {
                try discoverStructItems(gpa, items, ast, source, module, value, child, null);
            } else {
                try discoverGeneratedStructItems(gpa, items, ast, source, module, member_index, child);
            }
        }
    }
}

fn declarationName(ast: *const structures.Ast, name: []const u8, declaration: u32) structures.Name {
    const node = ast.nodes[declaration];
    if (node.tag == .static_binding and ast.nodes[node.data.node_node.b.index()].tag == .overload)
        return .fromText(name, null);
    if (node.tag != .static_binding or ast.nodes[node.data.node_node.b.index()].tag != .func)
        return .{ .identifier = name };
    var count: usize = 0;
    for (functionParameters(ast, declaration)) |parameter| count += @intFromBool(parameterMode(ast, ast.nodes[parameter.index()]) != .static);
    return .fromText(name, count);
}

fn appendItem(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    kind: structures.ItemKind,
    file_id: structures.FileId,
    module: structures.ModuleId,
    name: structures.Name,
    declaration: u32,
    is_public: bool,
    parent: ?u32,
    source_site: ?i64,
) !u32 {
    var owned_name = try name.clone(gpa);
    errdefer owned_name.deinit(gpa);
    const index: u32 = @intCast(items.items.len);
    try items.append(gpa, .{
        .loc = .{ .origin = if (kind == .top_level_entry) .{ .entry = file_id } else .{ .module = module }, .source_site = source_site, .kind = kind, .name = owned_name },
        .declaration = declaration,
        .parent = parent,
        .is_public = is_public,
    });
    return index;
}

test "unresolved function body cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testUnresolvedFunctionBodyAllocations, .{});
}

test "qualified namespace discovery cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    const parser = @import("parser.zig");
    const source =
        \\struct S
        \\  value: int
        \\static S.read = func(imm self: S) int -> return self.value
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testQualifiedNamespaceDiscoveryAllocations, .{ &report.ast.?, source });
}

fn testQualifiedNamespaceDiscoveryAllocations(gpa: std.mem.Allocator, parsed: *const structures.Ast, source: []const u8) !void {
    var tree = try discoverItems(gpa, parsed, source, @fromBackingInt(@intCast(0)));
    defer tree.deinit(gpa);
}

test "discard assignment has distinct unresolved statement" {
    const parser = @import("parser.zig");
    const source = "func inspect(imm value: int)\n  _ = value";
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzer(parsed, source, TestAnalysisContext{}, std.testing.allocator).buildUnresolvedBody(.{ .function = .{ .declaration = declaration.index(), .parameters = &.{.{
        .mode = .imm,
        .type_id = .int,
    }} } });
    var unresolved = switch (result) {
        .success => |value| value,
        .unsupported => unreachable,
    };
    defer unresolved.deinit(std.testing.allocator);

    const root = unresolved.blocks[@backingInt(unresolved.root_block)];
    try std.testing.expectEqual(@as(u32, 1), root.statements.end - root.statements.start);
    const statement = unresolved.statements[root.statements.start];
    try std.testing.expectEqual(UnresolvedBody.ValueId, @TypeOf(statement.lifetime_extend.value));
    try std.testing.expectEqual(@as(u32, 0), @backingInt(statement.lifetime_extend.value));
}

test "function signature cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFunctionSignatureAllocations, .{});
}

test "struct definition cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testStructDefinitionAllocations, .{});
}

test "struct factory independent inference unwraps public fields" {
    const parser = @import("parser.zig");
    const source =
        \\struct Factory(T: type)
        \\  pub value: T
        \\  pub amount: int
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    const parsed = &report.ast.?;
    const wrapped = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const declaration = if (parsed.nodes[wrapped.index()].tag == .@"pub") parsed.nodes[wrapped.index()].data.node else wrapped;
    const annotation = structFactoryFieldAnnotation(parsed, source, declaration.index(), "value").?;
    const span = tokenSpan(parsed, parsed.nodes[annotation.index()].token_index);
    try std.testing.expectEqualStrings("T", source[span.start..span.end]);
    const independent = try analyzer(parsed, source, TestAnalysisContext{}, std.testing.allocator).run("analyzeIndependentStructFieldType", .{ declaration.index(), "amount" });
    switch (independent) {
        .success => |type_id| try std.testing.expectEqual(@as(?structures.TypeId, .int), type_id),
        .unsupported => return error.UnexpectedSemanticIssue,
    }
}

fn testStructDefinitionAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
    const source =
        \\static Record = struct
        \\  pub first: int
        \\  second: bool
        \\  third: none
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzer(parsed, source, TestAnalysisContext{}, gpa).run("analyzeStructDefinition", .{ @as(structures.ItemId, @fromBackingInt(@intCast(0))), declaration.index() });
    switch (result) {
        .success => |definition_value| {
            var definition = definition_value;
            definition.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

fn testFunctionSignatureAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
    const source = "static target = func(a: int, b: int, c: int) int -> return a";
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzer(parsed, source, TestAnalysisContext{}, gpa).run("analyzeFunctionSignature", .{declaration.index()});
    switch (result) {
        .success => |signature_value| {
            var signature = signature_value;
            signature.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

fn testUnresolvedFunctionBodyAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
    const source =
        \\static target = func(a: int, b: int, c: int) int
        \\  first(a)
        \\  const aggregate = int{field = first(a)}
        \\  var mutable_aggregate = aggregate
        \\  mutable_aggregate.field = first(a)
        \\  aggregate.field
        \\  aggregate.callback(aggregate.callback(a))
        \\  var value: int = a
        \\  const selected: int = if a < b and (if a < b -> value = second(b, c) else value = third(c, b)) > 0 -> value + 1 else value
        \\  value = selected
        \\  const looped = loop
        \\    value += 1
        \\    if value < b -> continue
        \\    break value
        \\  return third(looped, a, b) + value * -c
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzer(parsed, source, TestAnalysisContext{}, gpa).buildUnresolvedBody(.{ .function = .{ .declaration = declaration.index(), .parameters = &.{
        .{ .mode = .imm, .type_id = .int },
        .{ .mode = .imm, .type_id = .int },
        .{ .mode = .imm, .type_id = .int },
    } } });
    switch (result) {
        .success => |unresolved_value| {
            var unresolved = unresolved_value;
            unresolved.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

const TestAnalysisContext = struct {
    pub fn staticBindings(_: @This()) ![]const structures.StaticBinding {
        return &.{};
    }
    pub fn withStaticBindings(self: @This(), _: []const structures.StaticBinding) @This() {
        return self;
    }
    pub fn stdMemoryFunction(_: @This(), _: []const u8) !?structures.ItemId {
        unreachable;
    }
    pub fn staticCondition(_: @This(), _: structures.Node.Index) !?bool {
        unreachable;
    }
    pub fn staticIteration(_: @This(), _: structures.Node.Index) !?[]const structures.CompileTimeValueId {
        unreachable;
    }

    pub fn panicFunction(_: @This()) !?structures.ItemId {
        unreachable;
    }

    pub fn iterationEndType(_: @This()) !structures.TypeId {
        unreachable;
    }

    pub fn rangeConstructor(_: @This(), _: bool) !?structures.ItemId {
        return null;
    }

    pub fn fromEndConstructor(_: @This()) !?structures.ItemId {
        return null;
    }

    pub fn allocator(_: @This()) std.mem.Allocator {
        return std.testing.allocator;
    }
    pub fn referenceType(_: @This(), _: structures.TypeId, _: bool) !?structures.TypeId {
        unreachable;
    }
    pub fn borrowAccess(_: @This(), _: structures.TypeId) !?struct { element_type: structures.TypeId, writable: bool } {
        return null;
    }

    pub fn internByteString(_: @This(), _: []const u8) !structures.ByteStringId {
        unreachable;
    }
    public_annotation: bool = false,
    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn internVariant(_: @This(), _: []const structures.TypeId) !structures.TypeId {
        unreachable;
    }

    pub fn memberStorageType(_: @This(), member: structures.MemberSpec) !structures.TypeId {
        if (member.kind == .owned) return member.type_id;
        unreachable;
    }

    pub fn memberSpec(_: @This(), storage_type: structures.TypeId) !structures.MemberSpec {
        return .{ .type_id = storage_type };
    }

    pub fn internVariantMembers(_: @This(), _: []const structures.MemberSpec) !structures.TypeId {
        unreachable;
    }

    pub fn internTuple(_: @This(), _: []const structures.MemberSpec) !structures.TypeId {
        unreachable;
    }

    pub fn tupleMembers(_: @This(), _: structures.TypeId) !?[]const structures.MemberSpec {
        return null;
    }

    pub fn borrowElement(_: @This(), _: structures.TypeId) !?structures.TypeId {
        return null;
    }

    pub fn internCallable(_: @This(), _: structures.CallableType) !structures.TypeId {
        unreachable;
    }

    pub fn variantMembers(_: @This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }

    pub fn evaluateWhereMembership(_: @This(), _: structures.Node.Index, _: structures.TypeId) !?bool {
        unreachable;
    }

    pub fn containsBorrow(_: @This(), _: structures.TypeId) !bool {
        unreachable;
    }

    pub fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }

    pub fn structDefinition(_: @This(), _: structures.TypeId) !?structures.StructDefinition {
        return null;
    }

    pub fn arrayType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
        return null;
    }

    pub fn generatedStructType(_: @This(), _: structures.Node.Index) !structures.TypeId {
        unreachable;
    }

    pub fn structIdentityType(_: @This(), _: structures.StructIdentity) !structures.TypeId {
        unreachable;
    }

    pub fn ownedFunction(_: @This(), _: structures.StructIdentity, _: []const u8) !?structures.InstanceId {
        unreachable;
    }

    pub fn functionSignature(_: @This(), _: structures.InstanceId) !?structures.FunctionSignature {
        unreachable;
    }

    pub fn functionShape(_: @This(), _: structures.ItemId) !?structures.FunctionShape {
        unreachable;
    }

    pub fn overloadCallReturnsType(_: @This(), _: structures.FunctionOverloadId, _: structures.Node.Index) !bool {
        unreachable;
    }

    pub fn needsInheritedInference(_: @This(), _: structures.InstanceId) !bool {
        unreachable;
    }

    pub fn isGenericStruct(_: @This(), _: structures.ItemId) !bool {
        unreachable;
    }

    pub fn specializeFunction(_: @This(), _: structures.InstanceId, _: []const structures.CompileTimeValueId) !structures.InstanceId {
        unreachable;
    }

    pub fn internCompileTimeValue(_: @This(), _: structures.CompileTimeValue) !structures.CompileTimeValueId {
        unreachable;
    }

    pub fn lookupCompileTimeValue(_: @This(), _: structures.CompileTimeValueId) !structures.CompileTimeValue {
        unreachable;
    }

    pub fn lookupCompileTimeTuple(_: @This(), _: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
        unreachable;
    }

    pub fn executeComptime(_: @This(), _: structures.Node.Index) !?structures.CompileTimeValueId {
        unreachable;
    }

    pub fn executeComptimeWithType(_: @This(), _: structures.Node.Index, _: ?structures.TypeId) !?structures.CompileTimeValueId {
        unreachable;
    }

    pub fn staticParameterType(_: @This(), _: structures.InstanceId, _: usize, _: []const structures.CompileTimeValueId) !structures.TypeId {
        unreachable;
    }

    pub fn resolveName(_: @This(), _: []const u8) !?structures.NameReference {
        return null;
    }
    pub fn isPublicAnnotationReference(_: @This(), _: structures.NameReference) !bool {
        return true;
    }
    pub fn isPublicFieldType(_: @This(), type_id: structures.TypeId) !bool {
        return type_id.isPrimitive();
    }
    pub fn resolveMemberWithOperands(_: @This(), _: structures.NameReference, _: []const u8, _: structures.SourceSpan, _: ?usize) !?structures.NameReference {
        return null;
    }
    pub fn staticItem(_: @This(), _: structures.InstanceId) !?structures.CompileTimeValueId {
        return null;
    }
    pub fn functionItemReference(_: @This(), _: structures.InstanceId) !?structures.FunctionReference {
        return null;
    }
    pub fn resolveLocalConflict(_: @This(), _: []const u8) !?structures.ItemId {
        return null;
    }

    pub fn resolveStatic(_: @This(), _: []const u8) !?structures.CompileTimeValueId {
        return null;
    }
};
