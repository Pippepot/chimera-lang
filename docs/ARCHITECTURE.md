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

Unchecked IR array and allocation projections require in-bounds storage
positions. Their indices are nonnegative; standard accessors validate bounds and
raw allocation callers supply the required proofs. Initialization requirements
belong to the operation using that position. Cursor offsets are
a separate operation and can be negative. Native addressing trusts these
contracts rather than repeating source checks.

Private cursor storage operations reuse cursor-element and borrow-read IR to
project a slot without reading its contents. Taking and consuming initialization
use ordinary ownership moves, including custom hooks; destruction runs in place.
Library algorithms own bounds and slot-initialization proofs. Reference contracts
distinguish a cursor's backing dependency from references stored in its elements
through referent paths. Alias exclusions involving a symbolic stored reference
remain obligations until call-site substitution supplies its actual owner.
Substituting a referent path follows stored references rather than treating a
write through them as a write to the cursor's backing slot.

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

`ConstructFunctionBody` caches deep-owned semantic construction independently of
callee provenance. `TypeFunctionInstance` consumes that cache and publishes fully
validated SSA under merged reference-effect dependencies. It publishes only when
the captures pass reference/lifetime checks and there are no ownership generations or
initializer regions. Repartitioning that unchanged capture set cannot invalidate
this stronger proof. `InferReferenceEffects` derives the merged summary from an
available conservative typed callee, otherwise from its precise contract. It
unions ordinary and per-alternative origins, including incoming no-write captures.
Both results track whether any precision was actually lost. An attempt consuming
only exact effects can publish its precise exported contract without retyping.
Reuse supports mutable flat references and single-reference-field carriers whose
referent cannot contain borrows; layered references, aggregate slots, and captured
variable effects retain precise analysis. A conservative body exporting effects
is reused only for transparent single-call forwarding with matching signatures
and unchanged argument sources;
`AnalyzeFunctionInstance` derives their precise contract from the callee.
Rejected conservative attempts fall back to full precise analysis; probe-local
diagnostics are not published. `ProbeFunctionInstance` shares successful full
reference/lifetime-validated bodies between runtime analysis and reference
contract inference, including cleanup-sensitive bodies. Unsuccessful probes
retain the ordinary precise-inference and diagnostic-producing analysis paths.
Recursive or unavailable body probes publish no reusable body rather than
a failed query, so successful precise fallbacks remain eligible for persistence.
With parallel workers, `ProbeReferenceCallees` discovers visited contract
callees through diagnostic-isolated reference inference before body typing
waits on their effects. Bodies that conservative typing cannot accept (owned values needing drops) skip this discovery, since it would type them an extra time. Their contracts are prefetched concurrently; only
ordinary demands observe their results and diagnostics. The provisional
discovery analysis is never reused as a validated body, and prefetch hints do
not force revalidation of existing queries after an edit.
`TrivialReferenceContractBody` caches proofs of empty reference/context effects
without runtime typing. Call-free proofs reuse cached construction directly;
only transitive proofs add query nodes. Scalar proofs can follow a single direct
call in an unconditional single-block body. Multiple calls, branches, short-circuit
expressions, early returns, and recursive proof cycles retain ordinary analysis
rather than demanding dormant callees. Callee edits invalidate these proofs through
normal query dependencies.
Construction, typing, and cached-body reuse return views to the query engine's
deep publication copy rather than making redundant query-local copies.
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

