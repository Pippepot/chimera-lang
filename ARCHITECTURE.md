# Architecture

This is a high-level map of the compiler's ownership and stage boundaries. [syntax&semantics.txt](syntax&semantics.txt) owns language rules, [ROADMAP.md](ROADMAP.md) tracks upcoming work and priorities, and [PROGRAM_FLOW.md](PROGRAM_FLOW.md) describes the current queries, invalidation, and result lifetimes in detail.

## Queries and stages

- `src/main.zig` registers source inputs and requests `BuildExecutable`. Compiler queries in `src/queries.zig` coordinate parsing, semantic analysis, typing, compile-time interpretation, and code generation; the engine in `src/query/` schedules and memoizes work without depending on compiler stages. `src/structures.zig` holds shared data, and frontend and backend stages do not import query orchestration.
- The engine records input and query dependencies, including reads of absent inputs. It can run independent queries on workers, but a result publishes only after its dependencies settle. Recomputations commit owned results, dependencies, and diagnostics together; equal observable results stop invalidation from propagating. Inputs are refreshed only while the database is idle.
- Plain owned results and intern values share structural content equality and recursive slice cleanup in `src/value.zig`; intern hashing follows the same fields. Result types opt into these operations explicitly, so new fields participate automatically. AST payloads, maps, borrowed source graphs, and reference-counted snapshots retain their own representation and ownership rules.
- A missing optional result can mean source rejection or unavailable state; source diagnostics are emitted separately. Infrastructure failures remain errors, and broken compiler invariants use assertions. `src/diagnostics.zig` owns presentation, not semantic decisions.
- Query orchestration shares item location and AST loading without reading source text implicitly. Semantic-result helpers emit source issues and preserve infrastructure errors; each consumer chooses whether unavailable analysis propagates as an error or a missing query result.

## Sources and identity

- `SourceRegistry` publishes source text, file-to-module ownership, module membership, and existence as query inputs, preserving file IDs across directory refreshes. It also registers the embedded `std` files. The module catalog, not interner presence, determines whether a module currently exists.
- Declarations are shared across a module, while imports and implicit prelude bindings belong to individual files. The module graph validates imports, exports, and declaration ownership before compiling the entry, without evaluating unused declarations or bodies. Resolution uses the defining file's effective scope.
- `ItemId` names a declaration independently of its current source location; `InstanceId` adds canonical compile-time specialization arguments. Resolution goes through current module membership, so moving or removing a declaration invalidates its users. The interner gives variants and callables canonical identities and declared or generated structs nominal identities; both struct forms expose the same definition to downstream stages. Query keys and cached results retain owned data or stable, session-local identities rather than references into replaceable source.
- Arrays have canonical structural identity `{ element_type, length }`, not
	generated named fields or nominal struct identity. `AnalysisContext.typeNamespace`
	associates a type with its source namespace independently of `structIdentity`.
	Arrays use the specialized standard-source namespace for member lookup while
	their actual `structIdentity` is `null`.
- `int` and `bool` use compiler-owned operation namespaces in the registered
	prelude source, independently of whether a user imports its exports. Their
	explicit members use ordinary declarations and callable identities; primitive
	expression lowering supplies intrinsic arithmetic and predicates.

## Analysis and compile time

- Semantic analysis validates source and lexical structure in a query-local expression graph. Typing resolves names, specializes static arguments, checks operations and calls, and publishes a single typed SSA control-flow graph for each demanded function or compile-time thunk. Signatures and bodies are separate queries, so a caller can refer to a function without analyzing its body.
- `AnalyzeFunctionInstance(InstanceId)` owns all runtime bodies, including unspecialized declarations. `AnalysisContext` supplies source-dependent resolution, visibility, and specialization. Its `TypeFacts` view owns context-free structural and ownership lookups and is also used directly by diagnostics and cache validation. `HostTypes` adds physical layout for codegen; compile-time interpretation uses its own call executor. These adapters derive existing query facts without adding caches.
- Typing chooses type-specific operations and explicit coercions before publication. Selected user-defined conversions use ordinary calls with ordinary destinations, reference origins, and cleanup. Joins, ownership uses, and fallible success/failure paths are represented in the graph; later stages do not rediscover their legality or build another general-purpose lowering IR. Source evaluation order is preserved.
- Expression evaluation shares one dispatcher for access context, optional construction destination, and discarded results. Unevaluated type discovery and executed calls share member classification while retaining their separate evaluation and signature demands.
- Generic calls infer static arguments from unevaluated argument types before
	evaluating their arguments. The specialized call prepares each argument once,
	in source order, through the ordinary call path.
