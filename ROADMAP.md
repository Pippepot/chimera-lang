# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Immediate design priorities

Investigate these before the remaining implementation milestones, in this order.
Ranges and slices come first because they shape indexing, iteration, collection
APIs, and borrowing. Revisit implementation ordering when these decisions settle.

1. **Range index dispatch.** Define how borrowed integer element indexing and
  owned slice-handle results coexist in bracket syntax: `array[2..5]`,
  `array[..5]`, and `array[2..]`. Preserve reusable typed bounds and ordinary
  value/reference semantics without returning a union or borrowing a temporary
  Span. Settle from-end indexing (potentially `array[^1]`) and independently
  typed FromEnd bounds. `..^` remains inclusive, so from-end slice bounds need a
  distinct spelling. The named slicing contract and remaining decisions are recorded
  in [docs/RANGE_SLICING_PROPOSAL.md](docs/RANGE_SLICING_PROPOSAL.md).
2. **Iteration composition interfaces.** Reference alternatives and typed
  reference tuples provide the ownership-aware result model for the
  `next() -> T | End` protocol. Settle computed member specifications, narrow
  callable result/effect discovery, and storage-preserving variant narrowing
  for general library adapters. These deferred proposals are not prerequisites
  for the sole next/End protocol. Preserve lending, destination construction,
  and the distinction between references and owned Ref handles. The approval
  boundary and general-adapter requirements are recorded in
  [docs/BORROWED_AGGREGATES_PROPOSAL.md](docs/BORROWED_AGGREGATES_PROPOSAL.md).
3. **Static comprehensions.** Fixed-size Array construction with compile-time
  iteration shape and runtime element evaluation. Prefer `static if` and
  `static for` ordering; determine when filtering preserves a static count.
4. **Collection spreading and comprehensions.** `[1, ..values, 5]` and
  `[x * 2 for x in values if x > 0]`. Preserve fixed-size Array literal
  semantics and favor List for potentially runtime-sized results; settle mixed
  static/runtime sizes, evaluation order, ownership, and partial failure cleanup.
5. **Enum-indexed arrays.** Dense, type-safe arrays indexed directly by enum
  values; define domain coverage, storage order, and initialization.
6. **Value-producing blocks.** Blocks and labeled `break` carrying values;
  define result typing, ownership, cleanup, and interaction with failure.

## Ordered milestones

### 3. Generic iteration adapters

- Resolve the proposed generic composition interfaces before implementing a
  general library entrypoint. Do not add reflection, type builders, or new
  conditional-binding semantics without approval.
- Build on ordinary type factories' tested exact effect selection with explicit
  static arguments. Derive effects from callable signatures only through an
  approved discovery interface. Cover infallible and fallible producers and
  callbacks without making every adapter fallible; choose free functions or
  wrapper methods.
- Verify borrowed-place versus owned Ref items, lending from reused cursor
  buffers, move-only filtering, and consuming extraction from the result union.
- Verify zip's left-to-right polling and unmatched-item cleanup on exhaustion
  and failure; reject actual invalidation and ordinary overlapping mut arguments,
  without imposing exclusive mutable borrowing. Typed reference tuples exercise
  composition without requiring tuple destructuring.
- Preserve direct construction of fresh immovable sources, cursors, and items
  through the result union. Establish which adapters support immovable items;
  diagnose unsupported relocation rather than adding implicit copies.
- Preserve source evaluation, binding modes, loop results, and cleanup on all
  exits. Cover native/comptime parity and incremental changes to protocol
  resolution, borrowing, and fallibility. Concrete fixed-type adapters alone
  are not sufficient evidence for the generic library contract.

### 4. List mutation

- Add removal and extend existing append/reserve relocation to
  reference-containing elements, with per-element provenance and failure cleanup.
  Borrowed get/index results and replacement through tracked reference slots
  use the existing place semantics.
- Structural mutation during iteration and explicit consuming traversal, with
  stable backing references distinguished from content-dependent views.

### 5. Structural tuples

- Extend explicitly typed multi-element tuples with unannotated inference and
  destructuring, including `const (x, y) = point`. Resolve singleton forms and
  independent pattern modes; support multiple results and Map items.

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
  `all`, and `sorted`.
- Generalize `min`, `max`, and `clamp` beyond integers, defining ownership and
  comparator behavior.

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
