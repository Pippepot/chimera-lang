# Roadmap

[syntax&semantics.txt](syntax&semantics.txt) owns language rules; this document tracks the implemented foundation and next priorities. Settle missing semantics there before implementation. Legacy parity is not a goal.

## Current foundation

- Incremental queries retain stable declaration and type identities, diagnostics, owned results, and equal-result reuse.
- Folder modules, file-scoped imports, re-exports, qualified lookup, entry-only execution, and directory refresh are implemented. The embedded `std.prelude` is implicitly imported by user files, with an explicit-import override.
- Named and generated structs have nominal identity, namespace members and instance calls, layout, field operations, and validated move/copy/drop hooks.
- Struct fields are private to their defining module by default; `pub` publishes
  individual fields in declared and generated definitions. Initialization,
  reads, writes, borrows, consuming moves, and callable fields share privacy
  checks, distinct from unknown names. Factory specialization and re-export
  preserve the defining module; every file there can access private fields.
  Public field annotations reject hidden declaration names and private nominal
  types, including callable and variant components and generated type arguments.
  Whole-value ownership operations retain private fields. Runtime, compile-time,
  incremental visibility edits, and snapshot reuse are covered. `std.memory`
  storage fields use this general rule without name-matched exceptions.
- Function signatures support ordered `where` conditions checked at specialization
  using static values, including type and namespace member tests with `is`.
- Type-namespace operation functions cover arithmetic, all comparisons, unary
  `neg`/`not`, and `[]`/`[]=`. Explicit members and callable values share exact
  compiler-specified signature validation, including rejection of three-operand
  addition. Lookup uses the left operand's namespace with ordinary visibility
  and static specialization, independently of imports. `int` and `bool` expose
  compiler-owned standard namespaces. Boolean expressions and calls can be
  conditions; `and`/`or`, type inspection, assignment, and transfer retain their
  dedicated semantics. Root, field, reference, and indexed compound assignment
  reuse binary operations and ownership-aware replacement. Native/compile-time
  parity, invalid signatures, failure evaluation order, ownership hooks,
  generic lookup, signature/visibility edits, and snapshot reuse are covered.
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
- Fallible invocations use `callee?(args)` in ordinary expression contexts;
  only a context requiring that specific call to be fallible permits omission.
  Direct and binding conditions, logical conditions, and `where` conditions
  retain unmarked calls; comparisons and extraction require markers on their
  call operands. Direct, namespace, instance, indirect, specialized, returned,
  deferred, and type-valued calls share the rule. Markers on ordinary callables
  and general postfix `?` are rejected. Validation precedes eager arguments
  once the callable's fallibility is known. Runtime, compile-time, ownership,
  incremental recomputation, and snapshot reuse retain ordinary failure behavior.
- Nonescaping `init` parameters construct or forward exactly once on successful
  paths through direct, generic, and indirect calls. Complete expression inference,
  immovable destinations, captured writes, guarded root/field transfers, and
  ordinary success/failure work in native execution and the interpreter's
  scalar/aggregate subset. All consumption into a destination is potentially
  fallible, including for literals; `func` cannot acquire hidden failure.
  Initializers reject caller-directed return, break, and continue while permitting
  local loop exits. Bare `fail` propagates ordinary failure from fallible
  functions and initializer regions. Failure can skip construction; writes and
  completed transfers survive it, and partial fields clean before receiving frames unwind.
  Native checked references cross forwarding. The interpreter supports scalar
  and inline-array checked-reference operations, but not heap allocation.
  Query/cache reuse and incremental edits account for modes, effects, ownership
  capabilities, boundaries, and fallibility.
  Box construction and raw slot initialization are ordinary init consumers,
  including aliases and callable values.
