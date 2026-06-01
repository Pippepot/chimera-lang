# AGENTS.md — Project conventions & lessons

## Code organization

- **Entry point.** `main.zig` is the main Zig file; run with `zig run main.zig -- <source-file> [program-args...]`. No `build.zig`.
- **Module split:**
  - `main.zig` owns CLI/runtime entrypoint (`main`) and orchestration of query stages + diagnostics printing.
  - `ast.zig` owns AST module/declaration/type nodes and expression nodes (`AstNode`, `IfNode`, `VarNode`, `ConstNode`, `BlockNode`).
  - `runtime.zig` owns runtime helper entrypoints (`writeProgram`, `runProg`).
  - `parser.zig` owns lexer + parser (`parseOwned`) from source text to module AST, plus `computeParse` for query integration. Includes ownership syntax (`move/copy/drop` struct properties, param access modes, postfix move `^`).
  - `resolver.zig` owns pre-typecheck symbol resolution (`computeResolve`) and symbol diagnostics.
  - `astgen.zig` was removed — type analysis depends directly on resolve.
  - `analyze.zig` owns type inference/checking (`unit`, `bool`, `int`, `float`, function types), comptime evaluation, ownership policy computation/validation, ownership-flow analysis, and `computeAnalyze` for query integration.
  - `typecheck.zig` was legacy; now deleted from tree.
  - `query.zig` owns the revisioned incremental query system (`QueryDb`) and stage orchestration (frame management, dependency tracking, memo verification).
  - `query_cache.zig` owns cross-run persistent query cache encoding/decoding, atomic save/load, and stale-cache cleanup.
  - `ir.zig` owns multi-function IR types and typed AST -> IR lowering, plus `computeLower` for query integration. Includes ownership-aware lowering (borrow-pointer path for `read/mut`, ownership transfer for `var/deinit`, hook-call lowering for copy/move func policies).
  - `codegen.zig` owns IR -> x86 machine code + ELF emission, plus `computeCompile` for query integration. Records `program_code_len` (offset before helpers) in the ELF padding.
  - `disasm.zig` owns a pattern-based x86 disassembler that reads raw machine code and produces human-readable assembly text (used by `--debug=asm`). No emitter dependencies — operates purely on bytes + an 80-entry pattern table, with resilient unknown-byte fallback.
  - `db.zig` owns shared query types (`SourceId`, `Revision`, `Dependency`, `QueryKey`, `QueryStats`, `Stage`, `CompileResult`, `DbError`) and comparison helpers.
  - `scope.zig` owns a shared lexical scope stack utility (`ScopeStack`) reused by typechecker and lowering.
  - `debug.zig` owns debug flag parsing and AST/SSA/x86 debug dumps.
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
- **Postfix move operator:** `expr^` parses to `Ast.Tag.move_expr` and has postfix precedence.
## Type syntax

- **Primitive types:** `unit`, `bool`, `int`, `float`, `none`.
- **Function types:** `func(ParamType1, ParamType2, ...) ReturnType` — usable in parameter annotations (`f: func(int) int`), return type annotations, and `const`/`var` binding annotations.
- **Named struct types:** referenced by their declared name (e.g. `Foo`) — usable in `const`/`var` binding annotations.
- **Variant types:** compiletime type unions written with `|` (e.g. `comptime Sum = int | float | Foo`) and usable in annotations.

## Struct types and initialization

- **Struct declaration:** `comptime Name = struct` followed by newline and indented field lines (`field: type`).
- **Struct ownership properties:** struct bodies may include `move = ...`, `copy = ...`, `drop = ...` lines in addition to fields. Reserved keys `move/copy/drop` are not valid field names.
- **Policy RHS forms:** `trivial`, `fieldwise`, `none` (`move/copy`), `explicit` (`drop`), named hook functions, and inline `func` hooks (`->` one-line or indented body).
- **Struct init:** `TypeName{field1 = expr, field2 = expr, ...}`. Must provide all fields in order; field count and names are checked by the typechecker.
- **Field access:** `expr.fieldName`. The expression must be of a named struct type.
- **Field assignment:** `p.x = expr` is supported for `var` variables and `mut` parameters. Uses `store` for local slots and `store_ptr` with offset for borrowed pointers. Chained field access (`a.b.c = val`) resolves the full slot offset through the chain.
- **IR fields added:**
  - `field_assign` AST tag in `ast.zig` stores `data0 = field_access_node, data1 = value_expr`.
  - `Function.ret_slots: u32` in `ir.zig` stores the return value slot count explicitly (not inferred from IR `Type`, which loses struct field count).
