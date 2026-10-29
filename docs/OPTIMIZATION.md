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
Allocation-element operations inside loops first snapshot storage-based
descriptors with `value_copy`. This makes the descriptor read independent of
the varying element index. Ordinary alias and write analysis governs movement,
and descriptor replacement keeps the read inside the loop. Codegen can retain
the backing address from an immutable snapshot in a register.

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
parameters stepped by a constant. `loops.zig` owns their read-only analysis;
`idioms.zig` owns transformations. The analysis indexes instruction ownership
once per unchanged CFG and shares immutable-value, counter, normalized-exit,
and range facts across existing rewrites. Functions without loops skip it.

Counter matching does not imply monotonicity or termination. An iteration-range
query separately proves that the latch update cannot wrap, including the final
update. Dead-loop removal separately requires an acyclic iteration body before
using a wrapping equality counter to prove termination. A nested loop that may
not finish must not disappear with its containing loop. Address-taken values
cannot supply immutable counter, constant, or range facts.

The rewrite driver invalidates control-flow and operand facts after every
successful transformation and restarts analysis before trying another rule.
Rules retain their own effect, escape, and shape requirements; there is no
persistent analysis cache, extra IR, or generic rewrite framework. The idioms are:

- removal of a loop with no effects whose exit test compares a ±1 induction
  variable for equality, which always terminates under wrapping arithmetic;
- removal of proven integer comparisons in a loop body using constant or
  guarded dynamic starts, nonzero constant strides, and an invariant exit bound.
  Ascending and descending loops support strict or inclusive limits and reversed
  operands. Each proof bounds the latch update in widened arithmetic before
  assuming monotonicity; wrapping counterexamples retain their checks;
- `fill` and descending `move` for element loops, guarded by
  `0 <= start <= end` so the original loop still runs when indices would wrap.

Preheaders forward a common immutable incoming value directly rather than
introducing a redundant parameter that would hide an induction start constant.
Entry ranges intersect constant-bound predicates on dominating branches, using
only a single-predecessor successor that dominates the preheader. Guards on just
one path through a join do not establish a range. Body comparisons use both the
counter's numeric interval and its relation to the same invariant exit limit.
These are local proofs, not a general range solver: no runtime guards, unchecked
fallbacks, pointer induction, or vectorization are introduced.

### Backend

Functions with allocatable scalar values lower to the query-local x86 instruction
stream in `src/backend/machine.zig` before allocation or byte encoding. Fixed-only
functions stream operations directly to encoding, avoiding a buffered stage with
no allocation work. The buffered stream contains
fixed-register operations, virtual scalar reads and writes, parameter definitions,
symbolic branches, labels, preservation operations, and explicit scratch-dead boundaries. Constants
remain immediates; scalar computation initially uses `eax`, with fixed scratch
registers for division, addressing, calls, and bulk copies. Virtual values can use
four caller-saved registers (`r8`-`r11`) and six preserved registers
(`rbx`, `rbp`, `r12`-`r15`). Fixed operands reserve conflicting registers, and
direct and indirect calls exclude caller-saved registers from crossing live ranges. External
runtime helpers retain the same direct encoding path and calling convention.
Local targets are nonzero positions after labels; zero represents no local
target, keeping fixed operands compact without optional-target padding.

Eligible integer and boolean locals become virtual registers with stack spill
homes under the existing backward-positioned-edge gate. Repeated, unaddressed
by-value scalar parameters are candidates independently of that gate. They retain
their incoming ABI slots as spill homes; an unallocated parameter emits no entry
load. Temporaries allocate first, then parameters cache only in spare caller-saved
registers, avoiding temporary spills and additional preservation work. Addressed
values and initializer environments retain storage. The weighted live-range allocator
derives its CFG and eligible-value liveness from the expanded machine stream,
including division branches and the actual edge-copy reads and writes. This CFG
is a temporary analysis, not a second authoritative graph. Separate definitions
retain separate live ranges rather than extending one interval across dead gaps.
Operand reads precede definitions, allowing last-use reuse. Disjoint definitions
can reuse caller-saved registers on either side of calls; there is no general
call-site live-range splitting or spill/reload insertion. Frames currently reserve
preservation capacity for all six preserved registers before allocation; emitted
saves and restores include only preserved registers actually used.