- Ownership tracks root and supported field transfers, borrowed and owned parameters, mutable copy-back, inferred `Ref` origins, and path-sensitive ASAP cleanup. `deinit` consumes owned roots and fields in place, including conditional and loop selections, constructs fresh arguments in call-lived storage, rejects borrowed sources, and lets custom move hooks transfer fields. Storage joins retain addresses independently of movability. Unfinished sources clean up remaining automatic fields without waiving explicit-field obligations. Later argument failure, contained reference origins, runtime and compile-time execution, and parameter-mode and movability edits across query/cache reuse are covered. Derived `argumentPassing` selects direct or address-passed arguments without a duplicate ownership-capability field; arrays and containing structs or variants use destinations independently of direct movability. Codegen owns physical argument layout. `Box` and `Buffer` provide host storage; `Ref` and scoped aliases retain checked origins for named places and supported fields, but not temporary projections. All runtime inputs capable of supplying origins conservatively contribute to function return dependencies; signatures have no `from` clauses or explicit narrowing contracts.
- `Array(T, N)`, exported by `std.prelude`, has canonical structural identity
  `{ element_type, length }`, with nonnegative static `int` length and checked
  size at natural element alignment, including zero-length arrays. Storage is
  contiguous and inline, with no heap header: local, embedded, boxed, and returned
  arrays follow their owner's storage or receiving destination.
  `Array(T, N).filled(imm value: T)` evaluates its argument once and performs
  `N` ordinary copies, including custom hooks. It requires element copy support
  even for `N = 0`, when the argument still evaluates but no copies run. Empty
  arrays themselves are trivial, contain no reference origins, and impose no
  element-hook obligations. Nonempty whole-array copy, move, and drop operations
  compose element capabilities and lower through typed loops. Fallible `get`
  and `get_mut` return bounds-checked immutable or writable element references.
  Native execution and the interpreter's scalar/inline-array reference subset,
  ownership, incremental recomputation, and snapshot reuse are verified. Static
  array values publish through semantic `array_init` and indexed destination
  stores, not `struct_init`. Collection literals construct directly in final
  element destinations without requiring copies. Default construction
  and individual element consumption are not public APIs. Indexed reads return
  ordinary copies; indexed writes use a deferred initializer after bounds
  validation. Replacement retains checked-reference restrictions: direct move,
  automatic drop, and no borrowed-reference elements. Immovable elements remain
  accessible through `get`/`get_mut`, not copied reads or replacement.
- Compiler-provided `extern` declarations use named std identities and ordinary calls, with fallibility determined by their signatures. `std.exit.exit` is exported by the prelude, with distinct runtime termination and compile-time compiler control.
- Host-only `std.memory` provides checked typed allocation, unsafe indexed
  construction, transfers and destruction, `Box(T)` with automatic destruction,
  copyable `Ref(T, writable)` handles with checked origins, and `Buffer(T)` with
  borrowed `BufferView(T)` slices. `Box.new(init item: T)` allocates before the
  entire initializer through ordinary calls, aliases, and callable values, then
  forwards to explicitly fallible `unsafe_initialize` for construction in the
  final slot; `Allocation.unsafe_init` is fallible too. The constructor explicitly
  deallocates unfinished storage after partial fields clean and propagates with
  `fail`. Buffer growth relocates in reverse order and retains a valid old-buffer
  prefix on initialization failure while destroying the completed replacement
  suffix and releasing its storage. Allocation failure preserves the original
  contents. Inference requires an unevaluated result type;
  `Box(T).new` supplies it for loops and block-local results. Copying into a new
  Box uses ordinary initialization; consuming extraction requires directly
  movable values. Live-reference replacement retains its existing restrictions.
  `Box`, `Ref`, and `List` are prelude exports. Scoped writable aliases and checked
  `Buffer.get_mut` are supported. [syntax&semantics.txt](syntax&semantics.txt)
  owns host storage and cross-target contracts; [ARCHITECTURE.md](ARCHITECTURE.md)
  records representation boundaries and future API design.
