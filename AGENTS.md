# AGENTS.md — Project conventions & lessons

## Code organization

- **Entry point.** `main.zig` is the main Zig file; run with `zig run main.zig -- <source-file> [program-args...]`. No `build.zig`.
- **Module split:**
  - `main.zig` owns CLI/runtime entrypoint (`main`) and orchestration of query stages + diagnostics printing.
  - `ast.zig` owns AST module/declaration/type nodes and expression nodes (`AstNode`, `IfNode`, `VarNode`, `ConstNode`, `BlockNode`).
  - `runtime.zig` owns runtime helper entrypoints (`writeProgram`, `runProg`).
  - `parser.zig` owns lexer + parser (`parseOwned`) from source text to module AST, plus `computeParse` for query integration.
  - `resolver.zig` owns pre-typecheck symbol resolution (`computeResolve`) and symbol diagnostics.
  - `typecheck.zig` owns type inference/checking (`unit`, `bool`, `int`, `float`, function types), plus `computeType` for query integration.
  - `monomorphize.zig` owns the monomorphization stage artifact (`computeMonomorphize`).
  - `query.zig` owns the revisioned incremental query system (`QueryDb`) and stage orchestration (frame management, dependency tracking, memo verification).
  - `query_cache.zig` owns cross-run persistent query cache encoding/decoding, atomic save/load, and stale-cache cleanup.
  - `ir.zig` owns multi-function IR types and typed AST -> IR lowering, plus `computeLower` for query integration.
  - `codegen.zig` owns IR -> x86 machine code + ELF emission, plus `computeCompile` for query integration.
  - `db.zig` owns shared query types (`SourceId`, `Revision`, `Dependency`, `QueryKey`, `QueryStats`, `Stage`, `CompileResult`, `DbError`) and comparison helpers.
  - `scope.zig` owns a shared lexical scope stack utility (`ScopeStack`) reused by typechecker and lowering.
  - `debug.zig` owns debug flag parsing and AST/SSA debug dumps.
  - `helpers_bin.zig` owns pre-assembled helper blobs (`print_int`, `print_bool`, `print_float32`, `print_string`, `atoi`).
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

- **Program root is module + optional top-level entry block.** Parse produces declarations and an executable top-level entry node (`Module.entry`), and top-level statements are valid.
- **Program bodies use explicit block nodes.** Multi-statement bodies parse to `AstNode.block` containing ordered statement pointers.
- **Binary ops** use `*const [2]AstNode` (pointer to fixed-size array of two children).
- **Statements are newline-separated.** `;` is not a statement separator.
- **`const` locals are lexical and non-mutable.** `var` locals are lexical and mutable. Rebinding/shadowing is currently rejected for both.
- **Binding annotations are optional.** `const`/`var` support `name: Type = expr`; annotation must match inferred RHS type.
- **`const` is statement-scoped.** `const name = expr` binds in the surrounding block scope; it no longer owns a nested `body` expression.
- **Parentheses are grouping only.** `(...)` does not create a new scope.
- **Parser ownership:** `parser.parseOwned` returns `ParsedAst` with an arena that owns all AST allocations.
- **Query ownership:** parse memo values in `QueryDb` own `ParsedAst`; callers borrow `*const AstNode` via `parsedAst`.
- **Unary minus** is lowered in parser as either negative literal or `0 - expr`.
- **String parsing:** the lexer's `next()` does `self.index += 1` before dispatching `"` to `parseString()`, so `parseString` must NOT also increment — use `const start = self.index - 1` instead of `self.index += 1`.

## Type syntax

- **Primitive types:** `unit`, `bool`, `int`, `float`, `string`.
- **Function types:** `func(ParamType1, ParamType2, ...) ReturnType` — usable in parameter annotations (`f: func(int) int`), return type annotations, and `const`/`var` binding annotations.
- **Named struct types:** referenced by their declared name (e.g. `Foo`) — usable in `const`/`var` binding annotations.

## Struct types and initialization

- **Struct declaration:** `comptime Name = struct` followed by newline and indented field lines (`field: type`).
- **Struct init:** `TypeName{field1 = expr, field2 = expr, ...}`. Must provide all fields in order; field count and names are checked by the typechecker.
- **Field access:** `expr.fieldName`. The expression must be of a named struct type.
- **IR lowering:**
  - `var`/`const` with a `struct_init` value allocates N consecutive stack slots (one per field) and emits `store` for each field value.
  - Field access for index 0 returns the base slot directly. For higher indices it emits `field_load(base, field_index)` which loads from slot `base + field_index`.
- **Structs in function args/returns** are not yet supported.

