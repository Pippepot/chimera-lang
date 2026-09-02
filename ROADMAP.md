# Refactor roadmap

Last updated: 2026-08-30.

This is a temporary handoff document. Update it after each completed milestone and delete obsolete details rather than preserving history here. Durable design rules live in `ARCHITECTURE.md`; agent workflow lives in `AGENTS.md`.

## Goal

Replace the legacy compiler pipeline with a Salsa-like incremental pipeline that analyzes, lowers, and compiles functions independently, then links reachable function artifacts into an ELF executable.

The target is a deliberately selected language subset, not complete legacy feature parity:

- Every successfully parsed file has one synthetic top-level entry. A declaration named `main` has no entry-point significance.
- The top-level body has `unit` result. Values produced by top-level statements, including calls, are discarded.
- `int` is a signed 32-bit value.
- `exit(value: int)` is an unshadowable intrinsic that terminates the process with the supplied status.
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

Type identity is shared by those queries:

```text
VariantTypes canonical interner -> InternedTypeId -> TypeId
TypeLayout(TypeId) -> TypeLayout
```

The repository root now has a new-pipeline CLI in `main.zig`. `legacy/main.zig` remains a behavioral reference and is not part of the refactored execution path.

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

- `FunctionSignature(ItemId)` analyzes only a function header and owns its ordered parameter `TypeId`s plus its explicit return `TypeId`. It resolves `int`, `unit`, `none`, and structural variants through the type interner; direct `unit`/`none` parameters, direct `none` returns, parameter modes, and other type families remain unsupported.
- For declared functions, `AnalyzeFunctionBody(ItemId)` depends on the signature and accepts immutable local bindings and bare calls ending in a supported return. Integer functions return an `int` expression; unit functions use a bare return or return a unit-valued expression.
- The parser encodes precedence and nesting in the AST. Body analysis walks that expression tree into typed values: parameters, decimal integer constants, `none`, and calls are leaves; unary negation and binary `+`, `-`, `*`, and `/` compose integers; value-producing `if/else` joins equal types or infers a containing variant for compatible member branches.
- An `if` condition is a fallible expression, not a `bool`. The selected forms are integer `<`, `>`, `<=`, `>=`, `==`, and `<>`; their success or failure becomes a typed predicate terminator and no comparison-result value enters SSA.
- Calls accept arbitrary numbers of expressions evaluated left-to-right. The typed boundary validates arity and each argument type against the callee signature.
- For the synthetic entry, `AnalyzeFunctionBody(ItemId)` accepts root-level `static` bindings, immutable local bindings, and bare calls, discards unused values, and returns `unit`.
- Unresolved-body construction resolves lexical local names and resolves optional `int`, `unit`, or variant annotations through the same type protocol as signatures. The query then resolves calls and validates annotations, operations, fallible predicate operands, branch joins, arguments, and returns before publishing type-specific `FunctionBodyAnalysis`; SSA and codegen do not repeat those type checks.
- A `const` binding normally names an existing typed value without an instruction. A variant annotation emits the explicit exact-member injection required to give the binding its declared representation. Bindings and bare calls may be interleaved, aliases reuse the same value ID, and local values shadow module callables.
- Body analysis owns block and typed-instruction arrays containing stable identities and value-ID operands; it stores no AST indices, token spans, or borrowed source text.
- Typed calls record their result `TypeId`. Unit and variant values are rejected at integer-operation boundaries before typed IR is published.
- `exit(value: int)` bypasses local and module callable lookup, publishes a dedicated unit-valued instruction, and requires exactly one `int` operand.
- Declared-function signature and body analysis depend explicitly on source text, so equal-shape spelling edits remain observable despite structural AST equality.
- Equal signatures suppress downstream recomputation across body-only edits; body analysis recomputes independently.
- Top-level `return` remains invalid through semantic analysis, ordinary lowering and compilation, and executable construction.

### Variant types and first runtime value slice

