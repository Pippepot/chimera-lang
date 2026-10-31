# Optimizer

[ARCHITECTURE.md](ARCHITECTURE.md) owns stage boundaries,
[COMPILER.md](COMPILER.md#verify) owns verification commands, and
[ROADMAP.md](../ROADMAP.md) owns future priorities. This guide describes the
current runtime IR, transformations, and native machine stage.

## Boundary

`PrepareFunctionInstance` runs local passes on a typed body. Its surviving direct
calls form `DirectCallees`; statically dead calls do not enter the graph.
`OptimizeFunctionInstance` inlines prepared callees, repeats local passes, and
runs loop transformations. Only codegen consumes the optimized body.

Interpretation, reference contracts, signatures, and diagnostics consume typed
bodies. Optimization cannot change compile-time execution or source diagnostics.
Every inlined callee passes `ValidateRuntimeFunction`, so inlining cannot conceal
a runtime-type diagnostic.

Passes consume IR facts, never source syntax, typing state, `CallBehavior`, or
standard-library names. Unknown address uses count as address-taking; unknown
instructions are not removed, moved, or numbered. Preserve typed numeric widths,
overflow and conversion policies, eager effects, conditional initialization,
ownership hooks, storage identity, and panic behavior. Shift counts outside the
operand width remain executed errors, even when their result is unused. Mutable
references do not imply universal non-aliasing.

## IR and Local Passes

Typing publishes memory form: locals use `local_storage` slots accessed through
`value_copy`, preserving the identity needed by reference and lifetime checks.
The optimizer edits a scratch `Function`, then rebuilds all published side tables
from live users. Memory roles come from operands rather than separate load/store
instruction tags. Unreferenced side-table entries are inert.

Plain values are immutable. Indirectly passed parameters alias argument storage,
so block merging substitutes them rather than treating them as snapshots.
Logical type, addressability, move capability, and argument passing remain
independent. Addressable values require private, unwritten storage before a
rewrite can alias them as immutable snapshots.

`numeric_binary` and `numeric_unary` retain concrete types and overflow modes;
`numeric_convert` retains a destination type and policy independently of its
optional result representation. Trapping arithmetic remains live when discarded
and cannot be speculatively hoisted. Native 32-bit arithmetic uses
32-bit operand bits and immediate/register/memory operands directly; checked
add/subtract and signed multiply retain native overflow-flag traps. Division and
narrow saturation widen operands only when their lowering algorithm needs it.
Floating-point identities must preserve NaN, infinity, subnormals, and signed zero.
Compiler-internal i32 address/count operations retain their established modular
semantics. Canonicalization lowers
i32 comparisons to ordinary predicates and arithmetic to those modular operations
only under wrapping or a proof that overflow is impossible. Bounds describe
successful results; the potentially trapping producer remains live.

`aggregate` constructs fields, `compare` produces bool, `select` chooses a scalar,
and `pbr` branches. `fill` and directed `move` preserve the element order of the
loops they replace. Calls have ordinary results or explicit destinations, and
every control-flow edge carries explicit branch arguments.

```text
prepare:  sroa -> promote -> (joins -> canonicalize)* -> number -> dead -> cleanup
optimize: inline -> prepare passes again -> hoist -> loop idioms -> prepare passes
```

| Pass | Owner | Main Facts |
| --- | --- | --- |
| Inlining | `inline.zig` | Callee cost, recursion, initializer regions |
| Scalar replacement | `sroa.zig` | Field types, slot uses |
| Promotion | `promotion.zig` | Eligibility, pruned SSA, dominance frontiers |
| Canonicalization | `canonicalize.zig` | Operation semantics, algebra, borrow chains |
| Value numbering | `numbering.zig` | Dominance, local memory reads |
| Cleanup | `cleanup.zig` | Jump threading, block merging, selects |
| Hoisting | `hoisting.zig` | Loops, resource reads and writes |
| Loop idioms | `idioms.zig` | Counters, exits, proven ranges |
| Compaction | `compaction.zig` | Liveness from users |

Canonicalization expands signed division by a constant power of two into a
sign-dependent bias, wrapping addition, and arithmetic right shift, followed by
negation for a negative divisor. The bias preserves truncation toward zero,
including the minimum integer divisor. Mutable/address-exposed inputs retain
ordinary division. Local rules share a pure scalar emitter that inherits the
matched instruction's span and inline frame. The canonicalizer rebuilds only
expanded block instruction lists, once in execution order. Existing address and
memory facts stay conservative because emitted scalar values are private and
introduce no writes or address exposure.

Joins and canonicalization converge together. Repeat an earlier phase only when
a later mutation changes facts it consumed. Removed storage uses or address
exposure can require another round; deleting unread scalar computations cannot.
Dead parameters invalidate storage passes only when their incoming arguments
change surviving uses or eligibility. Numbering visits dominating definitions
before uses, so its substitutions need no extra numbering/liveness round.

Storage-free bodies skip scalar replacement and promotion. Type classification
visits newly added values. Numbering reuses table capacity, not candidates;
aggregate lookup allocates only for inserted owned keys. Normalize replacements
at consuming boundaries rather than on both producer exit and consumer entry.
Cached normalized operands and address-use facts remain local to the editable
function and invalidate on relevant operand, value, replacement, or CFG mutation.

Reachability, reverse postorder, incoming edges, dominators, and tree intervals
are computed lazily. Only promotion needs dominance frontiers. Value rewrites,
parameter edits, and motion preserve CFG analyses; edge and block changes do not.
Incoming edges retain source block and ordinal, never mutable-array pointers.

## Inlining

The inline cost limit is `InlineLimit` (48 by default). Eligible callees must have
a natively valid typed body and lie outside the caller's recursive component.
`CallComponent` finds SCCs only when query cycle detection requires them; acyclic
instances retain the cheap query path. Component discovery may schedule sibling
direct-callee work, but component queries stay demand-driven.

Optimization hints start unrequested callees from prepared IR, including
initializer regions, without observing their results. Ordinary inliner reads own
dependencies and runtime validation. Temporary hint edges settle on success or
failure; existing optimized bodies retain lazy validation after edits.

Directly passed aggregate arguments make primitive constants free in callee cost
because they expose scalar-replacement opportunities. Caller growth still counts
every inserted instruction. No std identity or speculative specialization is
needed. Within one pass, repeated calls reuse resolution and eligibility facts.
`InlineFunctionFacts` shares immutable callee analysis and depends on its optimized
body; initializer-region facts stay local.

Arguments become entry block parameters unless readonly values, storage, or
initializers can substitute directly. Returns branch to a continuation and write
the call destination where present. Visible initializer regions inline through
ordinary capture writes. Inline frames retain instance, call span, and parent
frame so native panic traces preserve source call sites.

The std bundle can supply prepared and optimized bodies and call components.
Optimized bodies and native code require the producer's inline limit; preparation
and call components do not. New generic instances follow ordinary queries.

## Memory and Joins

Resource analysis distinguishes value storage, parameter storage, allocation
contents, immutable values, and unknown roots. Distinct slots do not alias, nor
does allocation contents alias a stack slot. Private slots cannot be modified
through escaped references. Address-taken results and block parameters remain
mutable roots even when their producing instruction is a plain value.

Numbering needs roots and address-taking facts; hoisting additionally needs
exposure. Hoist only invariant pure instructions or reads untouched by loop
writes; potentially faulting reads move only from the header. Snapshotting an
allocation descriptor makes its address independent of a changing element index,
not immune to ordinary alias/write checks or descriptor replacement.

Scalar replacement splits eligible structs and rebuilds whole reads with
aggregates; field reads then fold. Promotion handles scalar/directly passed slots.
Single-block slots use a local fast path; other slots share backward liveness and
one dominator-tree renaming walk with sparse restoration. Typing guarantees no
reachable read before initialization; scalar promotion may use typed zero on
unreachable incoming paths, while other slots remain in memory.

Canonicalization folds reconstruction from original fields back to the original
value. Redundant merge parameters disappear when all incoming values agree,
including unchanged backedges. Variant joins can pass a common injected payload
and rebuild the variant only for remaining users. Immutable struct joins preserve
common fields without inventing relationships between changing fields.

Mixed variants used only by tags and primitive payload reads may split into tag
and scalar parameters. Inactive scalar payloads use valid zero values; aggregate,
reference, owning, or addressable uses retain their normal representation. Use
facts are indexed once, parameters removed together, and incoming arguments
rebuilt once per block. A known incoming predicate may bypass an empty join to an
independent terminal exit, never skipping cleanup or fabricating a payload.

## Loops

Backedges in the dominator tree identify loops, canonicalized with a preheader
and single latch. `loops.zig` owns read-only instruction, counter, exit, and range
facts; `idioms.zig` owns transformations. Successful rewrites invalidate relevant
facts and restart analysis. Loop-free functions skip this work.

Counter matching alone proves neither monotonicity nor termination. Range proofs
must bound the latch update, including the final increment, in widened arithmetic.
Address-taken values cannot supply immutable counter/range facts. Dead-loop
removal separately requires an acyclic iteration body, so potentially nonterminating
nested loops survive. A checked unit-stride equality counter can be discarded
only when its initial value approaches the bound without crossing an endpoint.

Supported rewrites remove effect-free terminating equality loops, eliminate
proven integer comparisons, and replace eligible element loops with fill or
descending move. Check elimination supports constant or guarded dynamic starts,
checked constant-offset starts, nonzero constant strides, invariant bounds, and
strict/inclusive exits. Proved-safe latch arithmetic becomes modular only when
the widened range includes its final update. Fill/move
uses `0 <= start <= end` guards and retains the original loop as its fallback.

Carried boolean exits rotate either flag polarity into the latch predicate.
Explicit exit parameters preserve bound-exit and collision-exit state, including
shared exits and existing branch arguments. Latch effects still execute before
the exit decision; a final overflowing increment remains a panic.

Ranges intersect dominating predicates only where one successor dominates
the proof site; a guard on one path through a join is insufficient. Body proofs
combine numeric intervals with relationships to the same invariant limit.
These are local proofs, not a general range solver or vectorizer.

## Native Machine Stage

Functions needing scalar allocation lower to the private stream in
`src/backend/machine.zig`; fixed-only functions encode directly. The stream makes
virtual reads/writes, fixed registers, clobbers, labels, branches, copies, and
scratch-dead boundaries explicit. Constants stay immediate. Machine CFG/liveness
is temporary analysis of expanded instructions, not a second authoritative CFG.

Virtual values use caller-saved `r8`-`r11` or preserved `rbx`, `rbp`, `r12`-`r15`.
Fixed operands reserve conflicts and calls exclude caller-saved crossing ranges.
Syscall argument setup reserves the registers it writes. Linux preserves
`r8`-`r10`; a syscall itself reserves/clobbers `r11`, so a cold panic syscall
does not exclude the other three from the entire function.
Eligible locals retain the backward-positioned-edge gate; repeated unaddressed
scalar parameters are separate candidates with incoming ABI spill homes.
Temporaries allocate first, then parameters use spare caller-saved registers.
Unallocated parameters need no entry load; addressed values retain storage.

The weighted allocator tracks separate definitions and expanded edge-copy uses.
Reads precede definitions, permitting last-use reuse. Disjoint ranges can reuse
registers across calls, but there is no general call-site splitting or reload
insertion. Frames reserve preservation capacity before allocation; only used
preserved registers are saved and restored.

Arithmetic may reuse a legal operand register when scratch results are dead;
subtraction reuses only its left operand. Direct register/stack arithmetic avoids
unnecessary `eax` copies, while fixed/spilled operands retain compact addressing.
With dead accumulator scratch, scalar register copies bypass `eax`, and comparisons
use register, immediate, or stack operands directly while preserving flags.
Labels prevent combining across targets. Forward/reverse scalar edge copies bypass
scratch only when every source survives; cycles and unsupported shapes stage all
sources. Allocation must not create new copy hazards.

The encoder shares instruction metadata with assembly rendering, reuses selected
encodings, and patches symbolic branches after emission. Relocations, call return
positions, and initializer references become byte offsets; outlined regions append
after their parent. Machine streams never publish or cache. Range/label invariants
are checked at their boundary; displacement and size limits are recoverable errors.

Shifts use immediate counts or `cl`; dynamic counts are checked before the
instruction, so x86 count masking cannot change language semantics. Invalid
counts trap. Comparisons produce canonical bools, selections use conditional moves, and
single-use compare/increment/select combinations can use wrapping boolean addition.
Fills use `rep stosb`/`rep stosd`; directed copies use `rep movsb` and restore the
direction flag after descending copies. Single-use element addresses and legal
constant stores can use indexed operands without pointer temporaries.

## Verification and Measurement

`Fixture.expectParity` compares optimized native execution with typed-body
interpretation. Safe builds check references and branch argument counts after
each pass and on publication. Incremental tests distinguish edits to inlined and
out-of-line callees; `InlineLimit=0` preserves calls for structural/reuse tests.
Machine tests cover fixed-register and call conflicts, spills, expanded branches,
edge-copy cycles, parameter pressure, relocations, and panic provenance.

Each implementation slice needs matched cold, fresh leaf-edit, and generated
runtime measurements under the [benchmark protocol](../benchmarks/README.md#measurement-protocol).
Freeze frontend, workloads, compiler mode, std configuration, affinity, and worker
counts. Retain raw samples, investigate capped noise, and reject repeatable
regressions rather than treating smaller IR or code size as a performance result.
