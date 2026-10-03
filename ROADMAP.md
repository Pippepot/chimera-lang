# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules; this document tracks the implemented foundation and next priorities. Settle missing semantics there before implementation. Legacy parity is not a goal.

## Current foundation

- Incremental queries retain stable declaration and type identities, diagnostics, owned results, and equal-result reuse.
- Folder modules, file-scoped imports, re-exports, qualified lookup, entry-only execution, and directory refresh are implemented. The embedded `std.prelude` is implicitly imported by user files, with an explicit-import override.
- Named and generated structs have nominal identity, namespace members and instance calls, layout, field operations, and validated move/copy/drop hooks.
- Function signatures support ordered `where` conditions checked at specialization
  using static values, including type and namespace member tests with `is`.
- Capability-backed `T.copy` and `T.move` support type-qualified and instance
  calls, aliases, indirect calls, and `where` tests. Callable types retain explicit
  runtime parameter modes. Primitive, callable, variant, declared, and generated
  types share operation selection; runtime and compile-time calls invoke the
  selected hooks once. Reserved names and invalid ownership definitions are
  checked before availability, including capability edits and snapshot reuse.
- Owning initialization of a type that cannot move directly constructs in its
  final destination: bindings, owned arguments, assignments, struct fields,
  variant payloads, conditional and loop results, direct, indirect, and fallible
  call results, ownership members, and function results. Named locals copy or
  explicitly move into a destination, partial construction cleans completed
  fields, and runtime and compile-time execution share the typed destinations.
  Such values keep their storage: field reads and joins view it, mutable locals
  update fields, `mut` arguments, and replacements in place, variant copies and
  transfers construct member by member, and fresh `imm` arguments construct in
  widened temporaries.
- Typed SSA covers calls, static specialization, callable values, variants, joins, loops, divergence, and fallible control flow. Compile-time thunks and specialized calls evaluate through typed IR, including structs, hooks, and type-valued functions; ordinary compile-time thunks cannot capture runtime locals.
- Nonescaping `init` parameters construct or forward exactly once on successful
  paths through direct, generic, and indirect calls. Complete expression inference,
  immovable destinations, captured writes, guarded root/field transfers, and
  caller-directed return, break, and continue work in native execution and the
  interpreter's scalar/aggregate subset. Source failure can skip construction;
  writes survive failure and partial fields clean before receiving frames unwind.
  Native checked references cross forwarding; general compile-time reference and
  allocation execution remains unsupported. Query/cache reuse and incremental
  edits cover modes, effects, ownership capabilities, and lexical exits.
  Box construction and raw slot initialization are ordinary init consumers,
  including aliases and callable values.
- Ownership tracks root and supported field transfers, borrowed and owned parameters, mutable copy-back, inferred `Ref` origins, and path-sensitive ASAP cleanup. `deinit` consumes owned roots and fields in place, including conditional and loop selections, constructs fresh arguments in call-lived storage, rejects borrowed sources, and lets custom move hooks transfer fields. Storage joins retain addresses independently of movability. Unfinished sources clean up remaining automatic fields without waiving explicit-field obligations. Later argument failure, contained reference origins, runtime and compile-time execution, and parameter-mode and movability edits across query/cache reuse are covered. The internal calling convention derives direct or address-passed arguments from ownership capabilities and consuming access; codegen owns physical argument layout. `Box` and `Buffer` provide host storage; `Ref` and scoped aliases retain checked origins for named places and supported fields, but not temporary projections.
- Compiler-provided `extern func` declarations use named std identities and ordinary calls. `std.exit.exit` is exported by the prelude, with distinct runtime termination and compile-time compiler control.
- Host-only `std.memory` provides checked typed allocation, unsafe indexed
  construction, transfers and destruction, `Box(T)` with automatic destruction,
  copyable `Ref(T, writable)` handles with checked origins, and `Buffer(T)` with
  borrowed `BufferView(T)` slices. `Box.new(init item: T)` allocates before the
  entire initializer through ordinary calls, aliases, and callable values, then
  forwards to `unsafe_initialize` for construction in the final slot. Library
  storage guards release unfinished allocations after partial fields clean on
  failure or lexical exit. Inference requires an unevaluated result type;
  `Box(T).new` supplies it for loops and block-local results. Copying into a new
  Box uses ordinary initialization; consuming extraction requires directly
  movable values. Live-reference replacement retains its existing restrictions.
  `Box` and `Ref` are prelude exports. Scoped writable aliases and checked
  `Buffer.get_mut` are supported. [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md)
  records the host storage model and accepted cross-target design.
