# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) owns compiler boundaries. This file tracks
future work in priority order, not completed features or implementation history.

Settle missing semantics before implementation. Each phase includes
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Ordered phases

### 1. Match

- Evaluate the subject once; support literal, wildcard, binding,
  `pattern as name`, and `is Type` patterns with exhaustiveness and redundancy
  diagnostics.
- Define copying, borrowing, consumption, and arm-exit cleanup for subjects and
  bindings, including noncopyable payloads and unmatched alternatives.

### 2. Algorithms and iterator adapters

- Start with `swap`, `reverse`, and `sort`, independently of Map/Set. Settle
  element capabilities, comparator access/fallibility, stability, failure
  guarantees, and mutating versus value-returning APIs.
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

### 3. Collections

- Map/Set: hashing, equality, key mutation, ownership, and ordered variants,
  building on tuples and iteration. Queue/Stack may reuse List.
- Enum-indexed arrays: domain coverage, storage order, and initialization;
  reuse those decisions for an efficient standard-library `EnumSet[T]`.

### 4. Optimization (implementation TBD)

- Establish representative generated-program runtime and code-size baselines,
  tracking compiler time and memory costs separately.
- Choose the implementation from measurements; IR, pipeline placement, passes,
  and backend strategy remain open. This is separate from the immediate
  compiler-performance regression gate.
- Require measurable gains and optimized/unoptimized behavioral comparisons
  covering evaluation order, failure, ownership/cleanup, diagnostics, and
  incremental/cache correctness.

## Independent foundations and ergonomics

Schedule these when needed; floating point does not gate collections or algorithms.

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
- Overloading beyond explicit sets, function literals/closures, `sizeof`, and
  return inference.
- Additional targets only for concrete use cases: layouts, allocation, access,
  and zero-byte behavior. Start with scalar device buffers; defer raw addresses
  and foreign memory.
- Finer invalidation only after measurement; decide unused-declaration validation
  separately from demand-driven compilation.
