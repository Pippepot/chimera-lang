# Architecture

This guide owns compiler boundaries, query demand, and result lifetimes.
[syntax&semantics.txt](../syntax&semantics.txt) owns language rules,
[ROADMAP.md](../ROADMAP.md) owns priorities, and
[COMPILER.md](COMPILER.md) owns build, debugging, and verification commands.
[OPTIMIZER.md](OPTIMIZER.md) describes optimizer and machine-stage details.

## Stage Ownership

| Surface | Responsibility |
| --- | --- |
| `src/main.zig`, `src/runtime.zig` | Source registration, CLI, executable publication and execution |
| `src/queries.zig` | Compiler query orchestration and dependency adapters |
| `src/query/` | Generic scheduling, memoization, publication, and failure recovery |
| `src/frontend/` | Parsing, semantic construction, typing, reference/lifetime analysis, interpretation |
| `src/optimizer/` | Runtime transformations of validated typed bodies |
| `src/backend/` | Host layout, machine lowering, allocation, encoding, and linking |
| `src/structures.zig`, `src/value.zig` | Shared representations and opted-in structural lifecycle operations |
| `src/intrinsics.zig` | Compiler-supported signatures, storage shapes, capabilities, and effects |

Frontend and backend stages do not import query orchestration. Query adapters
resolve identities and dependent facts; consumers trust contracts validated at
their owning boundary. Source rejection emits diagnostics, unavailable or stale
state remains distinct, infrastructure failures are errors, and broken compiler
invariants use assertions.

Published results are deeply immutable. Construction graphs, mutable analyses,
and finalization views remain local to their computation; neither source pointers
nor interpreter frame pointers may escape into cached results.

## Compilation Demand

Queries run on demand, not as whole-program passes. The main dependencies are:

```text
BuildExecutable
  ValidateModuleGraph -> ResolveFileImports / IndexItems
  CollectReachableInstances
    SelectEntry -> IndexItems -> DiscoverItems -> ParseFile
    CompileFunction
      AnalyzeFunctionInstance
      ValidateRuntimeFunction
      HostTypeLayout
      OptimizeFunctionInstance -> PrepareFunctionInstance -> typed body
```

The CLI registers the entry directory and embedded std sources. Module queries
validate imports, exports, duplicate names, and converter declarations without
analyzing unused bodies. A file's top-level statements form an ordinary unit
entry; a function named `main` has no special role.

`AnalyzeFunctionInstance` publishes typed SSA only after reference analysis and
lifetime planning. `CompileFunction` emits one artifact without compiling callees.
Reachability follows callable references from the designated entry, and linking
assembles the deterministic reachable closure. Unreachable bodies stay unanalyzed.
The CLI publishes `./prog` atomically and runs a private link or copy, so another
invocation cannot replace the executable being run.

Signatures, overload headers, namespaces, converters, reference contracts, and
compile-time execution have independent demands. Selected bodies and constrained
signatures are not prerequisites for discovering candidates. Argument type
discovery never executes conversions or argument effects; actual arguments run
once, left to right, after selection.

## Sources and Identity

`SourceRegistry` owns source, paths, file-to-module ownership, membership, and
existence inputs. File IDs survive directory refreshes; enumeration positions and
interner presence do not establish identity or module existence. The entry's
root `std/` is reserved for compiler-owned sources.

Declarations are module-wide; imports and implicit prelude bindings are
file-local. Resolution uses the defining file's effective scope. Explicit prelude
imports suppress defaults, and std files receive no implicit defaults.

`ItemId` identifies a declaration independently of its source location.
`InstanceId` adds canonical static arguments and any lexical static environment.
Resolution checks current membership, so moving or removing declarations
invalidates consumers. Query keys retain stable IDs or owned data, never pointers
into replaceable source.

Variants, tuples, arrays, and callable types have canonical structural identities;
declared and generated structs have nominal identities. Logical member types and
owned/reference storage kinds are independent. Arrays use structural element and
length identity, not generated fields. `ResolveTypeNamespace` associates types
with source namespaces independently of struct identity; visibility remains a
use-site decision.

Primitive operations use registered namespace members and ordinary callable
identities. Explicit overload sets own their membership; imports do not merge
them. Converter indexes and buckets conservatively select declarations by source
and target ownership. Cached absence is a dependency too. Constraints validate
selected signatures rather than trial-executing bodies or ranking candidates.

## Query Lifecycle

`ctx.input`, `ctx.get`, and `ctx.spawn` record dependencies, including absent
inputs. `ctx.emit` records diagnostics and other accumulators. Requests share
queued or running work, and spawned dependencies settle before publication,
including when their handles are discarded or the requester fails.

`ctx.prefetch` hints only previously unrequested queries. Hints observe neither
results nor diagnostics and publish no dependency. Their temporary wait edges
participate in cycle detection and settle before the requester returns. Ordinary
reads establish result dependencies; existing queries keep lazy edit validation.
Optimization takes independent hints from the prepared call graph and excludes
recursive components.

