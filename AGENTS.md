# AGENTS.md — Project conventions & lessons

## Code organization

- **Entry point.** `x86.zig` is the main Zig file; run with `zig run x86.zig`. No `build.zig`.
- **Module split:** `x86.zig` owns AST types + binary pipeline (`assembleAndLink`, `runProg`, `eval`, `main`). `codegen.zig` owns IR types, lowering, register allocator, and emission. `debug.zig` owns debug helpers.
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
- **`var` vs `const` on slices** — element mutation does NOT count as variable reassignment. Use `const` for slices where only elements are mutated.
- **`@intCast(value)`** — takes one argument; destination type is inferred from context. Not `@intCast(T, value)`.

## AST design

- **Binary ops** use `*const [2]AstNode` (pointer to fixed-size array of two children).
- **Stack-allocate nodes** when the tree is built and consumed in the same function. No arena/heap needed.
- **Emit private** — only `compile` is public. Tests use `eval` (full pipeline), not `emit`.
- **Factor binop lowering** — shared `lowerBinop` function lowers both children, returns `InstPair`. Each binop arm is a one-liner.
- **Factor codegen binops** — iadd/isub share `emitAddSub(mnemonic, p, i)` differing only by the mnemonic string. imul/idiv get their own helpers (`emitImul`, `emitIdiv`) due to x86 instruction quirks (three-operand `imul`, `cdq` before `idiv`). All four share the `freeOperands` + `assignResult` tail.

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
- **Factor repeated patterns** into shared functions. For codegen: `emitAddSub` with mnemonic param, `emitImul`/`emitIdiv` for x86-specific quirks, `freeOperands` + `assignResult` as shared tail.
- **Separate compile stages** into distinct public functions: `compile` → `assembleAndLink` → `runProg`, then compose as `eval`.
- **Emitter struct for stateful codegen** — when codegen helpers share mutable state (registers, spill slots, use counts), group state into a struct with `*@This()` methods. Zig's anonymous structs (`const foo = struct { fn _() ... }._`) cannot capture mutable variables across the namespace boundary, so the Emitter struct is the idiomatic alternative to threading 8+ parameters.
- **Caller-provided output buffer** — functions like `emitIr` take a `*std.ArrayList(u8)` buffer parameter instead of returning one. The caller controls allocation, enabling reuse (e.g., `compileIr` adds prologue/epilogue around the buffer, `debug.zig` uses a separate buffer for display).
- **Hoist `try` from format args** — don't inline `try foo()` inside a `buf.print(...)` format argument. Assign the result to a variable first. Error union types don't coerce to format arguments.
- **Single pass over multi-concern loops** — when a loop body has multiple concerns (find free reg, track spill victim), handle all in a single pass with simple branches. Don't split into sequential passes unless each has a genuinely different structure.