Inline variant cases reuse nominal struct identities with one anonymous payload
component and ordinary aggregate storage. Their declaration-owned namespaces and
generic specializations preserve identity through structural union composition;
qualified case lookup can forward through aliases and composed unions.
Construction preserves shorthand constructor and match-case names until typing
supplies an expected type. Typing reuses qualified nominal-case lookup, including
visibility and ambiguity checks, and owns initializer-shape validation after the
target type is resolved.
Semantic construction uses the same type/value context for unit, none, and
qualified payload-free case references. It emits a type value in type contexts
and an ordinary empty constructor for a case in value contexts. Typing and
argument discovery trust that distinction without reinterpreting type values.
Compile-time and runtime expressions use the same defaults; a static alias of a
payload-free case supplies an explicit type annotation.
Item discovery tracks type-producing positions so bare runtime case values do
not introduce declarations or collide with repeated references to the same case.
Synthesized payload converters have ordinary callable identities and bodies;
the backend has no case-specific instruction. Payload declarations validate
copyability and public exposure before consumers see their definitions.
Variant layouts select one-, two-, or four-byte tags from the alternative count;
unit/none-only variants need only the tag, and singleton unions remain tag-free.
Native tag writes also zero the existing prefix alignment padding (up to four
bytes), allowing full-width tag reads without increasing storage.

Structural subtyping is shared by static constraints, runtime type tests, and
value typing. The frontend constructs changed tuple representations with ordinary
field and variant operations before publishing IR, preserving ownership and
reference origins. Logical compatibility never permits reusing incompatible
destination storage; annotated static results are materialized by typed thunks.

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

Worker-local pools recycle computation scratch. Scratch and result arenas are
unsynchronized bump arenas owned by one computation; a result arena's first
chunk is sized from the query type's previous result. A database with zero
workers is single-threaded and takes no scheduler or allocator locks. Structurally
owned outputs compact into result arenas; queries opting into direct result allocation must
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
and publishes one authoritative typed SSA CFG. Numeric arithmetic carries its
concrete type and overflow mode; numeric conversions carry their destination and
policy. The shared numeric semantics module owns constant execution and literal
representability. Overflow contexts affect selected primitive operations in the
current expression and never specialize an ordinary callee by caller mode. All
branch arguments and call destinations are explicit; downstream stages do not
reconstruct source legality.

`std/primitives.chi` owns primitive operations, literal conversion, and lossless
numeric converters. The prelude imports this module without declaring operations.
Primitive namespace lookup and converter discovery use that registered defining
module, independently of a user file's prelude imports.

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

## Closures and Bound Methods

Concrete runtime captures, implicit runtime-callable specialization, and generic
struct result patterns, bound methods, and owning lexical-environment erasure
implement callable v1 (slices 1 through 4).
Inferred function references remain thin; fixed `func(...)` values use the
descriptor/payload ABI below. The rules belong to
[syntax&semantics.txt](../syntax&semantics.txt); [CLOSURES.md](CLOSURES.md) develops
their design. This section specifies the required compiler boundaries rather
than promising that every described behavior is implemented.

The concrete implementation discovers synthetic invocation items at
closure expression sites. Interned lexical environments retain static bindings
and type-only capture/parameter metadata, never runtime capture contents.
Generated structs provide inline storage and fieldwise copying, inheriting
ordinary movement and cleanup capabilities. `AnalyzeClosureBody` validates and
publishes receiver-based invocation with an inferred or contextual result;
ordinary direct-call IR borrows the actual environment with an internal `ref`
receiver. Closure-body typing marks that receiver readonly, without attenuating
writable captured referents. This preserves references into small environments
that would otherwise be passed by value under `imm`.
Runtime callable parameter types are recorded independently in the instance's
interned environment, without adding positional static arguments. Call discovery
allocates an argument-type buffer only when a resolved parameter requires a
callable signature; ordinary calls and overload candidates need none.
Specialization reuses the discovered candidate signature and sparse argument
types, with null entries for non-callable parameters. `FunctionCallSignature`
caches dispatch classification and validated signatures for fixed targets;
callable targets defer validation until their concrete specialization is selected.
Type-only discovery and actual calls share that query rather than repeatedly
demanding candidate and validated signatures. Query snapshot
format changes invalidate older snapshots when this metadata shape changes.