- **IR direct vs indirect calls:**
  - `direct_call` (`DirectCallInst`) is used for calling a known function by name (no function-pointer indirection). Emits `call rel32` in codegen.
  - `call` (`CallInst`) is used for function-pointer calls (indirect). Emits `call rax` after loading callee address.
  - `lowerCall` detects `var_ref` to a known function (not shadowed by a local binding) and emits `direct_call` via `lowerDirectCall`.
  - `lowerMonomorphizedCall` also uses `direct_call`.
- **IR lowering:**
  - `var`/`const` with a `struct_init` value allocates N consecutive stack slots (one per field) and emits `store` for each field value.
  - Field access for index 0 returns the base slot directly. For higher indices it emits `field_load(base, field_index)` which loads from slot `base + field_index`.
  - Field assignment uses `store_ptr` for `borrowed_ptr` bindings and `store` for `local_slot` bindings.
- **Structs in function args/returns** are supported and participate in ownership-mode lowering. Multi-slot struct return uses R10 hidden pointer convention (caller sets R10 to return slot area before call, callee stores through R10-relative offsets).

## Ownership MVP

- **Struct policies:** `move/copy/drop` policies are computed per struct with defaults:
  - move defaults to `fieldwise`
  - copy defaults to `none`
  - drop defaults to `trivial`, upgrades to `fieldwise` if needed, and to `explicit` if any field requires explicit drop
- **Policy validation:** `trivial` requires trivial support on all fields; `fieldwise` requires support on all fields; `move=none` forces `copy=none`.
- **Hook signatures are strict:**
  - `copy`: `func(read self: Self) Self`
  - `move`: `func(var self: Self) Self`
  - `drop`: `func(deinit self: Self) unit`
- **Parameter access modes:**
  - `read` (default): immutable borrow
  - `mut`: mutable borrow
  - `var`: ownership transfer into callee
  - `deinit`: ownership transfer that must not remain alive at function end
- **Transfer syntax:**
  - explicit move with postfix `^`
  - `var` call arguments consume ownership with either `f(x)` or `f(x^)`
- **Static ownership checks:**
  - use-after-move / use-after-deinit diagnostics
  - stable-identity transfer restrictions (`move=none`)
  - explicit-drop obligations (`drop=explicit` must be satisfied via `deinit` transfer)
  - deinit-owned values cannot be transferred again
- **Lowering/codegen ownership path:**
  - `read`/`mut` parameters are passed by pointer and loaded/stored through pointer ops
  - `var`/`deinit` parameters use ownership-transfer value passing
  - copy/move hook calls are lowered when policies are `func`

## Monomorphization of comptime functions with runtime params