- `TypeId` replaces the closed primitive-type enum throughout semantic IR, SSA, signatures, and typed calls. `int`, `unit`, and `none` have reserved identities; database-interned identities occupy a disjoint encoded range.
- The encoded range means "interned type," not "variant." `InternedTypeId` is a 31-bit interner index because the enclosing 32-bit `TypeId` uses its remaining high bit to distinguish interned identities from reserved primitives. When a second interned type shape is implemented, replace the variant-only store with one type-data interner over the then-real shapes; do not add another type-ID encoding or parallel struct identity mechanism.
- `VariantTypes` owns its member slice and interns variants structurally. Canonicalization flattens nested variants, ignores source member order, and reports explicit or flattening-induced duplicate members before interning.
- The current canonical member universe is deliberately limited to `int`, `unit`, and `none`. Named types, aliases, and further runtime types extend canonicalization only when their own vertical slice needs them.
- `TypeLayout(TypeId)` publishes only immutable byte size and alignment. `int` is 4-byte aligned and sized; `unit` and `none` are zero-sized; a variant uses a 4-byte `u32` tag plus naturally aligned maximum-member payload storage and final tail padding. Variant payload offsets and future struct field offsets are not fields of this common result.
- Consequently, `int | none` is 8 bytes rather than the legacy layout's packed 5 bytes. The extra 3 bytes buy naturally aligned tag/payload loads and copies, remove the `u8` tag's 255-member ceiling, and give calls, stack slots, and future aggregate layout one ordinary alignment rule. A compact representation remains a possible measured optimization, not the semantic layout baseline.
- The type foundation establishes stable identity, ownership, equality, duplicate handling, and layout.
- Function parameter, return, and local annotations now resolve variant syntax at the semantic/query boundary. Successful signatures publish canonical `TypeId`s, reordered member spellings retain equal signatures, and no cached value borrows type AST nodes or source text.
- Explicit duplicate members produce one diagnostic at the repeated member. Unknown type-family diagnostics remain owned by the parameter, return, or local-annotation boundary.
- `AnalyzeFunctionBody` publishes variant-bearing typed IR only after validating exact-member injection and the one implicit subset-widening site: a function argument accepted by a wider variant parameter. Other subset widening remains rejected pending explicit operation syntax.
- `FunctionValueUse` carries a source value plus an optional target variant at branches, calls, and returns. Local variant annotations use the type-specific `variant_coerce` instruction. SSA preserves both forms without repeating semantic checks.
- Codegen allocates arguments, edge-copy scratch space, and spills from `TypeLayout`. Exactly four-byte results use `eax`; every other nonzero-sized result uses caller-provided stack storage. Copies cover the full layout, including payloads larger than one word. Subset calls remap variant tags by structural member identity.
- Differing primitive branch values infer their canonical containing variant. A member-to-existing-variant join keeps that variant; two different existing variants do not widen implicitly.

### Ordinary function SSA