Overload matching supplies callable contexts to closure expressions without
executing capture construction or publishing rejected candidates' diagnostics.
Closure analysis caches source rejection as data; selected formation publishes
those diagnostics. Environment identities normalize inferred and contextual
signatures and distinguish capture types without depending on capture contents.
Ordinary and generated member calls project a concrete callable field once and
borrow its actual storage as the invocation receiver. Reference fields forward
their existing reference rather than taking its address again. Captured lexical
locals are installed before inference regions evaluate their static expressions.

Semantic construction identifies closure expressions, lexical free bindings,
capture order, and method-value expressions. Generated environment and invocation
identities include the expression site and enclosing specialization. Concrete
bound-method types identify the selected method and receiver type. Canonical
specialization keys include inferred callable types, never runtime capture values
or receiver addresses. Concrete environments use ordinary struct construction,
copy/move capabilities, cleanup, and receiver-based invocation.

Typing distinguishes a declaration's callable requirement from a concrete stored
`func(...)` type. Runtime callable parameters infer hidden concrete types without
adding positional static arguments. Ownership modes remain independent of that
inference. Generic struct result patterns combine fixed declared arguments with
callable types inferred from returned values and field initializers. Inference
observes an `init` operand's eventual logical type without forcing construction.
Each callable result slot resolves independently; conflicting or unresolved
returns are source errors. This extends nominal struct inference, not inversion
of arbitrary type-valued functions or general function return inference.

Candidate discovery remains independent of selected bodies. `ResolveCallableResultType`
types the selected instance's returns without constructing their values, using
the cached semantic body and type-only initializer discovery. Declared generic
struct identity and noncallable arguments constrain field inference; callable
arguments are independent slots checked against their required signatures.
`FunctionInstanceSignature` publishes the settled concrete result before actual
typing chooses its destination and layout. `ConstructFunctionBody` needs only
candidate parameter types, avoiding a dependency back to the unresolved result.
An erased temporary cannot stand in for a concrete result. Ordinary declaration,
initializer-type, and body dependencies drive recomputation; conflicting returns
and unresolved inference cycles are source diagnostics. Missing or stale query
state remains unavailable and must not masquerade as a semantic inference failure.

Std Map and Filter fields retain concrete callbacks through `init` parameters.
Filter keeps borrowed and owned delivery in separate selected helper bodies,
preserving reference forwarding and ownership transfer. Runtime sorting uses a
concrete reference-field holder at the caller, never a copied callback or a
factory-local wrapper. Type-valued union results preserve reference member kinds
during semantic construction.

Stored `func(...)` values have one common native descriptor/payload representation:

| Construction | Payload | Copy and cleanup |
| --- | --- | --- |
| Named function or noncapturing closure | Unused; descriptor selects code | Representation copy; no allocation or owned cleanup |
| Borrowed-receiver bound method | Checked reference to the original receiver | Reference copy; no allocation or receiver ownership hooks |
| Capturing lexical closure | Pointer to an owned concrete environment | Allocate/copy captures; destroy captures and release storage |

Descriptors provide ordinary invocation, copy, and cleanup code. Track the
payload's storage form separately from invocation-target identity: a merged or
opaque target can still be known to require no environment allocation. Method
binding validates member selection, receiver identity, and required permissions
at the frontend boundary. Its erased receiver reference is independent of any
temporary bound-value wrapper. Borrowing the receiver never transfers ownership
of the provider or upgrades its authority. Ordinary `ref` still aliases callable
storage; it is not an erased callable view.