- **Comptime functions with runtime params** — `comptime foo = func(comptime T: type, x: T)` monomorphizes per unique call. `foo(int, 10)` creates `foo$int` with `x: int`; `foo(float, 1.23)` creates `foo$float` with `x: float`.
- **Comptime type in scope** — The comptime type parameter `T` is available for subsequent param type annotations (`x: T`), the function body, and return type annotations.
- **Per-function typechecking** — Each monomorphized instance gets its own `FunctionInfo` entry with concrete param types. The body shares the same AST but is typechecked independently per instance via `checkFunction`. `node_types` are cleared before each monomorphized body check to avoid stale cached types.
- **IR binding-based type lookup** — The IR lowerer resolves `var_ref` types from local bindings rather than the shared `node_types` map, correctly handling shared AST nodes across monomorphized instances.
- **`call_monomorph_targets`** — Maps call nodes to monomorphized function IDs so the IR/codegen emit calls to the correct concrete function (not the generic template).
- **Caching** — Monomorphized functions are cached by `(function_name, $, type_name)` key so repeated calls with the same comptime args reuse the same instantiation.

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
- **Condition binding form:** `if const name = <fallible-expr>` / `if var name = <fallible-expr>` binds `name` only in the success (`then`) branch.
- **Inline else-body:** `else <expr>` — no `->` needed, body is the next expression.
- **Block else-body:** `else` followed by newline and indented body.
- **`else if` chaining:** `else if <cond>` — the else body is an `if` expression, works naturally.
- **Indentation tracking:** Lexer emits `indent`/`dedent` tokens using a stack of column levels. Blank lines are ignored. Multiple dedents are
  emitted as needed (one per call via `pending_dedent`).
- **Cross-line else binding:** `parseBlockUntil` handles `else` on a new line after an `if` without `else` via `findIfWithoutElse`.
  Finds the rightmost unbound `if` in the preceding expression and attaches the `else` to it.
- **`parseBlockUntil`** stops on `eof`, `r_paren`, and `dedent` (but not `kw_else` — cross-line else is handled during sequencing).

## Fail semantics (Verse-style)

- **Fallible expressions** — comparisons (`<` `>` `<=` `>=` `==` `!=`), variant `is` checks, and variant `as` casts are fallible.
- **Fallible contexts** — only `if` conditions. Set `Checker.in_fallible_scope = true` while inferring the condition.
- **Restriction** — fallible expressions can ONLY appear in fallible contexts. Outside → error `FallibleOutsideFallibleContext`.
- **`if` condition** — must be a fallible expression. Non-fallible → error `IfConditionNotFallible`.
- **No bool condition** — `if` no longer requires a `bool` condition. Conditions are fallible expressions, not `bool`.
- **`if` without else** — no-op on failure. Then-body must be `unit`. Not itself fallible.
- **Comparisons produce `unit`** — comparisons return `.unit` in the typechecker, not `.bool`.
- **`bool` type** — exists for `true`/`false` literals and `printb`. Separate from fallibility.
- **Equality on bools** — also fallible (predicate branch `eqb`/`neb`, type `.unit`).
- **`is`** — checks a variant's runtime tag against a RHS type (or RHS type-union alias).
- **`as`** — checks a variant's runtime tag and on success yields payload typed as RHS member type.
- **`none` type** — a unit-like type with a single literal value `none`. Useful in variant types as a "null" or "no value" member (e.g., `int | none` is a nullable int).
- **`?` query operator** — postfix fallible operator that strips `none` from a variant. `x?` succeeds with the variant minus `none` (or the single unwrapped type); fails if the variant holds `none`. Works with condition binding: `if const v = x?`.
- **`is none` check** — the existing `is` mechanism works with `none`: `if x is none` checks if a variant holds the none member.
- **`isFallible(node)`** — helper checking node kind against `.lt`, `.gt`, `.le`, `.ge`, `.eq`, `.ne`, `.is`, `.as`, `.query_op`, `.and`, `.or`.
- **Scope isolation:** each block and each `if` branch restores bindings after inference/lowering; branch-local `const` names do not leak.


## `sizeof(T)` operator

- **Syntax:** `sizeof(type_expr)` — keyword `sizeof` followed by a type in parentheses.
- **Evaluation:** A comptime expression that evaluates to the logical byte size of the type. The result is an `int` and can be used in any expression context (print, arithmetic, bindings).
- **Size table:**

  | Type | Byte size |
  |------|-----------|
  | `unit`, `none`, `type` | 0 |
  | `bool` | 1 |
  | `int`, `float` | 4 |
  | `func(...)` | 8 (function pointer) |
  | struct | sum of field sizes |
  | variant (`A \| B`) | 1 (tag) + max member size |

