# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Top priority: scalar-flow performance regression

- Eliminate the remaining roughly 8-12% scalar/128-branch typing regression
  against commit `4556095` before starting the next language milestone.
- Reproduce with `zig build flow-benchmark --seed=0 -Doptimize=fast`.
  Alternate baseline and current binaries on the same pinned CPU over repeated
  trials; compare scalar and owning cases across all branch counts.
- Isolate the remaining allocation/page-fault and scalar-expression evaluation
  costs. The unresolved graph and snapshot footprints are unchanged, but clearing
  the nullable value buffer incurs additional demand-page faults. Scalar-argument
  helper inlining alone does not remove the regression; the complete cause and
  fix remain unverified.
- Require no repeatable scalar/128 slowdown or adjacent benchmark regressions,
  unchanged compiler behavior, relevant tests, the routine safe suite, formatting
  checks, and `git diff --check` before closing this priority.

## Ordered milestones

### 4. List mutation

- Removal, append, and relocation of reference-containing elements, with
  per-element provenance and failure cleanup. Borrowed get/index results and
  replacement through tracked reference slots use the existing place semantics.
- Structural mutation during iteration and explicit consuming traversal, with
  stable backing references distinguished from content-dependent views.

### 5. Structural tuples

- Unannotated tuple inference and destructuring, including
  `const (x, y) = point`. Resolve grouping/singletons and independent binding
  modes; support multiple results and Map items.

### 6. Match

- Single subject evaluation; literal, wildcard, binding, `pattern as name`, and
  `is Type` patterns. Diagnose redundancy and non-exhaustiveness.
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
- Settle general adapter interfaces across owned and borrowed whole carriers,
  mixed owned/reference alternatives, and nested tuples. Preserve exact declared
  producer/callback effects, left-to-right polling, captured authority, lending,
  and immovable destination construction. Filter predicate rejection must remain
  distinct from producer failure.
- Define End-only producer support, whether Zip remains exhausted after an input
  ends, and explicit disposal of rejected or unmatched explicit-drop items.
  Choose a separate API if boolean-result filtering with operational failure is
  needed.

### 8. Collections

- Map/Set hashing, equality, key-mutation rules, ownership, and ordered variants.
  Build on storage, tuples, and iteration contracts; Queue/Stack may reuse List.
- Efficient enum sets, preferably a standard-library `EnumSet[T]`; share enum
  domain decisions with enum-indexed arrays.

## Language ergonomics candidates

- Chained comparisons: `0 <= x < 10`; define single evaluation and failure flow.
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

- Compile-time member descriptors, narrow callable result/effect discovery, and
  structural tuple/variant builders for general adapters. Preserve logical type,
  whole-result ownership, and each alternative's owned/reference kind separately;
  keep descriptor aggregates compile-time-only. Settle eligibility and public
  contracts before implementation; proposed API names remain unapproved.
- Storage-preserving narrowing of mixed owned/reference variants and explicit
  storage-kind selection for ambiguous construction. Settle any new conditional
  binding syntax and its permission rules before implementation; preserve current
  const/var copying and ref aliasing semantics.
- Strided views: define representation, access, bounds, permissions, and backing
  lifetimes separately from contiguous Span slicing and RangeSequence traversal.
  Bulk range assignment remains a separate API decision.
- Expression-level failure fallback; assess guard bindings against existing
  fallible condition bindings before adding another form.
- Contextual enum shorthand (`.Red`) and smart casts after variant checks;
  define name resolution, narrowing, and invalidation by mutation.
- Generator suspension/yield syntax only if ordinary cursor composition proves
  insufficient; preserve item ownership, lending lifetimes, and failure effects.
- Publication of compile-time allocations into static/runtime storage: define
  serialization, relocation, mutability, and ownership before allowing escape.
- Local `static` bindings. Remove `comptime` only after verified equivalence
  across lexical scope, type-valued results, specialization, effects, and caching.
- Type-level `where` proofs of initializer infallibility; retain one `init` mode.
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