- Successful whole-program executables, typed runtime function bodies, and compiled functions persist in a content-addressed cache. Query snapshots restore interned identities and validate observed source inputs and equal-result query boundaries before reuse. Cache publication is atomic across compiler processes. Independent file and function queries use multiple workers.
- Aggregate reference origins retain field, variant, and owned-element projections through copies and joins. Writable effects apply across ordinary, indirect, and fallible calls, custom copy/move hooks, and scheduled destructor hooks; Box construction and extraction preserve contained origins. Initialized raw-allocation contents retain conservative origins, while empty allocations do not imply live elements.

## Priority and dependencies

Milestone 1 is the next priority: make initializer failure explicit and prohibit
caller-directed exits across deferred construction. All later milestones are
lower priority and retain their relative order, expanding the host storage and
reference foundation toward text, generic collections, and ordinary iteration.
Each language slice covers diagnostics, execution, ownership, and incremental
recomputation; reject unsupported forms at their owning boundary.

## Ordered milestones

### 1. Explicit initializer failure and control flow

Revise the deferred initializer rules in
[syntax&semantics.txt](syntax&semantics.txt) before implementation. The current
foundation above describes the existing behavior; this milestone replaces its
implicit failure propagation and caller-directed lexical exits.

- Keep `init` as the single parameter modifier. Treat consumption into a
  destination as potentially fallible for every initializer, including literals
  and expressions that cannot actually fail. Handle failure locally or propagate
  it from a declared `fallible` function; remove the exception that lets an
  ordinary `func` propagate failure from an initializer. Forwarding does not
  evaluate the expression; construction handles its potential failure, and
  forwarding calls obey the receiving callable's declared fallibility.
- Make a deferred initializer a control-flow boundary. Reject `return` targeting
  its caller and `break` or `continue` targeting loops outside the initializer;
  do not retarget these exits. Loops inside the initializer retain their own
  `break` and `continue`, and called functions return normally. Ordinary eager
  argument expressions retain their existing caller-directed exits. Preserve
  the boundary through forwarding, aliases, and indirect calls.
- Make raw slot initialization explicitly `fallible`, including
  `unsafe_initialize` and the planned `unsafe_initialize_all`. Use ordinary
  failure handling in `Box.new` to release the allocation after partial
  construction cleanup, and publish the Box only after successful construction.
  Remove `UninitializedStorage` and its helper when direct allocation and
  failure cleanup discharge every ownership path. Settle explicit failure
  propagation after cleanup without manufacturing a failing comparison.
- Preserve allocation-before-evaluation, destination construction, exactly-once
  consumption on successful paths, skipped evaluation on allocation failure,
  and partial-subobject cleanup before storage release. Initializer writes and
  completed transfers are not rolled back. Audit infallible ownership hooks and
  future converters: consuming an initializer must handle failure rather than
  acquire a hidden failure outcome.
- Verify handled and propagated failure, rejected unhandled consumption in
  `func`, infallible arguments accepted by the same fallible consumer, raw
  allocation cleanup, and caller-directed exit rejection versus allowed local
  loop exits and eager argument exits. Cover direct, forwarded, aliased, and
  indirect calls, native execution, the supported compile-time subset, and
  incremental recomputation and cache reuse when modes or fallibility change.