After allocation, arithmetic updates a register directly when it can reuse a
legal operand location and scratch results are dead; subtraction only reuses its
left operand. Register and stack operands use direct two-operand instructions,
avoiding intermediate copies through `eax`; fixed and spilled stack operands retain compact
displacements. Label boundaries prevent such combining across jump targets.
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
scalar selections use conditional moves. A comparison and a one-unit integer
increment feeding a select can emit a boolean addition when both intermediate
results are used only by that select. Both adjacent instruction orders are
recognized, with comparison dependencies and wrapping arithmetic preserved.
Fills use `rep stosb` or `rep stosd`,
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
  scratch-dead combining boundaries, call clobbers, fixed-register conflicts,
  parameter-cache pressure and load omission, expanded-branch register pressure, and
  signed division inside loops. Existing execution tests cover edge-copy cycles,
  calls, initializer regions, relocations, and panic provenance.

The 2026-10-29 parameter-residency run of `zig build test --seed=0 -Doptimize=safe -j1`
completed all 52 build steps: 2,101 tests passed and 19 skipped, without
allocation-failure sweeps. The codegen suite was cached after a focused run with
54 passing tests and five skips. Formatting checks and `git diff --check` also passed.

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

### Worker Affinity

The history point for `1c79b6c2568c` originally restricted both compilation
lanes to CPU 4: `--cpu 4` applies to every worker, not just the serial lane.
Cold compilation measured 34.776 s with zero workers and 41.378 s with eight
workers sharing that one CPU. It measures oversubscription, not multicore
scaling, and cannot be compared directly with preceding eight-worker points
whose affinity was CPUs 4-11.

Remeasuring the same committed source and benchmark suite on CPUs 4-11 produced
32.680 s serial and 24.940 s with eight workers; both cold measurements met
the 2% range criterion after two samples. Leaf edits were 341 ms and 453 ms
respectively, both unstable at the three-sample cap. Correcting affinity
restores the cold worker advantage, not a universal benefit for incremental
work. The report uses the new point and retains the original raw record.
The recorder warns about oversubscription without silently changing affinity
or dropping samples.

A separate control rebuilt an exact archive of the preceding `625baee` with
the same current driver and CPUs 4-11, measuring only its eight-worker lane.
It produced 25.638 s cold and 475 ms leaf edit, each stable after two samples;
its older recorded cold median was 19.650 s. The old compiler also slows under
current conditions, and these checks do not reproduce a new eight-worker
source regression. The latest commit's 24.940 s versus the control's 25.638 s
is a single-order comparison, not an established compiler speedup.

### Sieve Runtime Attribution

The 2026-10-26 attribution used the final 19,102-byte native sieve, with all four
backend source hashes matching the workspace, and GCC 16.2.1 `-O3` on the same
C workload. CPU-4-pinned runs used one warm-up and adaptive sampling. Diagnostic
copies replaced only selected native loop instructions, leaving allocation,
input, output, and the rest of the executable unchanged. Every copy passed 15
probes, including SIMD tails and the full 88-million bound. These are causal
experiments, not implemented compiler optimizations or general semantic proofs.

| Same-Binary Experiment | Median | Saved Versus Native | Share of Measured Gap |
| --- | ---: | ---: | ---: |
| Unchanged Chimera | 1.694 s | - | - |
| Unchanged C `-O3` | 1.347 s | - | - |
| Compact scalar count only | 1.446 s | 247 ms | 71% |
| SIMD count only | 1.429 s | 264 ms | 76% |
| Compact marking, checks retained | 1.593 s | 100 ms | 29% |
| SIMD count and compact checked marking | 1.358 s | 336 ms | 97% |

All rows in this comparison reached the stability criterion after two measured
runs, with measured order reversed between rounds. The baseline gap was 347 ms,
or 25.8% relative to C. The combined experiment finished 0.8% behind C, within
the observed timing uncertainty. Isolated savings overlap and must not be added
as independent contributions. Separate earlier wall timings were faster for
both programs; compare values within a matched batch, not across batches.

- **Counting is the main avoidable loss, not simply missing SIMD.** Chimera
  executes 58 instructions per element, retaining range-exhaustion state,
  conditional selects, bounds checks, array-base reloads, an address temporary,
  and register moves. A compact scalar count needs five instructions per
  element. Its replacement alone removes about 4.66 billion retired
  instructions. SIMD adds only another 17 ms in the matched native experiment;
  it does not explain the bulk of the count-loop gap.