Idle workers steal general work. A waiting worker executes only its awaited
queued dependency, avoiding false cycles through unrelated work. With zero
workers, spawned work stays queued until demanded. Cycle detection distinguishes
current verified edges from stale dependencies. The CLI defaults to two workers
where available; zero workers run synchronously.

Inputs change only while the database is idle, advancing the revision only for a
changed value. Nonzero live revisions leave zero available for never-failed
queries. A conservative transitive input fingerprint and bounded change journal
can validate unrelated revisions without traversing every dependency. Possible
matches, expired history, and failed subtrees use ordinary validation. Summaries
refresh even when recomputation returns an equal result.

Recomputation commits dependencies, output, and diagnostics together. Equal
observable results retain their old allocation and last-change revision; changed
diagnostics are observable even when the ordinary output is equal.
Infrastructure failure discards fresh state, retains the last completed memo,
and remains retryable. Failed children contribute no stale accumulators; recovery
invalidates parents' handled fallbacks.

Per-function queries do not imply per-body source invalidation: signatures and
bodies still read file source and AST. Same-file edits can rerun multiple
analyses; equal outputs stop propagation. Out-of-line callee edits can preserve
caller SSA and code while requiring relinking.

## Result Ownership

| Data | Owner and Validity |
| --- | --- |
| Source text, paths, membership | Database inputs, until replacement |
| Interned declarations, types, values, bindings | Database session |
| AST, scopes, signatures, IR, artifacts, executable bytes | Query output, until replacement or database destruction |
| Semantic graphs, flow state, origins, lifetime scratch | One body-analysis computation |
| Logical allocations, cells, transient captures | One evaluation session; backing may end earlier |
| Dependencies and diagnostics | Query entry, replaced atomically on recomputation |
| Published executable | Filesystem, independent of the database |

Worker-local pools recycle computation scratch. Structurally owned outputs
compact into result arenas; queries opting into direct result allocation must
place every owned payload in `Context.resultAllocator`. Pointer-based custom
outputs retain their computation arena. Equal and failed computations discard
fresh storage without replacing the old result. Consumers needing a longer
lifetime copy data or keep stable IDs.

Opted-in structural copying, equality, hashing, and cleanup share field traversal
in `src/value.zig`. Maps and borrowed graphs retain explicit ownership rules.
Intern entries occupy stable append-only chunks; immutable lookup can proceed
without the scheduler mutex, while insertion owns its separate synchronization.
Allocator pools and indexes are implementation details, not semantic query facts.

## Analysis and Lowering

Semantic construction validates syntax and lexical structure in a query-local
expression graph. AST payload classification and child enumeration are shared by
equality, rendering, and walkers; each walker retains its lexical boundary.
Typing resolves names and operations, specializes calls, inserts conversions,
and publishes one authoritative typed SSA CFG. All branch arguments and call
destinations are explicit; downstream stages do not reconstruct source legality.

`AnalysisContext` owns source-dependent lookup, visibility, and specialization.
`TypeFacts` supplies structural type and ownership facts; `HostTypes` adds host
layout. Copy/move/drop capabilities, runtime eligibility, logical type, member
storage kind, access permission, and argument passing remain independent facts.
Invalid definitions preserve their original diagnostic dependencies.

Flow typing refines reads, not declared storage or physical layout. Immutable
facts carry possible alternatives, mutation versions, and proof ancestry.
Aliases share place identity where justified; copied bits do not become aliases.
Joins combine incoming facts, writes invalidate overlapping proofs, saved booleans
retain versioned implications, and loop backedges must preserve entry proofs used
by the body. Unevaluated inference snapshots metadata without executing effects.

Body-local persistent buffers save independent value, availability, initializer,
and completion facts. Logical length is independent of the shared root. Captures
freeze a root; writes copy its pointer table and affected 16-slot page. Joins may
skip shared pages only after establishing their own length and state invariants.
These snapshots never become published IR.

Ranges, iteration, comprehensions, operators, and error handlers lower to ordinary
calls, projections, branches, and cleanup. `next` returns one retained poll carrier
with an owned `std.iteration.End` alternative. Static iteration runs source,
cursor, polling, and item snapshotting in one evaluation heap before analyzing
retained expressions; excluded subtrees remain unanalyzed.

Match coverage uses disjoint remaining scalar spaces and tuple products without
discarding field correlations. Only unguarded arms subtract coverage. The subject
runs once, captures prepare before guards, and ownership commits on selection.
Pattern ranges are compile-time intervals and built-in comparisons, not Range
objects or membership calls.

Marked errors are nominal metadata and ordinary variant data. Catch and postfix
propagation lower to the same SSA and lifetime machinery; neither native emission
nor interpretation has an error-only instruction or second return channel.
Entry forwarding cleans owners before invoking the ordinary unhandled-error
reporter.

## References, Construction, and Cleanup

Places retain typed projections and storage identity rather than byte offsets.
Reference fields store addresses while exposing their logical referents.
Permission follows the captured referent, not the mutability of its carrier.
Slot identity, owned-object generations, content versions, and active-tag proofs
are separate; replacing contents need not invalidate a stable slot address.

