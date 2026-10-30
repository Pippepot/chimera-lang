# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Error handling acceptance

Complete the [routine Safe suite](docs/COMPILER.md#verify) for nominal error
marking, `catch`, and postfix `?` before full regression acceptance. Focused
handler and entry-query checks pass; the full run was interrupted before completion.

## Flow typing acceptance

The implementation, source migration, and routine Safe verification are complete.
Investigate measured typing/memory overhead and finish matched cold, incremental,
and runtime comparisons against the pre-flow parent before acceptance.
See the [current status and remaining work](docs/FLOW_TYPING_HANDOFF.md).

## Immediate engineering priority

Continue reducing frontend compilation time before further runtime or machine-stage
optimization. Use the [frontend measurements](docs/FRONTEND_PERFORMANCE.md) to
choose the next change; this takes precedence over the milestones below without
changing their relative order.

1. Investigate remaining operation/member/call resolution costs: repeated
   namespace and signature demands, type-only argument discovery, and type-fact
   access. Reuse facts at their owning boundary before introducing another cache.
2. Review refinement-heavy snapshot retention and remaining branch/join work.
   Preserve the simple scalar, owning, narrowing, and real-backedge cases alongside
   broad compilation throughput, diagnostics, ownership, and evaluation order.
3. Keep fresh leaf edits proportional to the changed body. Attribute dependency
   validation and executable linking separately from frontend reanalysis; prioritize
   parsing or invalidation changes only when their measured contribution warrants it.

Accept changes only with matched uninstrumented cold, leaf-edit, and generated
runtime measurements under the [benchmark protocol](benchmarks/README.md#measurement-protocol).
Keep backend and workload changes separate so frontend gains remain attributable.

## Compiler simplification

Reduce compiler code to at most 34,000 lines under the existing `loc.sh` code
policy. Preserve language behavior, diagnostics, ownership, incremental queries,
and cache validation. Consolidate repeated lifecycle and traversal logic; keep
tests and line-count rules intact. Apply the same performance acceptance protocol
to simplification changes.

Investigate the slow precompile-std build as part of subsequent frontend
performance work.

## Ordered milestones

### Collection mutation provenance

- Preserve per-element provenance and failure cleanup through removal, append,
  and relocation of reference-containing elements. Borrowed get/index results,
  reference append/relocation, checked replacement, and explicit consuming
  traversal already have implementations and regression coverage.
- Settle structural mutation during iteration, distinguishing references into
  stable backing from views that depend on contents.

### 7. Basic collection algorithms

- `swap`, `reverse`, and `sort` need not wait for Map/Set. Define support for
  noncopyable and reference-containing elements, comparator access and
  fallibility, stability, failure guarantees, and mutating versus value-returning
  APIs.
- Build pull-iterator utilities in the standard library: `zip`, `enumerate`,
  `pairwise`, `windows`, and `chunks`; algorithms `map`, `filter`, `find`, `any`,
  `all`, and `sorted`; numerical helpers `min`, `max`, and `clamp`.

### 8. Collections

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

## Independent numeric foundations

Schedule integer/byte work when earlier milestones need it; floating point does
not gate collections or basic algorithms.

- Nondecimal integer literals and magnitudes beyond the current signed-64-bit
  literal representation; define spelling, typing, and range diagnostics.
- Byte arithmetic and comparisons, and named wrap/truncate/round/saturate/widen
  conversions (including int/byte), with explicit overflow and failure rules;
  no converters between numeric runtime types.
- Float representation, literals, operations, conversions, and exceptional
  values before library math. Mixed operations and extra widths need decisions.

## Deferred or independent

- Result-correlated mutation provenance: preserve per-alternative output effects
  through forwarding, saved results, later writes, loop joins, and cached contracts.
  Until then, caller-visible output dependencies merge all ordinary return paths.
- Contextual enum shorthand (`.Red`); define name resolution and inference.
- Generator suspension/yield syntax only if ordinary cursor composition proves
  insufficient; preserve item ownership, lending lifetimes, and failure effects.
- Publication of compile-time allocations into static/runtime storage: define
  serialization, relocation, mutability, and ownership before allowing escape.
- Local `static` declarations. Remove `comptime` only after verified equivalence
  across lexical scope, type-valued results, specialization, effects, and caching.
- Temporary-projection borrowing and lifetime extension.
- Shared ownership: atomic reference counts, access synchronization guarantees,
  and cycle policy. No upgradeable weak-reference API is proposed.
- Capturing closures, local function literals, `sizeof`, and return inference.
  Explicit named overload sets and noncapturing static function values exist.
- Additional targets only for concrete use cases: target/location-specific
  layouts, allocation, access, and zero-byte behavior. Start with scalar device
  buffers; defer raw addresses and foreign memory.
- Finer-grained invalidation only after measurements; decide unused-declaration
  validation separately from demand-driven compilation.
- **Enum-indexed arrays.** Dense, type-safe arrays indexed directly by enum
  values; define domain coverage, storage order, and initialization.
- **Value-producing blocks.** Blocks and labeled `break` carrying values;
  define result typing, ownership, cleanup, and interaction with failure.