- **Marking has unnecessary scalar work.** The hot loop executes 20 instructions
  per store versus C's four. It reloads the invariant array base, stores and
  reloads the element address, and shuttles values through scratch registers.
  Keeping the base in a register and using a direct indexed store reduces the
  loop to ten instructions while retaining both index bounds checks. This
  removes about 2.13 billion retired instructions and saves 100 ms in isolation.
- **Bounds-check removal is not a demonstrated prerequisite for parity.** The
  combined experiment above retains marking checks. An unchecked marking
  counterfactual saves another 22 ms, too small relative to timing uncertainty
  to assign a precise contribution. It is not safe as a compiler transform
  without a non-wrapping proof or guarded fallback.

Cycle samples put about 82% of native execution in marking and 18% in counting;
the hottest phase is not necessarily the largest avoidable difference from C.
Hardware counters recorded about 9.36 billion retired instructions for native
versus 1.00 billion for C, with fewer than 13,000 branch misses in either.
Allocation, zeroing, cleanup, and the algorithm were unchanged in the ablations,
so they do not explain the recovered 97% of the gap. Breakpoint-based phase
timings were unstable and are not used for the attribution percentages.

Raw samples, profiles, source hashes, phase probes, and assembly ablations are
preserved under `/tmp/chimera-sieve-attribution-20261026`. No production compiler
code changed during this investigation.

### Checked Scalar Loop Simplification

The production follow-up rotates a loop-carried exhaustion flag into a latch
test. The original header remains the initial guard and final-value merge, so
empty ranges and observed final iterator values retain their meaning. The
rewrite requires one latch, an empty header, a dominating body, and immutable
primitive carried values and select operands. It does not prove non-wrapping
induction or remove checks.

Native lowering fuses adjacent single-use compare/add-one/select sequences into
boolean addition, preserving integer wrapping. Single-use allocation-element
addresses fuse with adjacent scalar copies instead of passing through pointer
stack slots. Immutable allocation bases can use 64-bit virtual register operands
while whole descriptors retain their original storage. Constant integer stores
use a direct indexed address when the base has a register and scratch `rax` is
dead; spilled bases retain the ordinary address sequence. Both negative-index
and upper-bound marking checks remain.

An interleaved CPU-4 comparison of the final generated sieve measured 1.493 s
before these changes, 1.219 s after them, and 1.157 s for GCC `-O3`. The candidate
was stable after two measured runs; the baseline and C reached five samples
without stability. This supports a substantial scalar improvement, not a precise
remaining-gap estimate or a claim of C parity. All three executables passed
14 small-input probes and the 88-million workload. The native executable shrank
from 19,102 to 19,004 bytes. Frozen sources, hashes, executable copies, and raw
samples are under `/tmp/chimera-scalar-loops-20261026`.

### Scalar Arithmetic Selection

The 2026-10-29 comparison retained baseline and candidate ReleaseFast binaries
with identical frontend sources on an Intel Core Ultra 7 265K, using Zig 0.17.
Two out-of-line kernels each made 120 million calls. C used GCC `-O3 -fwrapv`
and `noinline` to retain wrapping arithmetic and the call boundary. Every output
matched. CPU-4 measurements used one warm-up, alternating order, and adaptive
sampling; all rows met the 2% range criterion after two samples.

| Kernel | Baseline | Direct Register/Stack Arithmetic | C | Change |
| --- | ---: | ---: | ---: | ---: |
| Scalar arithmetic | 0.672 s | 0.637 s | 0.591 s | -5.2% |
| Eight-parameter arithmetic | 0.820 s | 0.742 s | 0.678 s | -9.5% |

These are kernel results, not a general application speedup. Removing the
location planner's backward-edge gate produced byte-identical executables for
both kernels and was discarded; block numbering is not topological, so that
gate does not exclude every loop-free body. Direct register arithmetic alone
regressed the parameter kernel; selecting stack operands directly was also
necessary. Inputs, assembly, retained binaries, and raw samples are preserved
under `.history/backend-arithmetic-20261029/`.

Full-size acceptance used the existing million-line cold/leaf-edit and sieve
workloads, with serial compilation and runtime on CPU 4 and eight workers on
CPUs 4-11. Each retained binary used its ordinary bundled std and the adaptive
benchmark protocol. The initial eight-worker cold comparison suggested a 3%
slowdown, so that lane was repeated in the opposite order:

