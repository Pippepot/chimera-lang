# Refactor roadmap

Last updated: 2026-08-09.

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
                    ├── SourceText, BuildModuleScope, and each called FunctionSignature as needed
                    └── LowerToSSA(InstanceId) -> ?SsaFunction
                        └── CompileFunction(InstanceId) -> ?CompiledFunction

BuildExecutable(FileId) -> ?Executable
    ├── SelectEntry(FileId) -> ?ItemId
    └── CompileFunction(InstanceId) for every reachable referenced instance
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
- A line break after `return` ends the bare return before a following top-level expression, including after an inline function body.
- Token, parser-list, AST-transfer, and diagnostic construction paths have exact failure cleanup verified by allocation-failure injection.
- Structural AST equality includes primitive type nodes, allowing equal-shape spelling edits to retain parsed values while source-sensitive semantic queries still observe changed text.
- End-of-file tokenization unwinds every open indentation level even without a trailing newline.
- The dedicated equals state distinguishes `=`, `==`, and `=>`; other compound operators dispatch directly from the start state without an intermediate tokenizer state.
- AST debug rendering initializes its traversal state explicitly, so repeated-node detection never reads uninitialized memory.
- Top-level and nested static declarations use the `static` keyword and `static_binding` AST tag; `comptime` remains reserved for compile-time expressions and parameter modes.

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
- Every successfully parsed file produces a synthetic `$entry` for its root block, including empty, function-only, and static-only files.
- Stable `ItemLoc` data is separate from the current revision's raw declaration index.
- Stable locations are interned into opaque, session-local `ItemId`s whose names are owned by the database.
- `IndexItems` preserves source-order stable IDs and maps them to current declarations; `ResolveItem` performs an indexed lookup and returns the current declaration or `null`.
- Removed and restored locations reuse their IDs, including the synthetic top-level entry.
- `SelectEntry(FileId)` returns the indexed synthetic entry ID, returns `null` after parse failure, preserves identity across valid edits and restoration, and propagates parse diagnostics transitively.

### Backend smoke path

- `Executable` owns generated bytes and is safely deinitialized by the query database.
- Empty, function-only, and static-only source files flow through parsing, stable entry selection, resolution, lowering, code generation, and execution.
- `BuildExecutable` consumes the selected entry's ordinary `CompiledFunction`; no entry-specific semantic, SSA, or compilation path remains.
- The ELF builder emits a Linux startup stub that calls the selected entry, discards its register result, and exits with zero.
- Reachable artifact code is copied once into the owned executable at its required loaded-address alignment, then its relocations are resolved.
- Runtime root statements, including a top-level `return`, are rejected with one semantic diagnostic rather than silently compiled as an empty entry.
- Whole-program `BuildExecutable` remains distinct from per-function `CompileFunction`.

### Ordinary function semantics

- `FunctionSignature(ItemId)` analyzes only a function header and owns its ordered `int` parameter types plus an explicit `int` or `unit` return type. Parameter modes and non-`int` parameter types remain unsupported.
- For declared functions, `AnalyzeFunctionBody(ItemId)` depends on the signature and accepts a straight-line block of immutable local bindings and bare calls ending in a supported return. Integer functions return an `int` expression; unit functions use a bare return or return a unit-valued expression.
- The parser encodes precedence and nesting in the AST. Body analysis walks that expression tree into typed values: parameters, decimal integer constants, and calls are leaves, and unary negation plus binary `+`, `-`, `*`, and `/` compose them.
- Calls accept arbitrary numbers of expressions evaluated left-to-right. The typed boundary validates arity and each argument type against the callee signature.
- For the synthetic entry, `AnalyzeFunctionBody(ItemId)` accepts root-level `static` bindings and any number of bare calls, discards their values, and returns `unit`.
- Unresolved-body construction resolves lexical local names and records optional `int` or `unit` annotations. The query then resolves calls and validates annotations, operations, arguments, and returns before publishing type-specific `FunctionBodyAnalysis`; SSA and codegen do not repeat those type checks.
- A `const` binding names an existing typed value and emits no semantic or SSA instruction. Bindings and bare calls may be interleaved, aliases reuse the same value ID, and local values shadow module callables. Optional `int` and `unit` annotations are validated against their initializers.
- Body analysis owns block and typed-instruction arrays containing stable identities and value-ID operands; it stores no AST indices, token spans, or borrowed source text.
- Typed calls record their `int` or `unit` result type. Unit values are rejected at integer operation, argument, annotation, and return boundaries before typed IR is published.
- Declared-function signature and body analysis depend explicitly on source text, so equal-shape spelling edits remain observable despite structural AST equality.
- Equal signatures suppress downstream recomputation across body-only edits; body analysis recomputes independently.
- Top-level `return` remains invalid through semantic analysis, ordinary lowering and compilation, and executable construction.

