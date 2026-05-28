# AGENTS.md — Project conventions & lessons

## Code organization

- **Entry point.** `main.zig` is the main Zig file; run with `zig run main.zig -- <source-file> [program-args...]`. No `build.zig`.
- **Module split:**
  - `main.zig` owns AST types plus runtime entrypoints (`writeProgram`, `runProg`, `eval`, `main`) and query diagnostics formatting.
  - `parser.zig` owns lexer + parser (`parseOwned`) from source text to AST.
  - `typecheck.zig` owns AST type inference/checking (`unit`, `bool`, `int`, `float`).
  - `query.zig` owns the revisioned incremental query system (`QueryDb`) and stage memos (`parse`, `typecheck`, `lower`, `compile`).
  - `ir.zig` owns SSA/block IR types and typed AST -> IR lowering.
  - `codegen.zig` owns IR -> x86 machine code + ELF emission.
  - `debug.zig` owns debug flag parsing and AST/SSA debug dumps.
  - `helpers_bin.zig` owns pre-assembled helper blobs (`print_int`, `print_bool`, `print_float32`, `atoi`).
- **Project state** is documented in `.agents/project.md`.
- **AGENTS.md** lives alongside `main.zig` (project root, not repo root).

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

## AST + parser design

- **Binary ops** use `*const [2]AstNode` (pointer to fixed-size array of two children).
- **Statements are newline-separated.** `;` is not a statement separator.
- **`const` locals are lexical and non-mutable.** Rebinding/shadowing is currently rejected.
- **Parentheses are grouping only.** `(...)` does not create a new scope.
- **Parser ownership:** `parser.parseOwned` returns `ParsedAst` with an arena that owns all AST allocations.
- **Query ownership:** parse memo values in `QueryDb` own `ParsedAst`; callers borrow `*const AstNode` via `parsedAst`.
- **Unary minus** is lowered in parser as either negative literal or `0 - expr`.

## Query system design

- **`QueryDb` is reusable state.** Keep one DB across revisions to get incremental behavior.
- **Inputs are virtual source IDs.** `setSource(source_id, text)` updates source text and revision tracking.
- **Stage queries:** `parse(source_id)` -> `typecheck(source_id)` -> `lower(source_id)` -> `compile(source_id)`.
- **Memo metadata:** each memo tracks `deps`, `verified_at`, `changed_at`, and `computing`.
- **Red/green verification:**
  - If `verified_at == current_revision`, it is an immediate hit.
  - Otherwise re-check dependencies recursively before deciding to recompute.
- **Compile backdating:** if recomputed compile bytes are identical, preserve old `changed_at`.
- **Purity boundary:** queries return data only; writing executables and running child processes stay outside query code.

## Assembly generation

- **Use 64-bit registers** for push/pop: `push rax`, `pop rax`. `push eax` is invalid in 64-bit mode.
- **32-bit ops are fine** in 64-bit mode: `add eax, ebx`, `sub eax, ebx`, `imul eax, ebx`, `idiv ebx`.
- **Signed division** requires `cdq` before `idiv` (sign-extends `eax` into `edx`).
- **Exit syscall** — `mov edi, eax` (exit code), `mov eax, 60` (syscall number), `syscall`.

## Debug flags

- Use `--debug=ast,ssa,timing,query` (comma-separated) with `zig run main.zig -- ...`.
- `query` prints query diagnostics (revision, source updates, stage hits/recomputes, dependency checks/invalidations).

## CLI behavior

- The first non-debug CLI argument is treated as the source file path to compile.
- Remaining non-debug CLI arguments are passed through to the generated `./prog` (visible to `arg(n)`).

## Testing

- **Behavioral tests** compile and run full binaries from source strings via `QueryDb`.
- **Type tests** cover numeric/boolean typing, strict no-coercion behavior, and type errors.
- **Incremental tests** verify query cache hits, invalidation on source changes, per-source isolation, unchanged-source no revision bump, and compile `changed_at` backdating.
- **Debug formatting test** verifies stable query diagnostics text output.

## Git

- `.gitignore` generated files: `prog`, `main`, `x86.asm`, `x86.o`, `.zig-cache/`.
- Commit all source files including parser/query modules and tests.

## Style

- **No scoped blocks** for variable reuse. Use descriptive names instead (`asm_child`, `ld_child`).
- **Concrete types** not `anytype` for function parameters where the type is known.
- **Factor repeated patterns** into shared functions.
- **Hoist `try` from format args** — don't inline `try foo()` inside `buf.print(...)` format args.
- **Single pass over multi-concern loops** where practical.
