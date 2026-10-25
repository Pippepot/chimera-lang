const std = @import("std");
const structures = @import("structures.zig");
const standard_library = @import("standard_library");

pub const Effect = enum { pure, storage, control, io };

pub fn effect(symbol: standard_library.External) Effect {
    switch (symbol) {
        .io_read, .io_write => return .io,
        .exit, .panic_message, .static_iteration_item => return .control,
        .allocate,
        .allocate_host_storage,
        .deallocate,
        .deallocate_host_storage,
        .deallocate_box,
        .allocation_count,
        .unsafe_own_box,
        .unsafe_initialize,
        .initialize_collection,
        .initialize_collection_element,
        .unsafe_take,
        .unsafe_take_box,
        .unsafe_destroy,
        .unsafe_destroy_box,
        .unsafe_borrow,
        .borrow,
        .array_borrow,
        .empty_cursor,
        .array_cursor,
        .allocation_cursor,
        .cursor_offset,
        .cursor_element,
        .cursor_attenuate,
        => return .storage,
        .primitive_operation, .copy_value, .move_value, .array_filled, .array_from, .literal_byte, .byte_int => return .pure,
    }
}

pub fn validHostStorage(definition: *const structures.StructDefinition) bool {
    if (!ownedResource(definition, &.{ "address_low", "address_high", "byte_size" }, .explicit)) return false;
    for (definition.fields) |field| if (field.type_id != .int) return false;
    return true;
}

pub fn validAllocation(definition: *const structures.StructDefinition, storage_type: structures.TypeId) bool {
    return ownedResource(definition, &.{ "storage", "count" }, .explicit) and
        definition.fields[0].type_id == storage_type and definition.fields[1].type_id == .int;
}

pub fn validBox(definition: *const structures.StructDefinition) bool {
    return ownedResource(definition, &.{"allocation"}, .custom);
}

pub fn validSpan(facts: anytype, definition: *const structures.StructDefinition, element_type: structures.TypeId) !bool {
    return trivialView(definition, &.{ "data", "size" }) and definition.fields[1].type_id == .int and
        (try facts.storageCursorAccess(definition.fields[0].type_id)) == element_type;
}

pub fn validStaticString(facts: anytype, definition: *const structures.StructDefinition) !bool {
    return trivialView(definition, &.{"bytes"}) and (try facts.spanAccess(definition.fields[0].type_id)) == .byte;
}

pub fn validStorageCursor(definition: *const structures.StructDefinition) bool {
    return trivialView(definition, &.{ "address_low", "address_high" }) and
        definition.fields[0].type_id == .int and definition.fields[1].type_id == .int;
}

/// A resource can be neither moved nor copied and is released by its `drop` capability.
fn ownedResource(definition: *const structures.StructDefinition, names: []const []const u8, drop: structures.DropCapability) bool {
    const ownership = definition.ownership;
    return ownedFields(definition, names) and ownership.move == null and ownership.copy == null and
        ownership.drop != null and ownership.drop.?.capability == drop;
}

fn ownedFields(definition: *const structures.StructDefinition, names: []const []const u8) bool {
    if (definition.is_static or definition.fields.len != names.len) return false;
    for (definition.fields, names) |field, name| {
        if (field.kind != .owned or !std.mem.eql(u8, field.name, name)) return false;
    }
    return true;
}

fn trivialView(definition: *const structures.StructDefinition, names: []const []const u8) bool {
    if (!ownedFields(definition, names) or definition.ownership.move != null or definition.ownership.drop != null or
        definition.ownership.copy == null or definition.ownership.copy.?.capability != .trivial) return false;
    for (definition.fields) |field| if (field.is_public) return false;
    return true;
}

pub fn hasTypedBody(symbol: standard_library.External) bool {
    switch (symbol) {
        .allocate,
        .allocate_host_storage,
        .deallocate,
        .deallocate_box,
        .deallocate_host_storage,
        .allocation_count,
        .io_read,
        .io_write,
        .exit,
        .panic_message,
        => return false,
        else => return true,
    }
}

