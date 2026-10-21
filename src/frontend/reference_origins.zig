const std = @import("std");

pub fn Store(comptime Origin: type, comptime Projection: type, comptime Transform: type) type {
    return struct {
        origins: std.ArrayList(Origin) = .empty,
        projections: std.ArrayList(Projection) = .empty,
        transforms: std.ArrayList(Transform) = .empty,

        pub fn add(self: *@This(), allocator: std.mem.Allocator, head: ?u32, origin: Origin) !?u32 {
            var cursor = head;
            while (cursor) |index| {
                const existing = &self.origins.items[index];
                if (existing.frame_type == origin.frame_type and existing.generation == origin.generation and existing.cleanup_value == origin.cleanup_value and
                    existing.root == origin.root and std.meta.eql(existing.binding_identity, origin.binding_identity) and
                    existing.parameter == origin.parameter and existing.loop == origin.loop and
                    existing.source_kind == origin.source_kind and self.sameProjection(existing.source_path, origin.source_path) and
                    existing.storage_depth == origin.storage_depth and existing.after_write == origin.after_write and
                    existing.readonly == origin.readonly and existing.readonly_owned == origin.readonly_owned and
                    existing.variant_guard == origin.variant_guard and
                    existing.permanent == origin.permanent and existing.stable == origin.stable and existing.read == origin.read and
                    existing.deferred_capture == origin.deferred_capture and
                    existing.initializer_owner == origin.initializer_owner and
                    self.sameProjection(existing.projection, origin.projection) and
                    self.sameTransform(existing.transform, origin.transform)) return head;
                cursor = existing.next;
            }
            const index: u32 = @intCast(self.origins.items.len);
            var added = origin;
            added.next = head;
            try self.origins.append(allocator, added);
            return index;
        }

        pub fn sameProjection(self: *const @This(), left: ?u32, right: ?u32) bool {
            var first = left;
            var second = right;
            while (first != second) {
                const first_projection = self.projections.items[first orelse return false];
                const second_projection = self.projections.items[second orelse return false];
                if (!std.meta.eql(first_projection.step, second_projection.step)) return false;
                first = first_projection.next;
                second = second_projection.next;
            }
            return true;
        }

        pub fn sameTransform(self: *const @This(), left: ?u32, right: ?u32) bool {
            var first = left;
            var second = right;
            while (first != second) {
                const first_transform = self.transforms.items[first orelse return false];
                const second_transform = self.transforms.items[second orelse return false];
                if (!std.meta.eql(first_transform.operation, second_transform.operation)) return false;
                first = first_transform.previous;
                second = second_transform.previous;
            }
            return true;
        }

        pub fn merge(self: *@This(), allocator: std.mem.Allocator, first: ?u32, second: ?u32) !?u32 {
            if (first == null) return second;
            if (first == second) return first;
            var merged = first;
            var cursor = second;
            while (cursor) |index| {
                const origin = self.origins.items[index];
                merged = try self.add(allocator, merged, origin);
                cursor = origin.next;
            }
            return merged;
        }
    };
}
