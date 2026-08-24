# Review notes (engine-assisted pass)

Companion to the manual review. Covers refactor-path production code only (~4.2k loc):
`structures.zig`, `tokenizer.zig`, `ast_new.zig`, `semantic.zig`, `query_structures.zig`,
`ssa.zig`, `codegen_new.zig`, `query_new.zig`, `diagnostics.zig`, `runtime.zig`.
Each finding states the observation, the alternative considered, and a verdict.
Nothing here is applied; this is the comparison sheet.

## A. Query engine (`query_new.zig`, 1064)

### A1. Failure-recovery path is the subtlest code in the repo — comment it
`finishEntry(.failure)` keeps the old committed output and old `verified_at`
(only fresh computation state is dropped). On the next demand,
`enqueueForCurrentRevisionLocked` requeues the failed entry, and `runEntry`
then takes the *verify* branch: if deps are unchanged the entry flips back to
`.complete` without rerunning `Q.run`. So transient infra failures self-heal
via revalidation. Correct and elegant, but nothing marks those ~15 lines as
load-bearing. A 3-line why-comment at `finishEntry`/`runEntry` would protect
it from future refactoring. **Verdict: apply (comment only).**

### A2. Type erasure is justified; don't optimize the key
`ErasedKey{type_name, hash, value_ptr, eql_fn}` pays a `memcmp` on type name
per probe. Alternatives (interned type id, per-type maps) either need
comptime global state Zig doesn't cleanly offer or lose the single entry map
that scheduling/cycle detection requires. Hashes are already seeded with
`typeHash(Q)`; the name compare is what makes cross-type hash collisions
impossible rather than unlikely. **Verdict: keep as-is.**

### A3. Deadlock freedom comes from help-first waiting — worth stating
`waitForEntry` doesn't just sleep: it drains work (`takeWorkLocked`) before
`waitWork`. Combined with `reachesVisit` ignoring stale edges (deps used only
when `verified_at == revision` or mid-computation), this is what makes the
work-stealing scheduler safe for recursive queries. This is a design pillar
that exists nowhere in prose outside ROADMAP bullets. Candidate for one
paragraph in ARCHITECTURE.md at the next boundary update. **Verdict: docs.**

### A4. Missing introspection will bite at CLI migration
Legacy had `QueryStats` (hits/recomputes/dep checks). The engine has zero
counters and no way to enumerate entries. `--debug=query` cannot be ported
without adding a small stats struct to `Database`. Cheap (a few u64s bumped
under the existing lock), but deliberately deferred with the CLI milestone.
**Verdict: schedule with CLI slice, not before.**

### A5. Session-growth notes (no action)
Interned values grow monotonically per distinct name ever seen; `isIdleLocked`
is O(entries) under the lock per input write; cycle check is O(V+E) per edge
under the lock. All fine for CLI-scale sessions; revisit only for LSP-style
long-lived processes. **Verdict: none.**

### A6. Micro-clarity
`Handle.wait`'s `entry.output_ptr.?` unwraps the box pointer, not the
optional payload — outputs are boxed even when the payload is `?Ast = null`.
Correct, but reads like a trap. One comment. **Verdict: apply (comment).**

## B. Frontend (`tokenizer.zig`, `ast_new.zig`)

### B1. Strongest simplification candidate: drop the `_small` list tags
Lists exist in three shapes today: `.null` (empty), `_small` (≤2 inline in
`node_node`), and the ref-span form. Every producer (`addNodeList`) and every
consumer (`AstNodeListIterator`, `Ast.eql`, `renderNode`) multiplexes all
three. A uniform ref-span representation (empty = start==end) deletes five
node tags (`param_list_small`, `call_arg_list_small`, `type_list_small`,
`type_variant_small`, and their pairing logic), shrinks `Node.Tag`, collapses
the tag-pair parameters (`small_tag`, `list_tag`) threaded through parser and
iterator, and turns `AstNodeListIterator` into a trivial span walk.
Cost: one `u32` in `node_refs` per short list — negligible here.
Optional-child fields that legitimately use `.null` (signature return type,
param access, binding annotation) are a separate concern and stay untouched.
**Verdict: recommend before the control-flow slice, which adds more
list-shaped nodes and would otherwise inherit the tri-shape tax.**