- Operation expressions select the left operand's type namespace through the
	existing lookup and specialization APIs. Demanded signatures validate exact
	arity, receiver ownership, modes, types, result, and fallibility. Arithmetic,
	comparison, unary, and indexing calls reuse ordinary typed calls; no operation
	query or new backend instruction is needed. Boolean predicates and `and`/`or`
	remain explicit control flow. Indexed mutation selects `[]=` with a deferred
	initializer, while compound indexing freezes the index, reads the old value
	once, and scopes its temporary across getter/setter success and failure exits.
- Converter discovery derives candidates from the source and target owners'
	existing `ModuleDeclarations`, not imports or another query/cache. Additional
	static parameters infer from both types before any conversion executes; only
	the selected instance demands its constrained signature at actual use.
	Type-only inference matches nested conversions without evaluating their
	constraints or canonicalizing static sources. Candidate source modes come
	from unconstrained signatures, independently of source types. Module validation
	checks top-level placement, ownership, parameter modes, and inferability even
	for unused converters, without analyzing their bodies. Static struct sources
	and integer literals specialize ordinary converter functions; a known static
	argument does not force a runtime-capable converter body to run at compile time.
- Frame-dependent static-only operands cannot use independent source thunks.
	Their typed `static_conversion` operation reads the current interpreter value,
	interns the canonical argument, and selects and invokes an ordinary converter
	through the existing call executor, retaining builtin widening and ambiguity
	rules. Result destinations support immovable outputs. These operations never
	emit native code or restore as runtime bodies. The interpreter still owns
	logical storage; the query adapter owns specialization and dependencies.
- `TypeFacts.isRuntimeCapable` derives eligibility from existing definitions:
	static structs, `type`, and `int_literal` are compile-time-only, as are stored
	aggregates containing them. Ownership, movability, and physical representation
	remain separate dimensions. Native compilation validates the typed body and
	initializer regions before codegen, and allocation validates its element type
	before layout. Static-only types have no host layout.
- Ordinary and marked invocations share one AST call shape; the call's token records `(` or `?`. Semantic calls retain that source marker independently of their target. Source analysis requires it for fallible expression calls and permits omission only on the specific call used as a fallible condition. Semantic analysis checks declaration-known fallibility before evaluating explicit static arguments; typing checks it before signature demands, member specialization, and eager arguments can execute compile-time work or diverge. Generic declarations expose fallibility in the existing `FunctionShape` result before dependent types are specialized; shape equality includes it. Comparisons and extraction do not pass the exemption to their operands. The marker does not widen ordinary callables and does not enter published IR or change failure handling.
- Shared IR owns direct operand and successor enumeration. Body-level stored-reference walking includes operand side tables for normalization and capture pruning, keeping parameter targets and nested regions separate. Cache validation checks raw ranges before traversal, and backend use marking follows operation-referenced ranges; operation legality and addressability remain with their consumers. Block arguments describe their logical type and whether the join passes storage. Storage selection is independent of a type's move capability, and cleanup edge splitting preserves it.
- Calls share one operation with independent direct/indirect targets and optional result destinations. Owning initialization of an address-passed type constructs in the destination its consumer supplies: `local_storage` for locals, temporaries, and owned arguments, `result_storage` for the caller's result, and logical storage projections for fields, variant payloads, and array elements. Derived `argumentPassing` selects this representation for arrays and containing structs or variants as well as types that cannot move directly; it is not a duplicate ownership-capability field. Ordinary calls, copies, moves, and variant coercions write those destinations; conditional and loop results propagate them, and fallible results construct in storage instead of crossing the success edge. Typing never relocates a completed value that cannot move directly and rejects forms that would need it. Inferred-return compile-time thunks publish their result as a value instead. `Box.new` directly allocates one slot before forwarding its init parameter to fallible raw slot initialization. Success transfers the allocation into a Box; failure explicitly deallocates it after initializer cleanup and propagates with `fail`. No private storage guard, constructor interception, or Box-specific construction instruction is needed. Typing owns evaluation order, captures, and cleanup paths; codegen and the compile-time interpreter consume explicit destinations and operations.
- An address-passed value is denoted by its storage independently of its direct movability. Field and array-element reads are storage projections, and a mutable local keeps one storage value across field updates, replacements, `mut` arguments, and loops: `call_mut_argument` writes its destination, and loops carry only the local's lifetime generation, not a block argument. Replacement ends the old value before constructing in the same storage; a replaced field leaves its root's generation first, so an exit from the right-hand side sees the field missing. Joins that select such values pass addresses; codegen gives their block arguments address slots, and the compile-time interpreter passes storage cells, promoting a runtime slot before a storage projection or address-passed join creates a view. Compile-time field reads materialize only the selected field, so an unfinished sibling does not prevent access.
- For a borrowed variant argument that cannot move directly, its known type follows conditional results and loop breaks. Fresh initializers construct into storage of that type; existing values of the same type retain their borrowed storage. Widening an existing narrower value still requires direct movability. Typing carries the borrow context separately from an owning destination and preserves the source's cleanup and reference origins when widening directly movable values.
- Compile-time expressions that require evaluation, including initializers, static arguments, and expressions in type positions, are typed before interpretation; direct type aliases and declared struct identities can resolve without it. Compile-time calls are memoized by concrete instance and canonical argument values. Interpreted outcomes distinguish values, fallible failure, and compiler control; type values have no runtime representation.
- Static array values publish as semantic `array_init` expressions, lowering
	elements through indexed stores into typed destinations, not `struct_init`.
	This internal materialization is separate from deferred collection literals;
	it does not expose default construction or element consumption.
