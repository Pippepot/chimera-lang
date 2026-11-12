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
ownership/reference/cache qualification. Scoped context is separately implemented
and qualified below.

General borrowed erased lexical views, capture lists/move captures, mutable or
consuming invocation, explicit-drop captures, and directly returning anonymous
concrete closure types remain deferred. Every stage includes native/interpreter
parity, ownership, failure behavior, and incremental/cache qualification.

## Scoped context implementation slices

[SHAREDCONTEXT.md](docs/SHAREDCONTEXT.md#13-delivery-order-and-acceptance-tests)
owns the delivered behavior and acceptance record. All three slices are
implemented and qualified: explicit services and retained providers; scoped
bindings and execution; standard-library allocation and logging integration.
Native/evaluator behavior, lifetime and authority checks, incremental/persistent
reuse, the routine safe suite, and the
[runtime measurements](benchmarks/shared-context/README.md#recorded-qualification)
are qualified. No implementation slice remains pending in this sequence.

Automatic thread/task inheritance, asynchronous suspension across bindings, and
user-defined contextual declarations remain outside this revision's scope.

## Language ergonomics candidates

- Chained comparisons: `0 <= x < 10`; define single evaluation and Boolean short circuit flow.
- `defer` for scope-exit cleanup, including failure and nonlocal exits.
- String interpolation: `f"Value: {x}"`, potentially `{x=}`; settle formatting
  and allocation/failure behavior.
- String copy-on-write storage and efficient mutating compound assignment;
  define shared ownership, borrowed-view lifetimes, and allocator retention.
- Unicode code-point and grapheme iteration, counting, and slicing; define
  character APIs and the Unicode data/version policy.
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

## Independent filesystem library work

- Implement the proposed `std.files` API in [docs/FILES.md](docs/FILES.md):
  path values/views, whole-file helpers, typed opening settings, owned file
  handles with strict automatic cleanup, streaming I/O, and filesystem queries
  and operations. Settle the proposed filesystem semantics in the language
  reference before implementation; qualify ownership, failure paths,
  native/evaluator behavior, and incremental reuse.

## Deferred or independent

- Fix the remaining cold-compilation regression (roughly 1.3x serial against the
  historical baseline after
  [demand-sensitive cleanup scheduling](benchmarks/README.md#demand-sensitive-cleanup-scheduling-2026-11-12)).
  The
  [attribution](benchmarks/README.md#cold-compilation-regression-attribution-2026-11-11)
  traces it to owning containers (`Allocation`, `List`, `Box`, `String`) becoming
  borrow-bearing through the allocator provider and storage cursor, plus
  service-mutation application at calls. Further attribution and architectural
  work must cover typing and call preparation as well as provenance. A compact
  representation must keep provider retention, physical aliases, captured
  references, field/result paths, and invocation-time snapshots independent;
  a whole-value ambient-context bit is insufficient. Prefer retaining the
  published reference-contract/query boundary while investigating body-local
  provenance and contract-driven argument preparation. Preserve
  context/provider ownership, incremental typing reuse, and forwarding,
  saved-result, later-write, loop-join, and cached-contract behavior. Qualify
  fixes with fresh matched cold/leaf-edit measurements on unchanged 100,000-line
  and million-line workloads, with zero and eight workers.
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
