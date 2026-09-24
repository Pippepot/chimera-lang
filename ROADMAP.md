# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules; this document tracks the implemented foundation and next priorities. Settle missing semantics there before implementation. Legacy parity is not a goal.

## Current foundation

- Incremental queries retain stable declaration and type identities, diagnostics, owned results, and equal-result reuse.
- Folder modules, file-scoped imports, re-exports, qualified lookup, entry-only execution, and directory refresh are implemented. The embedded `std.prelude` is implicitly imported by user files, with an explicit-import override.
- Named and generated structs have nominal identity, namespace members and instance calls, layout, field operations, and validated move/copy/drop hooks.
- Typed SSA covers calls, static specialization, callable values, variants, joins, loops, divergence, and fallible control flow. Compile-time thunks and specialized calls evaluate through typed IR, including structs, hooks, and type-valued functions; local captures remain unsupported.
- Ownership tracks whole-root transfers, borrowed and owned parameters, mutable copy-back, and path-sensitive ASAP cleanup. Partial-field transfer, stable storage for immovable values, and origin-aware pointers/views remain open.
- Compiler-provided `extern func` declarations use named std identities and ordinary calls. `std.exit.exit` is exported by the prelude, with distinct runtime termination and compile-time compiler control.
- Successful whole-program executables, typed runtime function bodies, and compiled functions persist in a content-addressed cache. Query snapshots restore interned identities and validate observed source inputs and equal-result query boundaries before reuse. Cache publication is atomic across compiler processes. Independent file and function queries use multiple workers.

## Priority and dependencies

Make incremental compilation durable and parallel before expanding the language
toward generic collections and ordinary iteration. Independent slices can
proceed earlier. Each language slice covers diagnostics, execution, ownership,
and incremental recomputation; reject unsupported forms at their owning boundary.

## Ordered milestones

### 1. Persistent and parallel incremental compilation — complete

- The executable cache checks every loaded source byte and module path. Runtime
  function analysis and machine code snapshots retain the exact interned-ID
  table and each result's observed
  input and query dependencies. Changed inputs or changed query outputs trigger
  recomputation; successful, diagnostic-free results alone are persisted.
- Cache files use checksums and atomic replacement so concurrent compiler
  processes can read and write them. Query workers compile independent files and
  functions in parallel. The multi-file benchmark must show more than one worker
  beating one worker; concurrent compiler processes must safely read and save
  the same cache. Cold, warm, edited, corrupt-cache, and concurrent-run tests
  cover these paths.

### 2. Storage and pointer foundations

- Define **byte** representation, literals, and its relationship to `int`
  before byte-oriented storage and I/O; leave mixed numeric coercions for
  milestone 7.
- Specify partial-field transfer and stable storage for immovable values as
  concrete pointer/collection operations require them, including initialization,
  cleanup, and address stability.
- Separate pointee type, mutability, origin, ownership, and allocation policy.
  Implement origin-based lifetime and aliasing checks across returned/stored
  borrows and last-use destruction; current non-escaping `mut` calls are
  insufficient.
- Implement non-null **Pointer** (including explicitly unsafe operations), then
  unique **OwnedPointer** and allocation/release for collections. Add borrowed
  views for text and List slices, including storage-change invalidation. Add atomic
  **ArcPointer** later, after shared mutation and weak/cycle behavior are
  specified. Record the chosen language contracts in
  [syntax&semantics.txt](syntax&semantics.txt), using Mojo 1.0 as the versioned
  design reference; see the
  [pointer guide](https://mojolang.static.modular.com/docs/manual/pointers/)
  and [release notes](https://mojolang.static.modular.com/releases/v1.0.0/).

### 3. Text and basic I/O

- Define UTF-8 string literals and a `std` **String** exported through
  `std.prelude`. Specify its representation and ownership on the pointer/storage
  foundation: literal bytes can have static storage, while growing owned text
  needs allocation. Do not require every string value to be heap-allocated.
- Add compiler-provided runtime text output and fallible byte input/output
  through ordinary declarations; specify write failures, UTF-8 validation,
  borrowing for slices, and cleanup. Compile-time execution retains no ambient
  I/O.

### 4. Ranges, List, and iteration

- Implement exclusive/inclusive ascending ranges and empty-range behavior.
  Decide endpoint types, descending iteration, steps, overflow-safe termination,
  and whether `Range` is a library type with syntax support.
- Implement generic **List** with allocation, indexing/bounds behavior, growth,
  replacement/removal, and cleanup.
- Define an open iteration contract for Range, List, and user types before
  implementing `for x in iterable`; do not hard-code iterable types or assume
  traits. Start with read-only items, then specify mutation/consumption,
  iterator state and invalidation, loop results, and cleanup on every exit path.
  Range-only iteration may precede List if it uses that contract.

### 5. Structural tuples

- Implement ordered structural identity for `(foo, bar)` with type spelling,
  access, destructuring, layout, and elementwise ownership. Resolve grouping
  and singleton syntax alongside `()`; tuples support multiple results and
  later Map iteration.

### 6. Match

- Evaluate the subject once; add literal, wildcard, binding, `pattern as name`,
  and `is Type` patterns. Diagnose redundancy and non-exhaustiveness using
  existing branch joins and variant mappings.

### 7. Numeric foundations

- Define explicit conversions first: syntax, supported types, overflow,
  rounding, and failure. Settle implicit coercions and mixed operations
  separately, publishing conversions in typed IR.
- Specify and implement **float** representation, literals, arithmetic,
  comparisons, conversions, and exceptional values before floating-point
  library math. Additional widths (`u31`, `i128`, custom widths) are optional
  follow-ups.
- Specify operator-function declarations and lookup using `int.+` as the first
  case: operand modes, precedence, result and failure types, and whether
  compiler-owned primitive types can have `std`-defined namespace functions.
  Extend to float and user structs after their semantics are settled; do not
  assume general overloading follows from operator lookup.

### 8. Collections and algorithms

- Add **Map**, **Set**, **Queue**, and **Stack** on established storage and
  iteration contracts. Specify hashing/equality, ordering, mutation, and
  ownership; Queue/Stack may reuse List.
- Grow the standard library as prerequisites land: **swap**, **reverse**,
  **sort**, and numeric **math**. Decide comparator, stability, fallibility,
  and mutating/value-returning APIs for each.

## Deferred or independent work

- General overloading, function literals, closures, postfix `?`, `sizeof`,
  and return-type inference need separate language decisions.
- Extra targets need use cases; finer-grained invalidation needs measurements.
  Decide separately whether unreachable declarations should be validated
  (currently only demanded signatures, bodies, and values are diagnosed).