- **`var` locals** are mutable and use the same syntax as `const`: `var name = expr`.
- **Reassignment:** `name = expr` produces unit (can be used as an expression).
- **Type system:** Checker tracks `Binding { ty, mutable }` via `ScopeStack(Binding)`. Assignment validates mutability and type match.
- **IR lowering:** `var` evaluates the initializer, allocates a dedicated value slot via `allocValue`, emits a `store` IR instruction copying the initial value into the var slot, and binds the name to the slot. `assign` looks up the slot and emits another `store`. Reads (`var_ref`) load from the slot.
- **`store` IR instruction:** `InstPair { l = src_value, r = dst_slot }`, emits `mov rax, [rsp+src]; mov [rsp+dst], rax` in codegen.
- **Scope isolation:** `var` bindings use the same scope stack as `const`; branch-local vars are automatically isolated by existing mark/restore pattern.
- **Restrictions:** duplicate names rejected, reassigning to `const` errors, type mismatch on assignment errors.

## If/else syntax (indentation-based)

- **No `then` keyword.** `if` expects either `->` (inline) or a newline + indented block.
- **Inline then-body:** `if <cond> -> <expr>` — `->` is required for inline body.
- **Block then-body:** `if <cond>` followed by newline and indented body.
- **Inline else-body:** `else <expr>` — no `->` needed, body is the next expression.
- **Block else-body:** `else` followed by newline and indented body.
- **`else if` chaining:** `else if <cond>` — the else body is an `if` expression, works naturally.
- **Indentation tracking:** Lexer emits `indent`/`dedent` tokens using a stack of column levels. Blank lines are ignored. Multiple dedents are
  emitted as needed (one per call via `pending_dedent`).
- **Cross-line else binding:** `parseBlockUntil` handles `else` on a new line after an `if` without `else` via `findIfWithoutElse`.
  Finds the rightmost unbound `if` in the preceding expression and attaches the `else` to it.
- **`parseBlockUntil`** stops on `eof`, `r_paren`, and `dedent` (but not `kw_else` — cross-line else is handled during sequencing).

## Fail semantics (Verse-style)

- **Fallible expressions** — comparisons (`<` `>` `<=` `>=` `==` `!=`) are fallible. They succeed (returning `unit`) or fail.
- **Fallible contexts** — only `if` conditions. Set `Checker.in_fallible_scope = true` while inferring the condition.
- **Restriction** — fallible expressions can ONLY appear in fallible contexts. Outside → error `FallibleOutsideFallibleContext`.
- **`if` condition** — must be a fallible expression. Non-fallible → error `IfConditionNotFallible`.
- **No bool condition** — `if` no longer requires a `bool` condition. Conditions are fallible expressions, not `bool`.
- **`if` without else** — no-op on failure. Then-body must be `unit`. Not itself fallible.
- **Comparisons produce `unit`** — comparisons return `.unit` in the typechecker, not `.bool`.
- **`bool` type** — exists for `true`/`false` literals and `printb`. Separate from fallibility.
- **Equality on bools** — also fallible (predicate branch `eqb`/`neb`, type `.unit`).
- **`isFallible(node)`** — helper checking node kind against `.lt`, `.gt`, `.le`, `.ge`, `.eq`, `.ne`.
- **Scope isolation:** each block and each `if` branch restores bindings after inference/lowering; branch-local `const` names do not leak.

## String literals

- **Lexer:** `parseString()` slices content between `"` and `"` from `source[content_start..index]`.
- **Parser:** two-pass processing — first pass counts final length (handling `\\` escapes), second pass copies with escape expansion. Result allocated in arena as `[]const u8`.
- **Type system:** `string` is a primitive type (`Type.string`). `print` on string type emits `prints` IR.
- **IR lowering:** `string_lit(id)` instruction holds a table index; `Lowerer.addString` dupe-owns the bytes.
- **Codegen:** `string_lit` emits `lea rax, [rip + symbol]`, `prints` calls `print_string` helper.
- **Runtime representation:** 8-byte pointer to a `{len: u64, data: [len]u8}` structure in the `.rodata` segment.
- **Deduplication:** not yet implemented.
- **Helper (`print_string`):** two-syscall write: first `write(syscall, 1, data_ptr, len)`, second `write(syscall, 1, newline_ptr, 1)`. Newline byte stored in the red zone.

## Query system design

