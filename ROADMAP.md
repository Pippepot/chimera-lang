# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior.

## Ordered milestones

### Basic collection algorithms

- Qualify the existing collection algorithms and numerical helpers against
  representative workloads. Adapter pipelines over span and range cursors match
  equivalent index loops within about 25% (map into zip 1.6x; zipped ranges carry
  one iterator state each, up to 3x at depth four). Keep matched-baseline cold and
  leaf-edit compilation on million-line workloads, with zero and eight workers, and
  bundled/source standard-library compilation from regressing.

### Collections

- Map/Set hashing, equality, key-mutation rules, ownership, and ordered variants.
  Build on storage, tuples, and iteration contracts; Queue/Stack may reuse List.
- Efficient enum sets, preferably a standard-library `EnumSet[T]`; share enum
  domain decisions with enum-indexed arrays.

Map/Set completion is not a prerequisite for the callable or scoped context
sequences. Callable v1 supports existing algorithms and unlocks service
handles independently of new collection types.

## Callable implementation sequence

The [language rules](syntax&semantics.txt) specify callable behavior;
[CLOSURES.md](docs/CLOSURES.md) develops the design and
[architecture](docs/ARCHITECTURE.md#closures-and-bound-methods) owns query
and compiler boundaries. Callable v1 (slices 1 through 4) is implemented, including
owned environments, fallible erasure/cloning, heterogeneous storage, and
ownership/reference/cache qualification. Scoped context remains a separate milestone.

General borrowed erased lexical views, capture lists/move captures, mutable or
consuming invocation, explicit-drop captures, and directly returning anonymous
concrete closure types remain deferred. Every stage includes native/interpreter
parity, ownership, failure behavior, and incremental/cache qualification.

## Scoped context implementation slices

[SHAREDCONTEXT.md](docs/SHAREDCONTEXT.md#13-delivery-order-and-acceptance-tests)
owns this separate task. Its callable prerequisites are implemented. The shared
context implementation is an uncommitted draft and has **not passed milestone
acceptance**. Preserve the existing staged, unstaged, and untracked work.

Wrap-up verification on 2026-11-08: `zig build test --seed=0 -Doptimize=safe
--summary all` finished unsuccessfully: **2,162/2,346 tests passed, 97 failed,
71 crashed, and 16 skipped; 36/62 build steps succeeded, with 23 failed**.
The full output is currently in `/tmp/chimera-context-wrapup-routine.log` (a
temporary local log). Formatting checks over modified tracked Zig files and the
callable/context test roots, and `git diff --check`, passed. Allocation-failure
sweeps and runtime benchmarks were not run. The narrow context result below is
not evidence that the rest of the compiler remains qualified.

1. **Explicit services and retained providers.** Draft code implements affine raw
   storage and typed adoption, provider-retaining allocation owners, checked and
   unchecked borrowed allocator/logger factories, and owning callable environment
   allocation/release through retained providers.
2. **Scoped bindings and execution.** Draft code implements registered independent
   allocator/logger entries, ordinary and contextual `with` replacement, retention
   and restoration on ordinary exits, native thread-local state, isolated evaluator
   bindings, invocation/forcing-time selection, and checked service-cycle guards.
3. **Standard-library allocation and logging integration.** Draft code routes
   construction through context and growth/release through retained providers,
   migrates allocation/I/O failures to marked errors, and implements logging
   selection, filtering, forwarding, and root stderr output. Qualification remains
   incomplete; severity convenience functions are still missing.

The focused [shared-context suite](tests/shared_context_test.zig) currently passes
40 of 41 tests. The reachable reset-before-use arena case is rejected, but its
valid reset-after-last-use counterpart is also rejected. The positive failure is
`borrow_outlives_source` on `_ = values` after `arena.counter += 1`: an issued
backing origin resolves to an older binding identity even though the intervening
write should preserve storage. Scalar field replacement now records preserved
storage depth, but this alone did not fix the identity mismatch. Keep the failing
regression enabled; its original negative fixture was corrected to invoke `run`
so lazy analysis actually reaches the reset.

Complete these remaining tasks before marking any context slice accepted:

- **Restore routine-suite correctness first.** The inline-test root has missing
  mock capabilities: semantic `TestAnalysisContext.contextualEntry`, typing
  `TestMaterializerTypes.serviceCallableField`, `rawBlock`, and `contextualType`.
  Interpreter fixtures also lack `allocationElement` used by environment
  projection. Runtime regressions span callable, collection, reference, lifetime,
  query/static evaluation, cache/artifact, text, iteration, sorting, and optimizer
  suites. Repeated compiler crashes reach
  [reference path publication](src/frontend/typing.zig) (`publishOutputOrigins`
  and `publishSourcePath` assertions) and
  [lifetime ending validation](src/frontend/lifetime.zig) (`applyEndings` asserts
  that a generation is still open). Query tests also unwrap absent analysis/static
  results. Reproduce representative failures before deciding which tests need
  marked-error migration and which expose compiler defects; retain reference
  rejection coverage, including readonly collection captures and match-guard
  invalidation during cleanup. Optimizer call-count/loop-invariance checks and
  fresh-project bundled-std reuse expectations also fail and need investigation.
- **Backing lifetime and cleanup effects.** Fix the arena identity mismatch without
  weakening actual backing-replacement rejection. Review the complete cleanup
  path: `recordOwnershipHookEffects` currently returns during cleanup
  materialization after recording contextual effects, while scheduled collection
  publishes writes/outputs without attaching aggregate reference effects to the
  emitted cleanup. Add destructor-reset rejection and valid cleanup-order tests.
  Audit whether prospective cleanup service expansion registers candidate callbacks
  as executed mutations, and whether replanning cleanup locations refreshes their
  scheduled writes. These two scheduling concerns are review leads, not confirmed
  failing behaviors.
- **Forwarding and authority.** Add loop/backedge and recursive service-retention
  negative and positive cases. Review final contents reads extended to
  `maxInt(usize)` by mutable parameter publication, and the conservative fallback
  for owning-callable conditions sourced from nested parameter fields. Audit
  allocator factory authority checks against legitimate backend state updates.
- **Logging completion.** Add `trace`, `debug`, `info`, `warning`, and `error`
  convenience functions. Test a real broken stderr pipe (cause 32, progress 0,
  no SIGPIPE termination) and partial nonblocking writes (cause 11 and accurate
  progress including prefix/message/newline). Existing root destination and
  evaluator no-host-output tests do not cover those failure paths.
- **Incremental and persistence qualification.** Add backend/body edits that change
  retention or contextual effects without changing signatures; exercise disk
  restoration, portable artifacts, embedded std reuse, and malformed contextual
  IR/service-stack validation. Current formats are `CHIMERAQRY61`, `CHIMERAART19`,
  and `CHIMERASTD16`; reassess and bump consistently after final representation
  changes. The installed CLI predates the latest analysis fixes and must be rebuilt.
- **Measurements and final acceptance.** Qualify and run the unmeasured
  [shared-context benchmarks](benchmarks/shared-context/run.py), including layout,
  construction, spare append, growth, destruction, wrapper depths, and disabled/
  enabled no-op logging. Record matched measurements and their boundaries. Run
  the routine safe suite, formatting, and `git diff --check`, then rereview and fix
  new findings. Allocation-failure sweeps remain opt-in. Update owning documents
  to describe accepted behavior only after these checks pass.

## Language ergonomics candidates

- Chained comparisons: `0 <= x < 10`; define single evaluation and Boolean short circuit flow.
- `defer` for scope-exit cleanup, including failure and nonlocal exits.
- String interpolation: `f"Value: {x}"`, potentially `{x=}`; settle formatting
  and allocation/failure behavior.
- Selected-branch-only analysis for `static if`, including declarations and
  dependencies in the unselected branch.
- Further patterns: named-struct destructuring, sequence/rest patterns, extractors,
  direct membership and relative-comparison arms, and pattern Boolean algebra.
  Settle header initializers and capture ownership before introducing syntax.

## Independent numeric library work

- Extend text formatting and parsing to every numeric width and floating-point
  format, with explicit locale and exceptional-value rules.
- Build floating-point library math on the concrete arithmetic and conversion
  policies in [docs/NUMERICS.md](docs/NUMERICS.md).

## Deferred or independent

- Finish result-correlated mutation provenance performance qualification: remove
  cold-compilation regressions while retaining incremental typing reuse and
  forwarding, saved-result, later-write, loop-join, and cached-contract behavior.
- Expected-type shorthand for struct namespace members and omitted-type struct
  initializers; define member eligibility, syntax, and ambiguity beyond nominal cases.
- Generator suspension/yield syntax only if ordinary cursor composition proves
  insufficient; preserve item ownership, lending lifetimes, and failure effects.
- Buffered iterator adapters `pairwise`, `windows`, and `chunks`: settle retained
  item ownership, overlapping views, lending lifetimes, and partial chunks.
- Publication of compile-time allocations into static/runtime storage: define
  serialization, relocation, mutability, and ownership before allowing escape.
- Local `static` declarations. Remove `comptime` only after verified equivalence
  across lexical scope, type-valued results, specialization, effects, and caching.
- Temporary-projection borrowing and lifetime extension.
- Non-copyable nominal variant payloads: define borrowing and consuming payload
  extraction before lifting the current copyability restriction.
- Shared ownership: atomic reference counts, access synchronization guarantees,
  and cycle policy. No upgradeable weak-reference API is proposed.
- `sizeof` and general function return inference. Expression-body closure result
  inference and callable slots in declared adapter results belong to the callable
  sequence above; they do not require general return inference.
- Additional targets only for concrete use cases: target/location-specific
  layouts, allocation, access, and zero-byte behavior. Start with scalar device
  buffers and synchronous transfers; defer raw addresses and foreign memory.
  Keep logical types, layouts, address spaces, providers, and ABI independent.
  Asynchronous completion must retain resources and access obligations. Define
  kernel synchronization, collective participation, failure, and numeric policies
  before lowering; use established device backends where practical.
- Finer-grained invalidation only after measurements; decide unused-declaration
  validation separately from demand-driven compilation.
- **Enum-indexed arrays.** Dense, type-safe arrays indexed directly by enum
  values; define domain coverage, storage order, and initialization.
- **Value-producing blocks.** Blocks and labeled `break` carrying values;
  define result typing, ownership, cleanup, and interaction with failure.
- Runtime optimization: stronger loop bounds proofs, register allocation, and
  machine copy/address selection; SIMD only after scalar opportunities. Preserve
  wrapping and panic behavior without workload-specific special cases.
- Machine-stage cost: call-site live-range splitting, frame compaction, and
  scheduling when profiles justify them.
