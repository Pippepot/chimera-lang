# Refactor roadmap

Last updated: 2026-08-01.

This is a temporary handoff document. Update it after each completed milestone and delete obsolete details rather than preserving history here. Durable design rules live in `ARCHITECTURE.md`; agent workflow lives in `AGENTS.md`.

## Goal

Replace the legacy compiler pipeline with a Salsa-like incremental pipeline that analyzes, lowers, and compiles functions independently, then links reachable function artifacts into an ELF executable.

The target is a deliberately selected language subset, not complete legacy feature parity:

- Every successfully parsed file has one synthetic top-level entry. A declaration named `main` has no entry-point significance.
- The top-level body has `unit` result. Values produced by top-level statements, including calls, are discarded.
- `int` is a signed 32-bit value.
- The legacy `arg` builtin is outside the refactor scope.
- Legacy behavior and tests remain useful references only where they exercise the selected language subset.

## Current new pipeline

```text
SourceText(FileId)
    └── ParseFile(FileId) -> ?Ast
        └── DiscoverItems(FileId) -> ?ItemTree
            ├── IndexItems(FileId) -> ?ItemIndex
            │   ├── SelectEntry(FileId) -> ?ItemId
            │   └── BuildModuleScope(FileId) -> ?ModuleScope
            └── ResolveItem(ItemId) -> ?ResolvedItem
                ├── FunctionSignature(ItemId) -> ?FunctionSignature
                └── AnalyzeFunctionBody(ItemId) -> ?FunctionBodyAnalysis
                    ├── FunctionSignature(ItemId) for declared functions only
                    ├── SourceText, BuildModuleScope, and the target FunctionSignature for an entry call only
                    └── LowerToSSA(InstanceId) -> ?SsaFunction
                        └── CompileFunction(InstanceId) -> ?CompiledFunction

BuildExecutable(FileId) -> ?Executable
    ├── SelectEntry(FileId) -> ?ItemId
    └── CompileFunction(InstanceId{ selected entry }) -> ?CompiledFunction
```

`main.zig` still uses the legacy pipeline. Keep the legacy implementation as behavioral reference, but do not copy its architecture automatically.

## Completed

### Frontend

- `tokenizer.zig` and `ast_new.zig` implement the new tokenizer/parser and have broad parser coverage.
- `Ast` owns its token/node arrays and stores `FileId`; it does not borrow source text.
- Text rendering receives source text explicitly and uses token byte offsets.
- `ParseFile` reads `SourceText` through the query context and emits owned diagnostics.
- `diagnostics.zig` renders the refactored pipeline's public `structures.Diagnostic` values from source paths, source text, spans, and messages.
- Parser productions propagate syntax and allocation failures to one document boundary; syntax failure publishes exactly the first diagnostic, while allocation failure remains an infrastructure error.
- Required expression positions reject missing values without making the expression after `return` mandatory.
- Token, parser-list, AST-transfer, and diagnostic construction paths have exact failure cleanup verified by allocation-failure injection.
- Structural AST equality includes primitive type nodes, allowing equal-shape spelling edits to retain parsed values while source-sensitive semantic queries still observe changed text.
- End-of-file tokenization unwinds every open indentation level even without a trailing newline.
- The dedicated equals state distinguishes `=`, `==`, and `=>`; other compound operators dispatch directly from the start state without an intermediate tokenizer state.
- AST debug rendering initializes its traversal state explicitly, so repeated-node detection never reads uninitialized memory.

### Query engine

- `query_new.zig` provides typed concurrent memoization, work stealing, cycle detection, and diagnostic accumulators.
- Query definitions are independent from the engine implementation and use the context protocol.
- Inputs can be changed only while the database is idle, and the revision advances only when a stored value actually changes.
- `ctx.input` records direct input dependencies.
- Cached queries recursively verify their recorded input/query dependencies against revisions and recompute only when a dependency's observable result changed.
- Recomputation uses entry-owned fresh dependencies and accumulators, then atomically commits or discards them without exposing partial state.
- Equal outputs and accumulators preserve the retained allocation and `changed_at`; changed diagnostics are observable changes.
- Dynamic dependency sets replace stale edges after recomputation, and cycle detection ignores retained edges not verified in the current revision.
- Pointer-containing observable types must define value equality rather than inheriting pointer identity from `std.meta.eql`.
- Query and input keys are compile-time constrained to pointer-free stable identities; pointer-containing input values must define explicit clone, equality, and cleanup.
- Infrastructure failures discard fresh state, preserve the last completed memo, and are retryable rather than permanently cached.
- `SourceText` directly owns its source byte slice; no single-field file wrapper remains at the input boundary.
- Generic type erasure uses explicit pointer conversion, including for pointer-containing input values.

