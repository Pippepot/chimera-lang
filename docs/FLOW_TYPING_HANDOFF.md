# Flow typing: unfinished implementation handoff

**Unfinished and not release-ready.** The user requested that work stop, that the
current state be merged into the primary branch, and that fixes be deferred.
Do not interpret the updated language documentation as proof of implementation
completeness. No final performance acceptance or successful full suite exists.

## Design being implemented

- `value is Type` returns an ordinary bool and introduces no binding. Branches
  refine reads of the existing place; declared storage and assignment types stay
  fixed. Negative exiting guards, `and`, `or`, and `not` carry branch facts.
- Recursive match patterns refine original subjects and corresponding fields.
  Plain captures retain ordinary copy/ownership rules; `ref name` retains the
  source's permissions and lifetime. Narrowing never grants ownership.
- Colon is an ordinary annotation. Typed match captures and atomic conditional
  or checked bindings are removed. The user explicitly chose to preserve checked
  structural List/Span destructuring, while removing annotation-based filtering.
- Saved bool implications are versioned. Replacing a carrier invalidates its
  proof, including through aliases and call/hook effects. Payload writes should
  preserve the enclosing tag's proof.
- A loop body is typed once. A proof inherited at entry and actually used by the
  body must hold on every backedge. A test inside the loop establishes its own
  proof. This replaces an overly conservative initial blanket invalidation.

`syntax&semantics.txt` owns the intended semantics; `ARCHITECTURE.md` describes
ownership of the analysis state. Both were updated, but still need an audit
against the completed implementation.

## Current implementation

`src/frontend/flow_types.zig` stores immutable fact records, with possible stored
members, mutation versions, source spans, and invalidation provenance. Persistent
snapshot buffers contain fact IDs; ordinary variables have no second mutable
type field. `flow_snapshot.zig` supports growth without changing old snapshots.

`typing.zig` canonicalizes place origins and field paths across aliases and
inference captures; joins facts at CFG merges; projects narrowed reads; versions
writes; carries implications on bool values; and checks loop proof invariants.
Type discovery keys include the flow snapshot. Metadata-only discovery must not
execute argument effects early. Place identity for proofs is separated from
borrow dependencies (`flow_origins` versus `place_origins`).

Other foundational changes include keeping context-specific conversions out of
the raw expression cache, syntax-only field-place discovery during setup, and
retaining the iterator's original carrier type at its protocol boundary.

The latest edits (not fully revalidated) add scalar payload extraction without
unnecessary address pinning, independent projection for references and mutable
arguments, cleanup widening after a carrier mutation, fresh versions on reused
owned binding slots, and preserving a complete carrier when a consuming
parameter explicitly expects its declared type.

## Verification recorded before stopping

- The standard-library precompiler completed successfully on an intermediate
  revision after migration. Later edits have not all been checked through it.
- Ten focused tests in `tests/flow_typing_test.zig` passed on an intermediate
  revision, with native and compile-time parity where applicable. These cover
  branches, early returns, short circuiting, nested match fields, saved bool
  versions, loop backedges, aliases, payload writes, explicit ownership, and
  conversion-cache isolation. They are included in the normal build list.
- Full command: `zig build test --seed=0 -Doptimize=safe -j1 --summary all`.
  **1374/1533 passed, 19 skipped, 95 failed, 45 crashed.** This run preceded later
  fixes; the failing cases are listed in
  [the inventory](flow-typing/full-suite-failures.txt).
- A later focused match run passed its earlier cases and then aborted in
  `guarded match catch all copies retain feasible cleanup without changing their
  type`; see [the recorded failure](flow-typing/latest-match-failure.txt).
- Merge integration: a Zig compile-only check of `tests/flow_typing_test.zig`
  (`-Osafe -fno-llvm --test-no-exec`, using the previously built std artifact)
  succeeded after adapting the persistent expression buffer. Changed Zig files
  passed `zig fmt --check`, and the staged diff passed `git diff --check`.
  Runtime tests and a fresh bundled-std build were not repeated after integration.
- No exhaustive allocation-failure sweep was requested or run.
- No after-change benchmark comparison was completed.

## Remaining work, in priority order

1. **Get compilation and invariant checks clean after the merge.** The primary
   branch independently changed `BodyBuilder.values` from a slice to a persistent
   buffer and removed `captured_values`. The merge preserves that optimization
   and adapts the added flow-aware reads and captures to its buffer API. Validate
   flow-aware discovery, capture metadata, and match snapshots together. The
   cache rule must continue to preserve raw parameter values across conversions.

2. **Fix ownership and lifetime failures, rather than suppressing assertions.**
   The full inventory includes crashes in guarded/fresh explicit-drop captures,
   deferred initializer capture lengths, region capture setup, cleanup splitting,
   optional immovable construction, replacement calls, and cursor failure paths.
   The later match abort is a particularly small starting point. Audit
   `refineFlowOwners`, `refineVariantOwner`, `flowOwned`, `consumeOwnedPlace`,
   generation forwarding, and effect placement on individual CFG edges. Internal
   owner refinement must be recorded in a boundary belonging to that edge.
   Check nested variant fields' explicit-drop obligations as well as root owners.
   Verify that mutation restores all possible cleanup members without creating
   duplicate owners or losing conditional cleanup and partial-field metadata.