Compiler-owned adapter items retain their construction form independently of
the target recovered at a use site: named code, noncapturing closure, borrowed
receiver, or an opaque thin function reference. Concrete bound types identify
the selected method and store one original receiver reference. Erasure extracts
that reference, never an address of the temporary bound wrapper. Signature
membership and overload matching are separate from representation widening.
Binding checks receiver requirements without executing invocation effects.
Immutable storage identities survive lexical scope exit so cleanup retains
descriptor facts. Invocation recovery follows direct destination construction,
immutable copies, fields, variants, and unambiguous helper returns. A separate
construction proof joins all alternatives without requiring one invocation
target. Returned proofs are derived from analyzed IR and may depend on immutable
input parameters and owned struct-field paths. Unexposed mutable local storage
can retain this proof across assignments; opaque storage exposure or any owning
alternative prevents it. These derived facts use ordinary query dependencies,
not additional serialized metadata.

Callee evaluation and runtime argument evaluation have separate ownership
boundaries. Callee liveness follows storage paths through argument control flow,
including loop generation remapping. Reading an allocated payload snapshots its
environment identity; later handle replacement invalidates dependent borrows.
Owned definitions are anchored immediately, before nested construction can
consume them. Computed bound methods are values, not argument storage places.

On x86-64, thin references and concrete bound values occupy eight bytes; erased
handles occupy sixteen bytes, aligned to eight. Adapter artifacts prepend a
24-byte invoke/copy/drop descriptor and publish an executable `entry_offset`.
Function relocations target that entry; descriptor relocations target its prefix.
Invocation passes the payload as a hidden pointer-sized stack argument, with
known adapters retaining the receiver's logical type. Recovering a descriptor
target during optimization explicitly repacks its hidden argument when needed;
physical pointer equivalence never substitutes for logical type agreement.
Native debug rendering separates named descriptor entries from executable code.
The std precompiler retains original adapter targets even when their invocation
has been inlined, preserving reusable ordinary function specializations.
Copy and drop entries receive the whole handle; invocation receives its payload.
Ownership entries are separately compiled functions, without descriptor prefixes.
Indirect destruction consumes a snapshot of the handle bits, not a copy of its
environment. This keeps handle addressability separate from environment identity
and permits proven nonowning descriptor entries to inline.
Erased handles are opaque ownership units: consuming parameters and replacement
destroy remaining handles through descriptors, never through synthetic fields.
Numbering invalidates payload, invocation, and allocation reads when handle
storage changes.
Nonowning construction facts permit representation copies and no-op cleanup;
the stored callable type itself has custom copy/drop and trivial move capabilities.
The evaluator uses dedicated erased-handle cells, preserving receiver aliases
across copies and snapshots. Opaque pointer carriers do not weaken ordinary
borrow type assertions. Owned payloads retain typed evaluation allocations and
borrow their initialized environment element for invocation. Snapshots preserve
allocation identity. Only receiver-free handles become canonical static
constants. Query snapshots, portable artifacts, and std bundles version these
identities, values, and ABI together.

Contract inference needs distinct sources for owned environment storage, receiver
references, captured referents, retained allocation providers, and registered
ambient inputs. Extend borrow containment, projections, joins, copy/move/drop,
and indirect-call substitution together. A returned reference into an owned
environment depends on that owner; a returned captured reference keeps its
original referent dependency. Copies of bound methods retain receivers, while
copies of allocated environments establish fresh ownership and apply ordinary
capture-copy contracts. Unknown callables conservatively account for possible
captures, writes, returned dependencies, allocation, and cleanup hooks. Contract
demand cannot depend only on explicit reference arguments or reference results:
scalar-returning callbacks and implicit hooks can use captured or ambient state.
Opaque receiver writes are an explicit contract dimension, not a fabricated
written type. Copy/drop effects select owned-environment provenance; borrowed
receiver payloads have no ownership-hook effects even after opaque forwarding.
An unknown environment type uses a wildcard environment path, while invocation
still follows receiver authority and referenced contents conservatively.
Scheduled implicit cleanup contributes symbolic writes before contract
publication without adding ownership uses after lifetime solving. Even
scalar-returning erased factories therefore require receiver-effect contracts
during analysis.