- The compile-time interpreter owns `Cell` and `Value` storage, snapshots,
	logical equality, recursive cycle comparison, and checked-reference cell
	operations for the scalar/inline-array subset. Heap allocation remains
	unsupported. The query adapter owns canonical values, call keys, and dependency
	tracking; transient calls share frame-recursion state through one execution
	session. Calls carrying initializer handles or transient references bypass
	canonical argument memoization. Transient references cannot enter the intern
	cache or published canonical values.

## Deferred construction

Inference types the complete deferred expression in an isolated lexical context,
including statements, bindings, loops, and divergence, without publishing IR or
choosing placement. Nested regions share a query-local memo of inferred types
keyed by expression and expected type. After specialization,
executable typing checks current effects, availability, and ownership and builds
an ordinary typed region with its actual construction destination.

`init` participates in callable identity. Each parameter's pending/consumed state
is independent of T's ownership generations, joins across branches and loop
exits, and is checked at successful returns and backedges. Direct and indirect
calls support construction and exact-typed forwarding.

The analyzed caller owns nested regions and explicit capture operands. Arguments
and operands distinguish values, source storage, and pending initializers;
their logical types remain unchanged. Captured pending
handles retain init mode and their single-use obligation. Unused captures are
pruned before publication. Other captures retain caller storage through argument
preparation and the receiving call without acquiring region ownership.
Initializer handles are call-lived operands, not first-class callable values;
they cannot be stored, returned, or escape the receiving call.

Typing checks deferred reads, writes, and transfers against eager arguments,
indirect callees, writable references, hooks, and implicit cleanup. Deferred reads
conflict with every write to their referent; ordinary reference reads retain the
checks for invalidated owned storage. Borrowed aggregate or owning parameters
may alias other reference inputs; directly passed scalar copies have private
storage. Writes, including mutable calls and scoped aliases, update caller storage
immediately and survive later failure. Mutability and transfer authority remain
independent. Mutable alias writeback preserves the handle and merges conservative
stored-reference origins into tracked local owners, including boxed referents.
Reference-bearing writes through aliases with untracked owners are rejected at
argument preparation rather than silently losing dependency information.
Symbolic capture origins retain projections until caller substitution;
result origins and mutable effects cross forwarding without querying receiver
bodies. Region-local references cannot escape.

Transfers use caller-owned boolean cells for roots and field paths. Moves set
them when performed; consuming calls set them after eager argument preparation.
Nested regions and forwarding share those cells. Lifetime planning separates
guarded field owners from residual roots, excludes descendants from ancestor
cleanup, and checks completed ancestor transfers before dropping fields.
Restoration clears applicable predicates. Consuming conditional and loop results
carry independent nonowning cleanup and consumption-completion storage when
selecting captures or fresh values. Guarded generations forward into fresh join
generations to keep predicates at their owning control-flow boundary.

Ordinary call availability joins skipped evaluation and all successful or failed
region completions: receivers may handle initializer or forwarding failure and
return successfully. Ownership renews only for definitely available sources; failed
receiving calls retain possible-transfer state. Runtime predicates distinguish
skipped and completed transfers, while explicit-drop obligations require a static
plan. Pending source-place owners survive ordinary and deferred result joins;
read availability and definite consumption completion remain independent snapshot
facts. Actual calls consume definitely selected owners; mixed selections retain
guarded cleanup. Completion cells initialize when caller ownership begins and
reset at preparation; split field guards are inactive outside prepared paths.
Renewal retires the old guard; captures never gain region-owned generations.

Native code outlines regions, references, and relocations in the caller artifact.
Private handles contain callbacks and call-lived environments of storage addresses;
forwarding copies handles and construction supplies an ordinary result destination.
The interpreter uses the same regions and frame-local cells. Its active frames
snapshot logical arguments and captures, recursively including aggregate fields,
array elements, variant payloads, types, and nested handles, to detect cycles
across fresh storage while permitting finite recursion. Snapshot cloning indexes
source and copied cells, and comparison indexes visited cell pairs, so large
aggregate arguments do not require quadratic scans. The query adapter shares
this transient frame recursion through the execution session. Query equality,
cleanup, validation, and cache reuse include
nested regions and modes; published results contain no source or frame pointers.

