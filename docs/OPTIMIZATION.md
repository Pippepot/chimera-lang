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
before collecting address-taken facts. An editable function reuses normalized
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

Codegen uses immediates for constants and computes scalar results in `eax`.
In functions containing loops, the existing weighted live-interval allocator
keeps eligible integer and boolean values in six preserved registers. Addressed
values, incoming parameters, and initializer environments retain stack storage.
Liveness bitsets index only eligible values and reuse their edge scratch buffer.
Operand reads precede result definitions in the interval order, allowing a result
to reuse a register at its operand's last use.
Arithmetic updates that register directly when the result shares a legal
operand location; commutative operations may reuse either operand, subtraction
only its left operand. Immediate updates use compact signed-byte encodings
when possible. Division retains its fixed-register sequence.
Each function saves and restores the registers it uses. Independent scalar edge
copies bypass scratch storage; dependent copies still stage all sources before
writing any destination. Comparisons produce canonical boolean values;
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

## Remaining Work

- Recover the remaining compilation regression without reducing optimization.
  The CPU-4 matched million-line probe measured 18.89 s cold / 136.7 ms leaf edit
  for the saved pre-refactor compiler and 21.76 s / 141.3 ms after join and backend
  changes. Executable size fell from 177.8 MB to 135.0 MB. These are single
  measured cold/edit pairs after warm-up, not full benchmark medians.
  Subsequent shared inline-fact caching reduced the small probe's inlining work
  from about 13.8 ms to 8.2 ms; repeat the million-line comparison for that state,
  including eight-worker compilation. Join simplification remains a major cost.
- Continue the C assembly comparison. The latest paired sieve medians were
  2.264 s before the refactor, 1.036 s after terminal jump threading, and 0.570 s
  for C `-O3`, with one warm-up and nine samples on CPU 4. The later direct-register
  arithmetic change passed backend tests but has not been runtime-benchmarked.
  C vectorizes final counting and uses a tighter marking loop. Chimera still
  counts scalarly, retains bounds checks, reloads allocation bases, and stages
  dependent edge copies. Preserve wrapping arithmetic and panic behavior when
  pursuing bounds proofs, instruction selection, or vectorization; do not
  special-case the sieve or weaken its checks.
- Complete the routine safe test suite. Focused optimizer and backend suites
  pass, including incremental inlining, scalar variants, wrapping arithmetic,
  parallel copies, spills, and call preservation. The attempted full run did not
  produce a completion summary, so cross-suite verification remains outstanding.
  Use `zig build test --seed=0 -Doptimize=safe -j1` without allocation-failure sweeps.

Local measurement artifacts are under `.history/loop-optimization/`, including
`paired-before-compile.csv`, `paired-current-compile.csv`, `runtime.json`, probe
profiles, generated assembly, and `full-tests-current.txt`. They are ignored
experiment artifacts, not committed benchmark history.