Standard service factories construct private callable fields only from direct
bound methods or permanent named functions. Validate their nonallocating
construction, storage/release authority, and message-nonretention requirements
at that boundary. Preserve construction facts through factory returns, handle
copies, and opaque invocation. A stored `func(...)` type alone does not promise
nonallocating copying; service handles use ordinary fieldwise callable copies
under their stronger construction invariant. Incompatible protocols are source
errors; missing contracts require recomputation rather than an assumed safe
fallback. General borrowed erased lexical-closure views remain deferred.

Allocating erasure uses existing typed allocation and destination construction.
An unpublished reservation owns raw storage without destroying an uninitialized
environment. Ordinary aggregate construction tracks completed captures; publishing
the handle consumes both the completed environment and its reservation.
`callable_allocation` reconstructs a borrowed typed allocation view from an owned
payload, and logical `.environment` reference paths distinguish environment
ownership from captured referents. Opaque traversal deduplicates actual origin
sets and does not treat readonly owner storage as a referent mutation.
Reserve storage before forcing fresh capture initializers or running copy hooks;
ordinary partial-initialization cleanup owns unpublished storage. Capture hooks
remain infallible. Implicit reservation failure panics, while explicit fallible
erasure/cloning returns the shared `std.memory.AllocationError` through the existing
result channel. `std.callables.erase` specializes its concrete deferred initializer;
other compiler-owned external declarations retain fixed result shapes.
With scoped services, each environment retains its original release
provider in a nonallocating handle. A new copy selects a provider for its new
allocation. Invocation and implicit hooks use the context active when they run;
only an explicitly captured service handle preserves an earlier selection.

Interpreter values retain symbolic descriptor identities and checked receiver or
evaluation-heap references, never host-native descriptor pointers. Published
results may contain only representable symbolic values; actual evaluation-local
captures remain transient and cannot enter canonical arguments or caches.
Reachability follows descriptor invocation, copy, destruction, and release code.
The ABI, interned callable identities, bundled bodies, and persistent snapshots
invalidate incompatible representations through their versioned formats.
Native and interpreter execution must preserve the same effects and lifetimes.

## References, Construction, and Cleanup

Places retain typed projections and storage identity rather than byte offsets.
Reference fields store addresses while exposing their logical referents.
Permission follows the captured referent, not the mutability of its carrier.
Substituting effects through a readonly reference attenuates nested writes;
readonly collection backing does not attenuate independent captured references.
Slot identity, owned-object generations, content versions, and active-tag proofs
are separate; replacing contents need not invalidate a stable slot address.

Reference contracts preserve source/result paths, write requirements, and temporal
exclusions through calls, converters, and hooks. Acyclic contracts derive from
cached typed bodies. Cycles activate direct-callee discovery and fixed-point
inference within the recursive component. Equal contracts stop unrelated body
changes propagating. Per-alternative parameter outputs are part of the same cached
contract; unchanged alternatives retain their incoming capture. Caller substitution
checks aliases and authority and attaches result proofs to installed dependencies.
An explicit empty output group installs no captures; an absent group uses the
merged fallback. For indirect writes, explicit target contents override opaque
ancestor contents; storage addresses alone do not imply retained referent captures.
Incoming branches filter dependencies before joins discard branch-specific facts.
Each ordinary exit supplies its own returned alternatives and proof identity;
bare returns supply `unit` independently of previously analyzed branches.
Copies and forwarding retain proof identity, while joins preserve conservative
loop history. Result tests filter dependencies, never restore storage or undo
ownership effects. Paths with equal alternatives and untested results still merge.
Typing shares AND/OR conditions between identical origin payloads rather than
enumerating call histories. Selection uses dense guard-ID memos scoped to one
incoming refinement snapshot and preserves origin heads for unchanged selections.
Immutable, non-reference whole-value copies with matching result domains and no
explicit physical flow origins reuse their existing result proof. Match captures
with physical origins retain their narrowing and ownership identity. Physical
places remain separately indexed for write invalidation. Loop rebasing removes
iteration-local proofs before applying header correlation.

