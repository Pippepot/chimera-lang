# AGENTS.md — Project conventions & lessons

## Code organization

- **Single-file entry point.** `x86.zig` is the only Zig file; run with `zig run x86.zig`. No `build.zig`.
- **External assembly** goes in `.asm` files, embedded via `@embedFile("file.asm")` in the `compile` function.
- **Project state** documented in `.agents/project.md`.
- **AGENTS.md** lives alongside `x86.zig` (project root, not repo root).

## Zig 0.16 standard library

- **No `std.heap.GeneralPurposeAllocator`** — use `std.heap.page_allocator` or `init.gpa` from `std.process.Init`.
- **`std.ArrayList(u8)`** — use `initCapacity(gpa, n)` not `init(gpa)`. Methods take `gpa` as first arg: `buf.appendSlice(gpa, ...)`, `buf.print(gpa, ...)`, `buf.deinit(gpa)`.
- **Process spawning** — `std.process.spawn(io, .{ .argv = ..., .stderr = .inherit })`. Returns `Child`, call `child.wait(io)` to get `Term`.
- **Filesystem** — use `std.Io.Dir.cwd()`. Methods take `io`: `dir.writeFile(io, .{...})`, `dir.deleteFile(io, path)`.
- **I/O instance** — passed via `init: std.process.Init`, accessible as `init.io`. In tests, create `std.Io.Threaded.init(allocator, .{})`.
- **`main` signature** — `pub fn main(init: std.process.Init) !void` or return `u8` directly.
- **`zig test`** — test functions have no `init.io`. Create a Threaded Io manually.

## AST design

- **Binary ops** use `*const [2]AstNode` (pointer to fixed-size array of two children).
- **Stack-allocate nodes** when the tree is built and consumed in the same function. No arena/heap needed.
- **Emit private** — only `compile` is public. Tests use `eval` (full pipeline), not `emit`.

## Assembly generation

- **Use 64-bit registers** for push/pop: `push rax`, `pop rax`. `push eax` is invalid in 64-bit mode.
- **32-bit ops are fine** in 64-bit mode: `add eax, ebx`, `sub eax, ebx`, `imul eax, ebx`, `idiv ebx`.
- **Signed division** requires `cdq` before `idiv` (sign-extends `eax` into `edx`).
- **Exit syscall** — `mov edi, eax` (exit code), `mov eax, 60` (syscall number), `syscall`.
- **NASM doesn't read from stdin.** Always write source to a temp file. Use defer to clean up.

## Testing

- **Tests compile and run the full binary** and check the exit code, not assembly strings.
- **Test every AST node** (int, add, sub, mul, div, nested). Cover edge cases like negative results.
- Use `testing.expectEqual(expected: u8, actual: u8)` for exit code assertions.

## Git

- `.gitignore` generated files: `prog`, `x86.asm`, `x86.o`, `.zig-cache/`.
- Commit all source files including `.asm` and test files.

## Style

- **No scoped blocks** for variable reuse. Use descriptive names instead (`asm_child`, `ld_child`).
- **Concrete types** not `anytype` for function parameters where the type is known.
- **Factor repeated patterns** into shared functions (e.g., `emitBinary` for push/emit/mov/pop/op).
- **Separate compile stages** into distinct public functions: `compile` → `assembleAndLink` → `runProg`, then compose as `eval`.