### B2. Node payload-shape knowledge lives in two parallel switches
`Ast.eql` and `renderNode` each enumerate every tag→shape mapping. When
control flow adds tags, both must be updated in lockstep with the producers.
If a third full-shape consumer appears, centralize once (e.g. a
`Node.Shape` classifier or child-count function) rather than growing a
third switch. Today, with exactly two, centralizing would be machinery
without a customer. **Verdict: defer, with a named trigger.**

### B3. `parseReturn` residual branch
After the newline check, the `parseExpression` returning `.null` case survives
only for same-line non-starters (`return)`, `return,`). Both paths emit
identical `return_nothing` nodes. Could fold into one condition:
newline-or-nothing. Three lines, purely cosmetic. **Verdict: optional.**

### B4. Tokenizer is forward-heavy but sound
Number scanning supports Zig-style bases/exponents the language subset never
produces; indent/dedent synthesis (single-pop-per-call, blank-line reset) is
correct and tested. No newline tokens — which is precisely why the parser's
source-scan for bare return exists; that trade was reviewed and accepted.
**Verdict: none.**

## C. Semantic boundary (`semantic.zig`, `query_structures.zig`)

### C1. Merge the entry-body and function-body constructors
`buildUnresolvedEntryBody` and `buildUnresolvedFunctionBody` duplicate the
builder wiring, locals map, and owned-slice epilogue (~90 lines total); they
differ in: statement forms accepted (bare calls + skipped statics vs const
bindings + calls) and signature source (synthetic `{[], unit}` vs queried).
Unifying into one constructor parameterized by `ItemKind` removes a divergence
point exactly where the control-flow slice would otherwise have to make the
same change twice. **Verdict: recommend before control flow.**

### C2. `TypeExpectation` positional protocol survives multi-block — barely
The merge loop assumes expectations arrive sorted by `instruction_count`
(true by construction: monotonic appends during a linear statement walk).
Branches keep bindings sequential within their block, so global instruction
ordering still dominates expectation order — but this should be re-verified
the day conditionals introduce backtracking or re-walking in the builder.
The ordering invariant now carries a comment (applied earlier). **Verdict: hold.**

### C3. Layering is right; resist moving typing into `semantic.zig`
`resolveAndTypeBody` lives in `query_structures.zig` because it demands
`BuildModuleScope` and `FunctionSignature` through `ctx` — dependency
recording *is* the feature. Passing signatures in as a table would hide
edges from the engine. **Verdict: keep; no change.**

### C4. Message-string scatter
"only int and unit … supported yet"-family literals appear in `semantic.zig`
and test matrices. Two or three sites each; a central table adds indirection
for little consistency gain at this size. **Verdict: none until strings drift.**

## D. Backend (`ssa.zig`, `codegen_new.zig`)

### D1. Design note for the control-flow slice: canonical block-arg slots
When multiple blocks land, avoid the parallel-copy problem entirely by giving
every block argument a fixed stack slot in `LocationPlan`; each predecessor
stores live out-values to the successor's slots immediately before its
terminator branch. This extends the existing flat-slot model, keeps
`ValueLocation` unchanged, and sidesteps register-aware phi resolution.
Recorded here so it isn't rediscovered under time pressure. **Verdict: plan.**

