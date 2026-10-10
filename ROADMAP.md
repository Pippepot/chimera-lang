# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules;
[ARCHITECTURE.md](ARCHITECTURE.md) describes the compiler. This file tracks future
work and its priority, not completed features or implementation history.

Settle missing semantics before implementation. Each milestone covers
diagnostics, execution, ownership, and incremental/cache behavior. Legacy parity
is not a goal.

## Ordered milestones

### 3. Ranges, List, and iteration

- Inclusive/exclusive ranges: endpoint types, direction, steps, empty ranges,
  overflow-safe termination, and library versus syntax responsibilities.
- List removal and dynamic mutation of reference-containing elements, with alias
  invalidation and failure cleanup.
- An open `for` contract for ranges, collections, and user types. Start with
  read-only items; define mutation/consumption, loop results, and exit cleanup.

### 4. Structural tuples

- Tuple identity, type spelling, access, destructuring, layout, and elementwise
  ownership. Resolve grouping/singletons; support multiple results and Map items.

### 5. Match

- Single subject evaluation; literal, wildcard, binding, `pattern as name`, and
  `is Type` patterns. Diagnose redundancy and non-exhaustiveness.

### 6. Numeric foundations

- Nondecimal integer literals and magnitudes beyond the current signed-64-bit
  literal representation; define spelling, typing, and range diagnostics.
- Named wrap/truncate/round/saturate/widen conversions with explicit overflow
  and failure rules; no converters between numeric runtime types.
- Float representation, literals, operations, conversions, and exceptional
  values before library math. Mixed operations and extra widths need decisions.

### 7. Collections and algorithms

- Map/Set hashing, equality, ordering, mutation, and ownership; Queue/Stack may
  reuse List. Build on storage and iteration contracts.
- `swap`, `reverse`, `sort`, and numeric math as prerequisites land. Define
  comparator, stability, failure, and mutating versus value-returning APIs.

## Deferred or independent

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
