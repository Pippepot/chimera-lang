# ASAP destruction implementation handoff

This document is the implementation handoff for the last-use destruction item
in milestone 1 of [ROADMAP.md](ROADMAP.md). It is a plan, not a second language
specification. [syntax&semantics.txt](syntax&semantics.txt) remains authoritative,
and [ARCHITECTURE.md](ARCHITECTURE.md) owns durable compiler boundaries.

## Snapshot and current status

The repository was inspected on 2026-09-15 at baseline commit
`505de68fb896bf708c138973700c09eefa97cda5` (`Typing flattens at finish`) on
`master`. That commit contains the prerequisite changes in:

- `syntax&semantics.txt`: the ASAP rules now define ownership generations,
  subexpression boundaries, path-sensitive destruction, ordering, divergence,
  and `_ = value`.
- `typing.zig`: typed CFG construction now retains a mutable instruction list
  per block. Build-time instruction IDs remain stable, and `finish()` alone
  flattens the graph and assigns published value IDs.
- `ARCHITECTURE.md`: the mutable construction CFG and final publication
  boundary are documented.

The only intentional, uncommitted handoff changes are:

- `README.md`: this handoff is listed in the documentation index.
- `ASAP_DESTRUCTION_PLAN.md`: this file is the handoff artifact requested for
  the remaining delivery slices.

Do not undo or duplicate those changes. At this snapshot, all of the following
pass:

```sh
zig test query_new_test.zig       # 330 tests
zig test codegen_new_test.zig     # 23 tests
zig test main.zig                 # 94 tests
zig fmt --check typing.zig
git diff --check
```

No last-use analysis is implemented yet. Runtime destruction is still emitted
eagerly by lexical cleanup code in `typing.zig`.

## Goal and completion criteria

Complete this work when every currently supported whole-value ownership path
uses the specified ASAP timing:

- Every successful initialization has one ownership generation.
- Transfer or a consuming call ends the source generation without destroying
  it and forwards the obligation.
- An automatically destroyed generation is destroyed at the earliest legal
  completed subexpression boundary after its final use on each path.
- A never-used generation is destroyed immediately after initialization.
- Branches, fallible success/failure edges, loops, return, propagation, break,
  continue, and divergence behave as specified.
- Reinitializing a whole root handles the old and new generations separately.
- Owned temporaries, discarded results, call arguments, returned values,
  aggregate operands, and temporary aggregate projections follow the same
  analysis as named locals.
- Non-escaping borrows keep the current owner alive through the operation that
  uses the borrow.
- Simultaneous cleanup is deterministic and follows the specified ordering.
- `_ = value` is accepted as a non-consuming last-use marker and does not
  invoke copy or move merely to discard the value.
- Explicit-drop obligations remain checked on every path and never gain an
  implicit destructor.
- Published `FunctionBodyAnalysis` contains only type-specific ordinary IR.
  Codegen does not rediscover ownership and receives no generic `destroy`
  instruction.
- The old lexical cleanup scheduler and its transitional state are deleted once
  the cutover is complete.

The work is a semantic change, not an optimization. Tests must observe when
destructors run, not just count emitted calls.

## Scope boundaries

Implement now:

- Whole local roots, owned `var` and `deinit` parameters, and owned
  temporaries.
- Whole-root replacement and the existing replacement cleanup behavior for a
  field target.
- Struct and variant cleanup using the ownership strategies already published
  by `OwnershipCapabilities` and `StructDefinition`.
- The current borrow model: direct place borrows, field projections,
  conditional borrowed/owned results, `imm` calls, and mutable call copy-back.
- All CFG forms currently produced by typing.

Do not expand this slice into:

- Partial-field transfer or a general partially initialized place analysis.
- Independent ASAP liveness for every stored field. Preserve field replacement
  cleanup at its replacement boundary until partial places are implemented.
- Escaping pointer/view origins or unions of arbitrary origins. Milestone 6
  extends the same lifetime machinery to those.
- Stable storage for immovable values.
- Copy-to-move optimization. Mojo performs it, but it is not required to make
  destruction timing correct.
- Dynamic drop flags. Path-specific CFG cleanup must remain statically placed.
- A new query, public lowering IR, or codegen ownership logic.

When the milestone is closed, retain the deferred partial-place and origin work
in `ROADMAP.md`; do not claim Mojo's field-sensitive system is complete.