- Successful whole-program executables, typed runtime function bodies, and compiled functions persist in a content-addressed cache. Query snapshots restore interned identities and validate observed source inputs and equal-result query boundaries before reuse. Cache publication is atomic across compiler processes. Independent file and function queries use multiple workers.
- Aggregate reference origins retain field, variant, and owned-element projections through copies and joins. Writable effects apply across ordinary, indirect, and fallible calls, custom copy/move hooks, and scheduled destructor hooks; Box construction and extraction preserve contained origins. Initialized raw-allocation contents retain conservative origins, while empty allocations do not imply live elements.
- Named, generated, and expression `static struct` forms retain ordinary nominal
  identity, fields, visibility, namespaces, and ownership hooks. Runtime
  eligibility is independent of ownership and propagates through stored fields,
  array elements (including empty arrays), and variant members. Static-only
  values have no native layout; runtime storage, calls, and raw allocation reject
  them. Construction, mutation, hooks, and ordinary calls work in compile-time
  execution, and static arguments can specialize runtime-capable functions.
- Top-level `converter` declarations support `imm` runtime sources and `static`
  compile-time-only sources, with additional static parameters inferred from
  source and target types. Source/target module ownership and public/private
  visibility determine candidates independently of imports. Known expected
  types and explicit `T(value)` conversions use one ordinary infallible call,
  optionally followed by variant widening. Equal types bypass conversion;
  ambiguity is diagnosed at use and only the selected converter checks `where`.
  Conversion does not participate in inference or chain. Destinations,
  conservative reference origins, mutable argument authority, and left-to-right
  argument evaluation retain ordinary call rules. Frame-local static sources
  specialize from their current interpreted values, including after mutation.
- Decimal integer literals use compile-time-only `int_literal`; directly applied
  unary minus belongs to the literal. Unconstrained literals default to signed
  32-bit `int`, including an expected variant containing `int`. A standard-library
  converter checks the byte range through ordinary `where` conditions. Runtime
  `int` and `byte` do not implicitly convert. The current literal representation
  accepts signed 64-bit values; larger magnitudes, nondecimal literals, and float
  literals remain unsupported. Runtime/compile-time conversions, diagnostics,
  ownership, owning-module edits, and snapshot reuse are covered.
- Collection literals support contextual element conversion, empty and nested
  shapes, and default `Array(T, N)` construction. Their construction-only
  `collection_literal(T, N)` carriers feed consuming `init` converters. Concrete
  effects derive from typed initializer failure exits; infallible literals need
  no ordinary failure handling. Abstract initializers conservatively may fail;
  consuming converters cannot add unrelated ordinary failure. Expected targets
  determine element types through ordinary converter static inference.
- Host `List(T)` supports literal construction, `len`, `capacity`, bounds-checked
  `get`/`get_mut`, and reverse destruction. Elements construct directly in heap
  storage, including immovable elements. Implicit allocation failure terminates
  with status 134 before element evaluation. Explicitly fallible `List(T).from`
  exposes allocation and element failure instead. Ordinary element failure
  destroys the completed prefix, skips remaining elements, and frees storage;
  effects and completed transfers are not rolled back. Native ownership,
  deterministic allocation failure, repeated failed-construction release,
  Array/converter interpreter parity, and snapshot invalidation are covered.
  List and Buffer expose copied indexing and checked indexed replacement;
  BufferView exposes read-only copied indexing. Heap execution remains
  unsupported by the compile-time interpreter.

## Priority and dependencies

Text and basic I/O are the next implementation priority. Operator functions and
indexing now share ordinary namespace calls, static specialization, and checked
references rather than collection-specific compiler rules. Later
milestones expand the converter, inline-array, storage, and reference foundation
toward generic collections and ordinary iteration.
Each language slice covers diagnostics, execution, ownership, and incremental
recomputation; reject unsupported forms at their owning boundary.

## Ordered milestones

### 1. Text and basic I/O