### Item discovery

- `DiscoverItems(FileId)` produces an owned `ItemTree` for successfully parsed files.
- Top-level function locations are stable across body and unrelated index changes; renames change identity.
- Duplicate functions receive deterministic per-name disambiguators.
- Duplicate ordinals follow source order, so reordering invalid same-name declarations may reassign which declaration an existing location denotes.
- Every successfully parsed file produces a synthetic `$entry` for its root block, including empty, function-only, and compile-time-only files.
- Stable `ItemLoc` data is separate from the current revision's raw declaration index.
- Stable locations are interned into opaque, session-local `ItemId`s whose names are owned by the database.
- `IndexItems` preserves source-order stable IDs and maps them to current declarations; `ResolveItem` performs an indexed lookup and returns the current declaration or `null`.
- Removed and restored locations reuse their IDs, including the synthetic top-level entry.
- `SelectEntry(FileId)` returns the indexed synthetic entry ID, returns `null` after parse failure, preserves identity across valid edits and restoration, and propagates parse diagnostics transitively.

### Backend smoke path

- `Executable` owns generated bytes and is safely deinitialized by the query database.
- Empty, function-only, and compile-time-only source files flow through parsing, stable entry selection, resolution, lowering, code generation, and execution.
- `BuildExecutable` consumes the selected entry's ordinary `CompiledFunction`; no entry-specific semantic, SSA, or compilation path remains.
- The single-artifact ELF builder emits a Linux startup stub that calls the artifact, discards its register result, and exits with zero.
- Artifact code is copied into the owned executable at its required loaded-address alignment. The temporary builder rejects relocation/reference metadata until reachable-function linking exists.
- Runtime root statements, including a top-level `return`, are rejected with one semantic diagnostic rather than silently compiled as an empty entry.
- Whole-program `BuildExecutable` remains distinct from per-function `CompileFunction`.

### Ordinary function semantics

- `FunctionSignature(ItemId)` analyzes only a function header and currently accepts zero parameters with explicit `int` return type.
- For declared functions, `AnalyzeFunctionBody(ItemId)` depends on the signature and currently accepts inline or block bodies containing exactly one decimal integer-literal return.
- For the synthetic entry, `AnalyzeFunctionBody(ItemId)` accepts only root-level compile-time bindings, rejects runtime roots, and produces `unit` without requesting `FunctionSignature` or directly reading `SourceText`.
- Signature and body results are pointer-free semantic values with no AST indices, token spans, or borrowed source text.
- Declared-function signature and body analysis depend explicitly on source text, so equal-shape spelling edits remain observable despite structural AST equality.
- Equal signatures suppress downstream recomputation across body-only edits; body analysis recomputes independently.
- Top-level `return` remains invalid through semantic analysis, ordinary lowering and compilation, and executable construction.

### Ordinary function SSA

- `InstanceId` is currently a structural non-generic wrapper around `ItemId`, keeping callable identity distinct from declaration identity without an interner or registry.
- `LowerToSSA(InstanceId)` depends only on `AnalyzeFunctionBody` and produces an owned `SsaFunction`.
- The minimal function SSA represents a signed 32-bit integer constant or one symbolic `direct_call` targeted by `InstanceId`; synthetic entries discard call results and use a unit-return terminator.
- `SsaFunction` defines semantic equality and exact cleanup, so equal recomputation retains cached allocations and changed lowering replaces them safely.
- Synthetic entries lower through the same `SsaFunction` query as declared functions.
- Direct-call lowering remains independent of the callee body and lowering. Callee-body and declaration-reorder edits that preserve the target identity retain equal caller SSA, while target changes update the embedded `InstanceId`.

### Ordinary function artifacts