Callable invocation, contract, and nonowning-construction discovery share storage
traversal for copies, projections, initialization, and forwarding. Invocation
identity and ownership form remain independent. Immutable projections recover
known targets. Unambiguous factory returns
derive returned reference effects from cached body analysis through a separate
query boundary: equal effects retain caller analysis even when target identity
changes. Immutable forwarded parameters retain their source-parameter identity.
Conditions on owning callable storage retain the parameter and its owned-field
path independently of invocation targets. Opaque copying and cleanup therefore
discard potential capture-hook effects when a caller supplies a nonowning handle,
including through nested aggregates; genuinely owning alternatives retain them.
Reassigned storage and disagreeing return paths retain conservative callable
effects. Opaque calls inspect captured writable references even inside immutable
carriers; carrier immutability grants no write authority over the carrier itself.
Recovery follows identities until a target, an unknown source, or an actual cycle;
deterministic identity walks detect cycles in constant space without a source-depth
limit. Callable body recovery is demanded only
when executable typing needs a reference contract.

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

Typing records effects at stable body-local checkpoints. Immutable cleanup actions
select nominal hooks, owned fields, variant alternatives, and reverse array
destruction once. Effect analysis, emission, and remaining drop obligations consume
the same actions; hook contracts are queried only for effects, and invocation-time
origins, contexts, and cleanup locations remain separate.
Error handlers commit carrier selection and ownership transfer before executing
the handler body, so those effects remain attached when it returns, breaks,
continues, or diverges. Recovering results have a separate completion checkpoint.
Body-local effect summaries distinguish authority/exclusion checks, writes to
reference-bearing contents, deferred service mutations, and context effects.
Checks and scalar writes are validated during final effect collection without
making reference contents provisional. Unknown service payloads remain possible
contents writers until substitution determines their actual effects.
Scheduling refines this summary against each cleanup value. A fully resolved,
abstract ambient receiver keeps its published service mutation but cannot write
body-local contents until a caller installs a concrete receiver. It therefore
does not make the body's contents provisional. Known provider invocations,
parameter/local receivers, incomplete origins, and context selected by the hook
itself retain conservative scheduling. Ordinary service mutations expand at
their call site when their receivers are complete; incomplete receivers retain
their invocation-site context snapshots for deferred expansion.
Output-bearing cleanup
first retains prospective referents for lifetime planning, then substitutes hook
outputs at the scheduled boundaries and CFG edges. Fresh carrier reads resolve
against those ordered writes; prior aliases and copied handles retain their
captures. Outputs follow the remaining owned cleanup shape and reverse destruction
order, including individually indexed array elements. Guarded cleanup preserves
the untouched alternative. Final authority and lifetime checks precede lowering
accepted cleanup to ordinary operations. Candidate discovery and scheduling do not
publish executed service mutations, authority requirements, or exclusions; final
effect collection validates and attaches them to the emitted cleanup.
Nominal hooks remain authoritative.
Prospective candidates are grouped by target root and retain only paths and
captures; temporal locations belong to scheduled writes. Equivalent whole-owner
nominal-hook captures are collected once per value, generation, type, and resolved
origins only when substitution is snapshot-only. Content loads and read-version
captures remain conservative. Empty places that cannot
store borrows and own no resource require no deferred content reads.
A contents origin records the selections and exclusions applied to a parameter as its
source path, and callers replay that path against their own origins. Selecting a part
that the path's trailing exclusions already removed leaves nothing, so the origin is
dropped when the selection is made; keeping it multiplied the origins of nested cursor
adapters with every stage, since each adapter excludes and re-selects its source field.
A body whose store passes two million origins, far above ordinary bodies, fails
analysis with `AnalysisTooLarge` instead of exhausting memory.
Reference-bearing slots retain initial captures and ordered definition and mutation
writes, including writes before cleanup discovery. A local definition stops
backward traversal at its actual CFG boundary, rather than inheriting the previous
iteration's contents. Loop backedges rebase stored references, including references
inside owned allocations, using the loop's read and result-proof checkpoints.
A hook's captured-slot dereferences
resolve at its scheduled cursor rather than the already-unbound live state.
Mutable parameter outputs resolve at the return terminator after cleanup;
ordinary returned copies retain their earlier captures. Terminator cursors are
distinct before interning and never mutate an existing ordinary-read identity.
Pending reads use indexed stable checkpoints and resolve in reverse insertion
order. Final lifetime effects replace provisional effects; unchanged effects keep
the planned endings while authority checks still run. Cleanup scheduling restores
the pre-scheduling symbolic state each epoch and repeats until ending locations and
resolved scheduled writes stabilize. Superseded cleanup writes become inactive
without changing cursor write indices. A repeated nonstable schedule is a source
lifetime error; final validation cannot change the accepted lifetime effects.
Cleanup output collection and deferred reads share one CFG. Cleanup scheduling
retains its reaching-contents write index across epochs. Replacing cleanup writes
invalidates the roots they affect; other roots retain their symbolic cached
results, and only new reads or reads of affected roots are refreshed.
Reaching-content
lookups index ordered writes by root and block and memoize acyclic cursors within
the analysis, including known-empty results. Canonical origin nodes, projections,
transforms, and result-selection snapshots share identities. Origin guards are
combined in local construction storage before immutable nodes are interned;
merging sets cannot change either input. Frozen resolution
memoization distinguishes physical flow aliases from lifetime loans.
Cycle-dependent results retain the
incoming fallback and are not shared across different traversal contexts.
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
Transient-call snapshots use reclaimable per-frame arenas, not query-long scratch,
so repeated calls release their snapshot storage before the enclosing query ends.
Execution errors retain source spans and call notes; compile-time `exit` is
compiler control, not an ordinary result.

