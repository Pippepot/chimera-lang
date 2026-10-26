# Optimization Design

[ARCHITECTURE.md](../ARCHITECTURE.md) owns the optimizer boundary and
[ROADMAP.md](../ROADMAP.md) owns future priorities. This document owns the IR
shape the optimizer works on, the pass structure, and the reasons for both.

## Boundary

Two queries own optimized bodies:

- `PrepareFunctionInstance` runs the local passes on one typed body. Its direct
  calls form the call graph (`DirectCallees`), so statically dead calls never
  enter it, just as they never became reachable code before inlining.
- `OptimizeFunctionInstance` inlines into the prepared body, repeats the local
  passes, and runs the loop passes. Only codegen consumes it.

The interpreter, reference contracts, signatures, and diagnostics read the typed
body, so optimization cannot change diagnostics or compile-time results. An
inlined callee must pass `ValidateRuntimeFunction`, the same runtime-type check
that guards its own native compilation, so inlining cannot hide a diagnostic.

The optimizer reads IR facts only: instruction tags, operands, parameter modes,
storage projections, block arguments, struct field types, and whether a type is
passed indirectly. It never reads source constructs, typing state,
`CallBehavior`, or standard library names. Language features that lower to
existing IR need no optimizer change. Unknown means conservative: a use the
optimizer does not recognize marks the value address-taken, and an
unclassified instruction is never removed, moved, or numbered.

## Staged IR Plan

Keep a small set of deliberate semantic levels, not an extensible dialect
framework. Share SSA mechanics where their invariants agree; introduce a new
representation when a consumer needs facts that the previous level cannot
express directly.

1. **Typed semantics.** Keep compile-time execution, reference contracts,
  diagnostics, and source cleanup attached to typed bodies. Runtime
  optimization must not become a prerequisite for interpretation. Share
  operation semantics, not machine instructions, with the interpreter.
2. **Semantic optimization.** Retain logical values, storage projections,
  aggregates, variants, and explicit effects. Keep mutable analyses local to
  the optimizer, reuse them until mutation invalidates their facts, and publish
  immutable bodies. Introduce stronger operations only when transformations
  benefit from their semantics; ordinary induction facts need not become IR.
  A non-wrapping loop rewrite must prove its preconditions or retain a guarded
  fast path and the original fallback, including final-increment behavior.
3. **Native machine instructions.** Lower semantic operations before machine
  register allocation, making instruction operands, temporary values, fixed
  registers, clobbers, branches, and copies explicit. The machine stage owns
  physical locations and encoding; it does not repeat language validation.
  Verify machine constraints and preserve call-site provenance through lowering.
4. **Additional targets.** Separate logical types, representation domains,
  physical calling conventions, and execution capabilities. Layout facts belong
  to a type and representation domain; address spaces qualify reference access
  paths, not the logical referent type. Prefer explicit target observations in
  new compile-time APIs. Implicit observations require context-scoped semantic
  queries and coherent generated-type identities. Native cache and std-bundle
  compatibility must include the target facts they depend on.
5. **Explicit kernels.** Define execution, synchronization, failure, and numeric
  policies before device lowering. Retain parallel domains, workgroup storage,
  and collective participation until scheduling has consumed them. Structured
  kernel regions or explicit convergence information may share SSA machinery;
  do not maintain a second authoritative CFG. CPU barrier execution requires
  cooperating participants or phased/resumable lowering, not serial completion
  of individual work items. Begin with synchronous transfers and host-managed
  allocation; future asynchronous completion must retain resources and enforce
  access obligations, not merely keep owners alive.

Implement the current native foundation first. Additional targets and kernel
representations follow concrete use cases; use an established device backend
where practical rather than requiring a custom GPU allocator and scheduler.
General rewrite DSLs, dialect registries, tensor scheduling, and persisted
per-pass analyses remain deferred until they remove demonstrated complexity.

Preserve wrapping arithmetic, eager effect order, conditional initialization,
ownership hooks, storage identity, and panic behavior at every level. Mutable
references do not imply universal non-aliasing. Floating-point reassociation and
parallel reduction require an explicit language policy. Validate new boundaries
with native/interpreter parity, machine constraint tests, and incremental cache
tests; measure compilation time, memory, and generated execution rather than
using IR size as a performance claim.