Declared function fallibility remains independent of `init`. Initializer regions
retain a failure-capable ABI, while their typed failure exits determine concrete
construction effects without executing them or adding a query. Abstract init
parameters conservatively may fail. Consuming collection converters and the
private bulk initializer inherit only their supplied initializer's effect;
provably infallible literals need no ordinary failure handling. Converter bodies
must handle unrelated fallible operations locally. Forwarding leaves expressions
unevaluated; explicitly fallible APIs retain their declared call requirements.
Bare `fail` propagates
ordinary failure in a fallible function or initializer region. Partial fields
clean before receiving frames unwind, and cleanup and mutable copyback follow
ordinary failure paths. Captured writes and completed transfers are not rolled back.

An initializer region is a control-flow boundary: it produces its value, fails,
or diverges. Typing rejects `return` to the caller and `break` or `continue` to a
loop outside the region; loops inside it retain local exits. Forwarding, aliases,
and indirect calls preserve this boundary. Published IR has no lexical call
outcomes or nonlocal initializer continuations. Native calls use `edx` only for
ordinary success (`1`) or failure (`0`), with small direct results in `eax` and
larger or address-passed results in destination storage. There are no continuation
tokens. Never-returning calls omit impossible success successors.
Interpreter cells retain their owning storage allocator; projected fields,
array elements, and variant payloads inherit it recursively through region teardown.

Capture origin and availability summaries stay query-local; published IR
contains typed storage, initializer handles, and control-flow edges. Snapshot validation
confines handles to init arguments, targets, and matching owned-region captures,
checks writes against parameter modes, and reserves environment calling conventions
for nested regions. It validates capture mappings and successor representations:
success carries a return value (or unit for destination calls), and failure carries
no arguments. Mutable-result reads identify calls by their complete
argument range and return type; logical types and destinations match prepared
argument types, including coercions. Storage joins retain exact types without
coercion metadata; Box element projections and indexed allocation destinations
match their owner's element type. Physical layouts remain backend-owned.

Remaining work and priorities are tracked in
[ROADMAP.md](ROADMAP.md).

## Ownership and layout

- Struct definitions publish per-field visibility as a source fact. `AnalysisContext`
	derives a struct's defining module from its declared identity or generated
	factory identity and compares it with the accessing file's module; no separate
	visibility query or caller-specific definition is cached. Existing semantic
	name resolution validates public annotation references; computed annotations
	use the ordinary expression builder and lexical scopes. Their compile-time
	site keys retain the public-annotation policy so ordinary evaluated expressions
	cannot bypass it. Called function bodies retain their own module authority.
	Resolved nominal types are validated separately, including variants, callables,
	and generated type arguments. Typing checks initializer
	field names before field values and shares field projection validation across
	reads, writes, borrows, moves, and callable fields. Layout, ownership operations,
	codegen, and interpretation trust validated field indices and visit private
	fields normally. Standard storage types use the same privacy rule; compiler
	recognition remains tied to registered standard identities.
- Declared and generated structs publish a common definition with fields and validated ownership hooks. `OwnershipCapabilities(TypeId)` validates logical by-value containment and composes move, copy, and drop facts without requesting physical layout. Arrays compose these facts from their element type and length; empty arrays are trivial, contain no reference origins, and impose no element-hook obligations. Layout consumes validated facts before determining size, alignment, and field, variant, or array placement. Array length is a nonnegative static `int`; byte size is checked at natural element alignment, including zero-length arrays and zero-sized elements. Direct movement is derived from capabilities, not stored separately, and remains independent of derived `argumentPassing`. `HostTypeLayout(TypeId)` describes the x86-64 host representation; a non-host layout must be derived for its target's location-specific layout domain, never inferred from host layout. [syntax&semantics.txt](syntax&semantics.txt) owns the provider, location, layout, and access contracts.
- Typed borrowed places carry field-index paths, not byte offsets. Borrowing, consuming arguments, and receiver resolution share source-place traversal and field-name and visibility validation; codegen resolves physical offsets from the trusted path. Reference origins retain independent field, variant, and owned-element projections. Slot-storage identity is separate from the current contents' identity, including at loop joins.
- Custom copy and move hooks may rearrange reference-bearing fields, so their results conservatively retain all possible source origins rather than assuming field correspondence. Hook effects invalidate writable referents, including during in-place copies. Call arguments retain the provenance of their prepared values, and indirect callees retain borrow metadata through argument evaluation.
- Function return dependencies conservatively include all runtime inputs capable
	of supplying origins. This covers borrowed storage and references contained
	in prepared values; signatures have no `from` syntax or explicit contracts
	that narrow those dependencies. Callers substitute actual argument origins
	without querying receiver bodies.