- Defer type-level `where` assertions proving initializer infallibility and any
  effect polymorphism. No `init fallible` modifier or parallel infallible and
  fallible constructor APIs are required. Update
  [ARCHITECTURE.md](ARCHITECTURE.md#deferred-construction) and
  [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md) as the implementation and
  cleanup contracts change.

### 2. Field visibility

Implement field visibility from [syntax&semantics.txt](syntax&semantics.txt).
It replaces the temporary name-matched opaque storage owners in `std.memory`.

- Accept `pub` on declared and generated struct fields and publish visibility
  with the struct definition. Check it at every field projection and
  initializer field name against the defining module of the struct or its
  factory; report privacy distinctly from unknown fields. Reject a `pub` field
  whose type names a declaration hidden from importing modules.
- Remove `accessible_fields`, its name list, and its file-scoped exception.
  `std.memory` fields stay private through the general rule; standard type
  recognition keeps using registered identities. Mark fields `pub` where
  existing tests and examples access imported structs.
- Verify rejected initialization, reads, writes, borrows, and consuming moves
  from other modules; access from every file of the defining module; foreign
  specializations and re-exports; whole-value move, copy, and drop of values
  with private fields; compile-time execution; and incremental recomputation
  when a field gains or loses `pub`.

### 3. Converters and literal types

- Implement `static struct` expressions and named and parameterized declaration
  sugar from [syntax&semantics.txt](syntax&semantics.txt). Preserve ordinary
  nominal identity, visibility, namespace, and ownership rules. Track
  compile-time-only eligibility independently of ownership and propagate it
  through stored struct fields, tuple elements, and variant members; reject
  runtime materialization at the owning type boundary, not as a backend layout
  failure. Static parameters may still feed runtime-capable specializations.
- Verify static struct construction, local mutation, hooks, ordinary calls
  during compile-time execution, static arguments used by runtime functions,
  runtime storage and call rejection, aggregate propagation, aliases, and
  generated identities. Cover diagnostics, incremental recomputation, and
  cache reuse when the modifier or a contained type's runtime eligibility changes.
- Add `converter` declarations owned by the module of their source or target
  type, with pub/private visibility, static parameters inferred from both
  types, and `imm`, `static`, or `init` value parameters as the spec requires.
  Insert conversions only at known expected types, including one variant
  member followed by widening; report missing and ambiguous candidates at the
  use. Add explicit `T(value)`. Publish inserted conversions as ordinary typed
  calls. Static struct sources use static value parameters; their converters
  may construct runtime-capable results at runtime without retaining
  compile-time-only values in runtime storage.
- Give integer literals the `int_literal` type, fold a directly applied unary
  minus into the literal, and replace the compiler's byte literal rule with a
  `std` converter whose `where` clause checks the range.
- Verify diagnostics, reference origins through converters, compile-time
  execution, and incremental recomputation when either owning module adds or
  removes a converter.

### 4. Text and basic I/O

- Define UTF-8 string literals through the literal-type converter model and a
  `std` **String** exported through
  `std.prelude`. Specify its representation and ownership on the pointer/storage
  foundation: literal bytes can have static storage, while growing owned text
  needs allocation. Do not require every string value to be heap-allocated.
- Add compiler-provided runtime text output and fallible byte input/output
  through ordinary declarations; specify write failures, UTF-8 validation,
  borrowing for slices, and cleanup. Compile-time execution retains no ambient
  I/O.

### 5. Ranges, List, and iteration

- Implement exclusive/inclusive ascending ranges and empty-range behavior.
  Decide endpoint types, descending iteration, steps, overflow-safe termination,
  and whether `Range` is a library type with syntax support.
- Implement generic **List** with allocation, indexing/bounds behavior, growth,
  replacement/removal, and cleanup.
- Add `[a, b]` collection literals typed `collection_literal(T, N)`. List's
  `init` converter allocates before constructing elements in place through
  `unsafe_initialize_all`. Reject literals without an expected type until
  `Array(T, N)` exists as their default. Keep deferred construction distinct
  from static struct data: elements execute in the construction phase and may
  be runtime expressions.
- Define an open iteration contract for Range, List, and user types before
  implementing `for x in iterable`; do not hard-code iterable types or assume
  traits. Start with read-only items, then specify mutation/consumption,
  iterator state and invalidation, loop results, and cleanup on every exit path.
  Range-only iteration may precede List if it uses that contract.

### 6. Structural tuples

- Implement ordered structural identity for `(foo, bar)` with type spelling,
  access, destructuring, layout, and elementwise ownership. Resolve grouping
  and singleton syntax alongside `()`; tuples support multiple results and
  later Map iteration.

### 7. Match

- Evaluate the subject once; add literal, wildcard, binding, `pattern as name`,
  and `is Type` patterns. Diagnose redundancy and non-exhaustiveness using
  existing branch joins and variant mappings.

### 8. Numeric foundations

- Add named numeric conversion functions (wrap, truncate, round, saturate,
  widen) with specified overflow and failure behavior; converters never relate
  numeric runtime types. Settle mixed operations separately.
- Specify and implement **float** representation, literals, arithmetic,
  comparisons, conversions, and exceptional values before floating-point
  library math. Additional widths (`u31`, `i128`, custom widths) are optional
  follow-ups.
- Specify operator-function declarations and lookup using `int.+` as the first
  case: operand modes, precedence, result and failure types, and whether
  compiler-owned primitive types can have `std`-defined namespace functions.
  Extend to float and user structs after their semantics are settled; do not
  assume general overloading follows from operator lookup.

### 9. Collections and algorithms

- Add **Map**, **Set**, **Queue**, and **Stack** on established storage and
  iteration contracts. Specify hashing/equality, ordering, mutation, and
  ownership; Queue/Stack may reuse List.
- Grow the standard library as prerequisites land: **swap**, **reverse**,
  **sort**, and numeric **math**. Decide comparator, stability, fallibility,
  and mutating/value-returning APIs for each.

## Deferred or independent work

- Implement local `static` bindings specified in
  [syntax&semantics.txt](syntax&semantics.txt), including ordinary function-call
  initializers, lexical scope, enclosing static parameters, and references to
  local static bindings. The parser currently accepts local bindings, but
  semantic analysis rejects them as nested declarations. Verify that static
  bindings, extracting multi-statement computations into ordinary functions
  where needed, cover every `comptime` use case: inline and block results,
  type-valued results, specialization, runtime-capture rejection, demand-driven
  evaluation, fallible and diverging control flow, ownership, diagnostics,
  incremental recomputation, and cache reuse. If static bindings cover all cases,
  remove the `comptime` keyword from the language and migrate its uses; retain
  it until equivalence is established.
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
