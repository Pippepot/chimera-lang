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

1. **Memory roles from operands.** `value_copy` loads, copies, or stores
   depending on whether its operands denote storage. Storage is a property of
   the operand, not of the copy, so the instruction is not split: separate load,
   store, and copy tags would duplicate a fact every producer must keep
   consistent. Passes classify accesses from the operand that owns the fact,
   for example a `local_storage` slot read as a whole `value_copy` source.
2. **Promotion.** Non-escaping slots become SSA values; loop-carried values
   become block arguments. Struct slots split per field; variants split into a
   tag plus payload values. Promotion runs again after inlining, which removes
   the borrows that keep locals in memory.
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

## IR facts passes rely on

- A `fallible_call` delivers its result as the single parameter of its success
  block; that parameter has no branch argument and is always kept. Fallible
  edges carry no arguments, so promotion skips a slot whose merge would need
  one; inserting edge blocks would lift this limit.
- Values are immutable except through addresses. A value is address-taken when
  any use is not a known read (initializer captures, borrowed or `deinit` call
  arguments, storage block parameters, borrows); address-taken values are never
  aliased or promoted.
- Typed bodies may keep unreferenced side-table entries; passes visit
  references through users, never by scanning tables.
- A slot read before any store on a path is unreachable by typing's definite
  initialization; promotion supplies a typed zero there.

## Slices

1. **Boundary and canonicalization (done).** `OptimizeFunctionInstance`,
   constant folding, the algebra table, constant-branch folding, dead pure value
   and unreachable block removal, side-table compaction, a safe-build IR
   verifier, `--debug=optimized`, and the `optimization` timing row.
2. **Editable IR and scalar promotion (done).** An editable function that can
   add block parameters, branch arguments, and instructions, serialized back
   with dead block parameters removed. `int`, `bool`, and `byte` slots whose
   every use is a whole load, a whole store of a plain value, or a branch or
   return read become SSA values through pruned SSA construction; scalar copies
   of plain values alias their source.
3. **Inlining** with call summaries, cost limits, recursive-component
   exclusion, and inline-chain trace metadata, followed by promotion.
4. **Control-flow cleanup**: empty-block and jump-chain removal.
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