Each implementation slice must pass matched compilation and generated-runtime
benchmarks before acceptance. Compare snapshots with the same frontend,
workloads, compiler mode, std configuration, affinity, and worker counts using
the [benchmark protocol](../benchmarks/README.md#measurement-protocol). Preserve
raw samples; investigate noise with matched repeats rather than accepting a
repeatable cold, incremental, or runtime regression in exchange for another gain.

## IR shape

Typing publishes memory form: every local is a `local_storage` slot accessed
through `value_copy`. Typing keeps that form because reference and lifetime
checks are built around storage identity. The optimizer converts to values
after those checks, inside a scratch `Function` that can add blocks, block
parameters, branch arguments, and instructions, and is serialized back with
every side table rebuilt from live users.

- **Memory roles come from operands.** `value_copy` loads, copies, or stores
  depending on whether its operands denote storage, so the instruction is not
  split. Passes classify accesses from the operand that owns the fact.
- **Values and places.** A plain value is immutable: constants, arithmetic,
  comparisons, aggregates, copies without a destination, call results, entry
  parameters, and block parameters of directly passed types. A parameter of an
  indirectly passed type aliases its argument's storage, so it is substituted
  rather than copied when blocks merge, and it is never treated as a snapshot.
- **Aggregates.** `aggregate` builds a struct value from field values. Scalar
  replacement uses it to reassemble a split slot where the whole value is read,
  and `field_access` of an aggregate folds to the field.
- **Comparison values.** `compare` produces a `bool` with the branch predicate's
  operation; `select` chooses between two scalar values. `pbr` remains the
  branch.
- **Bulk memory.** `fill` writes one scalar value to consecutive elements and
  `move` copies consecutive elements, ascending or descending, with exactly the
  element order of the loops they replace.
- **Inline frames.** An optimized body lists the calls it inlined as frames of
  instance, call span, and parent frame; instruction and terminator frames
  parallel the spans. An initializer region moved into another function records
  its owning instance. Codegen turns a frame chain into one trace label per
  call site, so panic traces show inlined callers as separate frames.

Wrapping arithmetic leaves no poison or undefined behavior, which removes a
class of optimizer bugs but also LLVM's `nsw` shortcut. No-overflow facts must
be proven, for example from an exit test that bounds an induction variable.

## Pass structure

Per instance, callees first:

```
prepare:  sroa -> promote -> (joins -> canonicalize)* -> number -> dead -> cleanup
optimize: inline -> prepare passes again -> hoist -> loop idioms -> prepare passes
```

Joins and canonicalization converge together before numbering and dead-value
removal. A later pass changing the facts an earlier pass consumed triggers
another local round; changes already consumed within the round do not. Storage
uses and address exposure removed by dead-code elimination can trigger another
round; deleting only unread scalar computations cannot. Join profiling is
reported separately from CFG cleanup.
Storage passes repeat only when downstream storage uses or control flow changed and
local storage remains. Scalar replacement reaches its own fixed point;
new field types are classified before promotion. Type classification visits only
newly added values. Storage-free bodies skip scalar replacement and promotion;
the absence of live local slots is cached until a new slot is introduced.

Each editable function retains numbering-table capacity across local rounds,
but clears all candidates before each invocation. Aggregate lookup resolves
fields without allocating; only inserted keys own copied fields. Scalar
replacement reuses field-type layouts, including non-struct results, within
the same editable function.

Instruction replacements are normalized at consuming pass boundaries, not both
on producer exit and consumer entry. Canonicalization resolves replacements
before collecting address-taken facts, then normalizes consumers in its existing
fixed-point traversal rather than rescanning the body between rounds.
An editable function reuses normalized
operands and address-taken facts until mutation invalidates them. Replacements,
new values, operand-table edits, and changing passes invalidate operand facts;
control-flow edits invalidate them alongside the graph. Normalization follows
attached instructions and their owned side-table ranges; obsolete argument,
capture, and field entries are inert. These facts are local to the scratch
function and never change query dependencies.

| Pass | Owner | Driven by |
| --- | --- | --- |
| Inline | `inline.zig` | callee cost, recursive components, initializer regions |
| Scalar replacement | `sroa.zig` | struct field types, slot uses |
| Promotion | `promotion.zig` | slot accesses, pruned SSA construction |
| Canonicalize | `canonicalize.zig` | shared operation semantics, algebra table, borrow chains |
| Value numbering | `numbering.zig` | dominance; memory reads within a block |
| Cleanup | `cleanup.zig` | jump threading, block merging, select formation |
| Hoisting | `hoisting.zig` | loop analysis, resource effects |
| Loop idioms | `idioms.zig` | induction variables, exit tests |
| Compaction | `compaction.zig` | liveness from users |

Folding uses the same operation semantics as the interpreter
(`FunctionInstruction.integerResult`, `PredicateOperation.holds`). Algebra is a
table row per operation (commutative, identity, absorbing, negating, self
result), not a function per rule.

### Control Flow Analysis

Each editable function lazily caches reachability, reverse postorder, and incoming
edge locations. Dominators and tree intervals are added on demand; dominance
checks use interval containment. Only promotion requests dominance frontiers.
Value rewrites, parameter edits, and instruction motion preserve this analysis.
Adding blocks, folding edges, and CFG cleanup invalidate it before its next use.
Incoming edges identify their source block and ordinal rather than retaining
pointers into the mutable block array.

### Inlining

A callee is inlined when its optimized body costs at most `InlineLimit`
instructions and blocks (48 unless the input is set), it is not in a recursive
call component, and it has a typed body that compiles natively. `CallComponent`
finds strongly connected components of the prepared call graph; it is computed
only when the query engine reports a cycle, so acyclic programs pay one cheap
query per instance. Optimizing a caller demands its callees' optimized bodies,
never a member of its own component, so the queries stay acyclic.
With parallel workers, component discovery schedules sibling `DirectCallees`
dependencies ahead of traversal so their body analysis and local preparation can
overlap. Component queries remain demand-driven to preserve cycle handling.
When an argument is an aggregate passed directly by value, primitive constants
cost zero because its fields expose scalar-replacement opportunities and codegen uses immediates. Other
calls retain the ordinary instruction cost. The caller's growth budget still
counts every inserted instruction, including constants. This exposes small
aggregate factories without speculative specialization or standard-library identities.

Within an inline pass, repeated calls reuse callee resolution and per-body
eligibility and entry-address facts. `InlineFunctionFacts` shares immutable
callee analysis between callers and depends on `OptimizeFunctionInstance`, so
callee changes invalidate it normally. Initializer-region facts stay local to
the inline pass.

Std precompilation retains prepared bodies, call components, and optimized
bodies alongside typed bodies and native code. The lazy bundle supplies these
query results directly, including callee bodies needed for inlining. Its
optimized bodies and native code require the same inline limit as the producer;
prepared bodies and call components are independent of that policy. New generic
specializations still follow the ordinary query path.

Arguments become block parameters of the inlined entry, except read-only plain
values, storage, and initializer arguments, which are substituted. Returns
branch to the continuation, writing into the call destination when there is
one. All calls use ordinary results, including explicit variants. A call
to an initializer region whose `initializer_ref` is visible inlines the region,
with its capture writes as stores into the captured places.

### Memory

Resource effects classify every access by root: addressable value storage, parameter
storage, allocation contents, an immutable value, or unknown. Distinct slots
never alias, allocation contents never alias a stack slot, and a slot whose
address never leaves direct access cannot be written through a reference.
Root classification is separate from exposure analysis: numbering needs only
roots and address-taken facts, while hoisting also computes exposed roots.
Address-taken instruction results and block parameters are mutable roots too;
being produced by a plain-value instruction does not make their storage immutable.
Hoisting moves invariant pure instructions and reads whose resource no loop
instruction may write; a read that could fault moves only from the header.

Value numbering stores the first dominance candidate inline with each expression
key. Additional candidates share one overflow buffer, preserving candidate order
without allocating a separate list for every scalar or aggregate expression.

Scalar replacement splits struct slots whose uses are field projections, field
reads, whole stores, and whole reads; promotion then turns slots of scalar or
directly passed types into SSA values with block parameters at merges.
Single-block slots use an indexed local fast path. Other slots share block
bitsets and backward liveness propagation, then rename together in one
dominator-tree traversal with sparse save/restore state.
Promotion collects eligibility counts and indexed use sites in one traversal;
counts live per candidate slot rather than in separate value-sized arrays.

Canonicalization folds reconstruction from a value's original fields back to
that value. Cleanup removes merge parameters whose incoming values agree,
including unchanged loop backedges. An addressable snapshot can participate
only when its address remains private and no instruction writes its storage;
changing allocation contents does not change the descriptor snapshot.
Variant merges whose incoming edges all inject the same alternative carry its
payload directly and reconstruct the variant only for remaining consumers.
Field reads through immutable struct merges preserve common values and primitive
constants, including invariant fields of otherwise changing loop state.
Mixed variant merges used only by tag reads and primitive payload extraction
carry their tag and scalar payloads independently. Inactive scalar payloads use
valid zero values; aggregate and reference payloads retain their ordinary
representation. Ownership operations and addressable projections prevent this
rewrite, so it introduces no fabricated owning values or references.
Scalar-variant use facts are indexed once per join pass. Redundant parameters
are removed together so each incoming argument list is rebuilt once per block.
Scalar-variant consumer replacements share one body traversal and normalization.
Join rewrites share conservative address-taking facts; newly created parameters
and scalar instructions cannot introduce address exposure.

An incoming edge with a known predicate can bypass an empty join directly to a
terminal exit when that exit uses none of the join parameters. This removes
exhausted iterator paths without inventing payload values or skipping cleanup.

### Loops

Loops come from back edges in the dominator tree and are canonicalized with a
dedicated preheader and a single latch. Induction variables are header
parameters stepped by a constant. The idioms are:

- removal of a loop with no effects whose exit test compares a ±1 induction
  variable for equality, which always terminates under wrapping arithmetic;
- removal of `i >= c` and `i < n` checks dominated by an exit test `i >= n`
  when `i` starts at a constant at least `c` and steps by one;
- `fill` and descending `move` for element loops, guarded by
  `0 <= start <= end` so the original loop still runs when indices would wrap.

Preheaders forward a common immutable incoming value directly rather than
introducing a redundant parameter that would hide an induction start constant.

### Backend

Functions with allocatable scalar values lower to the query-local x86 instruction
stream in `src/backend/machine.zig` before allocation or byte encoding. Fixed-only
functions stream operations directly to encoding, avoiding a buffered stage with
no allocation work. The buffered stream contains
fixed-register operations, virtual scalar reads and writes, symbolic branches,
labels, preservation operations, and explicit scratch-dead boundaries. Constants
remain immediates; scalar computation initially uses `eax`, with fixed scratch
registers for division, addressing, calls, and bulk copies. These registers are
outside the six preserved registers available to virtual values. External
runtime helpers retain the same direct encoding path and calling convention.
Local targets are nonzero positions after labels; zero represents no local
target, keeping fixed operands compact without optional-target padding.

In functions containing loops, eligible integer and boolean values become
virtual registers with stack spill homes. Addressed values, incoming parameters,
and initializer environments retain storage. The weighted live-range allocator
derives its CFG and eligible-value liveness from the expanded machine stream,
including division branches and the actual edge-copy reads and writes. This CFG
is a temporary analysis, not a second authoritative graph. Separate definitions
retain separate live ranges rather than extending one interval across dead gaps.
Operand reads precede definitions, allowing last-use reuse. Frames currently reserve preservation
capacity for all six registers before allocation; emitted saves and restores
include only registers actually used.

After allocation, arithmetic updates a register directly when it can reuse a
legal operand location and scratch results are dead; subtraction only reuses its
left operand. Label boundaries prevent such combining across jump targets.
Encoding retains compact immediates and store-to-load forwarding. Scalar edge
copies bypass scratch storage when forward or reverse order preserves every
virtual source. Cycles and unsupported copy shapes stage every source before
writing destinations; machine liveness prevents allocation from introducing new
copy hazards. Coalesced register copies disappear only where scratch results are
dead.

Encoding resolves symbolic branch targets and maps relocation fields, call return
positions, and initializer references to byte offsets. Outlined initializer
artifacts are appended only after their parent's encoding. Artifacts retain the
existing owned code and metadata format; the machine stream is not published,
cached, or interpreted. Its owning boundary asserts virtual-value ranges and
relative-target labels; encoding reports displacement and function-size limits.
The encoder reuses its selected encoding for operand offsets and byte emission,
and collects branch patches during emission instead of rescanning every
instruction afterwards.
Comparisons produce canonical boolean values;
scalar selections use conditional moves. Fills use `rep stosb` or `rep stosd`,
and directed copies use `rep movsb`, clearing the direction flag after a
descending copy. Aggregate construction copies each field to its layout offset.

## IR facts passes rely on

- Calls are instructions with ordinary results or explicit destinations. Every
  control-flow edge is a branch with explicit argument payloads; there are no
  hidden call-result edges.
- Values are immutable except through addresses. A value is address-taken when
  any use is not a known read. Promotion excludes address-taken values; snapshot
  reconstruction and redundant-parameter elimination additionally prove private,
  unwritten storage before aliasing an addressable value.
- Typed bodies may keep unreferenced side-table entries; passes visit
  references through users, never by scanning tables.
- A slot read before any store on a path is unreachable by typing's definite
  initialization; promotion supplies a typed zero there for scalars and keeps
  other slots in memory.

## Verification

- `Fixture.expectParity` compares optimized native execution against the
  interpreter, which runs the typed body, so every parity test covers the
  optimizer.
- Safe builds verify value references and branch argument counts in the
  scratch function after every pass, and the published body afterwards.
- Incremental tests check that optimized bodies recompute when their own typed
  body or an inlined callee changes, and not when an out-of-line callee does.
- `InlineLimit` set to zero keeps calls out of line for tests about call
  structure and native artifact reuse.
- Machine tests cover symbolic byte offsets with register and spilled operands,
  scratch-dead combining boundaries, expanded-branch register pressure, and
  signed division inside loops. Existing execution tests cover edge-copy cycles,
  calls, initializer regions, relocations, and panic provenance.

The 2026-10-26 machine-stage run of `zig build test --seed=0 -Doptimize=safe -j1`
completed all 50 build steps: 2,112 tests passed and 24 skipped, without
allocation-failure sweeps. Formatting checks and `git diff --check` also passed.

## Measurements

The 2026-10-26 machine-boundary comparison used frozen identical frontend and std
sources with only backend changes between snapshots. ReleaseFast measurements
used the adaptive [benchmark protocol](../benchmarks/README.md#measurement-protocol):
one warm-up, at least two measured runs, and caps of three compilation or five
runtime samples. A full sample range within 2% of the median is marked stable;
capped noisy results remain explicitly
unstable. Compilation phases stop independently, and extra leaf edits use fresh
leaf values rather than cycling through cached bodies. These changed incremental
sequences retain a separate compilation identity from the fixed-count results.

Full-scale cycle profiles identified added machine-stage work rather than a
generated-runtime slowdown. Before the final encoding changes, the new
allocation/encoding function accounted for 1.89% of candidate cycles and
instruction appends another 0.32%; the old combined location/register planning
path accounted for 0.87% of baseline cycles, versus 0.39% for new location
planning. These are different scopes, not additive wall-time estimates. Source
attribution exposed repeated instruction scans, repeated encoding selection,
and fixed-instruction encoding. Compact target metadata, reuse of selected
encodings, and a branch-only patch list remove avoidable work. The stage still
performs allocation and encoding; an IR boundary is not intrinsically free.

Uninstrumented acceptance runs used CPU 4 for serial compilation and runtime,
and CPUs 4-11 for eight workers, without concurrent builds. Both baseline-first
and candidate-first orders were measured. All generated exit statuses and sieve
outputs were checked. Changes below compare candidate medians with baseline
medians in the same order:

| Measurement | Baseline First | Candidate First |
| --- | ---: | ---: |
| Million-line cold, zero workers | -7.11% | +0.77% |
| Million-line leaf edit, zero workers | +3.75% | -2.50% |
| Million-line cold, eight workers | -0.31% | -0.12% |
| Million-line leaf edit, eight workers | -3.42% | +1.82% |
| Sieve runtime | +0.80% | -2.05% |

No repeatable end-to-end regression was detected in these checks. Leaf-edit and
baseline-runtime samples often reached their caps and remained unstable; sign
changes across order reversals do not establish a speedup or exact equality.
The observed timing uncertainty remains a few percent. The million-line
executable grew from 133,702,505 to 134,113,669 bytes; the sieve executable shrank
from 19,155 to 19,102 bytes. Code size is not a runtime benchmark. Raw forward,
reverse, and profiled samples and source hashes were preserved separately.

## Remaining Work

- Reduce machine-stage analysis and encoding cost where profiles justify it.
  Register classes, frame compaction, scheduling, and additional targets remain
  follow-up work, not part of this first boundary.
- Recover compilation throughput without reducing optimization, and investigate
  the leaf-edit regression with matched profiles. Join simplification, repeated
  operand facts, and executable publication remain candidates, not proven fixes.
- Reduce the remaining C gap with general bounds proofs, allocation-base reuse,
  instruction selection, or vectorization. C vectorizes final counting and uses
  a tighter marking loop; Chimera still counts scalarly and retains bounds checks.
  Preserve wrapping arithmetic and panic behavior; do not special-case the sieve
  or weaken its checks.
