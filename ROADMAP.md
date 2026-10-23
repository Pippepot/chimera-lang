# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) owns compiler boundaries. This file tracks
future work in priority order, not completed features or implementation history.

Settle missing semantics before implementation. Each phase includes
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Ordered phases

### 1. Algorithms and iterator adapters

- Start with `swap`, `reverse`, and `sort`, independently of Map/Set. Settle
  element capabilities, comparator access/fallibility, stability, failure
  guarantees, ordering laws (including partial versus total ordering), and
  mutating versus value-returning APIs. Distinguish a negative comparison from
  operational failure.
- Before general adapters, settle the required compile-time member descriptors,
  callable result/effect discovery, and tuple/variant builders. Keep logical
  types, whole-result ownership, and member storage kinds separate; descriptors
  stay compile-time-only and public APIs remain undecided.
- Build `zip`, `enumerate`, `pairwise`, `windows`, `chunks`, `map`, `filter`,
  `find`, `any`, `all`, and `sorted`.
- Cover owned/borrowed carriers, mixed alternatives, and nested tuples while
  preserving declared effects, polling order, authority, lending, and immovable
  construction. Define End-only support, sticky exhaustion, and explicit-drop
  cleanup; keep predicate rejection distinct from producer/callback failure.

### 2. Collections

- Map/Set: key equivalence, equal-key hash consistency, key mutation, ownership,
  and ordering laws for ordered variants, building on tuples and iteration.
  Queue/Stack may reuse List.
- Enum-indexed arrays: domain coverage, storage order, and initialization;
  reuse those decisions for an efficient standard-library `EnumSet[T]`.

### 3. Optimization

[docs/OPTIMIZATION.md](docs/OPTIMIZATION.md) owns the target IR shape and pass
design. Remaining slices, in order:

- Split `value_copy` into explicit load, store, and copy operations.
- Promote non-escaping scalar locals to SSA values with slot effects.
- Inline small callees bottom-up with call summaries, cost limits, recursive
  component exclusion, and inline-chain trace metadata.
- Scalar replacement of struct and variant slots, then forwarding, dead-store,
  and invariant-hoisting passes over ownership-derived alias facts.
- Loop normalization, induction variables, bounds-check elimination, and fill
  and bulk-move idioms lowered to externs.
- Comparison values with `select`, then backend register allocation.

Each slice requires measured runtime or code-size gains, tracks compiler time
separately, and compares optimized against unoptimized behavior for evaluation
order, failure, ownership/cleanup, diagnostics, and incremental/cache
correctness.

## Independent foundations and ergonomics

Schedule these when needed; floating point does not gate collections or algorithms.

- Inline named variant cases alongside ordinary type alternatives: payload-free
  cases use implicit unit without payload storage; named cases remain distinct
  from bare unit/none and from other cases with the same payload type. Settle
  construction, matching, visibility, and identity across aliases/composition.
  Represent informative errors with ordinary variants, not payload-carrying failure.
- Concrete capturing closures: settle capture syntax/defaults, invocation access
  and consumption, and generic callable inspection alongside adapter needs.
  Environments live inline or construct directly in a return destination; Box
  explicitly selects heap storage. Preserve ordinary ownership and borrow rules;
  defer owning type erasure and do not introduce implicit environment allocation.
- Foreign interoperability: define a C ABI boundary, representation/layout,
  calling conventions, opaque handles, buffer access, callbacks, and ownership
  obligations separately from compiler-registered externs. Unrestricted raw
  pointers are not a prerequisite.
- Numeric foundations: nondecimal/wider literals, byte operations, and named
  wrap/truncate/round/saturate/widen conversions with explicit overflow and
  failure rules. No converters between numeric runtime types.
- Floating point: representation, literals, operations, conversions, exceptional
  values, mixed operations, and widths before extending library math.
- Chained comparisons: single evaluation and failure flow; `defer`: cleanup on
  failure and nonlocal exits; interpolation: formatting, allocation, and failure.
- General `static if`: analyze only the selected branch, including declaration
  visibility and dependency tracking.
- Compiler usability: check/build-only workflows and explicit output paths;
  prioritize formatter/editor integration against concrete user needs.

## Deferred candidates

- Mixed owned/reference variant narrowing and explicit storage-kind selection;
  settle binding syntax/permissions without changing const/var copying or ref aliasing.
- Strided views: representation, bounds, access, and lifetimes, separate from
  contiguous slicing and range traversal. Decide bulk range assignment separately.
- Failure fallback and guard bindings, only where existing condition bindings
  are insufficient; enum shorthand and smart casts with mutation invalidation.
- Match extensions beyond tuple patterns and ordinary and conditions: settle
  nominal record patterns/captures, relative comparisons, and container/range
  membership separately, preserving ordinary binding and extraction spelling.
  Settle narrowed header captures and migration of legacy scalar/type `as name`
  captures separately; tuple capture syntax does not extend that spelling.
- Generators/yield only if cursor composition proves insufficient; preserve
  ownership, lending, and failure effects.
- Compile-time allocation publication: serialization, relocation, mutability,
  and ownership before escape into static/runtime storage.
- Local `static`; remove `comptime` only after equivalent scope, type-valued
  results, specialization, effects, and caching are verified.
- Initializer infallibility proofs through `where`, retaining one `init` mode;
  temporary-projection borrowing and lifetime extension.
- Shared ownership: atomic counts, synchronization guarantees, and cycle policy;
  no upgradeable weak-reference API.
- Concurrency: thread transfer/sharing, synchronization, atomics, and data-race
  semantics before concurrent APIs; async remains deferred too.
- User project tooling: language-level tests and reproducible dependency/package
  declarations, separately from compiler tests and module discovery.
- Overloading beyond explicit sets, `sizeof`, and return inference.
- Additional targets only for concrete use cases: layouts, allocation, access,
  and zero-byte behavior. Start with scalar device buffers; defer raw addresses
  and foreign memory.
- Finer invalidation only after measurement; decide unused-declaration validation
  separately from demand-driven compilation.
