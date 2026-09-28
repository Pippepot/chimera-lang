# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules; this document tracks the implemented foundation and next priorities. Settle missing semantics there before implementation. Legacy parity is not a goal.

## Current foundation

- Incremental queries retain stable declaration and type identities, diagnostics, owned results, and equal-result reuse.
- Folder modules, file-scoped imports, re-exports, qualified lookup, entry-only execution, and directory refresh are implemented. The embedded `std.prelude` is implicitly imported by user files, with an explicit-import override.
- Named and generated structs have nominal identity, namespace members and instance calls, layout, field operations, and validated move/copy/drop hooks.
- Typed SSA covers calls, static specialization, callable values, variants, joins, loops, divergence, and fallible control flow. Compile-time thunks and specialized calls evaluate through typed IR, including structs, hooks, and type-valued functions; local captures remain unsupported.
- Ownership tracks root and supported field transfers, borrowed and owned parameters, mutable copy-back, inferred `Ref` origins, and path-sensitive ASAP cleanup. The internal calling convention derives direct or address-passed arguments from ownership capabilities; codegen owns physical argument layout. `Box` and `Buffer` provide host storage; `Ref` and scoped aliases retain checked origins for named places and supported fields, but not temporary projections.
- Compiler-provided `extern func` declarations use named std identities and ordinary calls. `std.exit.exit` is exported by the prelude, with distinct runtime termination and compile-time compiler control.
- Host-only `std.memory` provides checked typed allocation, unsafe indexed
  transfers and destruction, `Box(T)` with automatic destruction, copyable
  `Ref(T, writable)` handles with checked origins, and `Buffer(T)` with borrowed
  `BufferView(T)` slices. `Box.new` constructs directly movable values or
  initializes immovable structs in final storage; explicit duplication allocates
  distinct storage. Consuming extraction requires directly movable values.
  `Box` and `Ref` are prelude exports. Scoped writable aliases and checked
  `Buffer.get_mut` are supported. [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md)
  records the host storage model and accepted cross-target design.
- Successful whole-program executables, typed runtime function bodies, and compiled functions persist in a content-addressed cache. Query snapshots restore interned identities and validate observed source inputs and equal-result query boundaries before reuse. Cache publication is atomic across compiler processes. Independent file and function queries use multiple workers.
- Aggregate reference origins retain field, variant, and owned-element projections through copies and joins. Writable effects apply across ordinary, indirect, and fallible calls, custom copy/move hooks, and scheduled destructor hooks; Box construction and extraction preserve contained origins. Initialized raw-allocation contents retain conservative origins, while empty allocations do not imply live elements.

## Priority and dependencies

Build on the host storage and reference foundation to expand the language toward
text, generic collections, and ordinary iteration. Independent slices can
proceed earlier. Each language slice covers diagnostics, execution, ownership,
and incremental recomputation; reject unsupported forms at their owning boundary.

## Ordered milestones

### 1. Static signature constraints (implemented)

- Function signatures accept ordered, fallible `where` conditions after the
  return type and optional `from(...)` contract, on the signature line or
  following lines. Demanded specializations evaluate them using static values;
  runtime captures and failed constraints are rejected without changing the
  callable type. Static type subsets and namespace member types, including
  callable types and absent members, are supported by `is`.

### 2. Text and basic I/O

- Define UTF-8 string literals and a `std` **String** exported through
  `std.prelude`. Specify its representation and ownership on the pointer/storage
  foundation: literal bytes can have static storage, while growing owned text
  needs allocation. Do not require every string value to be heap-allocated.
- Add compiler-provided runtime text output and fallible byte input/output
  through ordinary declarations; specify write failures, UTF-8 validation,
  borrowing for slices, and cleanup. Compile-time execution retains no ambient
  I/O.

### 3. Ranges, List, and iteration

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

### 4. Structural tuples

- Implement ordered structural identity for `(foo, bar)` with type spelling,
  access, destructuring, layout, and elementwise ownership. Resolve grouping
  and singleton syntax alongside `()`; tuples support multiple results and
  later Map iteration.

### 5. Match

- Evaluate the subject once; add literal, wildcard, binding, `pattern as name`,
  and `is Type` patterns. Diagnose redundancy and non-exhaustiveness using
  existing branch joins and variant mappings.

### 6. Numeric foundations

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

### 7. Collections and algorithms

- Add **Map**, **Set**, **Queue**, and **Stack** on established storage and
  iteration contracts. Specify hashing/equality, ordering, mutation, and
  ownership; Queue/Stack may reuse List.
- Grow the standard library as prerequisites land: **swap**, **reverse**,
  **sort**, and numeric **math**. Decide comparator, stability, fallibility,
  and mutating/value-returning APIs for each.

## Deferred or independent work

- Borrowing temporary projections needs a lifetime-extension rule beyond the
  currently supported named places and dereferenced Refs.
- Shared owners require specified atomic ownership, weak-reference, and cycle
  behavior before implementation.
- General overloading, function literals, closures, postfix `?`, `sizeof`,
  and return-type inference need separate language decisions.
- Extra targets need use cases. Before enabling non-host allocation for one,
  resolve its layout and compatible types for its location, provide a
  resource-backed allocator and supported address-space access, and verify
  its zero-byte success or failure behavior. Do not reuse host layout or
  pointer-based access. Keep raw-address and foreign-memory operations deferred.
- Finer-grained invalidation needs measurements. Decide separately whether
  unreachable declarations should be validated
  (currently only demanded signatures, bodies, and values are diagnosed).