## Authoritative semantics to preserve

The relevant language rules are in `syntax&semantics.txt` under runtime
ownership and destruction. The important consequences are:

1. A lexical name may contain several sequential ownership generations.
   Visibility does not keep an old generation alive.
2. A final use in a nested expression may end a lifetime before the containing
   statement or outer expression finishes.
3. Source evaluation remains exactly once and left to right. Cleanup may be
   inserted only after the operation and all borrow dependencies that require
   the value.
4. Destruction is path-sensitive. If only one branch needs a value, other
   outgoing edges destroy it instead of extending it to the join.
5. A possible later-iteration use keeps a value live across the applicable
   backedge. Each loop exit is handled independently.
6. There is no cleanup after a no-return operation because no continuation
   exists. A value whose last use is earlier still dies at that earlier point.
7. At a shared boundary, destroy a dependent before an owner it can access;
   otherwise use reverse lifetime-start order. Fields in one aggregate cleanup
   remain reverse declaration order.
8. `_ = value` evaluates `value` once and records a use. It is not an owning
   destination, copy, transfer, or explicit-drop discharge.

Use one additional implementation interpretation for CFG joins: when different
incoming generations become one owned join result, consume the incoming
generations on their edges and start a synthetic join generation at the block
entry. This makes generation identity and simultaneous ordering deterministic
without a runtime ordering flag. If every incoming path carries the same
generation, keep it instead of manufacturing a join generation.

## What Mojo actually does

