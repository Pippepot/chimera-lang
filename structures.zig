// Source structures

pub const FileId = u64;

pub const File = struct { content: []const u8 };

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub const Diagnostic = struct {
    span: ?SourceSpan,
    message: []const u8,
};

pub const Ast = struct {};