- `CompileFunction(InstanceId)` depends only on `LowerToSSA` and produces an owned, relocatable `CompiledFunction` rather than an executable image.
- Declared integer-return artifacts use the x86-64 callable ABI and return a signed 32-bit value in `eax`; unit artifacts return without manufacturing a value.
- Artifacts carry required alignment, relocation records, and a deterministic referenced-instance table. Literal and unit artifacts use byte alignment and canonical empty metadata.
- A valid symbolic direct call compiles to `E8 00 00 00 00 C3`, owns one target `InstanceId`, and owns one `call_relative_32` relocation at displacement offset 1 with reference index and addend zero.
- Direct-call artifact construction accepts only the current one-call, unit-return SSA shape. Multiple calls, mixed instructions, and returning a call as a value are rejected as `InvalidSsa` before allocation.
- Artifact equality is content-based across code, alignment, relocations, and referenced instances. Cleanup independently frees all three owned slices exactly once, including every partial-allocation failure path.
- Semantic failures and diagnostics remain transitive through compilation, while invalid SSA is an infrastructure failure.
- Unit and direct-call synthetic entries compile independently to retained ordinary function artifacts without demanding or compiling the callee.
- Relocation resolution belongs to the linker boundary rather than `CompileFunction`; `CompileFunction` never lays out addresses or resolves references.
- Equal selected-entry artifacts preserve the retained executable allocation across unrelated valid source edits.

### Module scope for callable lookup

- `BuildModuleScope(FileId)` produces an owned, name-sorted mapping from declared top-level function names to stable `ItemId`s.
- Empty scopes are valid; synthetic entries and non-function top-level forms are excluded.
- Later same-name functions emit source-ordered diagnostics at their binding names and make the scope unavailable, while discovery and indexing preserve their distinct identities.
- Scope equality is independent of declaration order, lookup is logarithmic, and no persistent scope hash table is required.
- Scope construction does not request function signatures or bodies; duplicate diagnostics depend directly on the current AST so moved spans remain observable.

### Direct entry-call semantics

- A synthetic entry accepts either no runtime roots or exactly one bare-name, zero-argument call; top-level `return` and every other runtime-root shape remain invalid.
- Entry analysis validates the complete root shape before resolving the call, then resolves through `BuildModuleScope` and validates only the callee signature. Callee bodies remain demand-driven.
- The semantic result stores the stable callee `ItemId`, with no AST index, source span, borrowed spelling, or decision about how the call result affects the caller.
- Empty and compile-time-only entries do not request module scope, so duplicate-name diagnostics remain demand-driven and stale lookup dependencies are removed after edits.
- Direct calls lower to one symbolic SSA call carrying the callee `InstanceId`, discard its result, and return unit.
- Direct-call artifacts retain the stable target identity even though their machine-code and relocation bytes are target-independent. Callee body and declaration-order edits that preserve that identity retain the caller artifact.

### One-call linking

