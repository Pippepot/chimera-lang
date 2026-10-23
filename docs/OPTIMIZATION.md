# Optimization Design

[ARCHITECTURE.md](../ARCHITECTURE.md) owns the optimizer boundary and
[ROADMAP.md](../ROADMAP.md) owns slice priority. This document owns the target
IR shape, the pass structure, and the reasons for both.

## Boundary

`OptimizeFunctionInstance` turns a published typed body into an optimized
`FunctionBodyAnalysis`. Only codegen consumes it. The interpreter, reference
contracts, signatures, and diagnostics read the typed body, so optimization
cannot change diagnostics or compile-time results.

The optimizer reads IR facts only: instruction tags, operands, parameter modes,
storage projections, block arguments, and registered extern symbols. It never
reads source constructs, typing state, `CallBehavior`, or standard library
names. Language features that lower to existing IR need no optimizer change.
A new IR instruction needs one effect entry; folding comes from the shared
operation semantics and inlining from the generic operand visitors.

Unknown means conservative: a use the optimizer does not recognize marks the
value address-taken, and an unclassified instruction is never removed or moved.

## Why the current IR limits optimization

Typing publishes memory form. Every local is a `local_storage` slot accessed
through `value_copy` loads and stores, so `var x = a * b; x = x + 0` reads `x`
from a slot and no local rule sees that the load equals `a * b`. Every large
win (call removal, iterator collapse, copy elimination, bounds-check removal)
needs values, not slots. LLVM and MLIR both optimize on values and assign memory
late (mem2reg/SROA, MLIR bufferization). Here codegen's `LocationPlan` plays the
bufferization role: it gives storage only to values that need an address.

Target shape, in dependency order:

1. **Explicit memory operations.** `value_copy` means load, copy, or store
   depending on operand representation and destination. Split it into `load`,
   `store`, and `copy` so effects follow from the tag.
2. **Promotion.** Non-escaping slots become SSA values; loop-carried values
   become block arguments. Struct slots split per field; variants split into a
   tag plus payload values. This runs after inlining, which removes the borrows
   that keep locals in memory.
3. **Resource effects.** One classification reports pure, read, write,
   allocate, free, may-fail, or call, with the resource: slot, projection path,
   allocation contents, or unknown. Ownership supplies alias facts LLVM must
   infer: distinct slots never alias, exclusive `ref` parameters are `noalias`,
   readonly references are never written, and element writes are disjoint from
   header fields by projection path.
4. **Call summaries.** Per instance, bottom-up: effects, failure, argument
   escape, and inline cost. Recursive components stay conservative.
5. **Comparison values.** `cmpi` produces `bool` and `select` chooses a value;
   `pbr` remains the branch. This enables branchless `min`/`max`/`clamp`.
6. **Loop analysis.** Derive loops from the control-flow graph, normalize them
   (preheader, single latch, dedicated exits), and model induction variables as
   start/step recurrences.
7. **Inline chains in spans.** Trace metadata maps each code address to its
   inlined call chain, as syntax&semantics.txt requires for panic traces.

Wrapping arithmetic leaves no poison or undefined behavior, which removes a
class of optimizer bugs but also LLVM's `nsw` shortcut. No-overflow facts must
be proven, for example `i < n <= max-int` implies `i + 1` does not wrap.

## Pass structure

Passes are a few generic engines driven by per-operation data:

| Engine | Driven by |
| --- | --- |
| Canonicalize: fold, algebra, branch folding, value numbering | shared operation semantics, algebra table, effects |
| Promote: SROA, mem2reg | load/store tags and escape facts |
| Memory: forwarding, dead stores, invariant hoisting | resource effects |
| Inline | call summaries and cost |
| Loops: induction variables, bounds checks, fill/move idioms | loop analysis and dominating conditions |
| Compaction: unreachable blocks, dead pure values, renumbering | effects |

Folding uses the same operation semantics as the interpreter
(`FunctionInstruction.integerResult`, `PredicateOperation.holds`), so the two
cannot disagree. Algebra is a table row per operation (commutative, identity,
absorbing, negating, self result), not a function per rule.

Per-instance pipeline, callees first:

```
summaries -> inline -> promote -> canonicalize -> memory -> loops -> canonicalize -> compact
```

Register allocation is backend work that becomes worthwhile once values are SSA.

## Slices

1. **Boundary and canonicalization (done).** `OptimizeFunctionInstance`,
   constant folding, the algebra table, constant-branch folding, dead pure value
   and unreachable block removal, side-table compaction, a safe-build IR
   verifier, `--debug=optimized`, and the `optimization` timing row. On memory
   form it only sees constants and values that are not reloaded from slots.
2. **Explicit memory operations** (shape 1), touching typing, interpreter, and
   codegen once.
3. **Promotion of scalar locals** (shape 2, scalars only) with resource effects
   for slots.
4. **Inlining** with call summaries, cost limits, recursive-component
   exclusion, and inline-chain trace metadata.
5. **SROA** for structs and variants, then memory passes.
6. **Loops**: canonical form, induction variables, bounds-check elimination,
   fill and bulk-move idioms lowered to externs.
7. **Comparison values** and backend register allocation.

Each slice must show measured runtime or code-size gains and keep native
optimized execution in parity with unoptimized compile-time execution.

## Verification

- `Fixture.expectParity` compares optimized native execution against the
  interpreter, which runs the typed body, so every parity test covers the
  optimizer.
- The verifier checks value references, block targets, branch argument counts,
  and instruction ranges after every optimization in safe builds.
- Incremental tests check that optimized bodies recompute only when their typed
  body changes, and that equal recomputation keeps the old result.