### D2. Single-accumulator model couples two ideas
`.eax` as the returned-value location is entangled with "returned value is the
final instruction" (`LocationPlan.init` line 113 checks both). With
terminator-driven returns this decomposes naturally: terminators nominate the
value; the plan assigns `.eax` wherever the terminator says, not where the
instruction sits. Expect to rewrite that predicate, not the location model.
**Verdict: plan (part of D1's slice).**

### D3. `compileFunction`'s five guards collapse after control flow
The straight-line checks (`codegen_new.zig:281-287`) become genuine
capability limits or disappear. No action needed now; listed so their
disappearance later reads as planned, not accidental.

### D4. Effects (print/exit-code) insertion point
New instruction variants in `FunctionInstruction` (unit-returning, so no
location questions), `needed[]` unaffected, emitter gains a helper-call path.
Recommend *embedded* helper blobs (legacy `helpers_bin.zig` model) over
external symbols: the single-load-segment ELF stays valid, no PLT/dynamic
machinery. An `exit(value)` intrinsic is cheaper than print for behavioral
tests and may be the better first effect. **Verdict: plan with observable-output slice.**

### D5. Small items, no action
`referenced_instances` dedup is a linear scan (fine); `required_alignment = 1`
hardcoded but the linker validates generically (fine); division's explicit
encoding path vs the shared table is structurally justified (matches
ARCHITECTURE note); `ssa.lowerFunction` is a pure retag that could live beside
`FunctionIr` in structures.zig — left alone because its current placement
keeps structures.zig free of cross-stage logic.

## E. Cross-cutting

### E1. Identity-type inconsistency: `FileId = u64` vs `ItemId = enum(u32)`
Every other stable identity in `structures.zig` is an opaque enum; `FileId`
is a bare integer, so `(file: FileId, decl: u32)` transposes silently.
Aligning (`FileId = enum(u64)`) touches ~20 mechanical sites.
**Verdict: apply whenever inputs are next touched.**

### E2. `Diagnostic.file_id` unused by renderers
`renderDiagnostic` takes `source_path` separately and ignores `file_id`;
the field exists for engine-side bookkeeping only. Harmless, slightly
misleading. Either drop it or route rendering through it eventually.
**Verdict: none now; revisit at CLI slice.**

### E3. Test-facing APIs in production files
`directAccumulatorValues` / `transitiveAccumulatorValues` serve tests today
but are exactly the debug-dump surface the CLI will want (A4). Keeping them
in the engine is correct. **Verdict: none.**

## F. Sequencing recommendation (synthesis of the above)

1. **Pre-control-flow cleanups**: B1 (drop `_small` tags), C1 (merge entry
   constructor), E1 (FileId enum), A1/A6 comments.
2. **Control-flow slice**: D1/D2 strategy recorded above; re-check C2.
3. **Observable-output slice**: D4 (embedded helpers; consider exit-first).
4. **CLI migration**: A4 stats, E2, SSA dump, root `main.zig`; runtime.zig
   moves back out of legacy/.
5. **Persistence**: unchanged, last.

## Open questions to revisit during/after the manual review

- Does B1 interact with any serialization or persistent-cache plans?
  (Ref-spans are strictly more uniform to serialize — likely a win.)
- Should `ModuleScope` demand `IndexItems` instead of being built alongside,
  so duplicate diagnostics stop depending on `ParseFile` spans transitively?
  (Current direct-ParseFile dependence is documented as intentional.)
- Is `Instance` naming pulling weight? `InstanceId { item }` is a structural
  placeholder for substitutions; if generics get cut from the vision
  entirely, collapsing to `ItemId` downstream of analysis would delete a
  dimension. ROADMAP says substitutions are coming — confirm that intent.
- After entry/function constructor merge (C1): can `SelectEntry` +
  `BuildExecutable` treat the entry artifact identically enough that the ELF
  startup stub loses its special case? (It already does — stub calls an
  ordinary CompiledFunction. Confirm nothing else keys on entry-ness.)

## Resolutions (post-discussion, applied)

- **A1/A6 comments**: applied in `query_new.zig`.
- **C1 entry/function constructor merge**: done — single `semantic.buildUnresolvedBody(ast, source, declaration, kind, parameter_types, gpa)`; `AnalyzeFunctionBody.run` is now one straight line per phase. Entry-ness survives only as `ItemKind` gating statement rules.
- **Logic extraction from query_structures**: done — `typing.zig` now owns `resolveAndTypeBody`, expectation validation, span mapping, and issue emission. The query file passes `BuildModuleScope`/`FunctionSignature` as comptime parameters so typing stays decoupled from the catalogue while `ctx.get` keeps recording real dependencies mid-walk (laziness is observable: extra demands surface extra diagnostics).
- **E1 FileId enum**: reversed. Production code almost never manipulates raw `FileId` values (they live inside `Ast`/`ItemLoc`), so the compile-time win is small; the cost is `@enumFromInt` churn on ~150 test-literal sites. Zig's own frontend ships bare integer file indexes for the same reason.
- **B1 small list tags**: keep. Serialization is neutral either way (`Node.Data` is a fixed-width union and the AST is three flat arrays — both forms serialize as length-prefixed memcpy), so the decision rests on your speed rationale, which matches Zig's own astgen design. My consumer-multiplexing concern was overstated: `AstNodeListIterator` already centralizes it.
- **Parametric polymorphism confirmed** → `InstanceId` stays as the substitution-ready identity.
- **`exit(value: int) intrinsic`** recorded in ROADMAP as the selected first effect for the observable-output slice.
