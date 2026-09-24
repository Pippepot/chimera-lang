pub const codegen = @import("src/backend/codegen.zig");
pub const modules = @import("src/modules.zig");
pub const query = @import("src/query/engine.zig");
pub const queries = @import("src/queries.zig");
pub const runtime = @import("src/runtime.zig");
pub const structures = @import("src/structures.zig");

test {
    _ = @import("src/frontend/tokenizer.zig");
    _ = @import("src/frontend/parser.zig");
    _ = @import("src/frontend/semantic.zig");
    _ = @import("src/frontend/lifetime.zig");
    _ = @import("src/frontend/typing.zig");
    _ = @import("src/query/codec.zig");
    _ = @import("src/backend/disasm.zig");
}
