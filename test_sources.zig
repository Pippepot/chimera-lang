const std = @import("std");

pub const cache = @import("src/cache.zig");
pub const codegen = @import("src/backend/codegen.zig");
pub const comptime_interpreter = @import("src/frontend/comptime_interpreter.zig");
pub const modules = @import("src/modules.zig");
pub const query = @import("src/query/engine.zig");
pub const queries = @import("src/queries.zig");
pub const query_disk_cache = @import("src/query_disk_cache.zig");
pub const runtime = @import("src/runtime.zig");
pub const structures = @import("src/structures.zig");

var allocation_failure_backing: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
// In-place growth depends on allocator storage state. Reject resize and remap
// so every growth is an allocation checked by checkAllAllocationFailures.
var allocation_failure_growth = std.testing.FailingAllocator.init(allocation_failure_backing.allocator(), .{ .resize_fail_index = 0 });
pub const allocation_failure_allocator = allocation_failure_growth.allocator();

pub const SourceFixture = struct {
    db: *query.Database,

    pub fn init(source: []const u8) !SourceFixture {
        return initFiles(source, &.{});
    }

    pub fn initFiles(source: []const u8, files: []const modules.SourceFile) !SourceFixture {
        const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 2 });
        errdefer db.deinit();
        try modules.registerSources(db, std.testing.allocator, source, files, &.{});
        return .{ .db = db };
    }

    pub fn deinit(self: SourceFixture) void {
        self.db.deinit();
    }

    pub fn printDiagnostics(self: SourceFixture, entry: structures.FileId) !void {
        const source = (try self.db.input(queries.SourceText, entry)).*;
        std.debug.print("Chi entry source:\n{s}\n", .{source});
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, entry, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| std.debug.print("file {d}: {any} at {any}\n", .{ diagnostic.file_id, diagnostic.kind, diagnostic.span });
    }

    pub fn executable(self: SourceFixture, entry: structures.FileId) !structures.Executable {
        if ((try self.db.get(queries.BuildExecutable, entry)).*) |program| return program;
        try self.printDiagnostics(entry);
        return error.TestUnexpectedResult;
    }

    pub fn expectExit(self: SourceFixture, entry: structures.FileId, status: u8) !void {
        const program = try self.executable(entry);
        try runtime.writeProgram(std.testing.io, program.bytes);
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
        const actual_status = try runtime.runProg(std.testing.io, std.testing.allocator, &.{});
        if (actual_status != status) try self.printDiagnostics(entry);
        try std.testing.expectEqual(status, actual_status);
    }

    pub fn runIo(self: SourceFixture, input: []const u8) !std.process.RunResult {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const executable_bytes = try self.executable(0);
        var program = try runtime.prepareProgram(io, allocator, executable_bytes.bytes);
        defer program.deinit(io);
        defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
        var child = try std.process.spawn(io, .{ .argv = &.{program.path}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
        defer child.kill(io);
        // Fixtures use bounded input; close it to make EOF observable.
        std.debug.assert(input.len <= 4096);
        try child.stdin.?.writeStreamingAll(io, input);
        child.stdin.?.close(io);
        child.stdin = null;
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(64, .none)) |_| {} else |err| {
            switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }
        try reader.checkAnyError();
        const term = try child.wait(io);
        const stdout = try reader.toOwnedSlice(0);
        errdefer allocator.free(stdout);
        return .{ .term = term, .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
    }

    pub fn expectSourceExit(source: []const u8, status: u8) !void {
        const fixture = try init(source);
        defer fixture.deinit();
        try fixture.expectExit(0, status);
    }

    pub fn expectParity(source: []const u8, status: u8) !void {
        return expectFilesParity(source, &.{}, status);
    }

    pub fn expectFilesParity(source: []const u8, files: []const modules.SourceFile, status: u8) !void {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const program = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
            defer std.testing.allocator.free(program);
            const fixture = try initFiles(program, files);
            defer fixture.deinit();
            try fixture.expectExit(0, status);
        }
    }

    pub fn expectDiagnostic(self: SourceFixture, file: ?structures.FileId, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        try std.testing.expect((try self.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| {
            if ((file == null or diagnostic.file_id == file.?) and std.meta.activeTag(diagnostic.kind) == kind) return;
        }
        try self.printDiagnostics(0);
        return error.ExpectedDiagnostic;
    }

    pub fn expectLibraryDiagnostic(self: SourceFixture, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        const file = (try self.db.input(queries.StandardFile, @backingInt(@import("standard_library").File.memory_allocation))).*;
        try self.expectDiagnostic(file, kind);
    }

    pub fn expectSourceDiagnostic(source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        return expectSourceFileDiagnostic(source, 0, kind);
    }

    pub fn expectAnySourceDiagnostic(source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        return expectSourceFileDiagnostic(source, null, kind);
    }

    fn expectSourceFileDiagnostic(source: []const u8, file: ?structures.FileId, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        const fixture = try init(source);
        defer fixture.deinit();
        try fixture.expectDiagnostic(file, kind);
    }

    pub fn expectRejected(source: []const u8) !void {
        const fixture = try init(source);
        defer fixture.deinit();
        try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        try std.testing.expect(diagnostics.len != 0);
    }
};

pub fn renderTemplate(allocator: std.mem.Allocator, source: []const u8, values: anytype) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, position, '$')) |start| {
        try result.appendSlice(allocator, source[position..start]);
        var end = start + 1;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1) {}
        const name = source[start + 1 .. end];
        var matched = false;
        inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                try result.appendSlice(allocator, @field(values, field_name));
                matched = true;
            }
        }
        if (!matched) return error.UnknownTemplateParameter;
        position = end;
    }
    try result.appendSlice(allocator, source[position..]);
    return result.toOwnedSlice(allocator);
}

test "source templates substitute named dollar markers" {
    const rendered = try renderTemplate(std.testing.allocator, "Item{value = $value}; $value_long; $value; $empty", .{
        .value = "42",
        .value_long = "$untouched",
        .empty = "",
    });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Item{value = 42}; $untouched; 42; ", rendered);
    try std.testing.expectError(error.UnknownTemplateParameter, renderTemplate(std.testing.allocator, "$missing", .{}));
}

test {
    _ = @import("src/main.zig");
    _ = cache;
    _ = query_disk_cache;
    _ = queries;
    _ = modules;
    _ = runtime;
    _ = @import("src/frontend/tokenizer.zig");
    _ = @import("src/frontend/parser.zig");
    _ = @import("src/frontend/semantic.zig");
    _ = @import("src/frontend/flow_snapshot.zig");
    _ = @import("src/frontend/lifetime.zig");
    _ = @import("src/frontend/typing.zig");
    _ = @import("src/query/codec.zig");
    _ = @import("src/backend/disasm.zig");
}