- `InstanceId` is currently a structural non-generic wrapper around `ItemId`, keeping callable identity distinct from declaration identity without an interner or registry.
- `LowerToSSA(InstanceId)` depends only on `AnalyzeFunctionBody` and produces an owned `SsaFunction`.
- Function SSA has explicit blocks with typed block arguments, ordered instruction results, symbolic calls targeted by `InstanceId`, type-specific integer operations, and one predicate-branch shape carrying a type-specific operation.
- Block arguments and instruction results share one value-ID namespace. Calls and CFG edges reference ranges in separate flat operand arrays, so neither call arity nor edge arity is encoded as a terminator kind.
- A value-producing `if/else` lowers to one predicate branch, two result-producing regions, and a merge block whose argument is the expression's value. Branches may carry any number of arguments; edge arity and types are validated against the target block.
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
- Code generation assigns constants to immediate locations, leaves a directly returned computed result in `eax`, and gives values needed across instructions or blocks fixed stack slots. This preserves operands across intervening calls and control-flow edges without embedding machine locations in SSA.
- The current internal calling convention reserves one fixed outgoing argument area per caller frame and passes signed 32-bit arguments there. Callees address incoming arguments relative to their own fixed frame, supporting arbitrary current arity and nested or recursive calls without dynamic call-site stack adjustment.
- Signed 32-bit negation, addition, subtraction, multiplication, and division are emitted from type-specific integer instructions.
- The `exit` instruction emits the Linux exit syscall inline and contributes no callable reference or relocation.
- Location planning is separate from instruction emission. Regular immediate and stack encodings share one 32-bit encoder and an operation-to-opcode mapping; division remains explicit because its machine sequence is structurally different.
- The backend lays out arbitrary block graphs, patches forward and backward relative jumps, and transfers edge arguments in parallel through one reusable scratch area. This supports value joins now and avoids sequential-copy corruption when future loops carry multiple values across a backedge.
- Unit-returning calls use the same argument, relocation, and reachability machinery as integer-returning calls; code generation emits the call but assigns no result location.
- Artifact equality is content-based across code, alignment, relocations, and referenced instances. Cleanup independently frees all three owned slices exactly once, including every partial-allocation failure path.
- Semantic failures and diagnostics remain transitive through compilation, while backend capability and function-size failures remain infrastructure errors.
- Unit and direct-call synthetic entries compile independently to retained ordinary function artifacts without demanding or compiling the callee.
- Relocation resolution belongs to the linker boundary rather than `CompileFunction`; `CompileFunction` never lays out addresses or resolves references.
- Equal selected-entry artifacts preserve the retained executable allocation across unrelated valid source edits.

### CLI

- `main.zig` accepts `--debug=ast,ssa,asm,timing`, one source path, and optional program arguments.
- The CLI reads the source into `SourceText`, requests `BuildExecutable`, renders transitive source diagnostics, writes `prog`, runs it, and prints its exit code.
- SSA debug output follows the same reachable function graph as executable construction; it does not analyze unrelated functions merely for display.
- AST rendering uses the parser's existing source-aware renderer. Assembly rendering decodes the final linked code, including the startup stub and resolved calls.
- Timing separates source loading, query-database initialization, input insertion, executable construction, diagnostic collection, debug rendering, executable writing, execution, and the total. It does not invent per-query timings that the engine does not expose.
- The single-file CLI uses one query worker because the current dependency chain has no useful coarse parallelism; restore automatic worker sizing when multiple independent source or compilation roots can run concurrently and measurements show a benefit.
- `runtime.zig` reports write, spawn, wait, and abnormal-termination failures to the CLI instead of terminating the compiler internally.
- `example.chi` is the manual smoke input: `zig run main.zig -- example.chi` builds and runs it, then reports exit code 42.
- CLI-level tests cover successful execution with every debug view and diagnostic failure without execution.

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

