# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Ordered milestones

### 4. List mutation

- Removal, append, and relocation of reference-containing elements, with
  per-element provenance and failure cleanup. Borrowed get/index results and
  replacement through tracked reference slots use the existing place semantics.
- Structural mutation during iteration and explicit consuming traversal, with
  stable backing references distinguished from content-dependent views.

### 5. Structural tuples

- Tuple identity, type spelling, access, destructuring, layout, and elementwise
  ownership. Resolve grouping/singletons; support multiple results and Map items.

### 6. Match

- Single subject evaluation; literal, wildcard, binding, `pattern as name`, and
  `is Type` patterns. Diagnose redundancy and non-exhaustiveness.
- Define when subject and pattern bindings copy, borrow, or consume, including
  noncopyable payloads and cleanup of unmatched alternatives and arm exits.

### 7. Basic collection algorithms

- `swap`, `reverse`, and `sort` need not wait for Map/Set. Define support for
  noncopyable and reference-containing elements, comparator access and
  fallibility, stability, failure guarantees, and mutating versus value-returning
  APIs.

### 8. Collections

- Map/Set hashing, equality, key-mutation rules, ownership, and ordered variants.
  Build on storage, tuples, and iteration contracts; Queue/Stack may reuse List.

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