The reference implementation inspected was Mojo commit
[`6417db28ceef430d067755e9826cec65e19f9333`](https://github.com/modular/modular/blob/6417db28ceef430d067755e9826cec65e19f9333/Mojo/lib/LowerLIT/CheckLifetimes.cpp).
The manual behavior is documented in [Value destruction](https://mojolang.org/docs/manual/lifecycle/death/),
with executable documentation cases in
[`death/tests.mojo`](https://github.com/modular/modular/blob/6417db28ceef430d067755e9826cec65e19f9333/Mojo/docs/site/code/manual/lifecycle/death/tests.mojo).

The reusable ideas are:

- Mojo runs lifetime checking after semantic control flow exists, over mutable
  MLIR/HLCF regions.
- It first collects tracked values, then performs forward initialization/origin
  work, then performs a bottom-up destructor-insertion pass.
- The backwards state is effectively a bit set of values consumed or required
  later. The first use encountered backwards is the last use forwards.
- Differing branch sets are unified, with destructor calls inserted on the
  branch that does not need a value.
- Loops are dry-run to a fixed point before mutation, then replayed to insert
  cleanup.
- Destructors are inserted into the mutable IR; they are not delayed to machine
  code generation.
- Mojo is field-sensitive and also tracks origin dependencies. Those portions
  are deliberately beyond this compiler slice. The future model is described
  in Mojo's [origin design](https://github.com/modular/modular/blob/6417db28ceef430d067755e9826cec65e19f9333/Mojo/proposals/origin-design.md).

Do not transliterate Mojo's large pass. This compiler has a smaller type system,
explicit SSA blocks, and ownership strategies already selected during typing.
Use the same dataflow shape with the smallest metadata needed here.

## Current compiler map

### Pipeline and publication boundary

- `semantic.zig` builds `UnresolvedBody`, a query-local expression graph with
  structural source blocks and source-use spans.
- `typing.zig:resolveAndTypeBody` creates `BodyBuilder`, calls `build()`, and
  then `finish()`.
- `BodyBuilder` creates the only typed CFG. `BuildBlock` now owns mutable
  `BuildInstruction` sequences, and temporary high-bit instruction IDs do not
  depend on final placement.
- `BodyBuilder.finish()` orders blocks by their recorded layout order, flattens
  instructions, remaps every temporary instruction operand, and publishes
  `structures.FunctionBodyAnalysis`.
- `FunctionBodyAnalysis` is an owned, flat query result. Its equality and
  deinitialization are in `structures.zig`; codegen consumes it directly.

The lifetime pass belongs between `build()` and `finish()` inside the existing
`AnalyzeFunctionBody` work. Keep all new mutable metadata query-local and free
it from `BodyBuilder.deinit()`.

### Current ownership state

`BodyBuilder.Value` currently contains:

- The typed SSA representation (`id`, `type_id`).
- `borrowed_type` and `borrow_root` for the current non-escaping borrow model.
- `borrow_condition` for a value that is borrowed on some runtime paths and
  owned on others.
- `explicit_transfer` for validating owning versus borrowing contexts.

`local_availability` independently tracks source legality:
`unbound`, `available`, `transferred`, or `maybe_transferred`. Preserve this
forward analysis for use-after-transfer, whole replacement restoration, and
loop-backedge diagnostics. Last-use analysis supplements it; it does not replace
source availability checking.

`OwnershipCapabilities(TypeId)` already separates move, copy, and drop strategy
and exposes `needs_automatic_drop` and `requires_explicit_drop`. Do not add a
second type classification to the lifetime pass.

### Current cleanup machinery to migrate

The following functions or call sites currently decide lifetime end eagerly.
Move their automatic behavior into the new analysis, then delete the obsolete
state rather than leaving two schedulers:

| Area | Current function or state | Required end state |
| --- | --- | --- |
| Lexical blocks | `block()`, `endLocalsSince()` | No automatic scope-exit scheduling |
| Function exits | `finishFunctionExit()`, `endAllLocals()` | Terminators seed lifetime dataflow |
| Local end | `endLocal()` | Availability transition remains; automatic cleanup is scheduled globally |
| Expression statements | `discardValue()` | Record a non-consuming use at the statement boundary |
| Temporaries | `pending_temporaries`, `endPendingTemporaries()`, `endTemporary()` | Ownership generation and use/consume effects |
| Calls | `call_temporary_drops`, `dropCallTemporaries()` | Call-boundary effects; no call-local cleanup stack |
| Projection | eager `dropValue()` in `fieldAccess()` and conditional projection helpers | Final use of the aggregate owner at the projection/copy boundary |
| Assignment | eager `dropValue()` in `assignment()` | Whole-root generations analyzed; field-target replacement remains boundary-local for now |
| Conditional extraction | `FlowExit.temporary`, `enterFlowExit()`, extraction-local `endLocal()` | Effects on the appropriate CFG paths |
| Cleanup lowering | `dropValue()`, `dropVariantMember()` and ownership hook calls | Reused as the type-specific cleanup materializer |

Do not delete a current mechanism until every case it covers has an equivalent
effect and a regression test. In particular, fallible calls, partially built
struct initializers, conditional borrowed temporaries, and active variant
members already have regression coverage.

## Target construction model

### Keep ownership identity separate from SSA identity

Do not use `FunctionValueId` as an ownership generation ID.

A trivial copy or move may reuse the same SSA bits while creating or forwarding
a distinct ownership obligation. Mutable calls and field updates may produce a
new SSA representation while the same ownership generation continues. Branch
arguments can also merge alternative representations. Conflating these
dimensions will either double-destroy shared bits or lose required destruction.

Use a query-local identity such as:

```zig
const GenerationId = enum(u32) { _ };

const Generation = struct {
    type_id: structures.TypeId,
    start_order: u32,
    span: structures.SourceSpan,
    needs_automatic_drop: bool,
    requires_explicit_drop: bool,
    can_deinit: bool,
};
```

Store the type and policy once in the generation record. Effects should refer
to the generation ID and the currently valid SSA representation; do not repeat
the type on every effect.

Add ownership metadata to `Value` sufficient to distinguish:

- An owned generation represented by the value.
- A borrow of a known current generation.
- The existing conditional borrowed/owned case and its predicate.
- A value with neither relevant ownership nor borrow dependency.

Trivial-drop primitives and callables do not need tracked generations unless a
uniform code path makes doing so simpler. Never emit runtime cleanup for them.

### Represent completed subexpression boundaries

Instructions alone are insufficient. A source expression can lower to several
instructions and blocks, while a local read may lower to no instruction. Nested
expressions may complete at the same instruction position in a significant
order.

Extend the mutable block sequence with non-published markers:

```zig
const BoundaryId = enum(u32) { _ };

const BuildItem = union(enum) {
    instruction: BuildInstruction,
    boundary: BoundaryId,
};

const Boundary = struct {
    span: structures.SourceSpan,
    // Effects are ordered in forward semantic order.
    effects: std.ArrayList(LifetimeEffect) = .empty,
};
```

`finish()` skips boundary markers and continues to publish only ordinary
instructions. Build-instruction IDs remain stable exactly as they do now.

Allocate an expression boundary before lowering an expression, make it the
current boundary while that expression classifies its operands, restore the
parent boundary after nested evaluation, and insert the marker when the
expression successfully completes. This lets `borrowValue()` and owning-use
sites attach effects to the operation that actually requires the operand,
rather than to the nested identifier read.

Also create explicit internal transition boundaries where one source boundary
contains ordered ownership phases. Whole replacement is the important case:
the old generation's final use and destruction precede installation of the new
generation, while a never-used new generation ends after initialization.

A diverging expression has no completion marker after its no-return operation.
Earlier nested expressions still retain their own markers.

### Record typed lifetime effects while typing

Do not reconstruct ownership semantics later from `FunctionInstruction` tags.
The same representation may be borrowed, copied, moved, mutated, or consumed
depending on the already-resolved parameter mode and ownership strategy.

Use an ordered effect union along these lines:

```zig
const LifetimeEffect = union(enum) {
    define: struct {
        generation: GenerationId,
        value: structures.FunctionValueId,
    },
    use: struct {
        generation: GenerationId,
        cleanup_value: structures.FunctionValueId,
    },
    update: struct {
        generation: GenerationId,
        cleanup_value: structures.FunctionValueId,
    },
    consume: GenerationId,
};
```

Meanings:

- `define` starts a generation after successful initialization.
- `use` requires the generation through this boundary. If this is its last use,
  `cleanup_value` is the representation the destructor must receive.
- `update` both uses an existing generation and publishes its representation
  after mutation, so a destructor immediately after the mutation sees the new
  value.
- `consume` ends the generation without an implicit destructor.

Represent ownership-phi forwarding separately on CFG edges:

```text
predecessor generation --consume/forward--> successor generation
```

An edge can be identified during analysis by `(predecessor block,
successor ordinal)`: ordinal 0 for a plain branch, then/else for predicate
branches, and success/failure for fallible calls. No public edge identity is
needed unless implementation experience proves otherwise.

An ownership phi is not an ordinary in-block `define` effect. Its edge mapping
owns the transition so backwards demand for the successor generation is still
visible when translating it to the incoming generation. Model two edge cases:

- `forward source -> destination` for a value already owned by the caller.
- `produce destination` for a fresh value created by the terminator, such as a
  successful fallible call result.

Record effects at the semantic boundary that already owns the fact:

- Binding, whole replacement, owned call result, copy result, move result, and
  aggregate result define generations.
- A place borrow records a use of its owner when the borrowing operation
  completes, not when the identifier is looked up.
- Copy records a use of the source and defines the copy even when runtime bits
  are reused.
- Move consumes its input and defines its result. A direct transfer into a
  return or owned argument may forward directly if that avoids a useless
  intermediate generation.
- Owned arguments and returns consume their outgoing generation.
- Aggregate construction consumes owned field operands and defines the
  aggregate generation.
- Mutable calls record a use/update after copy-back, using the updated SSA
  value.
- A discarded expression records a use; it does not request ownership.
- Cleanup-generated instructions record no new user lifetime effects. Analysis
  has already finished before they are emitted.

### Join ownership explicitly

Extend captured `State`/`Value` metadata so joins compare ownership generation
as well as SSA value and source availability.

- If every reachable incoming path carries the same generation, retain it.
- If incoming generations differ, create one synthetic successor generation,
  add edge forwards from each incoming owned generation, and associate the
  successor generation with the joined `Value`.
- A generation change can require an ownership phi even when a trivial copy
  means the SSA value ID is unchanged. Do not force a runtime block argument
  solely for metadata; the joined generation may use the already-dominating
  representation.
- Loop-header ownership phis follow the same rule. Unchanged ownership can flow
  around a backedge; a reinitialized generation is forwarded into the header
  generation.
- Preserve `borrow_condition` for a join that is borrowed on some paths and
  owned on others. Scheduled cleanup for that generation must use the existing
  predicate pattern so only the owned runtime path is destroyed.

This avoids dynamic drop flags. The existing conditional borrow predicate is a
value-semantic join fact already required by the compiler, not a general shadow
initialized flag.

## Lifetime analysis

Run analysis only after the typed CFG, generation table, boundaries, and edge
forwarding are complete. Do not mutate the CFG during fixed-point computation.

### Reachability

Compute reachable blocks from the entry using terminators. Ignore unreachable
predecessors when merging sets. Terminator successors are:

- `branch`: one target.
- `predicate_branch`: then and else.
- `fallible_call` and `fallible_indirect_call`: success and failure.
- Returns and `diverge`: none.

Treat missing terminators, out-of-range blocks, duplicate definitions, and a
use before its definition as compiler invariants. Allocation/size failures are
errors. Only explicit-drop abandonment and existing ownership misuse are source
diagnostics.

### Backwards lattice

Use one bit per tracked generation. The lattice is union and therefore finite.
Keep `live_in`/`live_out` bit sets per reachable block and use a worklist or
reverse iterations until no set changes. For loops, this is the equivalent of
Mojo's dry-run-to-fixed-point phase.

Define a block's `live_in` as demand immediately inside the block, after its
ownership phis. For a predecessor edge:

1. Start with the successor's `live_in` set.
2. Apply ownership-phi mappings backwards. For `forward source -> destination`,
   replace a demanded destination with the source. For `produce destination`,
   stop demand at the edge because the terminator creates the value.
3. If a forwarded destination is not demanded, end the incoming source on that
   edge. If a produced destination is not demanded, end it at the successor
   entry using the produced block argument.
4. Merge successor-edge demand by union.
5. A generation demanded by some successors but not others must remain live
   before the branch. Record cleanup on each edge where it is not demanded.

Scan block effects backwards:

```text
consume G:
    require G before the consume; never schedule an implicit drop there

use/update G:
    if G is not already required later:
        automatic G -> schedule cleanup after this boundary
        explicit G  -> record abandonment diagnostic on this path
    require G before the effect

define G:
    if G is required later, remove it: the lifetime starts here
    otherwise:
        automatic G -> schedule zero-use cleanup after this definition
        explicit G  -> record abandonment diagnostic
```

Terminator ownership effects are scanned before the block's last boundary.
Returning an owned value and passing a consuming argument are consumes. Borrowed
terminator operands are uses. A return/failure/break/continue edge otherwise has
no implicit lexical seed: remaining automatic owners are found from their own
definitions and uses.

After convergence, perform a second deterministic traversal to produce the
cleanup plan and diagnostics. Do not append instructions during the dry run.
Deduplicate planned `(location, generation)` pairs and assert each automatic
generation has exactly one drop or consume on every reachable runtime path.

### Cleanup locations

A planned location is one of:

- After a stable `BoundaryId` within a block.
- On a specific outgoing edge.
- At block entry for a synthetic joined definition with no use.

Prefer edge cleanup blocks over inserting at a shared successor entry. A shared
successor may have other predecessors that still need the value. Always
splitting a non-empty cleanup edge is acceptable and keeps the rule simple.

Process multiple locations in one block from later to earlier, or find them by
stable boundary ID after each mutation. Never use a stale array index after a
split.

### Ordering at one location

First honor dependency edges when they exist. For the current non-escaping
borrow slice, borrowed owner uses extend the owner to the consuming operation;
there should be no long-lived cross-owner dependency graph yet.

For otherwise independent generations, sort by descending `start_order`.
Allocate `start_order` in exactly-once evaluation order. Synthetic join
generations start at their join entry. Preserve reverse field declaration order
inside one fieldwise cleanup.

Whole replacement has an ordered lifecycle transition and is not an arbitrary
simultaneous group: destroy the old generation before installing the new one
when both events meet at the replacement boundary.

## Cleanup materialization

Separate planning from lowering. A planned cleanup carries generation, current
SSA representation, location, ordering key, and `can_deinit`; it does not become
a generic published instruction.

Reuse the existing type-specific `dropValue()` behavior after refactoring it to
emit at a transformation cursor:

- Trivial drop emits nothing.
- Custom drop emits the already-resolved direct hook call.
- Fieldwise struct drop extracts fields and recursively emits cleanup in reverse
  declaration order.
- Fieldwise variant drop emits tag dispatch and cleans only the active member.
- Explicit drop emits no automatic call and is valid only for a
  cleanup-authorized `deinit` generation.

The simplest general insertion strategy is a dedicated cleanup block:

1. For an interior boundary, split the original block into a prefix and a new
   suffix. Move the original terminator and later build items to the suffix.
2. Branch from the prefix into a new cleanup block.
3. Make the cleanup block current and call the existing recursive cleanup
   lowering. It may create its own variant dispatch blocks.
4. Branch the cleanup flow to the suffix.

SSA values defined by the prefix dominate its unique cleanup/suffix path, so a
plain split requires no new block arguments. Multiple cleanups at the location
are emitted in the precomputed order.

For an outgoing `FunctionBranch`, retarget the predecessor to a cleanup block
and let that block forward the original branch argument range to the original
target. For a fallible-call success/failure edge, the interposed block must have
the same implicit result argument types as the original target and explicitly
forward them. Preserve success payload and mutable copy-back ordering.

Add narrowly named mutation helpers only when the materializer uses them, for
example `splitBlockAtBoundary`, `replaceTerminator`, and
`interposeCleanupEdge`. Keep block lifecycle transitions in these helpers and
assert that every block is entered once and terminated once.

Cleanup instructions are inserted after analysis, so they must bypass lifetime
effect recording. Preserve the existing active-hook suppression that prevents
compiler-generated copy/move/drop plumbing from recursively calling the hook
currently being typed.

## Control-flow cases that need deliberate handling

### Branches and conditional transfer

Union successor demand before scanning the predicate. Insert cleanup on a path
that neither uses nor consumes a generation. A root transferred on one branch
and untouched on another is valid for automatic-drop types: the transfer path
consumes it and the other path destroys it. The joined source root remains
unavailable for later source use.

Do not retain the current `possibly_transferred` diagnostic merely because an
automatic value reaches lexical scope end. Keep that diagnostic for an actual
later use of a maybe-transferred root.

### Fallible calls and propagation

Call arguments are evaluated left to right before the call terminator. Borrowed
arguments remain live through both success and failure of the call. Owned
arguments are consumed on both. A successful owned return generation starts
only on the success edge. Temporary arguments and partially built aggregate
operands must be cleaned on failure if they were initialized and not consumed.

Preserve mutable argument copy-back before any last use that depends on the
updated value. Test both success and failure paths.

### Loops

Do not special-case a single traversal. Solve backedges to a fixed point. A use
reachable in a later iteration makes the generation live on the relevant
continue/fallthrough backedges. Break edges have their own cleanup plan. Keep
the existing forward rule that an available root on loop entry must be restored
on every reachable backedge.

### Divergence

`diverge` has no successor and no cleanup location after it. Nested values whose
last use occurs before the no-return instruction still clean up at their earlier
boundaries. Do not manufacture an unreachable continuation solely to run
destructors.

### Reassignment

Whole-root replacement ends the old generation and defines a new one even if a
trivial copy reuses the same SSA ID. A final old-value borrow in the RHS keeps
the old generation through that borrow/copy and then permits destruction before
the replacement transition completes.

For a field target, preserve the existing extraction and cleanup of the old
field at the replacement boundary. Generalizing that field's lifetime to an
earlier last use requires partial-place state and is deferred.

### Explicit drop

An explicit-drop generation is valid only if every reachable path consumes or
forwards it, or it ends inside a `deinit`-authorized context. The backward pass
must diagnose a path where automatic cleanup would otherwise be required.

`_ = resource` records a use but does not satisfy the obligation. Conditional
consumption must diagnose only the path that abandons the value. Do not emit an
automatic drop before producing the diagnostic.

## Delivery slices

Complete these in order. Keep the tree green after each slice; do not mix the
public semantic cutover into the representation work.

### Slice 0 — mutable construction CFG (already complete)

Delivered in the current working tree:

- `BuildBlock` owns mutable build-time instructions.
- Stable temporary instruction IDs are independent of final position.
- `finish()` is the only flatten/remap step.
- Published IR and codegen are unchanged.

Before continuing, rerun the snapshot verification commands and inspect the
working diff so concurrent user changes are preserved.

### Slice 1 — boundaries and discard-pattern plumbing

Implement:

- Change each build block's instruction sequence to ordered `BuildItem`s and
  add stable, non-published expression boundary markers.
- Add current/parent boundary tracking around `value()` and statement-owned
  operations, including control-flow expressions and divergence.
- Make `finish()` skip markers while preserving existing published order and
  value remapping.
- Recognize assignment-statement target `_` in `semantic.zig` before local name
  lookup and publish a distinct lifetime-extension/discard statement. Treat it
  as the discard pattern in this context, not a mutable local target. Do not
  broaden underscore rules in other identifier contexts during this slice.
- Type `_ = value` once, reject explicit transfer there under the existing
  borrowing-context rule, and avoid copy/move solely for the discard.

Tests:

- AST shape for `_ = value` can continue using the existing assignment node.
- Unresolved semantic output distinguishes `_ = value` from ordinary
  assignment.
- Published SSA before and after marker introduction is unchanged for existing
  branch, loop, call, and aggregate cases.
- `_ = move_only_value` does not request copy; `_ = value^` remains invalid in
  a borrowing context.
- Allocation-failure cleanup covers boundary/effect lists.

### Slice 2 — ownership generations and typed effects

Implement:

- Generation table and independent IDs.
- Owned/borrowed generation metadata in `Value` and captured states.
- `define`, `use`, `update`, and `consume` effects at every ownership
  classification site.
- Ownership forwarding at conditional joins, loop headers/exits, fallible call
  continuations, and expression-result joins.
- Distinct generations for trivial copies and whole replacements even when SSA
  IDs match.
- No behavior change yet: retain current cleanup while validating internal
  metadata invariants.

Audit every `ownValue`, `copyValue`, `moveValue`, argument mode, return,
aggregate construction, field projection, mutation copy-back, and transfer
site. An ownership effect added downstream from the place that decided the
operation is a design smell.

Tests:

- Trivial copy has two obligations despite one SSA ID.
- Mutable copy-back changes representation without silently creating or losing
  a generation.
- Branch and loop joins create ownership phis only when generations differ.
- Owned call results exist only on success.
- Existing runtime output and diagnostics remain unchanged.

### Slice 3 — backwards solver and cleanup plan

Implement:

- Reachability and successor enumeration.
- Per-block generation bit sets and edge-phi remapping.
- Monotone fixed-point solving for arbitrary cycles.
- A second, deterministic planning traversal.
- Automatic cleanup records, explicit-abandonment records, and simultaneous
  ordering without CFG mutation.
- Internal assertions for exactly one definition and path-complete end of every
  tracked generation.

Keep current eager cleanup active and run the new solver in analysis-only mode;
do not publish duplicate calls.

Tests should exercise the solver through small table-driven cases covering:

- Straight-line last use and zero use.
- One-arm use and one-arm consume.
- Join forwarding.
- Backedge use, continue, and break.
- Return/failure/diverge.
- Explicit-drop abandonment on only one path.
- Reverse start order at a shared boundary.

Small solver-only tests may live beside the private implementation in
`typing.zig`. Observable cross-module behavior belongs in
`query_new_test.zig`.

### Slice 4 — cleanup materializer and CFG mutation

Implement:

- Stable boundary lookup after mutations.
- Interior block splitting.
- Ordinary and fallible edge interposition with argument forwarding.
- Ordered cleanup-block emission using the existing type-specific drop logic.
- Conditional owned/borrowed cleanup using the existing predicate semantics.
- Variant dispatch rejoining the original continuation.
- Final flattening of the transformed CFG.

Keep automatic cutover disabled until synthetic/manual schedules prove:

- A custom drop can be inserted inside a completed block.
- Two drops at one boundary retain requested order.
- Cleanup on one predicate edge does not run on the other.
- Fallible success/failure payloads survive an interposed cleanup block.
- A variant cleanup dispatch reaches the original suffix.
- New blocks and instructions deinitialize under every allocation failure.

No `destroy` opcode may appear in `structures.FunctionInstruction` or codegen.

### Slice 5 — semantic cutover and old-scheduler removal

Invoke lifetime analysis after `build()` and before `finish()`, materialize its
plan, and remove eager automatic scheduling.

Migrate in one coherent cutover:

- Named roots and owned parameters.
- Whole-root replacement.
- Discarded and never-used temporaries.
- Struct initializer operands and partial construction failure.
- Ordinary/fallible call arguments and results.
- Temporary aggregate projections.
- Conditional borrowed/owned temporaries.
- Return, failure propagation, break, continue, and all loop backedges/exits.
- Explicit-drop path validation.

Then delete or reduce the old machinery listed in the migration table. Retain
only field-target replacement cleanup that is explicitly deferred, the
type-specific cleanup emitter, and forward source-availability validation.

Required observable regression matrix:

- A destructor runs before a later unrelated call or `exit`, immediately after
  the last use.
- A never-used initialized value dies before the next source operation.
- Reassignment destroys each generation once; an RHS borrow delays the old
  generation through that borrow.
- A value used only in one branch is destroyed at entry to the other path.
- Conditional transfer drops only the non-transfer path and produces no
  scope-end `possibly_transferred` error.
- A later-iteration use keeps a value across the backedge; break and continue
  clean path-local values.
- Return and failure clean non-escaping values, while returned/consumed values
  are not dropped locally.
- No destructor is placed after `exit`/`diverge`.
- Shared-boundary values drop in reverse start order; struct fields retain
  reverse declaration order.
- `_ = value` moves the last use to that statement and invokes neither copy nor
  move merely for the marker.
- `_ = explicit_value` still produces the explicit-drop diagnostic unless a
  later consuming path satisfies it.
- Existing custom copy/move/drop, variant, mutable argument, incremental query,
  and allocation-failure tests continue to pass.

The existing test technique of defining a drop hook that calls
`exit(self.value)` makes timing observable: the first destructor reached
becomes the process exit status. For ordering tests, let non-selected values'
hooks return and make only the expected first value call `exit(42)`.

### Slice 6 — cleanup, incremental behavior, and documentation

Perform the two required review passes from `AGENTS.md`.

Correctness pass:

- Check ownership transfer, allocation cleanup, pointer/slice lifetimes,
  generation forwarding, fallible paths, loop convergence, divergence, and
  every block/terminator mutation.
- Verify no scheduled cleanup uses an SSA value that fails to dominate the
  cleanup block.
- Verify a diagnostic path publishes no partially transformed body.
- Verify generated cleanup calls preserve query dependencies on custom hook
  identities.

Cleanup pass:

- Delete transitional analysis-only flags, legacy temporary stacks, redundant
  spans/types, and helpers with no remaining caller.
- Keep one owner for each lifecycle transition and one operand/effect
  enumerator.
- Reread the complete flow from `resolveAndTypeBody()` through `finish()` and
  simplify it.

Incremental tests:

- Edit a final use so a destructor moves to another boundary; body and compiled
  output must change.
- Restore the original source; value-equal analysis should be retained according
  to existing query semantics.
- Edit a custom drop hook body; reachability and executable behavior must
  update without changing unrelated body analysis.
- Turn a valid consume path into abandonment and back; diagnostics and recovery
  must be exact.

Documentation:

- Update `ROADMAP.md` current foundation to state which ASAP slice is now
  implemented and leave origins/views/partial places as future work.
- Replace the temporary scope-cleanup paragraph in `ARCHITECTURE.md` with the
  actual lifetime pass, metadata ownership, and publication contract.
- Change `syntax&semantics.txt` only if implementation uncovered a true missing
  language decision; do not copy algorithm details into it.
- Either mark this handoff complete or remove it once its remaining information
  is fully represented by the owning documents.

## Final verification

Run the complete repository verification listed in `README.md`, sequentially
for suites that write `./prog`:

```sh
zig test tokenizer.zig
zig test ast_new.zig
zig test semantic.zig
zig test diagnostics.zig
zig test query_new_test.zig
zig test codegen_new_test.zig
zig test main.zig
zig fmt --check typing.zig semantic.zig ast_new.zig structures.zig query_new_test.zig
git diff --check
```

Also inspect `git status --short` and the complete diff. Do not stage, revert,
or rewrite unrelated user changes.

## Failure patterns to avoid

- Do not equate generation identity with SSA value identity.
- Do not infer copy/move/borrow/consume from an opcode after typing already made
  that decision.
- Do not insert cleanup while loop dataflow is still converging.
- Do not insert cleanup at a shared successor entry without proving every
  predecessor needs the same cleanup.
- Do not keep a value to lexical scope end merely because that is convenient
  for one exit path.
- Do not use one global reverse-local stack for simultaneous destruction.
- Do not add a runtime initialized/drop flag to repair path-insensitive
  analysis.
- Do not analyze compiler-generated destructor plumbing as new user-owned
  values.
- Do not automatically destroy an explicit-drop generation.
- Do not publish a generic ownership operation to codegen.
- Do not silently expand the slice into origins, pointers, views, stable storage,
  or partial-field transfer.