Calls whose results or mutable parameters may retain evaluation-local identities
execute transiently, including argument-free factories. Publication recursively
checks actual contents before interning results, static arguments, conversions,
or copy-back. Transient handles never enter canonical values or disk snapshots;
representable extracted data can publish normally.

Context-sensitive calls also execute transiently. Each executor owns separate
allocator/logger bindings and an active-service stack; neither uses host TLS.
Recursion snapshots include the current bindings. Root allocation belongs to
the evaluation heap; the root logger is disabled and performs no host output.

## Scoped Context

Physical alias origins participate in flow invalidation without creating lifetime
loans into provider-object storage. Retention origins keep issued storage and its
release authority alive without claiming that counter writes alias element bytes.
Both properties survive contract publication and caller substitution.

Canonical registered declarations identify the independent allocator and logger
entries. Semantic construction preserves declaration identity through aliases and
reexports. Reading an entry snapshots a handle; only scoped replacement writes its
storage. Ordinary assignment, writable aliases, and moving out of an entry are
source errors.

Typing tracks each ambient entry as a symbolic input alongside ordinary parameters.
A scoped replacement evaluates its right-hand side under the previous bindings,
retains its installed dependencies and saved handle, and restores the saved binding
on ordinary exits after body cleanup. Returned allocations and saved service handles
retain their providers or backends, rather than temporary binding storage.

Reference contracts carry independent contextual reads, writes, source identities,
and mutation outputs. Service payload origins also retain symbolic invocation
metadata. Deferred service-mutation records preserve backend retention requirements
through opaque wrappers and are resolved against the installed receiver at callers.
Each record carries the allocator/logger origins active at its invocation site.
Internal overrides therefore survive contract forwarding; an expired callee-local
provider remains an explicit expired dependency when a backend retains new storage.
These are analysis facts and introduce no hidden runtime call arguments.
Storage construction and copy/drop qualification remain independent of invocation
identity. Allocator results retain both release dependencies and physical cursor
provenance, so adopted typed storage cannot acquire independent alias proofs from
its raw backing.

