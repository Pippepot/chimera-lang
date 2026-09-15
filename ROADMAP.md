# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) is authoritative but incomplete. Make missing language decisions before implementing dependent behavior; legacy parity is not a goal.

## Current foundation

- Incremental queries preserve stable declaration and type identities, owned results, diagnostics, and equal-result retention.
- Typing publishes one SSA control-flow graph with fallible edges, joins, loops, calls, callable values, variants, and divergence.
- Structs have nominal identity, cycle-checked layout, source-ordered initialization, field access, field updates through mutable local roots, and validated move/copy/drop strategy overrides.
- Function-valued struct properties receive stable owner-qualified item identities, reuse ordinary signature and body queries without entering module scope, and are validated against exact copy/move/drop signatures. Typing lowers custom hooks to ordinary direct calls, recursively composes fieldwise struct and active-variant operations, and suppresses redispatch only for compiler-generated plumbing inside the active hook.
- Callable declarations and types share ordered mode/type parameter records. Function declarations support omitted or explicit `imm`, borrowed `mut`, owned `var`, and cleanup-authorized `deinit`; inferred callable values retain exact modes. Mutable arguments require exact-typed mutable places and reject overlapping immutable or mutable argument paths.
- Lexical const and var bindings have stable root-place identities. Typing tracks available, transferred, and possibly transferred states through branches and loops; whole assignment restores a mutable root.
- Bare place values borrow in observation and `imm` calls. Bindings, replacement assignments, struct fields, returns, and owned calls require copy support; `^` explicitly transfers movable local roots. Owned temporaries pass directly. `var` and `deinit` parameters are mutable owned roots, with only `deinit` authorized to satisfy explicit drop. Partial-field transfer remains rejected.
- Query-local generation analysis computes and materializes path-sensitive cleanup at the earliest completed boundary after each final use. It covers roots, parameters, temporaries, calls, projections, conditional ownership, control-flow edges, and whole-root replacement; field-target replacement remains boundary-local until partial places are implemented. Explicit-drop trees must transfer or reach a `deinit` parameter on every path. Automatic custom drop lowers to ordinary typed IR, while trivial and hook-free fieldwise cleanup require no runtime instruction.

## Priority and dependencies

Build toward small programs that use an always-included standard library,
generic collections, and ordinary iteration. Prioritize modules, external
declarations, and specialization as foundations for that library. Specify
advanced ownership storage alongside the pointer and collection operations
that need it.

The order below is the default implementation priority, not a requirement to
finish every item in one milestone before starting independent work. Proposed
features and decisions marked TBD are planning commitments, not settled language
rules. Record their semantics in `syntax&semantics.txt` before implementation.
Each slice must cover diagnostics, execution, ownership paths, and incremental
recomputation. Keep unsupported forms rejected at their owning boundary.

## Ordered milestones

### 1. Lifetime analysis, control flow, and callable expressions

- **Last-use destruction:** replace scope-exit scheduling with Mojo-style ASAP
  destruction, including subexpression boundaries. Start with supported values
  and non-escaping borrows, then extend the same analysis to origins and views
  in milestone 6. Account for cleanup uses, reassignment, branches, loops, and
  every exit path. Specify ordering when several lifetimes end together and
  explicit lifetime-extension syntax. Test observable destructor order and
  preserve explicit-drop obligations; this is a semantic change, not an
  optional optimization.
- **Match:** evaluate the subject once; support literal, wildcard, binding,
  `pattern as name`, and `is Type` patterns; diagnose redundancy and
  non-exhaustiveness; reuse existing branch joins and variant mappings.
- **Captureless function literals:** assign stable nested declaration identities,
  reuse signature/body/reachability queries, and reject captures. These provide
  callbacks for later collection algorithms. Defer closures.

### 2. Numeric foundations

- Define **explicit numeric conversions/casts first**: syntax, supported source
  and destination types, failure behavior, rounding, and overflow. Existing
  variant extraction with `as` does not provide numeric conversion semantics.
- Specify integer division and add **byte**, deciding its arithmetic behavior,
  literal typing, and relationship to integer types.
- Then specify **numeric coercions (TBD)**: whether conversions may be implicit,
  mixed numeric operations, and their interaction with literal typing. Publish
  accepted conversions in typed IR rather than rediscovering them in codegen.
- Specify the full **float** model (representation, literals, conversions,
  arithmetic, comparison, and exceptional values), then implement it as one
  scalar slice. This supports the standard library's floating-point math.
- Evaluate additional integer widths, including **u31** and **i128**, and whether
  custom bit/byte lengths are supported. Exact widths, storage layout, alignment,
  arithmetic, and ABI behavior are TBD; these optional extensions need not block
  byte, float, or the first library.

### 3. Modules and struct namespaces

- **Modules:** specify cross-file declarations, imports, qualified lookup,
  visibility, and cycle rules. Preserve declaration identity and track source
  dependencies across files. Start with the module support needed to organize
  the standard library; package distribution can wait.
- **Functions defined inside a struct namespace:** these are namespace
  declarations; functions used with instance call syntax declare an explicit
  receiver parameter. Implement the specified qualified-call desugaring and
  ordinary argument modes. Resolve lookup and name conflicts before
  implementation. Reuse owner-qualified
  function identities while keeping ordinary namespace functions separate
  from validated copy/move/drop properties and instance layout.

### 4. External declarations and standard-library bootstrap

- Add **external** for compiler-defined functions and externally defined
  functions, including **C ABI** calls. Specify how declarations identify their
  implementation, symbol, and calling convention; compiler-defined behavior and
  foreign ABI calls have distinct implementation requirements.