Reference contracts preserve source/result paths, write requirements, and temporal
exclusions through calls, converters, and hooks. Acyclic contracts derive from
cached typed bodies. Cycles activate direct-callee discovery and fixed-point
inference within the recursive component. Equal contracts stop unrelated body
changes propagating. Caller substitution checks aliases and authority; result
alternatives do not narrow the merged mutation effects of ordinary return paths.

Address-passed values construct in their consumer's explicit destination. Locals,
results, fields, variant payloads, and array elements use the same machinery;
representation does not imply immovability. Ordinary reference arguments pass
caller storage directly. Joins preserve selected storage and exact types.
Directly movable replacement prepares a separate value before ending the old
generation; destructive replacement ends it before construction at the same place.

An `init` argument is an affine, call-lived pending initializer. Inference checks
its complete expression without execution or placement; executable typing then
builds an ordinary region at the receiving destination. Captures preserve storage,
authority, ownership, and single-use obligations through forwarding. Regions may
return their own value or diverge, but cannot exit an enclosing caller or escape
as first-class handles. Skipped regions leave captures untouched; completed
writes and transfers do not roll back.

Typing records effects at stable body-local checkpoints. The lifetime solver
produces one path-sensitive ending plan; typing rejects abandonment and lowers
accepted cleanup to ordinary operations. Nominal hooks remain authoritative.
Partial-field obligations, stored-member restrictions, and reference provenance
survive refinement and forwarding. Cleanup snapshots are selected at the latest
reaching point on each path, including known-empty contents. Block splitting does
not rekey reference effects. A final CFG check includes destructor writes between
borrow acquisition and use.

## Compile-Time Execution

Expressions requiring evaluation are typed before interpretation; aliases and
declared type identities may resolve directly. Concrete representable calls use
`ExecuteComptimeCall`, keyed by instance and canonical arguments, and record
ordinary body, layout, and hook dependencies. Type-returning static calls need no
site-specific wrapper IR.

The interpreter owns logical cells, allocation records, snapshots, and an
evaluation heap shared by calls and initializer regions. Released backing becomes
invalid while cell identities remain tombstones until teardown. Frame recursion
compares logical snapshots while preserving aliases and allocation identity.
Execution errors retain source spans and call notes; compile-time `exit` is
compiler control, not an ordinary result.

Calls whose results or mutable parameters may retain evaluation-local identities
execute transiently, including argument-free factories. Publication recursively
checks actual contents before interning results, static arguments, conversions,
or copy-back. Transient handles never enter canonical values or disk snapshots;
representable extracted data can publish normally.

## Storage, Text, and Native Execution

Arrays store elements inline; Lists own an allocation and initialized prefix;
Allocation owns deallocation facts rather than element initialization state.
Box, Ref, Span, and text wrappers use ordinary declarations over validated storage
primitives. Construction and relocation use typed destinations, hooks, and cleanup.
Recoverable APIs return ordinary optional values; implicit allocation failure
panics. Zero-byte host allocations reserve a distinct stable address without
changing logical count or layout.

Span holds a typed cursor and length. Checked views retain permissions and
content dependencies; mutable handles cannot upgrade readonly captures. Static
bytes use symbolic interner identities and offsets. UTF-8 validation cannot
outlive conflicting writes, and transient cursors cannot publish as static data.
Target, provider, location, layout, and access are independent dimensions; host
layout must never establish the representation of inaccessible non-host memory.

Codegen consumes trusted typed IR and host layouts. It emits a private machine
stream where scalar allocation is needed; fixed-only functions encode directly.
Machine liveness follows expanded instructions, not a second language CFG.
Artifacts publish only code, relocations, constant data, and call-site metadata.
The internal ABI is derived centrally, not assumed to be a platform ABI.

Linking trusts validated artifact metadata and treats an incomplete reachable
closure as an invariant violation; size and displacement limits remain recoverable
backend errors. Immutable data is deduplicated into the read-only ELF segment.
Native I/O retries EINTR and returns ordinary optional failures. Panic prints a
source trace from read-only call-site metadata, exits 134, and does not unwind;
successful calls need no tracing instructions.

## Persistent Reuse

`--disk-cache` first checks an executable key covering source contents, paths,
module directories, and compiler identity. A miss may restore intern identities
and query outputs for a compatible file mapping. Representation and dependency
validation precede publication; damaged or stale state falls back to computation.
Successful writes replace caches atomically.

Ordinary runs independently install the embedded std bundle. Byte-identical std
text can reuse embedded parsed syntax; edited text uses normal parsing. Bundled
typed, prepared, optimized, call-component, and native results load lazily through
the scheduler with ordinary output ownership. Source overrides, membership or
representation changes, and incompatible identities use normal queries.
Optimized and native outputs require the producer's inline limit; prepared bodies
and call components do not. New generic specializations follow ordinary demand.
AST, SSA, optimized SSA, and assembly debug views bypass bundled results.