Deferred initializer inputs retain explicitly captured snapshots. Contextual result
dependencies instead use the forcing site's bindings and are conditional on the
actual initializer's returned contextual dependencies. Context reads performed by
cleanup or other effects do not alone attach a provider to the result.
A nonallocating literal initializer does
not introduce an allocator dependency merely because its result type can own
storage. Opaque initializer invocation conservatively includes context effects;
compiler-generated calls, converters, and ownership hooks also contribute them.

Native execution uses private GS thread state with lazily initialized roots. Each
synchronous frame caches its thread-state address after its first context operation;
subsequent reads still read the current individual handle. A new or foreign-origin
thread validates its thread ID and attaches fresh root state. Checked service
adapters push canonical factory/receiver pairs and remove them on every ordinary
return; repeated active pairs terminate with a service-cycle diagnostic. Cached CFGs
must balance that stack on ordinary returns and agree on depth at joins/backedges.

The evaluator owns independent bindings and a service stack for each evaluation.
Context-sensitive calls execute transiently, with binding state included in cycle
snapshots. The root allocator uses evaluation-local storage; the root logger is off
and performs no host output. Custom service state and allocated identities cannot be
published into canonical static values. Optimizer contextual resources remain
separate from ordinary memory, with reads invalidated by relevant writes and calls.

## Storage, Text, and Native Execution

Arrays store elements inline; Lists own an allocation and initialized prefix;
Allocation owns deallocation facts rather than element initialization state.
Box, Ref, Span, and text wrappers use ordinary declarations over validated storage
primitives. Construction and relocation use typed destinations, hooks, and cleanup.
Recoverable allocation and owned-storage growth return marked `AllocationError`
alternatives. Allocation retains its raw storage token, logical count, and
original allocator; growth and release use that provider. Infallible converters,
literal construction, and implicit callable erasure panic on refusal. Sorting
scratch uses an explicit root provider and exposes marked failures through its
recoverable implementation. Zero-byte host allocations reserve a distinct
stable address without changing logical count or layout.

Typed allocation construction, provider selection, and release are ordinary
library code over `RawBlock` and `AllocationLayout`. The native allocation
backend reserves and releases raw bytes; it does not construct `Allocation(T)`.

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
Data addresses use absolute 64-bit relocations, including cold runtime-failure
messages, so emitted artifacts satisfy the native snapshot contract.
The internal ABI is derived centrally, not assumed to be a platform ABI.

Linking trusts validated artifact metadata and treats an incomplete reachable
closure as an invariant violation; size and displacement limits remain recoverable
backend errors. Immutable data is deduplicated into the read-only ELF segment.
Native I/O retries EINTR and returns marked `IoError` with cause and progress. Panic prints a
source trace from read-only call-site metadata, exits 134, and does not unwind;
successful calls need no tracing instructions.

## Persistent Reuse

`--disk-cache` first checks an executable key covering source contents, paths,
module directories, and compiler identity. A miss may restore intern identities
and query outputs for a compatible file mapping. Representation and dependency
validation precede publication; damaged or stale state falls back to computation.
Only settled, accumulator-free, acyclic dependency subgraphs are persisted or
matched: memo cycles can retain a fallback from a failed dependency, so their
dependents must be recomputed. Successful writes replace caches atomically.

Ordinary runs independently install the embedded std bundle. Byte-identical std
text can reuse embedded parsed syntax; edited text uses normal parsing. Bundled
typed, prepared, optimized, call-component, and native results load lazily through
the scheduler with ordinary output ownership. Source overrides, membership or
representation changes, and incompatible identities use normal queries.
Optimized and native outputs require the producer's inline limit; prepared bodies
and call components do not. New generic specializations follow ordinary demand.
AST, SSA, optimized SSA, and assembly debug views bypass bundled results.