pub fn validOperationShape(operation: structures.Operation, signature: structures.FunctionSignature) bool {
    const index_write = operation == .@"[]=";
    const count = operation.operandCount();
    if (signature.parameters.len != count) return false;
    const receiver = signature.parameters[0];
    if (!(operation == .@"[]" and receiver.mode == .ref) and receiver.mode != (if (index_write) structures.ParameterMode.mut else .imm)) return false;
    if (operation != .@"[]" and signature.result_mode != .owned) return false;
    if (operation.isIndexer()) {
        if (signature.parameters[1].mode != .imm) return false;
        if (index_write and (signature.parameters[2].mode != .@"var" or signature.return_type != .unit)) return false;
        return true;
    }
    if (count == 2) {
        if (signature.parameters[1].mode != .imm) return false;
        if (!operation.isPredicate() and signature.parameters[1].type_id != receiver.type_id) return false;
    }
    return signature.return_type == (if (operation.isPredicate()) structures.TypeId.bool else receiver.type_id);
}

pub fn signatureIssue(facts: anytype, behavior: structures.CallBehavior, signature: structures.FunctionSignature, iteration_end: ?structures.TypeId) !?structures.Diagnostic.Kind {
    switch (behavior) {
        .box_new => return boxNewIssue(facts, signature),
        .box_value => return boxValueIssue(facts, signature),
        .list_append, .list_reserve, .list_remove, .list_consume, .collection_append_bounded, .collection_append_growing => return listElementIssue(facts, behavior, signature, iteration_end),
        else => return null,
    }
}

fn boxNewIssue(facts: anytype, signature: structures.FunctionSignature) !?structures.Diagnostic.Kind {
    if (signature.parameters.len != 1) return null;
    const element = signature.parameters[0].type_id;
    const capabilities = (try facts.ownershipCapabilities(element)) orelse return error.Unavailable;
    return if (capabilities.requires_explicit_drop) .{ .box_requires_automatic_drop = element } else null;
}

fn boxValueIssue(facts: anytype, signature: structures.FunctionSignature) !?structures.Diagnostic.Kind {
    const capabilities = (try facts.ownershipCapabilities(signature.return_type)) orelse return error.Unavailable;
    return if (!capabilities.isDirectlyMovable()) .{ .box_extraction_requires_direct_move = signature.return_type } else null;
}

fn listElementIssue(facts: anytype, behavior: structures.CallBehavior, signature: structures.FunctionSignature, iteration_end: ?structures.TypeId) !?structures.Diagnostic.Kind {
    if (signature.parameters.len == 0) return null;
    const element = (try facts.listElement(signature.parameters[0].type_id)) orelse return null;
    const capabilities = (try facts.ownershipCapabilities(element)) orelse return error.Unavailable;
    if (capabilities.requires_explicit_drop) return .{ .list_requires_automatic_drop = element };
    if (behavior != .collection_append_bounded and !capabilities.isDirectlyMovable()) return .{ .list_requires_direct_move = element };
    if (behavior != .list_consume) return null;
    if (element == iteration_end) return .{ .list_iteration_item_conflicts_with_end = element };
    if (try facts.variantMembers(element)) |members| {
        for (members) |member| if (member == iteration_end) return .{ .list_iteration_item_conflicts_with_end = element };
    }
    return null;
}