- `deinit` call arguments carry exact-typed source storage; typing propagates consuming access through conditional and loop results and materializes fresh argument coercions before publishing their addresses. Storage joins preserve the selected address in codegen and the selected cell in compile-time interpretation, including directly movable and zero-sized types. Preparing an owned root retains its generation until the call or failure cleanup. Typing rejects overlapping writes to any retained source while later arguments are prepared. Move hooks receive consuming access, and nested hooks dispatch normally. Local deinit authority is separate from a generation's fields-only cleanup policy. Typing derives remaining explicit-field obligations before lifetime planning; the solver does not interpret structural ownership. Deferred `init` capture effects are checked at callable acquisition and argument preparation, with published regions and cleanup surviving query/cache reuse; the language document owns those contracts.
- `AnalysisContext` derives `copy` and `move` member availability from validated ownership capabilities and specializes private declarations in `std/ownership.chi`. These use ordinary instance identities and canonical callable types, with capability checks also applied when their signatures are demanded. Typing builds their bodies with the existing selected ownership operations and lifetime machinery; runtime codegen and compile-time interpretation consume ordinary typed IR. No member query, recursive source wrapper, or backend ownership dispatch is added.
- Typing tracks ownership at control-flow edges. Lifetime effects are recorded in a boundary of the block where their operation executes; block statements and results never record into an enclosing expression's boundary. A `mut` parameter root is caller-owned and carries no generation; a value assigned to the whole root passes to the caller's place. After constructing the graph, `src/frontend/lifetime.zig` plans path-sensitive cleanup and explicit-drop obligations from query-local metadata. Typing rejects abandonment before materializing the plan as ordinary typed operations; neither the solver's state nor a generic destruction operation enters published IR.
- Conditions, branch results, and loop exits share predecessor joining for values, flow state, storage, ownership, and reference origins, with explicit policies for binding identity and borrowed facts. Loop headers establish ownership generations before typing the body; entry and backedges forward into those generations, and completion checks missing fields and cleanup policy without remapping body metadata.
- Cleanup values retain reference provenance through ownership forwarding. After materialization, typing checks paths from expression-borrow reads through mutating destructor calls to later uses, stopping at fresh reads. Fieldwise and standard Box destruction visit only contained destructors; user hooks conservatively receive all writable references in their argument. Read identities and cleanup effects are query-local and do not enter cached IR.
- Immutable local-binding metadata has one allocation owner. Live local values remain contiguous. Query-local snapshots retain only the prefix through the last bound local: up to 256 slots use independent contiguous copies; larger states share reference-counted 16-slot pages and copy a page before mutation. Capturing live values reuses equal pages from the preceding snapshot; restoring a snapshot clears the omitted tail. `State` owns cloning, cleanup, and joining the independent flow facts: local and field availability, initializer consumption, and definite consumption completion. Those arrays remain full-sized and independent of value-page sharing. Value and storage selection remain with the control-flow builder.
- Lifetime tables remain dense. `src/control_flow.zig` indexes incoming and outgoing edges without merging parallel edges and shares directional dirty-block scheduling across the three analyses. Availability and representations share forward traversal while retaining separate facts and joins. Typing rebuilds the index after cleanup insertion for backward reference checks, preserving both invalidated and valid path states. Ownership forwarding hints are stably grouped by predecessor and successor ordinal, so edge lowering visits only matching hints. Opt-in `BodyMeasurements` records snapshot and dense lifetime-table allocations without changing cached IR or publishing accumulators; `zig build flow-benchmark -Doptimize=fast` exercises branch scaling.

## Storage design

`Array(T, N)` stores contiguous elements inline, without a heap header. Local
arrays use local storage; embedded and boxed arrays use their owner's storage,
and returned arrays construct in receiving destinations. `filled(imm value: T)`
evaluates its argument once and makes `N` ordinary copies, including custom
hooks. It requires element copy support even at zero length, where the argument
still evaluates but no copies run; this constructor requirement is separate
from the empty array's trivial capabilities. Whole-array copy, move, and drop
lower through typed loops over element operations. Fallible `get` and `get_mut`
check bounds and return immutable or writable references tied to the array's
checked origin. Dynamic element origins may conservatively cover the whole
array without disjoint-index proofs. Collection literals construct elements in
source order directly into final storage, including immovable elements; partial
failure cleans the current element and completed prefix in reverse order.
Without an expected target they construct an Array. Expected targets derive
element types through existing converter declarations and static inference.
Pending `collection_literal(T, N)` types have no ordinary value representation.
Standard `[]` and `[]=` methods reuse checked `get`/`get_mut` and reference
replacement. Reads copy elements through ordinary ownership operations; writes
retain automatic-drop, direct-move, and reference-origin restrictions. List and
Buffer use the same methods; BufferView only exposes copied reads. Default
construction and individual element consumption remain absent.

`List(T)` owns an allocation and initialized count. Its literal converter obtains
storage before evaluating elements and uses a typed allocation-array storage
projection to construct the deferred region directly in that storage. Allocation
failure terminates runtime execution with status 134, outside ordinary failure
flow. Element failure cleans the prefix and releases storage normally. The
explicitly fallible `List(T).from(...)` instead exposes allocation failure and
retains ordinary element failure. Successful Lists destroy elements in reverse
order and release storage. Growth and iteration are not implemented. Heap
execution remains unsupported by the compile-time interpreter.