3. **Complete the distinction between logical types, stored alternatives, and
   addressable projections.** Exercise owned and reference alternatives with the
   same logical type, multi-member narrowed subsets, indirect layouts, custom
   copy/move hooks, and immovable members. Metadata type discovery and emitted
   values must agree. A subset must not reinterpret the original layout or create
   an alias to a repacked temporary with the original owner's lifetime. Preserve
   explicit wide-carrier references and consuming arguments. Finish projected
   field consumption and assignment under narrowed variant parents. The current
   helper paths need a complete lifecycle review, not more isolated exceptions.

4. **Finish alias and control-flow validation.** Cover unknown/dynamic indices,
   incomplete or loop-derived reference origins, potentially aliasing parameters,
   direct stores, reference stores, custom hooks, initializer effects, and indirect
   calls. Test unrelated fields and payload writes that preserve a tag. Check
   rebinding/version reset, bool copies and joins, and nested loop backedges,
   including backedges emitted before a later proof use is discovered. Confirm
   that retesting within an iteration breaks dependence on an entry proof.

5. **Finish the source migration and update tests intentionally.** Most fixtures
   were transformed automatically; their correctness is not established by the
   amount converted. Remaining examples include typed tuple binding conditions
   in `tests/tuple_test.zig`, template fragments containing `$hook`/`$operation`,
   escaped/generated source strings, stale replacement needles, old diagnostic
   expectations, and ordinary annotations on structural patterns that previously
   filtered variants. Preserve structural length checks. Ensure destructuring an
   already narrowed existing place uses that payload without changing ownership.
   Search all `.zig`, `.chi`, docs, and benchmark generators for removed syntax.
   Review generated match guards for copying, coverage, name scope, and cleanup
   timing. Parenthesized match statements can be parsed as continuation calls on
   the preceding expression; many were unwrapped after the full run. Nested
   multiline subjects also exposed delimiter/layout problems; several fixtures
   were reformatted. Recheck the remaining cases rather than assuming all parse
   failures have been repaired. Simplify generated wrappers where practical.

6. **Diagnostics are incomplete.** Primary errors should use the effective read
   type, and write errors the declared destination type. Fact records retain
   proof/invalidation spans, but useful provenance notes and rendering are not
   implemented. Explain a lost proof at the actual mutation or backedge when
   appropriate. Remove obsolete diagnostic wording after its consumers migrate.

7. **Complete incremental and serialized-state verification.** Re-run query,
   artifact, disk-cache, and initializer suites after fixes. Confirm changes to
   a guard, alias, type alias, tuple pattern, callee effects, or ownership mode
   invalidate the relevant result. Keep flow state body-local; do not persist
   builder pointers or introduce new cross-query mutable state.

8. **Benchmark and review size only after correctness.** Baseline artifacts below
   are retained; there are no final measurements. Compare scalar code with no
   narrowing, owning code, and workloads heavy in refinements/aliases/loops.
   Include retained snapshot/fact memory and cold/incremental compilation. The
   existing measurement counts snapshot pages; separately account for fact,
   place/path, predicate, and inference-key tables. Audit metadata allocations on
   ordinary primitive reads. Check optimizer regressions (including scalar local
   promotion) and runtime code size. Reduce unnecessary helpers, old extraction
   wrappers, duplicate tracking, and fixture boilerplate without weakening the
   independent ownership/type dimensions.

9. **Final checks and documentation.** Run the relevant focused suites, then the
   routine suite with fixed `--seed=0` and default caches, `zig fmt --check`, and
   `git diff --check`. Do not enable `-Dallocation-failures=true` without an explicit
   request. Reconcile README/spec/architecture/roadmap with actual final behavior;
   remove this unfinished status only once the required work is complete.

## Benchmark baselines and reproduction

Baseline snapshot commit: `a3c235c76e6e00fe2fe3b1d8ec6f8f621e65f872`.
It includes the primary checkout's then-current tracked/untracked changes, before
flow typing. The primary checkout subsequently advanced with optimizer work.

- `zig build flow-benchmark -Doptimize=fast -j1`: see
  [typing baseline CSV](flow-typing/typing-baseline.csv). The unchanged scalar
  workload at 512 branches took 8.850 ms; the owning workload took 31.562 ms.
- `zig build history-benchmark --seed=0 -j1 -Doptimize=fast -- --case=core-1000000 --lines=10000 --samples=3`:
  see [history baseline CSV](flow-typing/history-baseline.csv). Cold samples were
  about 321–329 ms; leaf edits about 3.20–4.88 ms. Three samples were marked
  unstable; these are observations, not acceptance thresholds.
- The history generator used removed binding syntax and has been migrated. The
  primary branch also changed benchmark sampling. For a fair comparison, use a
  common valid workload and consistent driver/settings; disclose syntax/workload
  changes instead of attributing them all to flow-analysis overhead.
- Earlier size bookkeeping reported 34,847 production and 46,748 test lines, but
  the counting script was not retained. Recompute both revisions with a recorded,
  reproducible method before claiming a LOC change.

Local exploratory tools and logs were under `/tmp/chimera-flow-*` and
`/tmp/migrate-flow-tests.py`; they are not dependencies or shipped compiler code.
The separate worktree is intentionally removed after merging this snapshot.
