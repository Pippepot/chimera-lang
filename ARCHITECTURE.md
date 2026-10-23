# Compiler Architecture

This document owns current implementation boundaries and invariants, not a
feature catalog. [syntax&semantics.txt](syntax&semantics.txt) owns language rules,
[PROGRAM_FLOW.md](PROGRAM_FLOW.md) follows query demand and recomputation, and
[ROADMAP.md](ROADMAP.md) owns future work. Commands live in the
[compiler guide](docs/COMPILER.md).

## Code Map

| Owner | Responsibility |
| --- | --- |
| [src/main.zig](src/main.zig), [src/modules.zig](src/modules.zig) | CLI orchestration, source discovery, and source registration |
| [src/queries.zig](src/queries.zig) | Compiler queries, identity interning, and adapters between stages |
| [src/query/](src/query/) | Stage-independent scheduling, memoization, dependencies, and structural encoding |
| [src/structures.zig](src/structures.zig) | Shared syntax, identities, types, typed IR, diagnostics, and artifact contracts |
| [src/frontend/](src/frontend/) | Tokenization, parsing, semantic graphs, typing, references, lifetimes, and interpretation |
| [src/backend/](src/backend/) | Native code generation, x86 encoding, and disassembly |
| [src/intrinsics.zig](src/intrinsics.zig) | Supported intrinsic signatures, storage shapes, effects, and capability policy |
| [src/value.zig](src/value.zig) | Opt-in structural copying, equality, hashing, and cleanup |
| [src/diagnostics.zig](src/diagnostics.zig), [src/debug.zig](src/debug.zig), [src/profiling.zig](src/profiling.zig) | Presentation and opt-in measurement, not semantic decisions |
| [src/runtime.zig](src/runtime.zig) | Atomic executable publication and isolated execution |
| [std/](std/) | Embedded language-level standard library and its registration metadata |

Frontend and backend stages do not import compiler query orchestration. Queries
supply services to stages; the generic engine does not know compiler query names.
Keep shared contracts together where their consumers need the same invariants.
Split a subsystem only when it can own meaningful state or behavior, not merely
to shorten a file.

## Sources and Identity

`SourceRegistry` publishes text, paths, file ownership, module membership, and
module existence as inputs. Refreshes preserve file IDs and happen only while
the database is idle. The module catalog determines existence; interning a
module path does not create a module.

Declarations belong to modules; imports and implicit prelude bindings belong to
files. Resolution uses the defining file's effective scope. Module validation
checks imports, exports, and declaration ownership without executing unused
declarations or analyzing unused bodies.

`ItemId` identifies a declaration independently of its current location.
`InstanceId` adds canonical static arguments and, for generated declarations,
lexical static bindings. Declared and generated structs are nominal; arrays,
tuples, variants, and callable types have canonical structural identities.
Type identity and the source namespace used for member lookup are separate.
Queries retain owned values or stable identities, never replaceable source views.

## Analysis and Published IR

The parser produces syntax; semantic analysis builds a query-local expression
graph. Typing resolves names and specialization, chooses operations and
conversions, checks ownership and references, and constructs one typed SSA
control-flow graph. Signatures and bodies are separate query results.

`AnalysisContext` supplies source-dependent resolution and specialization.
`TypeFacts` exposes structural types, borrow shape, ownership, and runtime
eligibility. `HostTypes` adds host layout. These adapters derive existing facts
rather than creating redundant caches. Intrinsic validation belongs at the
analysis boundary; interpretation and native emission consume its contracts.

Source constructs lower before publication: match becomes tests and branches;
iteration becomes ordinary cursor calls and control flow; collection building
uses ordinary destinations, calls, and nested initializer regions. Primitive
operations may select existing IR directly after ordinary argument preparation.
Later stages do not repeat source legality checks or introduce another general
lowering IR. Evaluation order remains explicit.

Match patterns retain recursive tuple structure independently of operation
typing. Typing checks structural coverage before lowering disjoint tuple and
variant alternatives. Borrowed captures construct their actual copies before
conditions; fresh captures reserve stable source places and acquire ownership
after condition success. Rejected conditions retain the candidate and clean up
independent attempt owners. Dispatch protection uses the shared reference/effect
analysis, including inserted cleanup. One source arm instantiated on distinct
paths receives distinct expression-cache state; cached SSA values never cross
those paths.

Calls have independent target, arguments, and optional result destination.
Logical type, owned/reference member storage, movability, and argument passing
are separate dimensions. Address-passed values use storage projections and
caller-provided destinations; reference arguments preserve caller storage.
`init` handles are call-lived construction operands with nested typed regions,
not first-class functions. Failure edges, partial construction cleanup, and
captured writes are explicit; failure does not roll back completed effects.

## Ownership and References