- **`QueryDb` is reusable state.** Keep one DB across revisions to get incremental behavior.
- **Inputs are virtual source IDs.** `setSource(source_id, text)` updates source text and revision tracking.
- **Path-backed inputs:** `setSourceFile(source_id, source_path, text)` enables persistent cache load/save for that source.
- **Initialization options:** `initWithOptions(gpa, QueryDbOptions)` controls persistent cache enablement, optional cache dir override, and `io` handle. `init(gpa)` remains a default wrapper.
- **Stage queries:** `parse(source_id)` -> `resolve(source_id)` -> `typecheck(source_id)` -> `monomorphize(source_id)` -> `lower(source_id)` -> `compile(source_id)`.
- **Memo metadata:** each memo tracks `deps`, `verified_at`, `changed_at`, and `computing`.
- **Red/green verification:**
  - If `verified_at == current_revision`, it is an immediate hit.
  - Otherwise re-check dependencies recursively before deciding to recompute.
- **Compile backdating:** if recomputed compile bytes are identical, preserve old `changed_at`.
- **Persistent cache keying:** strict validation includes cache schema version, compiler fingerprint, and source hash.
- **Persistent cache cleanup:** cache loader performs eager sweep for stale source entries (cache file exists but source file no longer exists).
- **Purity boundary:** queries return data only; writing executables and running child processes stay outside query code.
- **Generic memo type:** `db.Memo(T)` in `db.zig` provides the memo struct for any value type. Each stage's `computeXxx` returns `db.Memo(T)`. `query.zig` owns the generic orchestration (frame management, dep tracking, memo caching) via a single generic `ensureMemo` function and calls stage-specific compute functions.

## Assembly generation

- **Use 64-bit registers** for push/pop: `push rax`, `pop rax`. `push eax` is invalid in 64-bit mode.
- **32-bit ops are fine** in 64-bit mode: `add eax, ebx`, `sub eax, ebx`, `imul eax, ebx`, `idiv ebx`.
- **Signed division** requires `cdq` before `idiv` (sign-extends `eax` into `edx`).
- **Exit syscall** — preserve return value as exit code via `mov edi, eax`, then set `mov eax, 60`, then `syscall`.

## Debug flags

- Use `--debug=ast,ssa,timing,query` (comma-separated) with `zig run main.zig -- ...`.
- `query` prints query diagnostics (revision, source updates, stage hits/recomputes, dependency checks/invalidations).

## CLI behavior

- The first non-debug CLI argument is treated as the source file path to compile.
- Remaining non-debug CLI arguments are passed through to the generated `./prog` (visible to `arg(n)`).
- Query cache is enabled by default for CLI runs; use `--no-query-cache` to disable it.

## Testing

- **Behavioral tests** compile and run full binaries from source strings via `QueryDb`.
- **Type tests** cover numeric/boolean typing, strict no-coercion behavior, and type errors.
- **Incremental tests** verify query cache hits, invalidation on source changes, per-source isolation, unchanged-source no revision bump, and compile `changed_at` backdating.
- **Persistent cache tests** verify cross-`QueryDb` reuse, disable flag behavior, failure caching, corrupted cache recovery, and stale cache deletion.
- **Debug formatting test** verifies stable query diagnostics text output.

## Git

- `.gitignore` generated files: `prog`, `main`, `chimera.asm`, `chimera.o`, `.zig-cache/`, `*.qcache`.
- Commit all source files including parser/query modules and tests.

## Persistent cache

- **`Ast.serialize`/`deserialize` layout must match exactly.** Use `computedSize` to get offsets and total size. `deserialize` must NOT add `@sizeOf(Header)` to `layout.total` — `layout.total` already includes the header. The data slice passed to `deserialize` is the full serialized output (header + payload), and `data[0..layout.total]` is the correct view.
- **Span struct uses `usize` fields** (not `u32`), so `@sizeOf(Span)=16` and `@alignOf(Span)=8` on x86-64. This matters for alignment padding in the serialization format.

## Query system

- **Moving a local `ArrayList` into a memo field transfers ownership.** Do NOT `defer list.deinit(gpa)` on a list that was assigned to `memo.deps` — the memo owns the memory and `deinitMemo` will free it. Using `defer` causes a double-free when `deinitMemo` later frees the same allocation.
- **Zero-recompute test pattern:** call `compileResult` twice with no `setSource`/`setSourceFile` between calls. The second call returns an immediate hit because `memo.verified_at == self.revision` (set during first computation). All 6 recompute counters remain at 0.

## Style

- **No scoped blocks** for variable reuse. Use descriptive names instead (`asm_child`, `ld_child`).
- **Concrete types** not `anytype` for function parameters where the type is known.
- **Factor repeated patterns** into shared functions.
- **Hoist `try` from format args** — don't inline `try foo()` inside `buf.print(...)` format args.
- **Single pass over multi-concern loops** where practical.