- Establish runtime-symbol linking and the supported foreign argument, return,
  layout, and ownership boundary. The current internal calling convention is
  not a C ABI. Expand supported foreign signatures in explicit slices.
- Replace dedicated `exit` handling with a runtime declaration as part of this
  work; remove the temporary intrinsic machinery.
- Bootstrap an **always-included standard library** using modules and external
  declarations where needed. Include **sqrt** among the common functions
  available unqualified; settle the rest of that set and name-conflict rules.
  Add initial **math functions** as numeric support permits; define allocation
  and release services for later pointers and collections. Exact APIs and
  compiler/library placement remain open.

### 5. Specialization and structural tuples

- **Compile-time specialization:** use generic pointer and collection APIs as
  the concrete requirements for `static` parameters, general `comptime`, and
  specialization arguments in `InstanceId`. Specify the supported compile-time
  operations and failure behavior; preserve incremental instance reuse.
- **Structural tuples**, such as `(foo, bar)`: implement the specified ordered,
  unnamed structural identity. Specify type spelling, element access,
  destructuring, layout, and elementwise ownership.
  Resolve grouping and singleton syntax consistently with the existing `()`
  unit value. Tuples support multiple values and later map iteration; they can
  be implemented independently of specialization.

### 6. Storage, origins, pointers, and borrowed views

- Specify **partial-field transfer** and **final storage for immovable values**,
  including partial initialization, cleanup, stable addresses, and calling
  conventions. Implement each when required by a concrete operation rather
  than making all storage work a prerequisite for unrelated language features.
- Implement **Pointer**, **OwnedPointer**, and **ArcPointer** with the Mojo 1.0
  semantics recorded in `syntax&semantics.txt`. The requested **UnsafePointers**
  capability belongs to unified Pointer's explicitly unsafe operations, rather
  than a separate type. [Mojo's pointer guide](https://mojolang.static.modular.com/docs/manual/pointers/)
  and [1.0 release notes](https://mojolang.static.modular.com/releases/v1.0.0/)
  are the versioned design reference.
- Before choosing representations, separate pointee type, mutability, origin,
  ownership, and allocation policy. Implement origin-based lifetime and aliasing
  checks and connect them to last-use destruction. Track dependencies through
  returned and stored borrows, including multiple possible origins and
  collection element invalidation. Define construction, dereference, and origin
  syntax; map pointer APIs and foreign memory access to this language's parameter
  and ownership rules. Existing non-escaping `mut` calls do not provide the
  required lifetime tracking.
- **Borrowed views:** support non-owning views that can be returned and stored
  while preserving backing-data lifetime and access restrictions. Define the
  first view API alongside List slices and iteration; infer origins where
  possible and expose them in borrowing contracts when needed. Test owner
  destruction timing, escaping views, and invalidation by storage changes.
- Establish low-level storage and **Pointer**, then **OwnedPointer** and the
  collection operations that use it; add **ArcPointer** afterward. Decide the
  compiler/standard-library boundary and specify API details for shared mutation,
  cycles/weak references, and explicit-drop compatibility using Mojo's contracts.
  Preserve the chosen non-nullability, unique ownership, and atomic shared
  ownership guarantees while settling those details.

### 7. Ranges, List, and iteration

- **Ranges:** implement the specified exclusive/inclusive bounds and ascending
  empty-range behavior. Specify endpoint types, explicit descending iteration,
  steps, and overflow-safe termination.
  Decide whether `Range` is a library type with language syntax support.
- Implement a generic **List** as the first collection using the established
  allocation, ownership, and specialization contracts. Specify indexing,
  bounds failures, growth, element replacement/removal, and cleanup.
- Add **`for x in iterable`** for a Range, List, other collections, and custom
  types conforming to an iteration contract. **How a type conforms is TBD**;
  do not assume a trait system or hard-code a closed set of iterable types.
- Implement read-only iteration by default; specify explicit mutation and
  consumption syntax. Specify iterable evaluation, item binding lifetimes,
  iterator state, exhaustion, mutation during iteration, and cleanup on normal
  exit, `break`, `continue`, return, and failure. Decide loop result semantics
  and reuse the existing control-flow and ownership machinery. A range-only
  slice can precede List, but must fit the same intended iteration contract.

### 8. Collection and algorithm library

- Add **Map**, **Set**, **Queue**, and **Stack**. Decide representations and
  whether Queue/Stack reuse List storage; do not assume each needs a compiler
  type. Specify equality/hash requirements for Map/Set and iteration order,
  mutation, and ownership behavior for every collection.
- Add standard-library **reverse**, **sort**, and **swap**, and expand **math
  functions**. Specify mutating versus value-returning APIs, comparator and
  ordering contracts, sort stability, and ownership/aliasing requirements.
  Ship individual functions as soon as their prerequisites exist.
- **Operator functions (TBD):** decide declaration syntax, lookup, admissible
  operators, operand modes, result types, and fallibility using concrete numeric
  or collection examples. Coordinate with coercions and namespace functions;
  ordinary named functions can support the initial library.

## Other open or deferred work

- General overloading and closures need separate semantic decisions; namespace
  calls, iteration conformance, and operator functions do not implicitly settle
  either feature.
- Persistent caching and extra targets need an explicit use case.
- Finer-grained source invalidation and parallel CLI compilation require measured
  evidence that current whole-file dependencies or scheduling are limiting.
- Decide whether the CLI should validate unreachable declarations; current
  compilation intentionally diagnoses only demanded signatures, bodies, and values.
- Specify postfix `?`, `sizeof`, and return-type inference before implementation.
- Remove `legacy/` only after active tooling has replacement regressions.