The implemented host API fixes execution target, provider, and location
implicitly. `Allocation(T)` retains logical element count separately from
mapped byte size; public counts are `int`, while checked byte-size arithmetic
uses wider unsigned storage. For a zero-byte request the host provider reserves
one byte for a distinct stable address and records the reserved size for
deallocation without changing the logical count or layout.

`Allocation` is explicit-drop and owns deallocation facts, not element
initialization state. It needs no runtime initialization bitmap: unsafe indexed
operations require caller-proven bounds and initialization, while containers
track initialized ranges. `Box` retains a complete one-element allocation;
`Buffer` derives capacity from its allocation and tracks only its initialized
prefix. Do not introduce a thin allocation handle until retaining layout and
location has a demonstrated material cost. Compiler storage and lifetime checks
need not be expressible as ordinary library code.

### Future allocation interface

This is a conceptual interface, not public non-host declarations. Layout
resolution binds a target, location, type, count, and alignment before a provider
receives the request. Keep resolved byte `AllocationLayout` separate from that
typed request so a host layout cannot be paired with device storage, or a count
with inconsistent bytes:

```text
fallible resolve_layout(
		static T: type,
		target,
		location,
		count,
		alignment = natural_for(T, target, location),
) ResolvedAllocationLayout(T)

fallible allocate(
		mut provider,
		resolved: ResolvedAllocationLayout(T),
) Allocation(T)

func deallocate(static T: type, deinit allocation: Allocation(T))
```

Prefer `allocate` and `deallocate`; `release` is ambiguous with decrementing
shared ownership. The allocation retains the resolved request and provider
authority directly or through lifetime dependencies. Layout and location
accessors remain sketches. Host low-level operations stay under `std.memory`,
with matching `Allocation` methods; `Box` and `Ref` are prelude exports.
`unsafe_own_box` is internal ownership transfer, not a public constructor.
Consuming `value(T, owner)` uses deinit access without preliminary owner
relocation; `get_value` would obscure borrowing versus copying versus transfer.
`Ref.copy` copies only the handle; `Ref.read` requires pointee copy support.

Convenience wrappers may bind location and provider without merging them:

```text
host.allocate(layout, using = allocator)
device.allocate(layout)
copy(source, mut destination)
```

These spellings remain conceptual. `device` is a runtime resource for one
device, not an enum case. A kernel boundary produces an address-space-qualified
Ref or view with a representation validated for that target; host code cannot
dereference device-only memory. Workgroup and private storage remain explicit
kernel declarations. Non-host layouts must be keyed by type and the target's
location-specific layout domain. Add neither a device layout query nor a
general provider dispatcher until a concrete target needs them; start with
validated scalar elements. The roadmap owns remaining prerequisites and the
deferred shared-owner design.

### Mojo comparison