### Ordinary function SSA

- `InstanceId` is currently a structural non-generic wrapper around `ItemId`, keeping callable identity distinct from declaration identity without an interner or registry.
- `LowerToSSA(InstanceId)` depends only on `AnalyzeFunctionBody` and produces an owned `SsaFunction`.
- The minimal function SSA has explicit blocks with typed block arguments, ordered instruction results, symbolic calls targeted by `InstanceId`, and type-specific integer operations over value IDs; each block owns its terminator.
- Block arguments and instruction results share one value-ID namespace. Calls reference ranges in one flat operand array, so neither parameter count nor call arity is encoded as an instruction kind.
- Semantic and SSA functions share one block/value/instruction representation parameterized by call-target identity (`ItemId` before instantiation, `InstanceId` after it).
- Lowering preserves each call's trusted result type, so discarded unit calls remain ordinary symbolic calls without acquiring a machine value location.
- `SsaFunction` defines semantic equality and exact cleanup, so equal recomputation retains cached allocations and changed lowering replaces them safely.
- Synthetic entries lower through the same `SsaFunction` query as declared functions.
- Direct-call lowering remains independent of the callee body and lowering. Callee-body and declaration-reorder edits that preserve the target identity retain equal caller SSA, while target changes update the embedded `InstanceId`.

### Ordinary function artifacts

- `CompileFunction(InstanceId)` depends only on `LowerToSSA` and produces an owned, relocatable `CompiledFunction` rather than an executable image.
- Declared integer-return artifacts use the current internal x86-64 calling convention and return a signed 32-bit value in `eax`; unit artifacts return without manufacturing a value. External ABI compatibility is not currently selected.
- Artifacts carry required alignment, relocation records, and a deterministic referenced-instance table. Literal and unit artifacts use byte alignment and owned zero-length metadata.
- Each symbolic call emits `E8 00 00 00 00` and one `call_relative_32` relocation; the deterministic reference table deduplicates repeated targets while preserving first-use order.
- Code generation assigns constants to immediate locations, leaves a final computed result in `eax`, and gives earlier computed values needed later fixed stack slots. This preserves expression operands across intervening calls without embedding machine locations in SSA.
- The current internal calling convention reserves one fixed outgoing argument area per caller frame and passes signed 32-bit arguments there. Callees address incoming arguments relative to their own fixed frame, supporting arbitrary current arity and nested or recursive calls without dynamic call-site stack adjustment.
- Signed 32-bit negation, addition, subtraction, multiplication, and division are emitted from type-specific integer instructions.
- Location planning is separate from instruction emission. Regular immediate and stack encodings share one 32-bit encoder and an operation-to-opcode mapping; division remains explicit because its machine sequence is structurally different.
- Calls may be discarded or returned, and may precede a returned integer. The current backend accepts one explicit straight-line block and reports other valid SSA shapes as `UnsupportedControlFlow`.
- Unit-returning calls use the same argument, relocation, and reachability machinery as integer-returning calls; code generation emits the call but assigns no result location.
- Artifact equality is content-based across code, alignment, relocations, and referenced instances. Cleanup independently frees all three owned slices exactly once, including every partial-allocation failure path.
- Semantic failures and diagnostics remain transitive through compilation, while backend capability and function-size failures remain infrastructure errors.
- Unit and direct-call synthetic entries compile independently to retained ordinary function artifacts without demanding or compiling the callee.
- Relocation resolution belongs to the linker boundary rather than `CompileFunction`; `CompileFunction` never lays out addresses or resolves references.
- Equal selected-entry artifacts preserve the retained executable allocation across unrelated valid source edits.

### Module scope for callable lookup

- `BuildModuleScope(FileId)` produces an owned, name-sorted mapping from declared top-level function names to stable `ItemId`s.
- Empty scopes are valid; synthetic entries and non-function top-level forms are excluded.
- Later same-name functions emit source-ordered diagnostics at their binding names and make the scope unavailable, while discovery and indexing preserve their distinct identities.
- Scope equality is independent of declaration order, lookup is logarithmic, and no persistent scope hash table is required.
- Scope construction does not request function signatures or bodies; duplicate diagnostics depend directly on the current AST so moved spans remain observable.

### Callable body semantics

