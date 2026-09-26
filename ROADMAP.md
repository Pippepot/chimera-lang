# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules; this document tracks the implemented foundation and next priorities. Settle missing semantics there before implementation. Legacy parity is not a goal.

## Current foundation

- Incremental queries retain stable declaration and type identities, diagnostics, owned results, and equal-result reuse.
- Folder modules, file-scoped imports, re-exports, qualified lookup, entry-only execution, and directory refresh are implemented. The embedded `std.prelude` is implicitly imported by user files, with an explicit-import override.
- Named and generated structs have nominal identity, namespace members and instance calls, layout, field operations, and validated move/copy/drop hooks.
- Typed SSA covers calls, static specialization, callable values, variants, joins, loops, divergence, and fallible control flow. Compile-time thunks and specialized calls evaluate through typed IR, including structs, hooks, and type-valued functions; local captures remain unsupported.
- Ownership tracks whole-root transfers, borrowed and owned parameters, mutable copy-back, and path-sensitive ASAP cleanup. The internal calling convention derives direct or address-passed arguments from ownership capabilities; codegen owns physical argument layout. Partial-field transfer, general stable storage for immovable values, and origin-aware pointers/views remain open.
- Compiler-provided `extern func` declarations use named std identities and ordinary calls. `std.exit.exit` is exported by the prelude, with distinct runtime termination and compile-time compiler control.
- Host-only `std.memory` provides checked, fallible typed allocation and explicit deallocation, unsafe element transfer for directly movable elements, and `Ref(T)` with automatic destruction. `Ref.new(value)` infers `T`, while `Ref(T).new(value)` specializes it explicitly; both construct directly movable values or initialize immovable structs with directly movable fields in final storage. Consuming extraction remains limited to directly movable values. `Ref` is exported by the prelude. Zero-byte host allocations succeed with a distinct, stable address; recursive in-place construction, explicit duplication, and safe `Borrow` origins remain open.
- Successful whole-program executables, typed runtime function bodies, and compiled functions persist in a content-addressed cache. Query snapshots restore interned identities and validate observed source inputs and equal-result query boundaries before reuse. Cache publication is atomic across compiler processes. Independent file and function queries use multiple workers.

## Priority and dependencies

Establish storage and reference foundations before expanding the language toward
text, generic collections, and ordinary iteration. Independent slices can
proceed earlier. Each language slice covers diagnostics, execution, ownership,
and incremental recomputation; reject unsupported forms at their owning boundary.

## Ordered milestones

### 1. Storage, allocation, and references

Use [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md) as the design note;
record accepted contracts in [syntax&semantics.txt](syntax&semantics.txt) before
implementing them. Value construction and binding do not choose allocation.
Keep value type, allocation provider, memory location, target-aware layout,
address space, lifetime origin, and access mutability distinct.

Implemented host subset:

- `std.memory.allocate(T, count)` derives the host layout from `T`, rejects
  negative counts and size overflow through fallible control flow, and reserves
  a distinct address even for zero-byte requests. `Allocation(T)` owns
  uninitialized storage with explicit drop;
  `deallocate` consumes it without destroying elements. `unsafe_initialize`
  and `unsafe_take` transfer directly movable elements with caller-proven bounds
  and initialization state.
- `Ref.new(value)` infers `T`, and `Ref(T).new(value)` fallibly constructs a `Ref(T)` for directly movable,
  automatically droppable `T`. Moving the owner preserves its storage; last-use
  destruction destroys `T` and frees the allocation, while `value` consumes the
  owner and extracts `T`. `Ref` is a prelude export; low-level
  allocation requires an explicit `std.memory` import.
- `Ref.new(T{...})` or `Ref(T).new(T{...})` also initializes an immovable or custom-move struct
  directly in its allocation when its fields can move directly. Fields evaluate
  once in source order and are cleaned up on failure. Destruction runs in the
  allocation; `value` cannot extract a `T` that does not move directly.

Resolved storage contract (non-host APIs are not yet implemented):

- Target-specific element layout and memory location are validated together;
  the typed request binds layout to type and count, while provider policy stays
  independent. The owner retains deallocation authority. Address space belongs
  to access, not the value type. Successful zero-byte allocations retain distinct,
  stable identities; a provider that cannot supply one fails the request.
- The host layout query, mmap provider, and pointer-based access emitters are
  explicitly host-only. Target-neutral allocation sizing checks element strides
  and count overflow, including for zero-count requests.

Remaining work:

- Extend in-place construction to nested immovable fields and other initializer
  forms, and provide explicit duplication of copyable `T` into a new allocation.
  Add the missing unsafe indexed destruction and borrowing operations on
  `Allocation` before exposing safe initialized access.
- Implement `Borrow(T)` as a non-owning, non-null reference to a live initialized
  value. Copying it must not copy `T` or acquire ownership; mutation depends on
  the access path and aliasing rules. Re-export it from `std.prelude` once its
  origin checks exist.
- Extend generation-based lifetime and aliasing checks to borrows from locals,
  allocations, owners, and collections, including returned/stored borrows,
  transfers, last-use destruction, and invalidation when storage changes.
  Conservatively retain every possible source of a borrow, including borrowed
  inputs to bodyless calls. Reject returned borrows with no inferable origin
  and other unprovable origins at compile time, without user origin annotations.
  Specify partial-field transfer, initialization, cleanup, and address stability
  where they affect these operations; today's non-escaping `mut` calls do not
  establish the needed lifetime guarantees.
- Build collection storage on `Allocation(T)` with initialized length and
  capacity. Borrowed text and List views must follow the same lifetime and
  storage-change invalidation rules. Defer atomic shared ownership until its
  supported locations, mutation, weak references, and cycle behavior are set.

Mojo 1.0 is a design reference, not the naming contract; see its
[pointer guide](https://mojolang.static.modular.com/docs/manual/pointers/) and
[release notes](https://mojolang.static.modular.com/releases/v1.0.0/).

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
