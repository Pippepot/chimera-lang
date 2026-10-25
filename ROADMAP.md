# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Immediate design priorities

Investigate these before the remaining implementation milestones, in this order.

1. **Static comprehensions.** Fixed-size Array construction with compile-time
  iteration shape and runtime element evaluation. Prefer `static if` and
  `static for` ordering; determine when filtering preserves a static count.
2. **Collection spreading and comprehensions.** `[1, ..values, 5]` and
  `[x * 2 for x in values if x > 0]`. Preserve fixed-size Array literal
  semantics and favor List for potentially runtime-sized results; settle mixed
  static/runtime sizes, evaluation order, ownership, and partial failure cleanup.

## Ordered milestones

### 4. List mutation

- Removal, append, and relocation of reference-containing elements, with
  per-element provenance and failure cleanup. Borrowed get/index results and
  replacement through tracked reference slots use the existing place semantics.
- Structural mutation during iteration and explicit consuming traversal, with
  stable backing references distinguished from content-dependent views.

### 5. Structural tuples

- Tuple identity, type spelling, access, destructuring, layout, and elementwise
  ownership, including `const (x, y) = point`. Resolve grouping/singletons;
  support multiple results and Map items.

### 6. Match

- Single subject evaluation; literal, wildcard, binding, and typed `name: Type`
  patterns. Diagnose redundancy and non-exhaustiveness.
- Define when subject and pattern bindings copy, borrow, or consume, including
  noncopyable payloads and cleanup of unmatched alternatives and arm exits.
- Check whether existing expression semantics cover value-producing `if` and
  `match`; align any missing rules with value-producing blocks.

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
- Contextual enum shorthand (`.Red`) and smart casts after variant checks;
  define name resolution, narrowing, and invalidation by mutation.
- Generator suspension/yield syntax only if ordinary cursor composition proves
  insufficient; preserve item ownership, lending lifetimes, and failure effects.
- Publication of compile-time allocations into static/runtime storage: define
  serialization, relocation, mutability, and ownership before allowing escape.
- Local `static` bindings. Remove `comptime` only after verified equivalence
  across lexical scope, type-valued results, specialization, effects, and caching.
- Temporary-projection borrowing and lifetime extension.
- Shared ownership: atomic reference counts, access synchronization guarantees,
  and cycle policy. No upgradeable weak-reference API is proposed.
- General overloading, function literals/closures, `sizeof`, and return inference.
- Additional targets only for concrete use cases: target/location-specific
  layouts, allocation, access, and zero-byte behavior. Start with scalar device
  buffers; defer raw addresses and foreign memory.
- Finer-grained invalidation only after measurements; decide unused-declaration
  validation separately from demand-driven compilation.
**Enum-indexed arrays.** Dense, type-safe arrays indexed directly by enum
  values; define domain coverage, storage order, and initialization.
**Value-producing blocks.** Blocks and labeled `break` carrying values;
  define result typing, ownership, cleanup, and interaction with failure.