- Calls are value-producing operations; block terminators or statement position determine whether their values are returned or discarded.
- Body analysis validates the complete supported block shape, resolves calls through `BuildModuleScope`, and validates only callee signatures. Callee bodies remain demand-driven.
- Semantic call instructions store stable callee `ItemId`s with no AST indices, source spans, or borrowed spellings.
- Empty and static-only entries do not request module scope, so duplicate-name diagnostics remain demand-driven and stale lookup dependencies are removed after edits.
- Calls lower independently to symbolic SSA calls carrying callee `InstanceId`s.
- Direct-call artifacts retain the stable target identity even though their machine-code and relocation bytes are target-independent. Callee body and declaration-order edits that preserve that identity retain the caller artifact.

### General reachable-function linking

- `BuildExecutable` breadth-first traverses deterministic referenced-instance tables, compiles each reachable instance once, and terminates on shared targets and cycles by marking identities before enqueueing them.
- The linker accepts a pre-collected artifact graph, rejects duplicate, missing-entry, missing-reference, and malformed-relocation metadata, and lays out each supplied artifact once in collection order.
- Every relocation is patched after layout using the target artifact's recorded address; reference bounds, patch-field bounds, alignment, signed 32-bit displacement, and addends are validated independently of frontend-producible graph shapes.
- Callee compile failure (a semantic issue in the called function's body) surfaces as `BuildExecutable` returning `null` with the callee's diagnostic transitively attached; this is demand-driven specifically by `BuildExecutable`'s own dependency on the callee's `CompileFunction`, since entry analysis itself validates only the callee's signature.
- Dynamic query dependencies follow current reachability, while caller artifacts remain independent of callee bodies.
- Query, codegen-unit, and execution tests cover transitive calls, shared targets, cycles, reachability removal, multiple relocations, metadata failures, displacement overflow, and allocation-failure cleanup.

## Current temporary limitations

- Static binding initializers are currently opaque to entry analysis; contextual validation inside them belongs to future general semantic analysis.
- Function signatures support ordered `int` parameters and an explicit `int` or `unit` return; inferred returns, parameter modes, other parameter types, named types, and compound types are deferred.
- `FunctionBodyAnalysis` and `SsaFunction` use explicit block tables but semantic analysis and code generation currently accept only one straight-line block; branches, loops, and multiple source returns are deferred.
- Calls currently support only bare file-local function names. Arguments can be any supported expression; mutable locals, assignment, and nested lexical scopes are deferred.
- Expressions currently support only decimal `int` constants, calls returning `int` or `unit`, immutable-local references, unary negation, and binary `+`, `-`, `*`, and `/`. Unit values can be discarded, aliased, or returned from unit functions; other value types and operators remain unsupported.
- `InstanceId` has no generic substitutions yet.
- Callable scope is file-local and contains only functions; imports, visibility, other namespaces, and overloading are deferred.
- Input updates are allowed only while no query is queued or running.
- Query result pointers remain stable across equal recomputations but must be treated as invalid after a changed recomputation replaces that result.
- The parser currently stops after its first syntax diagnostic; synchronization and multi-error recovery are deferred.

`ItemId` identifies a stable declaration, not a future instantiated callable. Do not replace it with an AST pointer or assume it is the final function-instance identity.

## Later milestones

### 1. Expand the selected language through vertical slices

- Add module- and item-level queries for declarations, scopes, type definitions, layouts, and compile-time values.
- Add per-function or per-instance name resolution, typing, diagnostics, lowering, and code generation only as each slice requires.
- Extend SSA and codegen only as each semantic feature requires.
- Next prioritize control flow and observable output, before aggregate, compile-time, variant, and ownership features. The selected first effect is an `exit(value: int)` intrinsic.
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
zig test semantic.zig
zig test query_new_test.zig
zig test ssa.zig
zig test codegen_new_test.zig
zig fmt tokenizer.zig query_new.zig query_new_test.zig query_structures.zig structures.zig ast_new.zig semantic.zig ssa.zig codegen_new.zig codegen_new_test.zig
git diff --check
```

Last observed results:

- `zig test ast_new.zig`: 71 passed.
- `zig test tokenizer.zig`: 31 passed.
- `zig test diagnostics.zig`: 2 passed.
- `zig test semantic.zig`: 73 passed.
- `zig test query_new_test.zig`: 163 passed.
- `zig test ssa.zig`: 6 passed.
- `zig test codegen_new_test.zig`: 19 passed.
- The legacy `zig test legacy/test.zig` remains blocked by an unrelated `query_cache.load` call/signature mismatch.

## Handoff notes

- `query_new.zig`, `query_new_test.zig`, `query_structures.zig`, `structures.zig`, `ast_new.zig`, `diagnostics.zig`, `typing.zig`, `ssa.zig`, and `codegen_new.zig` are the main files for the current refactor path.
- The refactor path owns the repository root. The legacy pipeline and CLI live under `legacy/` with their own copy of `runtime.zig` and import nothing from the refactor path.
- Run `git status --short` before editing and preserve all user-owned changes.
