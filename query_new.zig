const std = @import("std");
const structures = @import("structures.zig");
const parser = @import("parser.zig");
const ast = @import("ast_new.zig");

const Revision = u64;

pub const QueryError = error{
    SourceNotFound,
    QueryCycle,
};

pub fn QueryResult(comptime T: type) type {
    return struct {
        value: ?T, // value can be null when a query has failed, producing diagnostics only
        diagnostics: std.ArrayList(structures.Diagnostic),
        deps: std.ArrayList(u64),
        verified_at: Revision = 0,
        changed_at: Revision = 0,
        computing: bool = false,
    };
}

pub const QueryDB = struct {
    gpa: std.mem.Allocator,
    sources: std.AutoHashMap(structures.FileId, structures.File),
    asts: std.AutoHashMap(structures.FileId, structures.File),

    pub fn init(gpa: std.mem.Allocator) QueryDB {
        return QueryDB{
            .gpa = gpa,
            .sources = std.AutoHashMap(structures.FileId, structures.File).init(gpa),
        };
    }

    pub fn setSource(self: @This(), path: []const u8, content: []const u8) !structures.FileId {
        const path_hash = std.hash.Wyhash.hash(0, path);
        const file = structures.File{ .content = content };
        try self.sources.put(path_hash, file);
        return path_hash;
    }

    pub fn queryAst(self: @This(), sourceId: structures.FileId) QueryError!QueryResult(structures.Ast) {
        const source = self.sources.get(sourceId) orelse return QueryError.SourceNotFound;
    }

    pub fn query(self: @This(), comptime T: type)
    // pub fn save(self: @This(), io: std.Io.Writer) !void {}

    // pub fn load(self: @This(), io: std.Io.Writer) !void {}

    pub fn deInit(self: @This()) !void {
        self.sources.deinit();
    }
};

// Query is a function with dependencies
const Query = struct {
    // Deps

};

const AstQuery = struct {

};

// One way to set it up is, pre register available queries at comptime - scheduler sets up dependencies internally based on return type. API asks for type only
// Not good if queries depend on other inputs than other queires only. - which they do, file id

const Scheduler = struct {
    queries: []


};