| Measurement | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Serial cold | 20.027 s | 19.964 s | -0.3% |
| Serial leaf edit | 148.9 ms | 146.4 ms | -1.7% |
| Eight-worker cold, candidate first | 11.877 s | 12.234 s | +3.0% |
| Eight-worker leaf edit, candidate first | 173.6 ms | 178.5 ms | +2.8% |
| Eight-worker cold, baseline first | 12.636 s | 12.098 s | -4.3% |
| Eight-worker leaf edit, baseline first | 182.6 ms | 182.2 ms | -0.2% |
| Sieve runtime | 0.622 s | 0.623 s | +0.01% |

The serial baseline, both initial parallel leaf-edit results, and the reversed
parallel baseline reached the compilation sample cap without stability.
The sign reversal does not establish a compilation speedup or a repeatable
regression. Sieve samples were stable after two runs; its C `-O3` reference was
0.575 s. All generated outputs and statuses passed. These checks support no
detected repeatable end-to-end regression, not exact performance equivalence.

### Parameter Residency and Call Constraints

The next 2026-10-29 comparison keeps the arithmetic-selection implementation as
its baseline. Retained ReleaseFast binaries have identical frontend and std
sources, including a concurrent frontend change rebuilt into the baseline.
The same CPU-4 kernels, wrapping C reference, output checks, warm-up, alternating
order, and adaptive sampling produced:

| Kernel | Baseline | Candidate | C | Change |
| --- | ---: | ---: | ---: | ---: |
| Scalar arithmetic | 0.637 s | 0.621 s | 0.590 s | -2.5% |
| Eight-parameter arithmetic | 0.749 s | 0.739 s | 0.679 s | -1.3% |

All three implementations met the 2% range criterion after two samples in each
kernel. These small isolated gains do not establish an application-wide speedup.
The candidate combines optional parameter caching, four additional registers with
call constraints, and direct arithmetic on spilled virtual operands.

Eager parameter allocation was rejected: long-lived parameters displaced
temporaries and more than doubled the parameter kernel's runtime. A live-range
density heuristic also regressed. The accepted policy allocates temporaries
first and caches parameters only in remaining caller-saved registers, retaining
the incoming ABI home otherwise. This also avoids extra callee-save traffic.

Full-size acceptance used the same million-line and sieve workloads and affinity
as the arithmetic-selection comparison. The initial eight-worker run suggested a
slowdown, so that lane was repeated in reverse order:

| Measurement | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Serial cold | 19.965 s | 19.767 s | -1.0% |
| Serial leaf edit | 150.0 ms | 149.4 ms | -0.4% |
| Eight-worker cold, candidate first | 11.878 s | 12.434 s | +4.7% |
| Eight-worker leaf edit, candidate first | 180.6 ms | 194.2 ms | +7.6% |
| Eight-worker cold, baseline first | 12.107 s | 12.006 s | -0.8% |
| Eight-worker leaf edit, baseline first | 184.4 ms | 173.8 ms | -5.8% |
| Sieve runtime | 0.625 s | 0.623 s | -0.3% |

The serial baseline leaf edits, initial parallel candidate cold samples, both
initial parallel leaf-edit results, and reversed candidate leaf edits remained
unstable at their sample caps. The sign reversal does not establish a compilation
speedup or a repeatable regression. Sieve was stable after two samples; its C
`-O3` reference was 0.579 s. All outputs and statuses passed. The million-line
executable shrank from 121,025,902 to 119,544,702 bytes. Retained binaries, source
patches and hashes, inputs, assembly, and raw samples are preserved under
`.history/backend-parameters-20261029/`.

### Guarded Loop Ranges

The next 2026-10-29 comparison keeps the parameter-residency compiler as its
baseline, with only `src/optimizer/idioms.zig` changed among production sources.
A runtime-input kernel performs sixteen scans with varied dynamic starts and a
stride of three. An entry guard bounds the limit, making the latch update safe;
the baseline retains redundant lower- and upper-bound tests inside the loop.
The candidate removes both tests while retaining the entry guards and exit test.

CPU-4 runs used retained ReleaseFast compilers, one warm-up, alternating order,
and adaptive sampling. Matched C used GCC `-O3 -fwrapv`; every output agreed.
All three implementations met the 2% range criterion after two samples:

| Workload | Baseline | Candidate | C | Change |
| --- | ---: | ---: | ---: | ---: |
| Guarded stride-three scans | 1.469 s | 0.933 s | 0.240 s | -36.5% |