- Define UTF-8 string literals through the literal-type converter model and a
  `std` **String** exported through
  `std.prelude`. Specify its representation and ownership on the pointer/storage
  foundation: literal bytes can have static storage, while growing owned text
  needs allocation. Do not require every string value to be heap-allocated.
- Add compiler-provided runtime text output and fallible byte input/output
  through ordinary declarations; specify write failures, UTF-8 validation,
  borrowing for slices, and cleanup. Compile-time execution retains no ambient
  I/O.

### 2. Ranges, List, and iteration

- Implement exclusive/inclusive ascending ranges and empty-range behavior.
  Decide endpoint types, descending iteration, steps, overflow-safe termination,
  and whether `Range` is a library type with syntax support.
- Extend generic **List** with growth, replacement/removal, and the corresponding
  alias-invalidation and failure-cleanup rules. Literal construction, explicit
  recoverable construction, indexing/bounds behavior, and destruction are
  implemented above.
- Define an open iteration contract for Range, List, and user types before
  implementing `for x in iterable`; do not hard-code iterable types or assume
  traits. Start with read-only items, then specify mutation/consumption,
  iterator state and invalidation, loop results, and cleanup on every exit path.
  Range-only iteration may precede List if it uses that contract.

### 3. Structural tuples

- Implement ordered structural identity for `(foo, bar)` with type spelling,
  access, destructuring, layout, and elementwise ownership. Resolve grouping
  and singleton syntax alongside `()`; tuples support multiple results and
  later Map iteration.

### 4. Match

- Evaluate the subject once; add literal, wildcard, binding, `pattern as name`,
  and `is Type` patterns. Diagnose redundancy and non-exhaustiveness using
  existing branch joins and variant mappings.

### 5. Numeric foundations

- Add named numeric conversion functions (wrap, truncate, round, saturate,
  widen) with specified overflow and failure behavior; converters never relate
  numeric runtime types. Settle mixed operations separately.
- Specify and implement **float** representation, literals, arithmetic,
  comparisons, conversions, and exceptional values before floating-point
  library math. Additional widths (`u31`, `i128`, custom widths) are optional
  follow-ups.

### 6. Collections and algorithms

- Add **Map**, **Set**, **Queue**, and **Stack** on established storage and
  iteration contracts. Specify hashing/equality, ordering, mutation, and
  ownership; Queue/Stack may reuse List.
- Grow the standard library as prerequisites land: **swap**, **reverse**,
  **sort**, and numeric **math**. Decide comparator, stability, fallibility,
  and mutating/value-returning APIs for each.

## Deferred or independent work

- Explicit type-level `where` assertions proving initializer infallibility
  remain deferred. Concrete construction-effect analysis and propagation are
  required by the collection-literal slice above. Keep one `init` mode rather
  than adding an `init fallible` modifier or parallel constructor signatures.
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
- Shared owners remain unnamed and deferred. The proposed control block holds
  one initialized value and synchronized reference counts: copying increments,
  ending an owner decrements, and the final owner destroys the value and releases
  storage. This does not synchronize value access. Specify provider and location
  atomic support and whether strong cycles are forbidden by API design or leak;
  no upgradeable weak-reference type is currently proposed.
- General overloading, function literals, closures, `sizeof`,
  and return-type inference need separate language decisions.
- Extra targets need use cases. Before enabling non-host allocation for one,
  resolve its layout and compatible types for its location, provide a
  resource-backed allocator and supported address-space access, and verify
  its zero-byte success or failure behavior. Do not reuse host layout or
  pointer-based access. Start device buffers with validated scalar elements,
  not arbitrary host structs. Settle address-space spelling and larger count
  types for that concrete target before adding layout queries or a general
  provider dispatcher. Keep raw-address and foreign-memory operations deferred.
- Finer-grained invalidation needs measurements. Decide separately whether
  unreachable declarations should be validated
  (currently only demanded signatures, bodies, and values are diagnosed).
