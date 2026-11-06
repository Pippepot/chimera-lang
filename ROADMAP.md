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
- Capturing closures, local function literals, `sizeof`, and return inference.
  Explicit named overload sets and noncapturing static function values exist.
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