- `BuildExecutable` resolves a direct-call entry by compiling the one `InstanceId` its artifact references (`ctx.get(CompileFunction, ...)`), then lays out the startup stub, entry artifact, and that one leaf callee artifact in order, each honoring its own `required_alignment`.
- The entry's single `call_relative_32` relocation is validated before any callee placement: reference index bounds, patch-field bounds against the entry's own code length, and signed 32-bit displacement range (including `addend`) via one shared `i128`-checked helper; the callee is asserted to be a leaf (no relocations of its own), since declared-function bodies cannot yet themselves call.
- Accepted artifact shapes are exactly "no call" (0 relocations, 0 referenced instances, no callee) and "one call" (1 and 1, with a callee supplied); every other combination, and any shape/callee mismatch, is `UnsupportedArtifactMetadata`.
- Callee compile failure (a semantic issue in the called function's body) surfaces as `BuildExecutable` returning `null` with the callee's diagnostic transitively attached; this is demand-driven specifically by `BuildExecutable`'s own dependency on the callee's `CompileFunction`, since entry analysis itself validates only the callee's signature.
- The entry's own compiled artifact stays equal, and its query result stays retained, across edits to the callee's body; only the linked executable's bytes change.
- Query, codegen-unit, and execution tests cover: successful linking and execution; entry-artifact retention across callee-body edits; callee compile failure surfacing transitively; relocation reference/bounds and displacement-overflow rejection; and allocation-failure cleanup for the linked path.

## Current temporary limitations

- Compile-time binding initializers are currently opaque to entry analysis; contextual validation inside them belongs to future general semantic analysis.
- Function signatures support only primitive `int`; parameters, inferred returns, named types, and compound types are deferred.
- `FunctionBodyAnalysis` is keyed by `ItemId` and currently holds `unit`, one nonnegative signed 32-bit integer result, or one stable direct-call target.
- `InstanceId` has no generic substitutions yet, and `SsaFunction` has an implicit single block with only an integer constant or symbolic call instruction and a unit or value return terminator.
- `BuildExecutable` resolves only the one-call shape (exactly one relocation and one referenced instance). Multiple references, multiple relocations, nested/transitive calls, cycles, deduplication, and general reachable-instance traversal remain unimplemented.
- Callable scope is file-local and contains only functions; imports, visibility, other namespaces, and overloading are deferred.
- Input updates are allowed only while no query is queued or running.
- Query result pointers remain stable across equal recomputations but must be treated as invalid after a changed recomputation replaces that result.
- The parser currently stops after its first syntax diagnostic; synchronization and multi-error recovery are deferred.

## Immediate next milestone: general reachable-function linking

- Generalize `BuildExecutable` from the one-call slice to traverse referenced instances and collect all reachable artifacts, without recursively checking callee bodies during caller semantics.
- Define a deterministic layout and deduplication scheme so a target referenced from multiple call sites is compiled and placed exactly once.
- Resolve multiple relocations and references per artifact, and across nested/transitive calls.
- Handle graph cycles among reachable instances (mutual recursion becomes reachable once declared-function bodies can themselves call).
- Add execution and incremental tests for transitive reachability: shared targets, cycles, and callee-body edits that add or remove reachability.
- Do not migrate the CLI yet.

`ItemId` identifies a stable declaration, not a future instantiated callable. Do not replace it with an AST pointer or assume it is the final function-instance identity.

## Later milestones

### 1. Expand the selected language through vertical slices

- Add module- and item-level queries for declarations, scopes, type definitions, layouts, and compile-time values.
- Add per-function or per-instance name resolution, typing, diagnostics, lowering, and code generation only as each slice requires.
- Extend SSA and codegen only as each semantic feature requires.
- Prioritize scalar parameters and locals, arithmetic, returns, control flow, and observable output before aggregate, compile-time, variant, and ownership features.
- Port relevant legacy behavior and regression tests with each supported feature, not as a final batch.
- Keep machine addresses and executable layout out of semantic and SSA results.
- Preserve the boundary between relocatable function emission and whole-program executable construction.

### 2. CLI migration and legacy retirement

- Move `main.zig` to the new query database.
- Restore diagnostics and debug output against new data structures.
- Remove legacy modules only after every selected behavior has a refactored regression test.
- Add persistent cross-run caching only after query values and serialization formats stabilize.

## Verification

Current focused commands:

```bash
zig test ast_new.zig
zig test tokenizer.zig
zig test diagnostics.zig
zig test query_new_test.zig
zig test ssa.zig
zig test codegen_new_test.zig
zig fmt tokenizer.zig query_new.zig query_new_test.zig query_structures.zig structures.zig ast_new.zig semantic.zig ssa.zig codegen_new.zig codegen_new_test.zig
git diff --check
```

Last observed results:

- `zig test ast_new.zig`: 70 passed.
- `zig test tokenizer.zig`: 31 passed.
- `zig test diagnostics.zig`: 2 passed.
- `zig test query_new_test.zig`: 143 passed.
- `zig test ssa.zig`: 5 passed.
- `zig test codegen_new_test.zig`: 15 passed.
- The legacy `zig test test.zig` remains blocked by an unrelated `query_cache.load` call/signature mismatch.

## Handoff notes

- The working tree is intentionally dirty and contains unrelated edits/deletions. Do not reset, restore, or reformat unrelated files.
- `query_new.zig`, `query_new_test.zig`, `query_structures.zig`, `structures.zig`, `ast_new.zig`, `diagnostics.zig`, `ssa.zig`, and `codegen_new.zig` are the main files for the current refactor path.
- Run `git status --short` before editing and preserve all user-owned changes.