pub fn validExternalSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    const expected_result: structures.ResultMode = switch (symbol) {
        .array_borrow, .borrow, .unsafe_borrow, .cursor_element => .reference,
        else => .owned,
    };
    if (signature.result_mode != expected_result) return false;
    switch (symbol) {
        .primitive_operation => return true,
        .static_iteration_item => return hasShape(signature, &.{.imm}) and signature.return_type == .unit,
        .copy_value => return hasShape(signature, &.{.imm}) and signature.parameters[0].type_id == signature.return_type,
        .move_value => return hasShape(signature, &.{.deinit}) and signature.parameters[0].type_id == signature.return_type,
        .array_filled => return validArrayFilledSignature(facts, signature),
        .initialize_collection => return validCollectionInitializerSignature(facts, signature),
        .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate => return validCursorSignature(facts, symbol, signature),
        .array_from => return validArrayFromSignature(facts, signature),
        .byte_int => return hasShape(signature, &.{.imm}) and signature.parameters[0].type_id == .byte and signature.return_type == .int,
        .io_write => return validByteOutputSignature(facts, signature),
        .io_read => return (try optionalPayload(facts, signature.return_type)) == .int and signature.parameters.len == 4 and
            signature.parameters[0].type_id == .int and (try facts.allocationElement(signature.parameters[1].type_id)) == structures.TypeId.byte and
            signature.parameters[2].type_id == .int and signature.parameters[3].type_id == .int and hasShape(signature, &.{ .imm, .imm, .imm, .imm }),
        .literal_byte => return hasShape(signature, &.{}) and signature.return_type == .byte,
        .array_borrow => return validArrayBorrowSignature(facts, signature),
        .exit => return hasShape(signature, &.{.imm}) and signature.return_type == .never and signature.parameters[0].type_id == .int,
        .panic_message => return hasShape(signature, &.{.imm}) and signature.return_type == .never and
            signature.parameters[0].type_id == try facts.panicMessageType(),
        .allocate_host_storage, .deallocate_host_storage => return validHostStorageSignature(facts, symbol, signature),
        .allocate, .deallocate => return validAllocationSignature(facts, symbol, signature),
        .allocation_count => return hasShape(signature, &.{.imm}) and signature.return_type == .int and
            (try facts.allocationElement(signature.parameters[0].type_id)) != null,
        .unsafe_initialize, .initialize_collection_element, .unsafe_take, .unsafe_destroy, .unsafe_borrow => return validAllocationAccessSignature(facts, symbol, signature),
        .borrow => return hasShape(signature, &.{.ref}) and (try facts.boxElement(signature.parameters[0].type_id)) == signature.return_type,
        .unsafe_own_box => return validBoxOwnershipSignature(facts, signature),
        .unsafe_take_box, .unsafe_destroy_box, .deallocate_box => return validBoxAccessSignature(facts, symbol, signature),
    }
}

fn validArrayFromSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{.init})) return false;
    const shape = (try facts.collectionLiteralType(signature.parameters[0].type_id)) orelse return false;
    const array = (try facts.arrayType(signature.return_type)) orelse return false;
    return std.meta.eql(shape, array);
}

fn validByteOutputSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{ .imm, .imm }) or (try optionalPayload(facts, signature.return_type)) != .int or signature.parameters[0].type_id != .int) return false;
    return (try facts.spanAccess(signature.parameters[1].type_id)) == structures.TypeId.byte;
}

fn validHostStorageSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    const storage_type = (try facts.hostStorage()) orelse return false;
    switch (symbol) {
        .allocate_host_storage => return hasShape(signature, &.{.imm}) and (try optionalPayload(facts, signature.return_type)) == storage_type and
            signature.parameters[0].type_id == .int,
        .deallocate_host_storage => return hasShape(signature, &.{.deinit}) and signature.return_type == .unit and
            signature.parameters[0].type_id == storage_type,
        else => unreachable,
    }
}

fn validAllocationSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    if (signature.parameters.len != 1) return false;
    const type_id = if (symbol == .allocate) (try optionalPayload(facts, signature.return_type)) orelse return false else signature.parameters[0].type_id;
    if (try facts.allocationElement(type_id) == null) return false;
    return if (symbol == .allocate)
        hasShape(signature, &.{.imm}) and signature.parameters[0].type_id == .int
    else
        hasShape(signature, &.{.deinit}) and signature.return_type == .unit;
}

fn validAllocationAccessSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    if (signature.parameters.len != (if (symbol == .unsafe_initialize or symbol == .initialize_collection_element) @as(usize, 3) else 2)) return false;
    const allocation = signature.parameters[0];
    if (allocation.mode != (if (symbol == .unsafe_borrow) structures.ParameterMode.ref else .mut)) return false;
    const element_type = (try facts.allocationElement(allocation.type_id)) orelse return false;
    if (symbol == .unsafe_take) {
        const capabilities = (try facts.ownershipCapabilities(element_type)) orelse return false;
        if (!capabilities.isDirectlyMovable()) return false;
    }
    if (signature.parameters[1].mode != .imm or signature.parameters[1].type_id != .int) return false;
    switch (symbol) {
        .unsafe_initialize, .initialize_collection_element => return signature.return_type == .unit and signature.parameters[2].mode == .init and signature.parameters[2].type_id == element_type,
        .unsafe_take, .unsafe_borrow => return signature.return_type == element_type,
        .unsafe_destroy => return signature.return_type == .unit,
        else => unreachable,
    }
}