This is an isolated check-heavy kernel result, not a general application speedup
or C parity. Earlier short runs were noisy and remain separate raw samples.

Full-size acceptance used the same million-line and sieve workloads and affinity
as the preceding comparisons:

| Measurement | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Serial cold | 19.892 s | 19.659 s | -1.2% |
| Serial leaf edit | 141.0 ms | 140.2 ms | -0.6% |
| Eight-worker cold, candidate first | 11.887 s | 11.883 s | -0.03% |
| Eight-worker leaf edit, candidate first | 172.0 ms | 182.1 ms | +5.8% |
| Eight-worker cold, baseline first | 12.288 s | 11.961 s | -2.7% |
| Eight-worker leaf edit, baseline first | 181.5 ms | 169.5 ms | -6.6% |
| Sieve runtime, baseline first | 0.620 s | 0.629 s | +1.4% |
| Sieve runtime, candidate first | 0.630 s | 0.623 s | -1.2% |

The initial parallel baseline leaf edits, reversed parallel baseline cold runs,
and reversed candidate leaf edits remained unstable. The leaf-edit and sieve
sign reversals do not establish a general speedup or a repeatable regression.
Both snapshots emitted 119,544,702-byte compilation workloads and 18,699-byte
sieves. Raw samples, inputs, assembly, retained binaries, and source snapshots
are preserved under `.history/backend-loop-ranges-20261029/`.

### Shared Loop Analysis

The following 2026-10-29 comparison consolidates loop facts rather than adding
an optimization. Dead-loop removal, fill/move, and check elimination consume
shared counter and exit matching; range construction no longer belongs to the
check-elimination rewrite. Regression tests cover nested rewrite composition,
proof invalidation after source edits, signed boundaries, and preservation of
potentially nonterminating inner loops.

Retained ReleaseFast compilers have identical frontend and std sources. The
million-line workload used the ordinary adaptive protocol, CPU 4 for serial
compilation and CPUs 4-11 for eight workers, with both run orders:

| Measurement | Baseline First | Candidate First |
| --- | ---: | ---: |
| Serial cold | -0.08% | -0.44% |
| Serial leaf edit | +0.81% | -1.42% |
| Eight-worker cold | -2.96% | +2.00% |
| Eight-worker leaf edit | -6.19% | +2.01% |

Cold samples met the stability criterion in both orders. Initial serial baseline
leaf edits and reversed parallel candidate leaf edits reached their caps without
stability. No repeatable compilation regression was detected; the parallel sign
reversals do not establish a speedup or exact performance equivalence.
Executable sizes were unchanged. The loop-range kernel was byte-identical;
paired sieve medians were 0.634 s baseline and 0.637 s candidate. Raw measurements,
retained compilers, and source snapshots are preserved under
`.history/loop-analysis-20261029/`; intermediate probes are labelled separately.

### Assembly Dump Scope

The earlier Chimera dump treated its flat ELF as raw x86 bytes, including
read-only strings after the code. Those apparent instructions are not executed
code. It also includes the entry point, allocator, syscall I/O, panic handling,
cleanup, and source-trace data. The C dump showed only `main`; dynamically linked
libc implementations were absent. Dump line counts therefore compare different
things and exaggerate the native code-size difference. Compare function-scoped
code and account for runtime/linkage separately. Redundant loop instructions
and aggregate copies are real remaining costs, distinct from that dump artifact.

## Remaining Work

- Frontend compilation time is the immediate engineering priority, ahead of the
  runtime and machine-stage work below. Follow the attribution and acceptance
  order in the [roadmap](../ROADMAP.md#immediate-engineering-priority); keep
  optimizer and backend changes separate from frontend comparisons.
- Close the remaining C runtime-performance gap through stronger loop bounds
  proofs, register allocation, and machine copy/address selection. Carried
  exhaustion state, adjacent conditional increments, and single-use element
  address temporaries now have scalar simplifications. SIMD counting remains
  an additional opportunity. General
  bounds proofs or guarded fast paths remain useful, but unchecked marking is
  not required by the measured near-parity experiment. Preserve wrapping
  arithmetic and panic behavior; do not special-case the sieve or weaken checks.
- Reduce machine-stage analysis and encoding cost where profiles justify it.
  Call-site live-range splitting, frame compaction, scheduling, and additional targets remain
  follow-up work, not part of this first boundary. Compilation throughput and
  leaf-edit times remain non-regression checks, not outstanding regressions.