- `CollectReachableInstances` breadth-first traverses deterministic referenced-instance tables, compiles each reachable instance once, and terminates on shared targets and cycles by marking identities before enqueueing them. `BuildExecutable` and SSA debug rendering consume its cached order.
- The linker accepts a pre-collected artifact graph, rejects duplicate, missing-entry, missing-reference, and malformed-relocation metadata, and lays out each supplied artifact once in collection order.
- Every relocation is patched after layout using the target artifact's recorded address; reference bounds, patch-field bounds, alignment, signed 32-bit displacement, and addends are validated independently of frontend-producible graph shapes.
- Callee compile failure (a semantic issue in the called function's body) surfaces as `BuildExecutable` returning `null` with the callee's diagnostic transitively attached; this is demand-driven specifically by `BuildExecutable`'s own dependency on the callee's `CompileFunction`, since entry analysis itself validates only the callee's signature.
- Dynamic query dependencies follow current reachability, while caller artifacts remain independent of callee bodies.
- Query, codegen-unit, and execution tests cover transitive calls, shared targets, cycles, reachability removal, multiple relocations, metadata failures, displacement overflow, and allocation-failure cleanup.

## Current temporary limitations

- Static binding initializers are currently opaque to entry analysis; contextual validation inside them belongs to future general semantic analysis.
- Function signatures and bodies support structural variants over `int`, `unit`, and `none`, including aligned runtime values in locals, branches, calls, and returns. Inferred function returns, parameter modes, aliases, named types, and other compound types remain deferred.
- Value-producing `if/else` supports integer comparison conditions and equal-typed single-expression branches. Statement-only `if`, compound branch bodies, condition bindings, multiple source returns, and loop syntax are deferred.
- Calls currently support only bare file-local function names. Arguments can be any supported expression; mutable locals, assignment, and nested lexical scopes are deferred.
- Expressions currently support decimal `int` constants, `none`, calls returning supported primitive or variant types, `exit(value: int)`, immutable-local references, unary negation, binary `+`, `-`, `*`, and `/`, and value-producing `if/else` over integer comparisons. Variant inspection and extraction operators remain unsupported.
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
- Continue variants through the dedicated rollout below; keep unrelated aggregate, compile-time, and ownership machinery out of those slices.
- Port relevant legacy behavior and regression tests with each supported feature, not as a final batch.
- Keep machine addresses and executable layout out of semantic and SSA results.
- Preserve the boundary between relocatable function emission and whole-program executable construction.

### Variant rollout after the foundation

The selected semantics are:

- `none` is distinct from `unit`; both are valid variant members. The first source-facing member types are `int`, `unit`, and `none`.
- Variants are structural and aliases are transparent. Member order is irrelevant, nested variants flatten, and an explicit or alias-expanded duplicate is a source diagnostic rather than silent deduplication.
- A plain member value may be injected wherever an expected type is a variant containing that exact member. A smaller variant may widen implicitly when passed to a function parameter whose variant contains all of its members. Other variant-subset widening, including rebinding an existing variant with a wider type, requires an explicit widening operation; select that operation's spelling before implementing those sites.
- Differing `if/else` value types infer their canonical containing variant once branch inference is selected. Diverging branches later join through `Never`, independently of variant construction.
- `is` accepts a member or subset type on its right and only selects success/failure control-flow edges. `as` is fallible extraction, not an unsafe cast; its success edge carries the narrowed payload. A bare `if value as int` is valid and discards that payload.
- Successful narrowing does not change the original binding's type. A condition binding receives the narrowed type and exists only in the success region. Immutable condition bindings arrive with extraction; mutable condition bindings remain deferred.
- Postfix `?` is valid only for a variant containing `none`. Its success payload is the sole remaining member or the canonical variant of all remaining members.
- `is`, `as`, and `?` remain valid only in a fallible-expression consumer until another consumer is deliberately added. They lower through the existing predicate terminator and success-edge block arguments, never through a materialized boolean.
- Variant parameters and returns are part of the first complete runtime slice. Initial variant-return functions require explicit returns; implicit unit fallthrough remains a separate feature.
- Variant equality and `match` are later slices. `match` should consume the same tag tests and payload-carrying edges rather than introduce a second narrowing model.
- The planned transparent alias syntax is `static MaybeInt = int | none`; `comptime` remains an expression modifier rather than a declaration keyword.

Implement the remaining work as vertical phases:

1. **Complete.** Exact-member injection, directional call-boundary subset coercion, semantic construction, SSA values, layout-driven locations, calls, returns, copies, and branch joins use the aligned tag-plus-payload representation end to end.
2. Represent explicit widening only after its operation syntax is selected; keep non-call subset widening rejected until then.
3. Add `is`, fallible `as`, postfix `?`, and immutable condition bindings together, using success-edge payload arguments and testing success, failure, scope, and narrowed types.
4. Expose `sizeof` through `TypeLayout` now that the runtime representation is exercised end to end. Then add inferred multi-return joins, equality, aliases, and `match` as separately tested slices.

### Fallible control-flow expansion gates

In this language, a fallible expression either succeeds or fails in a fallible context. It does not produce `bool`; success may additionally expose a value to the success path. The current integer comparisons only select an `if` edge. Preserve that model as the feature grows:

- Add `and`, `or`, and `not` when compound conditions are selected. Lower them by short-circuiting between predicate blocks (`and`: lhs success continues to rhs; `or`: lhs failure continues to rhs; `not`: swap destinations), with no boolean instruction or value.
- Add `is`, `as`, and `?` only when variants enter the selected type system. `is` selects an edge; successful `as` and `?` also pass the extracted payload as a success-edge argument.
- Add condition bindings with `as` or `?`, not as an isolated declaration feature. The binding exists only in the success region and uses the payload delivered by that edge.
- Permit fallible expressions outside `if` only when another consuming context is selected. Until then, comparisons remain valid only while lowering an `if` condition.
- Add loop syntax when its source semantics are selected. Reuse the existing predicate terminators, general edge arguments, backedge patching, and parallel copies; represent loop-carried state as header block arguments. A cyclic SSA/codegen regression already protects that representation even though no loop source form exists yet.

The fallible slice is complete when the relevant legacy short-circuit, variant extraction, binding-scope, and failure-path tests pass through the refactored pipeline without introducing a boolean condition value.

### Runtime declaration migration gate

The inline `exit` operation is deliberately temporary. Do not build external linking solely to remove this one operation. Start the migration when any of these makes the machinery pay for itself:

- a second runtime-backed function is selected;
- another target cannot use the inline Linux syscall sequence; or
- source-level foreign functions or system-library calls enter the selected language subset.

Migrate only after whole-program construction can represent and resolve runtime symbols and a runtime artifact can follow the selected calling convention. Then:

- seed the callable namespace with an unshadowable declaration associated with `__lang_exit`: `exit: (int) -> Never` when `Never` exists, or temporarily `(int) -> unit` plus `noreturn` otherwise;
- represent user-function and runtime-symbol call targets as their two actual identity shapes;
- reuse ordinary call validation, SSA, machine-call emission, and relocation handling;
- supply `__lang_exit` from a runtime artifact and remove the dedicated semantic/SSA `exit` operation and inline syscall emission.

The migration is complete when `exit` has no dedicated typing, SSA, or instruction-emission branch; its only special data is its compiler-seeded declaration and runtime symbol implementation.

### `Never` type migration gate

Do not add `Never` merely to improve the current straight-line `exit` model. Add it when the next control-flow slice requires at least one of:

- joining a diverging branch with a value-producing branch;
- proving that every reachable path of a value-returning function returns; or
- typing a second non-returning operation such as panic.

At that point, add `Never` as the bottom type in expression and branch-type joins, give non-returning runtime declarations a `Never` result, and remove any temporary `noreturn` property. Tests must cover branch joining, return completeness, unreachable continuations, and incremental recomputation when a path changes between returning and diverging.

### 2. Legacy retirement

- Add debug output to the new CLI only as corresponding refactored representations stabilize.
- Remove legacy modules only after every selected behavior has a refactored regression test.
- Add persistent cross-run caching only after query values and serialization formats stabilize.

## Verification

Current focused commands:

```bash
zig test ast_new.zig
zig test tokenizer.zig
zig test diagnostics.zig
zig test main.zig
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
- `zig test main.zig`: 84 passed.
- `zig test semantic.zig`: 73 passed.
- `zig test query_new_test.zig`: 183 passed.
- `zig test ssa.zig`: 7 passed.
- `zig test codegen_new_test.zig`: 22 passed.
- The legacy `zig test legacy/test.zig` remains blocked by an unrelated `query_cache.load` call/signature mismatch.

## Handoff notes

- `query_new.zig`, `query_new_test.zig`, `query_structures.zig`, `structures.zig`, `ast_new.zig`, `diagnostics.zig`, `typing.zig`, `ssa.zig`, and `codegen_new.zig` are the main files for the current refactor path.
- The refactor path owns the repository root. The legacy pipeline and CLI live under `legacy/` with their own copy of `runtime.zig` and import nothing from the refactor path.
- Run `git status --short` before editing and preserve all user-owned changes.