Typing owns source-place traversal, visibility, reference propagation, and
structural ownership decisions. A body-analysis workspace owns construction
graphs, nested regions, flow versions, provenance, and lifetime scratch.
Published results contain none of that mutable analysis state.
Initializer regions reserve their complete entry-argument and capture buffers
before binding. Type-only inference first walks unresolved expression dependencies
and captures only the required enclosing values and locals, including source
places, match patterns, and guards. Executable initializer regions retain full
enclosing-state capture; both paths use the same typing and ownership rules.

Reference contracts describe result origins, mutation requirements, and temporal
exclusions through fields, elements, and variants. Acyclic contracts derive from
cached typed bodies; recursive components use fixed-point contract analysis.
Storage identity, content identity, and variant-tag identity remain independent.
Readonly authority survives copying and call substitution; a mutable binding
cannot upgrade a readonly capture.

Graph construction records live in
[body_graph.zig](src/frontend/body_graph.zig); origin-chain storage lives in
[reference_origins.zig](src/frontend/reference_origins.zig). Typing retains their
semantic interpretation. Stable effect and boundary identities survive graph
insertion and splitting. Reference checks use exact operation positions,
including effects of fallible calls and inserted cleanup.

[flow_snapshot.zig](src/frontend/flow_snapshot.zig) owns persistent paged buffers.
Saved versions share unchanged pages in the body workspace. Availability,
values, initializer consumption, and completed transfers are independent facts;
joins may skip shared pages only when their own invariants permit it.

[lifetime.zig](src/frontend/lifetime.zig) computes one path-sensitive ending plan
from graph effects. Typing rejects explicit-drop abandonment and materializes
accepted cleanup as ordinary IR. The solver neither interprets type structure
nor publishes its state. Dense availability/demand bitsets and sparse cleanup
operand lookup avoid block-by-generation operand matrices.

## Compile-Time Execution

Required evaluation types code before interpreting it. The interpreter owns
logical cells, recursion snapshots, and one evaluation-local heap shared by
nested calls and initializer regions. The query adapter owns canonical values,
specialization, and dependency recording, not interpreter cell construction.

Calls with representable arguments and results can use canonical memoization.
Transient arguments, results, or mutable parameters route through the evaluation
session instead. Publication recursively rejects escaping heap handles while
allowing copied or extracted ordinary data. Symbolic static bytes retain intern
IDs and offsets, never native or evaluator addresses. Allocation failure in the
compiler remains retryable infrastructure failure.

Static expansion retains canonical lexical bindings in generated identities.
Excluded subtrees remain parsed but unanalyzed. Reached I/O is an execution
capability error; it cannot become an ambient compile-time effect.

## Query Ownership and Failures

Published outputs are deeply immutable. Dependencies, output, and diagnostics
commit together; equal observable recomputation retains the old result pointer
and stops invalidation. Inputs change only while the database is idle.

Computations use recycled scratch storage. Structurally owned outputs are copied
into result storage before scratch is released; custom pointer-based outputs
retain their computation arena and explicit cleanup contract. Borrowed workspace
or dependency views are not recursively destroyed on failed publication.
Temporary bodies and contracts used outside publication remain explicitly owned.

Source rejection and unavailable analysis usually publish `null`, preserving
observed dependencies and emitted diagnostics. Missing inputs and infrastructure
failures remain errors; invariant violations use assertions or `unreachable`.
An infrastructure failure discards fresh state and keeps the last completed memo
retryable. Do not use an error to discard a source-invalid fact's dependencies.

## Native Output and Persistence

Codegen consumes trusted typed IR and host layout, producing owned per-function
machine code, symbolic references, constant bytes, and trace metadata. It does
not compile callees. Reachability supplies a deterministic entry-first closure;
the linker lays it out and patches relocations. The backend and disassembler
share instruction descriptions. The callable ABI is compiler-internal.

The standard library uses ordinary declarations and instances. Registered
externs supply low-level host operations; containers, text, formatting, and
iteration otherwise execute library source. Host allocation retains logical
counts and complete deallocation facts. Non-host layouts and providers remain
future work governed by the language specification and roadmap.

Persistence has separate responsibilities:

- [cache.zig](src/cache.zig): checksummed disk entries and compiler/source keys.
- [query_disk_cache.zig](src/query_disk_cache.zig): session snapshots and restored
  dependency/representation validation.
- [query_artifact.zig](src/query_artifact.zig): portable artifacts with translated
  file, declaration, type, and specialization identities.
- [standard_bundle.zig](src/standard_bundle.zig): build-time std compilation and
  lazy per-query loading through the ordinary scheduler.

Byte-identical embedded std text reuses build-time ASTs; edited text parses
normally. Bundled bodies and native functions depend on the closed registered
standard library and validated representations. Incompatible records fall back
to ordinary computation. AST, SSA, and assembly debug views bypass the bundle.
Only successful work populates caches. Restoration validates untrusted bytes
at its boundary; downstream stages trust accepted metadata and check resource
limits, not source legality again.