- **Parsing:** `parsePrimary` matches `kw_sizeof`, calls `parseType()` for the inner type expression. Creates a `sizeof_expr` AST node with the type node as `data0`.
- **Typechecking:** `inferNode` resolves the inner type via `resolveTypeNode`, computes byte size via `computeByteSize`, stores it in `comptime_node_values` as a `ComptimeValue.int`.
- **Lowering:** `sizeof_expr` reads from `comptime_node_values` and lowers via `lowerComptimeValue` (emits `iconst`).
- **Tests cover:** primitive types, struct types, func types, variant types, arithmetic with sizeof, and variable binding.

## Query system design

- **`QueryDb` is reusable state.** Keep one DB across revisions to get incremental behavior.
- **Inputs are virtual source IDs.** `setSource(source_id, text)` updates source text and revision tracking.
- **Path-backed inputs:** `setSourceFile(source_id, source_path, text)` enables persistent cache load/save for that source.
- **Initialization options:** `initWithOptions(gpa, QueryDbOptions)` controls persistent cache enablement, optional cache dir override, and `io` handle. `init(gpa)` remains a default wrapper.
- **Stage queries:** `parse(source_id)` -> `resolve(source_id)` -> `typecheck(source_id)` -> `lower(source_id)` -> `compile(source_id)`.
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

- Use `--debug=ast,ssa,timing,query,asm` (comma-separated) with `zig run main.zig -- ...`.
- `query` prints query diagnostics (revision, source updates, stage hits/recomputes, dependency checks/invalidations).
- `asm` prints x86 assembly disassembly of the emitted machine code (helpers excluded). The disassembler operates on raw bytes via a pattern table; it does not call into the emitter or IR.

## CLI behavior

- The first non-debug CLI argument is treated as the source file path to compile.
- Remaining non-debug CLI arguments are passed through to the generated `./prog` (visible to `arg(n)`).
- Query cache is enabled by default for CLI runs; use `--nocache` to disable it.

## Testing

- **Behavioral tests** compile and run full binaries from source snippets via `QueryDb`.
- **Type tests** cover numeric/boolean typing, strict no-coercion behavior, and type errors.
- **Ownership tests** cover parser/property syntax, policy validation, hook signatures, copy/move/deinit diagnostics, `mut` writeback, and hook invocation behavior.
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

## Monomorphization

- **All-comptime-param functions** must be monomorphized (not skipped). The `inferCall` condition should check `mask != 0` without requiring `has_runtime_params`. Pure-comptime functions (all params are comptime, zero runtime params) need monomorphized instances so their bodies get lowered and executed.
- **`comptime struct` name type** — when a `comptime struct` name (e.g. `Bar`) is used in value position (e.g. as a call argument to a `comptime T: type` parameter), its type should be `.type_type`, not `.{ .named = name }`. The struct instance type is only correct in type annotation position.

## Inferred return types

- **Optional return type annotation:** Function declarations may omit the return type after the parameter list. The type is inferred from `return` statements (or the body expression if no explicit return).
- **Variant inference:** If multiple `return` statements return different types, the inferred return type is a variant over the deduplicated set of types.
- **Recursive functions:** Two-pass inference handles recursion. First pass collects return types with a placeholder (`.unit`), catching `TypecheckFailed` errors from self-referential calls. Second pass re-checks with the correct inferred type.
- **Monormorphized functions** with inferred return types are checked immediately on creation (not deferred to the `run()` loop), with checker state saved/restored around the recursive call to avoid corrupting the outer function's inference state.
- **`lowerValueAsType`** derives the source type from the local binding for `var_ref` nodes, not the shared `node_types` map, avoiding stale types across shared AST nodes in monomorphized instances.

## Style

- **No scoped blocks** for variable reuse. Use descriptive names instead (`asm_child`, `ld_child`).
- **Concrete types** not `anytype` for function parameters where the type is known.
- **Factor repeated patterns** into shared functions.
- **Hoist `try` from format args** — don't inline `try foo()` inside `buf.print(...)` format args.
- **Single pass over multi-concern loops** where practical.