fn validBoxOwnershipSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{.deinit})) return false;
    const element_type = (try facts.allocationElement(signature.parameters[0].type_id)) orelse return false;
    return (try facts.boxElement(signature.return_type)) == element_type;
}

fn validBoxAccessSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    if (signature.parameters.len != 1) return false;
    const element_type = (try facts.boxElement(signature.parameters[0].type_id)) orelse return false;
    if (symbol == .deallocate_box) return signature.parameters[0].mode == .deinit and signature.return_type == .unit;
    if (symbol == .unsafe_destroy_box) return signature.parameters[0].mode == .mut and signature.return_type == .unit;
    const capabilities = (try facts.ownershipCapabilities(element_type)) orelse return false;
    return signature.parameters[0].mode == .mut and signature.return_type == element_type and capabilities.isDirectlyMovable();
}

fn validArrayFilledSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{.imm})) return false;
    const array = (try facts.arrayType(signature.return_type)) orelse return false;
    return signature.parameters[0].type_id == array.element_type;
}

fn validCursorSignature(facts: anytype, symbol: standard_library.External, signature: structures.FunctionSignature) !bool {
    if (symbol == .empty_cursor) return signature.parameters.len == 0 and try facts.storageCursorAccess(signature.return_type) != null;
    if (symbol == .cursor_element) {
        if (!hasShape(signature, &.{ .ref, .imm }) or signature.parameters[1].type_id != .int) return false;
        const source = (try facts.storageCursorAccess(signature.parameters[0].type_id)) orelse return false;
        return signature.return_type == source;
    }
    const target = (try facts.storageCursorAccess(signature.return_type)) orelse return false;
    if (symbol == .cursor_offset) {
        return hasShape(signature, &.{ .ref, .imm }) and signature.parameters[0].type_id == signature.return_type and
            signature.parameters[1].type_id == .int;
    }
    if (signature.parameters.len != 1) return false;
    const source = signature.parameters[0];
    switch (symbol) {
        .array_cursor => {
            const array = (try facts.arrayType(source.type_id)) orelse return false;
            return array.element_type == target and source.mode == .ref;
        },
        .allocation_cursor => return (try facts.allocationElement(source.type_id)) == target and source.mode == .ref,
        .cursor_attenuate => {
            const access = (try facts.storageCursorAccess(source.type_id)) orelse return false;
            return source.mode == .imm and access == target;
        },
        else => unreachable,
    }
}

fn validArrayBorrowSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{ .ref, .imm }) or signature.parameters[1].type_id != .int) return false;
    const array = (try facts.arrayType(signature.parameters[0].type_id)) orelse return false;
    return signature.return_type == array.element_type;
}

fn validCollectionInitializerSignature(facts: anytype, signature: structures.FunctionSignature) !bool {
    if (!hasShape(signature, &.{ .mut, .init }) or signature.return_type != .unit) return false;
    const element = (try facts.allocationElement(signature.parameters[0].type_id)) orelse return false;
    const collection = (try facts.collectionLiteralType(signature.parameters[1].type_id)) orelse return false;
    return collection.element_type == element;
}

fn hasShape(signature: structures.FunctionSignature, modes: []const structures.ParameterMode) bool {
    if (signature.parameters.len != modes.len) return false;
    for (signature.parameters, modes) |parameter, mode| if (parameter.mode != mode) return false;
    return true;
}

/// The native allocation and I/O boundary returns an ordinary two-member variant.
pub fn optionalPayload(facts: anytype, type_id: structures.TypeId) !?structures.TypeId {
    const members = (try facts.variantMembers(type_id)) orelse return null;
    if (members.len != 2) return null;
    if (members[0] == .none) return members[1];
    if (members[1] == .none) return members[0];
    return null;
}