The storage design was informed by Modular's repository at commit
[`975baa7`](https://github.com/modular/modular/tree/975baa793c02665a36194c285496e133c9452068),
inspected on 2026-09-17. Bracketed parameter lists and *origin* below are Mojo
terminology, not proposed Chimera syntax.

- Mojo's [allocation API](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/alloc.mojo)
	uses `Layout[T, alignment]` with runtime element count and compile-time
	alignment, deriving byte size. `Allocation[T]` owns storage and deallocation
	layout; consuming it invalidates dependent origins. `ThinAllocation` retains
	only the owning pointer and requires unsafe reattachment of the exact layout.
	`ManagedAllocation` frees storage automatically but accepts only trivially
	destructible elements because freeing does not run destructors. Allocation
	failure and negative counts abort; zero-sized types use a dangling sentinel.
	Chimera instead retains complete deallocation facts, uses ordinary fallible
	failure, and requires distinct stable identities for successful zero-byte
	allocations.
- Mojo's [Pointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/pointer.mojo)
	combines pointee type, mutability, origin, and address space. It is non-null;
	arithmetic, raw-address access, initialization, and destruction are unsafe.
	`UnsafePointer` is a deprecated alias. This supports one non-owning Chimera
	Ref abstraction, with permission granted only by its access path.
	[OwnedPointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/owned_pointer.mojo)
	allocates a single-element layout, copies or moves its value, and destroys it
	before deallocation; interior origins depend on the owner. Chimera's Box uses
	the same ownership model but initially retains a complete allocation rather
	than a thin handle with reconstructed layout.
- Mojo's [ArcPointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/arc_pointer.mojo)
	has a control block containing payload and atomic strong and weak counts.
	This bookkeeping does not synchronize payload access. Only the control-block
	pattern informs a future Chimera shared owner, not the Arc/WeakPointer names
	or upgradeable weak semantics.
- Mojo's [AddressSpace](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/address_space.mojo)
	defines `GENERIC`, `GLOBAL`, `SHARED`, `CONSTANT`, and `LOCAL` as pointer
	parameters; [stack_allocation](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/stack_allocation.mojo)
	lowers GPU shared, constant, and local storage by compile-time address space.
	Address space and dynamic allocation policy remain separate dimensions.
- Mojo's [DeviceContext and DeviceBuffer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/max/mojo/max/gpu/host/device_context.mojo)
	form a separate host-side GPU API, not a location-generalized `alloc`.
	A device-global buffer is freed through its context and becomes a device
	Pointer at a kernel boundary. Copies are explicit and asynchronous; pinned
	HostBuffer is also available. DeviceBuffer accepts scalar `DType` elements,
	not arbitrary host types, and kernel arguments use a
	`DevicePassable.device_type` mapping with target-aware ABI checks. This
	prevents host dereference of inaccessible memory but duplicates allocation
	surfaces without a general location model; unlike `alloc`, buffer creation
	is fallible. Chimera keeps location separate and initially requires
	synchronous transfers unless a completion resource retains both allocations.

## Storage design

The implemented host API fixes execution target, provider, and location
implicitly. `Allocation(T)` retains logical element count separately from
mapped byte size; public counts are `int`, while checked byte-size arithmetic
uses wider unsigned storage. For a zero-byte request the host provider reserves
one byte for a distinct stable address and records the reserved size for
deallocation without changing the logical count or layout.

`Allocation` is explicit-drop and owns deallocation facts, not element
initialization state. It needs no runtime initialization bitmap: unsafe indexed
operations require caller-proven bounds and initialization, while containers
track initialized ranges. `Box` retains a complete one-element allocation;
`Buffer` derives capacity from its allocation and tracks only its initialized
prefix. Do not introduce a thin allocation handle until retaining layout and
location has a demonstrated material cost. Compiler storage and lifetime checks
need not be expressible as ordinary library code.

### Future allocation interface

This is a conceptual interface, not public non-host declarations. Layout
resolution binds a target, location, type, count, and alignment before a provider
receives the request. Keep resolved byte `AllocationLayout` separate from that
typed request so a host layout cannot be paired with device storage, or a count
with inconsistent bytes:

```text
fallible resolve_layout(
		static T: type,
		target,
		location,
		count,
		alignment = natural_for(T, target, location),
) ResolvedAllocationLayout(T)

fallible allocate(
		mut provider,
		resolved: ResolvedAllocationLayout(T),
) Allocation(T)

func deallocate(static T: type, deinit allocation: Allocation(T))
```

Prefer `allocate` and `deallocate`; `release` is ambiguous with decrementing
shared ownership. The allocation retains the resolved request and provider
authority directly or through lifetime dependencies. Layout and location
accessors remain sketches. Host low-level operations stay under `std.memory`,
with matching `Allocation` methods; `Box` and `Ref` are prelude exports.
`unsafe_own_box` is internal ownership transfer, not a public constructor.
Consuming `value(T, owner)` uses deinit access without preliminary owner
relocation; `get_value` would obscure borrowing versus copying versus transfer.
`Ref.copy` copies only the handle; `Ref.read` requires pointee copy support.

Convenience wrappers may bind location and provider without merging them:

```text
host.allocate(layout, using = allocator)
device.allocate(layout)
copy(source, mut destination)
```

These spellings remain conceptual. `device` is a runtime resource for one
device, not an enum case. A kernel boundary produces an address-space-qualified
Ref or view with a representation validated for that target; host code cannot
dereference device-only memory. Workgroup and private storage remain explicit
kernel declarations. Non-host layouts must be keyed by type and the target's
location-specific layout domain. Add neither a device layout query nor a
general provider dispatcher until a concrete target needs them; start with
validated scalar elements. The roadmap owns remaining prerequisites and the
deferred shared-owner design.

### Mojo comparison

The storage design was informed by Modular's repository at commit
[`975baa7`](https://github.com/modular/modular/tree/975baa793c02665a36194c285496e133c9452068),
inspected on 2026-09-17. Bracketed parameter lists and *origin* below are Mojo
terminology, not proposed Chimera syntax.

- Mojo's [allocation API](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/alloc.mojo)
	uses `Layout[T, alignment]` with runtime element count and compile-time
	alignment, deriving byte size. `Allocation[T]` owns storage and deallocation
	layout; consuming it invalidates dependent origins. `ThinAllocation` retains
	only the owning pointer and requires unsafe reattachment of the exact layout.
	`ManagedAllocation` frees storage automatically but accepts only trivially
	destructible elements because freeing does not run destructors. Allocation
	failure and negative counts abort; zero-sized types use a dangling sentinel.
	Chimera instead retains complete deallocation facts, uses ordinary fallible
	failure, and requires distinct stable identities for successful zero-byte
	allocations.
- Mojo's [Pointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/pointer.mojo)
	combines pointee type, mutability, origin, and address space. It is non-null;
	arithmetic, raw-address access, initialization, and destruction are unsafe.
	`UnsafePointer` is a deprecated alias. This supports one non-owning Chimera
	Ref abstraction, with permission granted only by its access path.
	[OwnedPointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/owned_pointer.mojo)
	allocates a single-element layout, copies or moves its value, and destroys it
	before deallocation; interior origins depend on the owner. Chimera's Box uses
	the same ownership model but initially retains a complete allocation rather
	than a thin handle with reconstructed layout.
- Mojo's [ArcPointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/arc_pointer.mojo)
	has a control block containing payload and atomic strong and weak counts.
	This bookkeeping does not synchronize payload access. Only the control-block
	pattern informs a future Chimera shared owner, not the Arc/WeakPointer names
	or upgradeable weak semantics.
- Mojo's [AddressSpace](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/address_space.mojo)
	defines `GENERIC`, `GLOBAL`, `SHARED`, `CONSTANT`, and `LOCAL` as pointer
	parameters; [stack_allocation](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/stack_allocation.mojo)
	lowers GPU shared, constant, and local storage by compile-time address space.
	Address space and dynamic allocation policy remain separate dimensions.
- Mojo's [DeviceContext and DeviceBuffer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/max/mojo/max/gpu/host/device_context.mojo)
	form a separate host-side GPU API, not a location-generalized `alloc`.
	A device-global buffer is freed through its context and becomes a device
	Pointer at a kernel boundary. Copies are explicit and asynchronous; pinned
	HostBuffer is also available. DeviceBuffer accepts scalar `DType` elements,
	not arbitrary host types, and kernel arguments use a
	`DevicePassable.device_type` mapping with target-aware ABI checks. This
	prevents host dereference of inaccessible memory but duplicates allocation
	surfaces without a general location model; unlike `alloc`, buffer creation
	is fallible. Chimera keeps location separate and initially requires
	synchronous transfers unless a completion resource retains both allocations.

## Backend and execution

- Codegen consumes the published graph and layout queries directly, producing owned machine code and symbolic references per function without compiling callees. Reachability starts at the designated file's synthetic top-level entry, includes referenced callable values, and supplies a deterministic order for linking an x86-64 ELF executable. A function named `main` has no special entry role.
- Derived `argumentPassing` accounts for type structure and ownership capabilities: arrays and containing structs or variants pass by address even when directly movable, as do types that cannot move directly. One backend `CallLayout` supplies storage planning, argument emission, returns, mutable copy-back, and copy hooks. Mutable calls write their updated arguments back. The calling convention is internal to the compiler, not a platform ABI.
- Aggregate construction uses addressable storage, including four-byte register returns. Shared backend `copyRange` emits bulk byte copies for any aggregate when the selected operation permits them, not just arrays; nontrivial element operations retain typed loops and hooks. The encoder and assembly renderer share opcode bytes, operand widths, and display forms in `src/backend/x86_encoding.zig`; unknown bytes end decoding rather than permitting resynchronization inside an instruction. Divergence blocks emit an invalid-instruction trap so unexpected fallthrough cannot execute another block or outlined region.
- Embedded standard-library declarations use ordinary lookup, signatures, and instance identities. Supported compiler-owned externs, including exit and host-memory operations, publish artifacts under those identities. Allocation and extraction use host-only emitters; slot construction uses ordinary typed init calls into host storage. Another location will require its own provider and access path. A compile-time exit instead propagates compiler control to the driver without producing an executable. `src/runtime.zig` publishes and runs successful executables.
- Standard calls are classified by registered declaration identity at the analysis boundary; lowering retains the resolved behavior instead of rediscovering names. Box, Buffer, and reference-write type eligibility is checked when a signature is demanded, including acquisition as a function value. These capability constraints remain compiler-owned until the language can express them. Reference-write eligibility is shared with assignment typing. `Box.new` is an ordinary fallible library init receiver with explicit allocation cleanup. The compiler-owned fallible raw slot initializer publishes a typed body that selects an allocation element and invokes its init parameter into that destination; backend calls use the general init protocol.
- Standard memory structs retain nominal identity and specialization lookup over existing queries. Arrays instead retain canonical structural identity with a separate standard-source namespace association; representation and ownership checks remain type-specific.

## Persistence

- The in-memory engine handles every build, including builds using the optional disk cache. A successful whole-program executable is keyed by the loaded source and module snapshot plus compiler identity. A separate query snapshot restores interned identities and reuses typed runtime bodies and compiled functions only after validating their observed dependencies.
- Only successful work populates these caches; source rejection and compile-time control do not become executables. Cache validation and atomic publication keep damaged or partial data from being reused.
