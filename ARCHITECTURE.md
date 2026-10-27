# Architecture

This is a high-level map of the compiler's ownership and stage boundaries. [syntax&semantics.txt](syntax&semantics.txt) owns language rules, [ROADMAP.md](ROADMAP.md) tracks upcoming work and priorities, and [PROGRAM_FLOW.md](PROGRAM_FLOW.md) describes the current queries, invalidation, and result lifetimes in detail.

## Queries and stages

- `src/main.zig` registers source inputs and requests `BuildExecutable`. Compiler queries in `src/queries.zig` coordinate parsing, semantic analysis, typing, compile-time interpretation, and code generation; the engine in `src/query/` schedules and memoizes work without depending on compiler stages. `src/structures.zig` holds shared data, and frontend and backend stages do not import query orchestration.
- The engine records input and query dependencies, including reads of absent inputs. It can run independent queries on workers, but a result publishes only after its dependencies settle. Recomputations commit owned results, dependencies, and diagnostics together; equal observable results stop invalidation from propagating. Inputs are refreshed only while the database is idle.
- Query computations recycle bounded scratch arenas from a pool owned by their worker thread; computations demanded outside workers share one locked pool. Structurally owned outputs use separate result arenas, either compacted from scratch or allocated directly through an explicit query option; pointer-based custom outputs retain their computation arena instead. Publication transfers logical ownership without running an extra output destructor. Small pointer-free results use alternating inline slots so equal recomputations retain the old result pointer. Private query storage pools allocation size classes up to 1 MiB with one free list per class and a single database-lifetime backing arena. Larger blocks up to 256 MiB use power-of-four classes allocated individually: freed blocks are reused while queries run and returned to the original allocator whenever the database becomes idle. Larger or unusually aligned allocations use the original allocator directly. Each computation reaches its scratch arena through a recycling layer that returns released blocks of at least 16 bytes to power-of-two free lists, so container growth inside one computation reuses discarded buffers. Memo nodes are pooled, and small query identities live inside their nodes.
- Each computation owns contiguous dependency records, with a lazy flat index for larger sets. Completed dependency reads reuse its immutable output pointers without rescheduling; completion updates the slot registered by the demand without another key lookup. Failed dependency registration rolls back only its newly appended record and index slot. Erased keys and intern ownership checks compare shared immutable nominal type descriptors; serialized dependencies and intern values retain the descriptor's type name. Intern entries occupy stable append-only chunks; release/acquire publication permits immutable identity lookup without the scheduler mutex. Interning probes an open-addressed index of those entries without locking; only insertions take a dedicated intern mutex, and replaced indexes stay alive until the database is destroyed. Input and query updates still require an idle database. Imported cache outputs retain their original allocator contract, and equal live results computed during import validation keep their current dependencies.
- Plain owned inputs, results, and intern values share structural copying, content equality, and recursive slice cleanup in `src/value.zig`; intern hashing follows the same fields. Types opt into these operations explicitly, so new fields participate automatically. Inputs retain distinct declaration identities; plain interners share lifecycle implementations keyed by value and ID type. Cleanup skips pointer-free payloads without reading union tags, so partial ASTs, typed bodies, and code artifacts use their ordinary teardown. AST equality follows syntax payload classification; maps and borrowed source graphs retain explicit ownership rules.
- A missing optional result can mean source rejection or unavailable state; source diagnostics are emitted separately. Infrastructure failures remain errors, and broken compiler invariants use assertions. `src/diagnostics.zig` owns presentation, not semantic decisions.
- Published results are deeply immutable, including nested slice payloads. Construction retains mutable buffers only until publication; SSA capture marking and operand normalization use an explicit mutable finalization view, not the published body. `RuntimeCapable` and `BorrowShape` publish nullable facts for source-invalid types so rejected recomputations retain their dependencies and diagnostics.
- Each compiler query declares its profiling category beside its input, output, and computation. The generic engine reads this metadata without knowing compiler query names.
- Query orchestration shares item location and AST loading without reading source text implicitly. Semantic-result helpers emit source issues and preserve infrastructure errors; each consumer chooses whether unavailable analysis propagates as an error or a missing query result.
- AST nodes own payload classification and child enumeration. Equality, debug rendering, and semantic walkers share this syntax shape; walkers retain their own lexical and ownership boundaries. Semantic body construction shares one builder across explicit entry, function, compile-time expression, and constraint roots; only function roots permit returns.
- Embedded standard-library text is parsed at compiler build time with the ordinary scanner and parser. `ParseFile` copies those ASTs into query-owned storage only for byte-identical source and supplies the current file identity. Edited text uses ordinary runtime parsing and diagnostics; semantic query results are never precomputed.

## Sources and identity

- `SourceRegistry` publishes source text, file-to-module ownership, module membership, and existence as query inputs, preserving file IDs across directory refreshes. It also registers the embedded `std` files. The module catalog, not interner presence, determines whether a module currently exists.
- The CLI uses registry-issued file IDs when registering diagnostic source text; source-list positions do not encode identity.
- Declarations are shared across a module, while imports and implicit prelude bindings belong to individual files. The module graph validates imports, exports, and declaration ownership before compiling the entry, without evaluating unused declarations or bodies. Resolution uses the defining file's effective scope.
- `ItemId` names a declaration independently of its current source location; `InstanceId` adds canonical compile-time specialization arguments and, for generated declarations inside static expansion, an interned lexical static environment. Resolution goes through current module membership, so moving or removing a declaration invalidates its users. The interner gives variants and callables canonical identities and declared or generated structs nominal identities; both struct forms expose the same definition to downstream stages. Query keys and cached results retain owned data or stable, session-local identities rather than references into replaceable source.
- Arrays have canonical structural identity `{ element_type, length }`, not
	generated named fields or nominal struct identity. `AnalysisContext.typeNamespace`
	associates a type with its source namespace independently of `structIdentity`.
	Arrays use the specialized standard-source namespace for member lookup while
	their actual `structIdentity` is `null`.
- Primitive namespaces are compiler-owned items, separate from struct and type
	identity. `TypeNamespace` collects their qualified declarations from the
	registered prelude with the same member validation and visibility rules as
	struct namespaces. `int` and `bool` operations are extern members with ordinary
	callable identities; typing supplies their intrinsic bodies in the existing IR.
	Operator expressions, explicit calls, and callable values use the same members,
	independently of prelude imports. Qualified calls and methods share operation
	selection by runtime operand count or total count including explicit static
	arguments before specialization. Validated direct binary arithmetic calls lower
	to existing arithmetic IR; indirect calls retain the callable intrinsic body.
	Direct literal-byte intrinsics lower to constants from their validated static
	arguments, without per-literal helper functions. A string literal materializes
	as one `const_static_string` constant typed `std.text.StaticString`, whose
	registered shape (one private `bytes: Span(byte)` field) is validated where the
	type is resolved; native code writes the data address and byte count directly.
	Validated direct primitive predicates lower to the existing predicate-branch IR
	after ordinary argument preparation. Indirect predicates retain their callable
	bodies, and custom comparisons retain ordinary call dispatch.
	Compile-time literal predicates and type identity comparisons also lower directly.
	Intrinsic execution failures use the caller's operation span rather than adding
	a source diagnostic or trace frame for the compiler-generated body.
	Unresolved expressions distinguish source decimal literals from typed
	`int_literal` values, preserving literal predicates while applying the ordinary
	checked `int` default before operation selection.
- Declaration names distinguish ordinary identifiers from `Operation` identities.
	The same operator identity owns spelling, operand count, signature shape, and
	primitive support. Unary and binary `-` are distinct interned declarations;
	namespace collection, duplicate checks, and ordering preserve both. These
	unmarked forms retain shape-only selection. Explicit overload declarations own
	their complete name and reference separately identified implementations.
	`ResolveOverloads` publishes interned candidate sets with stable instance
	identities, not pointers into query-owned scopes. Direct calls, methods,
	operations, callable contexts, and unevaluated discovery share type-based
	selection for explicit sets; imports do not merge membership.
	`FunctionCandidateSignature` owns callable headers and declared operation
	validation without evaluating `where` clauses. Selected signatures validate
	constraints and capabilities normally. Candidate mismatches remain distinct
	from source errors and unavailable state; bodies are never trial-executed.
	One overload selection retains lazily discovered candidate-independent argument
	types across alternatives. Tuple literals and overloaded callable arguments
	remain contextual; arguments still execute once through ordinary preparation.

## Analysis and compile time

- Semantic analysis validates source and lexical structure in a query-local expression graph. Typing resolves names, specializes static arguments, checks operations and calls, and publishes a single typed SSA control-flow graph for each demanded function or compile-time thunk. Signatures and bodies are separate queries, so a caller can refer to a function without analyzing its body. A type-returning call with only static arguments reuses ordinary semantic call preparation and `ExecuteComptimeCall`, without building site-specific wrapper IR; the selected factory still validates and executes normally.
- `AnalyzeFunctionInstance(InstanceId)` owns all runtime bodies, including unspecialized declarations. `AnalysisContext` supplies source-dependent resolution, visibility, and specialization. Its `TypeFacts` view owns context-free structural traversal, borrow containment and storage reachability, and ownership lookups; diagnostics and cache validation use it directly. `HostTypes` adds physical layout for codegen; compile-time interpretation uses its own call executor. These adapters derive existing query facts without adding caches.
- `src/intrinsics.zig` owns compiler-supported intrinsic signatures, result and parameter modes, standard storage shapes, library capability policy, and effect classification without importing queries. Query adapters resolve registered identities and dependent type facts, then publish validation results and diagnostics. Typing, interpretation, and native emission consume validated contracts rather than separately checking source shapes. Logical field types and owned versus reference storage are validated independently.
- Typing chooses type-specific operations and explicit coercions before publication. Selected user-defined conversions use ordinary calls with ordinary destinations, reference origins, and cleanup. Joins, ownership uses, and pattern alternatives are represented in the graph; later stages do not rediscover their legality or build another general-purpose lowering IR. Source evaluation order is preserved.
- Joins derive values and flow facts from incoming exits. A single non-loop exit reuses its block and state when scope, destination, and ownership-generation normalization are already satisfied; suspended result blocks resume through the ordinary block lifecycle. Branches with no continuation do not create an unreachable result join. Branch resumption and loop backedges still retain full flow snapshots.
- Expression evaluation shares one dispatcher for access context, optional construction destination, and discarded results. Unevaluated type discovery and executed calls share member classification while retaining their separate evaluation and signature demands.
- Ranges lower to ordinary direct standard-library constructor calls. Missing
	endpoints become ordinary none expressions. One Range type retains raw
	`int | FromEnd | none` bounds and inclusivity; only traversal constructs normalized
	RangeSequence state after checking that both endpoints are present. Iteration
	and reversal panic for missing bounds; stepping returns an optional sequence.
	Library range resolution checks initialized extents before offset or
	inclusive-end arithmetic. Array/List/Span and text views use one range-based
	slice API. Explicit library index overloads select borrowed element getters
	or owned slicing functions, without a compiler slicing instruction or
	Range-specific dispatch. Index snapshots freeze direct primitive arguments
	while preserving ordinary borrowing and overlap checks for aggregate keys.
	Semantic `for`
	lowering uses hidden source/cursor bindings, ordinary member calls, scopes,
	conditionals, and loops. Typing selects an explicit `iter` factory or borrows
	the source cursor in place; binding inference preserves owned versus borrowed
	results. Each step calls `next` once before matching its retained result
	carrier; `End` is the sole exhaustion alternative.
	Generated protocol calls use ordinary return values. Published IR, cleanup,
	interpretation, and codegen need no iteration-specific representation.
	Typing tests the poll carrier's logical item alternatives and extracts the
	item with its owned or reference category before binding. `next` is the sole
	protocol, with no build option or legacy-method fallback.
	The protocol boundary requires an owned std.iteration.End alternative, resolved
	through the registered standard module independently of caller imports and
	shadowing. Single borrowed items remain places until ordinary initialization
	selects conversion or copying, including for const and var bindings. Inferred
	bindings of multiple item alternatives preserve their physical member kinds. Owned carrier
	extraction hands its generation to the payload at its existing address rather
	than inserting a source-level transfer, so fresh immovable payloads need no
	relocation. A null capture set is valid for a borrow-free active alternative
	of an otherwise reference-containing variant.
- Collection syntax retains ordered scalar, spread, and comprehension entries.
  Semantic analysis expands collection `static for` and `static if` clauses before
  analyzing retained element expressions. `ExecuteStaticIteration` runs ordinary
  source/cursor preparation and polling in one evaluation heap; a private
  interpreter callback snapshots each item before cleanup or the next poll,
  without extra element copies. `CompileTimeBindings` interns owned lexical
  names and canonical values, with unavailable-name entries for runtime lexical
  captures. Name resolution diagnoses only retained captures after static
  selection. Compile-time sites, generated struct identities, and their callable
  instances retain the environment needed to distinguish
  repeated source sites. Excluded subtrees are parsed but remain unanalyzed.
  Runtime comprehensions lower through the ordinary `for` and condition graph.
  Query-local emission operations let typing infer element types and cardinality,
  then construct Arrays or call List construction helpers with deferred element
  initializers. They introduce no published collection-building IR. Array spreads
  use structural element order; the runtime List path obtains its cursor from
  a compiler-selected standard factory rather than the Array's `iter` member.
- Generic calls infer static arguments from unevaluated argument types before
	evaluating their arguments. The specialized call prepares each argument once,
	in source order, through the ordinary call path. Variant annotations with one
	dependent arm infer from the source members remaining after fixed arms are
	removed. Fixed-only sources provide no evidence; inference does not partition
	sources between multiple dependent arms.
- Operation expressions select the left operand's type namespace through the
	existing lookup and specialization APIs. Demanded signatures validate exact
	arity, receiver ownership, modes, types, and result. Arithmetic,
	comparison, unary, and indexing calls reuse ordinary typed calls; no operation
	query or new backend instruction is needed. Boolean predicates and `and`/`or`
	remain explicit control flow.
	Comparison signatures may declare a different immutable right operand type;
	conversion remains ordinary call preparation and dispatch never swaps operands.
	Indexed mutation selects `[]=` with an eager
	owned argument, while compound indexing freezes the index, reads the old value
	once, and scopes its temporary across ordinary getter/setter exits.
	Compiler-supplied bodies use the existing transient-body executor; execution
	errors retain the caller span without publishing a generated source frame.
- Converter discovery uses a derived `ModuleConverterIndex` for each source or
	target owner. `ConverterHeads` conservatively classifies declarations by
	primitive type, nominal factory, or structural shape; computed annotations,
	widenable variants, and init sources retain wildcard keys. Index construction
	never executes a type annotation or instantiates a converter. Sorted buckets
	exclude unrelated declarations before ordinary inference. `ConverterBucket`
	projects visible identities, including empty sets, so unrelated index edits
	stop at that query boundary. Imports never change membership.
	`ConverterItems` collects the bucket declarations for a source type, target,
	and requesting module independently of any source value; string literals
	consult it before demanding per-value static-source matching.
	`ConversionCandidates` memoizes matching by requesting module, target type,
	and either source type, canonical static value, or unfinished fixed collection
	length. Its slices are query-owned and immutable to consumers. `ConverterMatch`
	shares each declaration probe independently of requester visibility; equal
	rechecks after file edits preserve candidate results. Existing file-level
	dependencies can still recheck a declaration's match after a body-only edit.
	The candidates query is also a disk-cache fingerprint boundary, including for
	cached absence and ambiguity. Additional static parameters infer from both
	types before any conversion executes; only the selected instance demands its
	constrained signature at actual use.
	Type-only inference matches nested conversions without evaluating their
	constraints or canonicalizing static sources. One declaration-level fact owns
	independent converter source and return types, rejecting incompatible candidates
	before specialization without repeating annotation analysis for each probe.
	Dependent or unsupported annotations retain ordinary signature probing.
	Specialized signatures reuse validated declaration shapes, while candidate
	signatures retain ownership of module-name and runtime-reference diagnostics.
	Candidate source modes come
	from unconstrained signatures, independently of source types. Module validation
	checks top-level placement, ownership, parameter modes, and inferability even
	for unused converters, without analyzing their bodies. Static struct sources
	and integer literals specialize ordinary converter functions; a known static
	argument does not force a runtime-capable converter body to run at compile time.
	`FunctionConstraints` evaluates a specialized header's requirements separately
	from signature publication, preserving a failed condition independently of
	unavailable query state or source errors. Conditions use ordinary compile-time
	expression lowering and interpretation, including `is` membership predicates.
	Runtime parameters are unavailable in those conditions. Query cycles diagnose
	circular requirements. The owning signature reports a
	failed condition at its own clause. Candidate discovery does not filter or rank
	converters by their constraints.
	Type member fallback `T.U` resolves U in the caller's lexical scope and uses
	`ConversionCandidates` to select a declared converter. Actual namespace members
	take precedence. The result is an ordinary specialized function constant with
	the declaration's actual callable signature; lookup synthesizes no conversion
	adapters. `is` probes inspect `FunctionConstraints` without demanding bodies,
	and distinguish a failed condition from unavailable analysis and source errors.
	Typing considers static literal converters before runtime literal defaults and
	prepares the selected converter input before choosing result placement. Borrowed
	and destination-backed contexts share selection and ordinary variant construction;
	a never-typed operand diverges without supplying a converter input.
	If neither widening nor a whole-value converter applies, typing selects a
	conversion for every source-variant member. Requirements validate every
	selected signature without executing bodies. Runtime typing evaluates the
	source once and lowers active-member dispatch through ordinary projections,
	calls, destinations, and ownership joins. Identity branches can remain
	borrowed while converted branches own results; views retain both possible
	source storage and the conditional owned generation. Empty referent sets on
	inactive reference alternatives do not themselves imply a lifetime error.
- Frame-dependent static-only operands cannot use independent source thunks.
	Their typed `static_conversion` operation reads the current interpreter value,
	interns the canonical argument, and selects and invokes an ordinary converter
	through the existing call executor, retaining builtin widening and ambiguity
	rules. Result destinations support immovable outputs. These operations never
	emit native code or restore as runtime bodies. The interpreter still owns
	logical storage; the query adapter owns specialization and dependencies.
- The interpreter owns allocation records, cell construction, allocation wrapping, release, and element counts behind logical-value operations. Query orchestration requests these operations using resolved type and layout facts without inspecting or constructing interpreter cells.
- `TypeFacts.isRuntimeCapable` derives eligibility from existing definitions:
	static structs, `type`, `int_literal`, and `string_literal` are compile-time-only,
	as are stored aggregates containing them. Ownership, movability, and physical representation
	remain separate dimensions. Native compilation validates the typed body and
	initializer regions before codegen, and allocation validates its element type
	before layout. Static-only types have no host layout.
- Calls have one AST shape and one ordinary return protocol. Callable identity contains parameter modes, types, and result mode/type. Generic shapes expose static parameter names and annotations before dependent specialization; they carry no failure effect.
- Variants, including optional and error alternatives, are ordinary data. Expected types perform ordinary conversion and ownership preparation; they create no control boundary. Comparisons, membership, `is`, and logical operators return bool. Conditions retain structural short circuit flow and materialize bool values in value contexts.
- Typed binding annotations select active alternatives without converters. Semantic construction separates the pattern from its source and mismatch handler. Typing evaluates the source once, checks membership, and commits copying, borrowing, or transfer only on the appropriate path. Standalone handlers must exit; handler scopes exclude introduced names. No special result carrier or callable conversion is needed.
- Shared IR owns enumeration of direct operands, explicit branch payloads, and successors. Body-level stored-reference walking includes operand side tables, keeping parameter targets and nested regions separate. SSA finalization identifies retained initializer captures before freezing arrays and normalizes instruction and compacted argument IDs together. Cache validation checks raw ranges before traversal, and backend use marking follows operation-referenced ranges; operation legality and addressability remain with their consumers. Block arguments describe their logical type and whether the join passes storage. Storage selection is independent of a type's move capability, and cleanup edge splitting preserves it.
- Calls share one operation with independent direct/indirect targets and optional result destinations. Owning initialization of an address-passed type constructs in the destination its consumer supplies: `local_storage` for locals, temporaries, and owned arguments, `result_storage` for the caller's result, and logical storage projections for fields, variant payloads, and array elements. Derived `argumentPassing` selects this representation for arrays and containing structs or variants as well as types that cannot move directly; it is not a duplicate ownership-capability field. Ordinary calls, copies, moves, and variant coercions write those destinations; conditional and loop results propagate them, and explicit variant results construct in their destination storage. Typing never relocates a completed value that cannot move directly and rejects forms that would need it. Inferred-return compile-time thunks publish their result as a value instead. `Box.new` returns Box(T) | none, allocates one slot before forwarding its init parameter to ordinary raw slot initialization, and returns none before construction when allocation is refused. Successful construction transfers the allocation into a Box. No private storage guard, constructor interception, or Box-specific construction instruction is needed. Typing owns evaluation order, captures, and cleanup paths; codegen and the compile-time interpreter consume explicit destinations and operations.
- An address-passed value is denoted by its storage independently of its direct movability. Field and array-element reads are storage projections, and a mutable local keeps one storage value across field updates, replacements, `ref`/`mut` arguments, and loops. Reference arguments pass the caller's address directly; no mutable-result copy-back operation is needed. Loops carry only the local's lifetime generation, not a block argument. Directly movable replacement prepares an owned value in separate storage, retains the target generation through preparation, and transfers into the existing storage after ending the old generation. Typing scopes local and reference targets during call preparation and retains every argument's backing owners through call completion and control-flow exits. Reference retention tracks live owners without treating it as access to an invalidated referent; ordinary access validation remains unchanged. Only ownership capabilities requiring destination construction select destructive replacement: the old value ends before constructing in the same storage, and a replaced field leaves its root's generation first, so an exit sees that field missing. Joins that select address-passed values pass addresses; codegen gives their block arguments address slots, and the compile-time interpreter passes storage cells, promoting a runtime slot before a storage projection or address-passed join creates a view. Compile-time field reads materialize only the selected field, so an unfinished sibling does not prevent access.
- Reference contracts preserve source and result paths through direct calls, converters, and custom ownership hooks. Fieldwise ownership preserves field correspondence; only unknown callable effects need conservative result projection. Parameter writeback merges all possible loans for each written referent before updating caller state. Slot identity, content identity, and variant-tag identity are independent, so a content write does not invalidate a surviving inline address or unchanged variant tag. Contract path walking uses physical reference-field storage, crossing internal references implicitly for structural steps and explicitly for referent outputs; snapshot validation accepts the same paths as body analysis.
- Unresolved loop reference origins defer source paths, returned-place storage
	depth and identity, readonly attenuation, reads, and refreshes until their
	incoming origins are known. State-dependent transformations retain the state
	at their use, so stable cursor aliases do not erase allocated-content loans
	or refresh a retained view across an invalidating advancement.
	Reference-access checks have exact instruction-position checkpoints, separate
	from the statement boundaries that collect lifetime effects. CFG validation
	checks inferred writes from ordinary calls and
	cleanup between acquisition and access, preserving field-path distinctions.
	Verified returned place origins are refreshed to post-call state with a
	deferred state-capturing transform. Loop-carried content reads are rebased to
	the header checkpoint before later transforms establish fresh reads, so a
	later poll cannot masquerade as acquisition of a retained earlier view.
- Temporal reference exclusions cross function boundaries alongside origins and
	write requirements. CFG analysis records parameter-relative dependencies used
	across an intervening mutation, including through calls and cleanup.
	Callers substitute their actual captures and reject overlapping dependency and
	invalidation paths. Distinct abstract paths in a generic body may alias at its
	caller; unrelated mutations and noninvalidating mutable aliases remain legal.
	These exclusions participate in contract equivalence and snapshot validation.
	Converters and ownership hooks substitute the same constraints as ordinary
	calls. Result variants do not change which completed writes invalidate prior
	contents; cleanup and ordinary calls retain the same reference effects.
- Struct construction and fieldwise copy or move use explicit storage and field projections for every ABI representation. Updating a directly passed struct copies its root once and writes the selected field into that copy, preserving earlier SSA values. Address-passed owners keep their existing storage. Copy and move share value-transfer dispatch and aggregate traversal while retaining separate ownership effects. Struct construction and field replacement use the array and variant storage machinery without separate typed instructions or field-value tables.
- For a borrowed variant argument that cannot move directly, its known type follows conditional results and loop breaks. Fresh initializers construct into storage of that type; existing values of the same type retain their borrowed storage. Widening an existing narrower value still requires direct movability. Typing carries the borrow context separately from an owning destination and preserves the source's cleanup and reference origins when widening directly movable values.
- Compile-time expressions that require evaluation, including initializers, static arguments, and expressions in type positions, are typed before interpretation; direct type aliases and declared struct identities can resolve without it. Compile-time calls are memoized by concrete instance and canonical argument values. Interpreted outcomes distinguish ordinary values and compiler control; type values have no runtime representation.
- Static array values publish as semantic `array_init` expressions, lowering
	elements through indexed stores into typed destinations, not `struct_init`.
	This internal materialization is separate from deferred collection literals;
	it does not expose default construction or element consumption.
- The compile-time interpreter owns `Cell` and `Value` storage, snapshots,
	logical equality, recursive cycle comparison, and an evaluation-owned heap.
	Allocation records have stable session identities and logical capacities;
	indexed cells are created lazily, independently of native addresses or capacity.
	Release invalidates owned contents and frees sparse backing storage. Cell
	identities remain as compiler-owned tombstones until session teardown, including
	on failure, compiler exit, or infrastructure errors. User destruction remains
	ordinary typed cleanup, not a heap callback.
	The query adapter owns canonical values, call keys, and dependency tracking.
	Nested calls and initializer regions share the heap and recursion frames. An
	`ExecutionFrame` borrows the body, slots, scratch space, and executor; it places
	instruction results and propagates control outcomes centrally.
	Calls carrying transient values, or whose resolved results or mutable parameters
	may retain storage identities, execute transiently; argument shape alone cannot
	make a zero-argument factory cacheable. Representable calls retain canonical
	memoization. Publication recursively checks actual contents before interning
	results, static arguments, conversions, and mutable copy-back. Escaping handles
	have a consuming-expression diagnostic and never enter canonical values or disk
	snapshots; copied or extracted ordinary data can be published.

## Deferred construction

Inference types the complete deferred expression in an isolated lexical context,
including statements, bindings, loops, and divergence, without publishing IR or
choosing placement. Nested regions share a query-local memo of inferred types
keyed by expression and expected type. After specialization,
executable typing checks current effects, availability, and ownership and builds
an ordinary typed region with its actual construction destination.
Both paths select captures from the expression's lexical dependencies, including
cached values' borrowed storage roots, rather than copying unrelated live state.

`init` participates in callable identity. Each parameter's pending/consumed state
is independent of T's ownership generations, joins across branches and loop
exits, and prevents repeated consumption across branches and backedges. Returns
may leave a parameter pending. Direct and indirect
calls support construction and exact-typed forwarding.

The analyzed caller owns nested regions and explicit capture operands. Arguments
and operands distinguish values, source storage, and pending initializers;
their logical types remain unchanged. Captured pending
handles retain init mode and their single-use obligation. Unused captures are
pruned before publication. Other captures retain caller storage through argument
preparation and the receiving call without acquiring region ownership.
Initializer handles are call-lived operands, not first-class callable values;
they cannot be stored, returned, or escape the receiving call.

Typing retains declared storage types in values. Flow snapshots contain IDs of
immutable facts only for tested variant places. Canonical reference origins and
field paths identify those places across aliases and inference captures. A fact
stores possible members, a mutation version, and proof ancestry; joins union
members while preserving dependence on incoming proofs, and writes invalidate
overlapping carriers. Independent tests establish new proofs. Place identity for
type proofs is separate from borrow dependencies of evaluated values. Reading copied bits does not create an
alias. Payload projection preserves the original layout, permissions, and owner.

Conditions carry facts on their CFG edges. Materialized booleans may retain
versioned implications. Loop bodies are typed once: an incoming fact actually
used by the body must hold on every backedge; tests inside the body establish
independent proofs. Inference cache keys include the immutable flow environment,
and inference reads metadata without executing arguments ahead of their effects.
These tables belong to body analysis, with no new cross-query mutable state.
Diagnostics attach source notes to a primary error when a write invalidates a
previous proof or a loop backedge cannot preserve a required entry proof. Notes
are immutable accumulator payloads with content equality across recomputations.

Typing checks deferred reads, writes, and transfers against eager arguments,
indirect callees, writable references, hooks, and implicit cleanup. Deferred reads
conflict with every write to their referent; ordinary reference reads retain the
checks for invalidated owned storage. Borrowed aggregate or owning parameters
may alias other reference inputs; directly passed scalar copies have private
storage. Writes update caller storage immediately and survive later returns;
mutability and transfer authority remain independent. Inferred reference contracts
carry result and mutation effects, with conservative projection for unknown
callables. Mutable outputs merge stored-reference origins into tracked owners,
including boxed referents. Output summaries merge all ordinary return paths;
selecting a result alternative does not narrow those mutation effects.
Reference descriptors do not own their referents.
Reference-bearing writes through aliases with untracked owners are rejected at
argument preparation.

`InferReferenceContract` derives acyclic contracts from cached validated typed
bodies, avoiding a second semantic pass. Signatures incapable of carrying
reference effects need no contract analysis. A query cycle activates
`ReferenceCallees`, which discovers direct reference-call dependencies and seed
contracts without depending on final callee contracts. Inference finds the root's
recursive component and iterates only inside that component. Contract-only passes
validate ownership and references without freezing unused body IR. The separate
contract result stops invalidation when body edits preserve its observable facts,
including edits that create or remove recursion. `BorrowShape` caches the distinct
contains-borrow and stores-borrow structural facts; `RuntimeCapable` caches the
structural runtime capability check. A result that cannot store borrows needs no
source-storage traversal. Primitive ownership, passing, and layout facts are
derived directly at their adapters.

Symbolic capture origins retain projections until caller substitution;
result origins and mutable effects cross forwarding through reference contracts.
Region-local references cannot escape.

Transfers use caller-owned boolean cells for roots and field paths. Moves set
them when performed; consuming calls set them after eager argument preparation.
Nested regions and forwarding share those cells. Lifetime planning separates
guarded field owners from residual roots, excludes descendants from ancestor
cleanup, and checks completed ancestor transfers before dropping fields.
Restoration clears applicable predicates. Consuming conditional and loop results
carry independent nonowning cleanup and consumption-completion storage when
selecting captures or fresh values. Guarded generations forward into fresh join
generations to keep predicates at their owning control-flow boundary.

Ordinary call availability joins skipped evaluation and every region completion.
Any receiver can return without constructing a deferred argument. Ownership
renews only for definitely available sources; possible transfers remain visible.
Runtime predicates distinguish
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
across fresh storage while permitting finite recursion. Allocation snapshots freeze
logical capacity, release state, and instantiated cells while preserving allocation
identity and aliases, even after backing storage is released. Snapshot cloning indexes
source and copied cells, and comparison indexes visited cell pairs, so large
aggregate arguments do not require quadratic scans. The query adapter shares
this transient frame recursion through the execution session. Typing retains
initializer backing dependencies by initializer identity and records their uses
at consumption, including pre-acquired contextual converter initializers. Query equality,
cleanup, validation, and cache reuse include
nested regions and modes; published results contain no source or frame pointers.

An `init` parameter is affine: construction or forwarding may occur at most once;
any ordinary return may skip it. Initializer regions use ordinary calls, results,
and reference contracts. Captured ownership conditions retain skipped captures
and clean only captures actually acquired by construction. Completed transfers
and writes are never rolled back.

A region is a control-flow boundary: it returns its declared value or diverges.
It cannot return to the caller or break/continue an outside loop. Native regions
use the ordinary ABI, with direct results or an explicit result destination.
There is no success register or failure successor. Recoverable collection
construction explicitly returns List(T) | none from its allocation protocol.


Capture origin and availability summaries stay query-local; published IR
contains typed storage, initializer handles, and control-flow edges. Snapshot validation
confines handles to init arguments, targets, and matching owned-region captures,
checks writes against parameter modes, and reserves environment calling conventions
for nested regions. It validates capture mappings and ordinary call results;
all successor payloads are explicit branch arguments. Mutable-result reads identify calls by their complete
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
- Typed borrowed places carry field-index paths, not byte offsets. Borrowing, consuming arguments, and receiver resolution share source-place traversal and field-name and visibility validation; codegen resolves physical offsets from the trusted path. Reference origins retain independent field, variant, and owned-element projections. Slot-storage identity is separate from the current contents' identity, including at loop joins. Identity resolution visits each shared join once per lookup, with a local worklist for branches and cycle detection across loop backedges; simple identity chains allocate no traversal storage.
- Custom copy and move hooks may rearrange reference-bearing fields, so their results conservatively retain all possible source origins rather than assuming field correspondence. Their result origins use the same shape projection as ordinary calls. Hook effects invalidate writable referents, including during in-place copies. Call arguments retain the provenance of their prepared values, and indirect callees retain borrow metadata through argument evaluation. A value's storage origins are distinct from the borrows it contains: an `imm` parameter of a borrow-carrying type carries its parameter place separately, and an owned temporary of such a type supplies its generation as storage, so forwarding either to a callee whose result borrows the argument's place keeps the owner alive.
- Physical copy and move traversal retains captured-reference and source-storage origins through struct, tuple, array, and variant projections until the actual hook call. Trivial bit copies strip logical ownership metadata, and owned copies acquire a new generation. Hook write requirements and temporal effects are recorded at the hook instruction on its active control-flow path.
- Readonly owned-content restrictions follow finite origin projections, not a
  recursive expansion of the type graph. Symbolic aggregate origins retain the
  restriction until projection or call substitution exposes a storage view or a
  captured reference; only owned storage views are attenuated. Contracts and
  snapshots preserve unresolved restrictions across calls.
- Recursive contract paths are widened on both their source and output sides;
  descendant projections conservatively retain dependencies through selection.
  This keeps recursive parameter write-back summaries finite as well as returns.
- `deinit` call arguments preserve exact-typed source storage when direct movement is unavailable or a deferred capture requires caller identity. Directly movable arguments snapshot into independent owned storage before later arguments execute. Typing propagates consuming access through conditional and loop results and materializes fresh argument coercions before publishing their addresses. Storage joins preserve the selected address in codegen and the selected cell in compile-time interpretation, including zero-sized types. Preparing an owned argument retains its generation until the call or ordinary exit cleanup. Typing rejects overlapping writes to retained source storage while later arguments are prepared. Move hooks receive consuming access, and nested hooks dispatch normally. Local deinit authority is separate from a generation's fields-only cleanup policy. Typing derives remaining explicit-field obligations before lifetime planning; the solver does not interpret structural ownership. Generation cleanup shapes retain sparse stored-member restrictions and missing paths with both field and variant projections. Refinement replaces an owner generation on the relevant CFG edge, preserving its lifetime origin, conditional cleanup, and partial fields. Writes widen only affected tag restrictions; sibling and payload writes preserve other restrictions. Cleanup uses the original physical layout and honors nominal hooks. Deferred `init` capture effects are checked at callable acquisition and argument preparation, with published regions and cleanup surviving query/cache reuse; the language document owns those contracts.
- `AnalysisContext` derives `copy` and `move` member availability from validated ownership capabilities and specializes private declarations in `std/ownership.chi`. These use ordinary instance identities and canonical callable types, with capability checks also applied when their signatures are demanded. Typing builds their bodies with the existing selected ownership operations and lifetime machinery; runtime codegen and compile-time interpretation consume ordinary typed IR. No member query, recursive source wrapper, or backend ownership dispatch is added.
- Typing tracks ownership at control-flow edges. Lifetime effects are recorded in a boundary of the block where their operation executes; block statements and results never record into an enclosing expression's boundary. A `mut` parameter root is caller-owned and carries no generation; a value assigned to the whole root passes to the caller's place. After constructing the graph, `src/frontend/lifetime.zig` produces one path-sensitive ending plan. Each generation's explicit-drop requirement determines whether its ending is an abandonment diagnostic or automatic cleanup. Typing rejects abandonment before materializing the accepted plan as ordinary typed operations; neither the solver's state nor a generic destruction operation enters published IR.
- Cleanup reference captures are snapshots at control-flow positions, including
	known-empty contents after explicit updates. Stable instruction and boundary
	identities survive initializer hoisting. On first boundary lookup, the body
	builder creates a dense location table, then maintains it when markers are
	appended, instructions inserted, or blocks split. Subsequent lookups do not
	rescan the graph; bodies without lookups allocate no table.
	Before inserting cleanup blocks,
	typing selects the latest reaching snapshot independently on each path. Reused
	storage does not resurrect cleared captures or overwrite an earlier ending's
	provenance; ordinary uses with missing metadata do not prove empty contents.
- Conditional bindings establish ownership effects in their matched block.
  Consuming variant extraction consumes the whole generation on that edge and
  defines the selected payload's generation; the unmatched edge keeps whole-value
  cleanup. If matched alternatives require explicit drop, mismatch consumes that
  generation and drops only the unmatched automatic alternatives, using original
  variant tags. Owned bindings copy borrowed payloads; ref bindings alias them.
  Projections retain established reference origins across bindings.
- Match typing resolves recursive patterns against the subject's logical domain.
  Exhaustiveness and redundancy share disjoint remaining spaces: integer
  intervals, scalar literal complements, and tuple products preserve correlations
  between fields and nested alternatives without enumerating complete product
  domains. Only unguarded arms subtract coverage. Dispatch tests the retained
  subject, prepares captures before
  guards, and commits ownership on selection; arm results and cleanup use ordinary
  control-flow joins and lifetime planning.
  Semantic construction evaluates range bounds through ordinary compile-time
  queries and normalizes inclusive, exclusive, and omitted bounds to closed
  integer intervals without endpoint overflow. Typing selects the numeric domain
  and emits built-in comparisons; ranges are recursive pattern leaves and do not
  construct Range values or dispatch membership methods.
- Source places have local, parameter, or reference-result roots with typed field
  paths. `ref` bindings, parameters, and results preserve storage identity and
  access permission; reference fields expose T while storing its address. Typed
  IR uses borrowed reads, addresses, and writes. Variant payload borrows retain
	their origins and active-tag dependency. Runtime locals establish stable
	storage at binding, shared across loops and later references. Projections preserve
  field precision on mutable output. Frame storage remains distinct from
  caller-owned allocations, so references to copied parameters cannot escape.
  `Ref(T)` is an ordinary struct with one public reference field, `value`;
  `Ref.from(place)` constructs its handle. Array, List, and Span `get` and `[]`
  return `ref T` with receiver permissions. Owned reads copy T at the access
  boundary; ref bindings alias it.
- `MemberSpec` separates logical type from owned/reference member storage.
	Variant members use canonical storage identities, reusing internal reference
	types for address payloads; logical matching decodes those identities. Owned
	matching copies referenced payloads before rebuilding a logical union rather
	than reinterpreting address bytes. Tuple identities contain ordered member
	specifications. `TupleDefinition` derives positional field metadata so layout,
	projection, contracts, and ownership share the existing aggregate machinery.
	`ref` binds a primary type in source annotations; parentheses extend its scope.
	Persistent compile-time tuple values validate positional count and member
	storage types before restoration, using the same ordered specifications.
- Semantic return statements preserve whether the body supplied an implicit
  return. Typing evaluates and discards inline unit bodies with ordinary lifetime
  effects; explicit returns and bodies with other result types check the result.
- Conditions, branch results, and loop exits share predecessor joining for values, flow state, storage, ownership, and reference origins, with explicit policies for binding identity and borrowed facts. Unmatched ownership of whole locals and fields ends on live incoming paths before joining transferred and available states. Loop headers establish ownership generations before typing the body, including immutable owners whose cleanup shape can change; entry and backedges forward into those generations, and completion checks missing fields and cleanup policy without remapping body metadata.
- Cleanup values retain reference provenance through ownership forwarding, including unused owning parameters. After materialization, typing checks paths from expression-borrow reads through mutating destructor calls to later uses, stopping at fresh reads. Fieldwise, Box, and allocation destruction preserve contained captures. Custom destructors use inferred projected write requirements and temporal exclusions, enforcing captured authority and exporting actual effects through owning callers. Read identities and cleanup effect sites are query-local and do not enter cached IR.
- A body-analysis workspace owns all construction data, including nested initializer regions, flow versions, reference provenance, and lifetime scratch. It allocates from the computation's scratch allocator. Finishing a body or reference contract copies its structural result into that allocator once; the workspace is released with the computation's scratch. Internal graphs and temporary containers need no individual teardown or partial-construction cleanup.
- `src/frontend/body_graph.zig` owns graph construction records independently of the lifetime solver. Every graph effect has a stable body-local identity and an optional lifetime operation; ownership-neutral checkpoints carry no lifetime payload. Pending and realized reference uses retain checkpoint identities, and terminator reference effects retain identities through block splits. Boundary moves and cleanup splitting do not repair reference-use indices or rekey effect maps; a final location index resolves identities for validation. `src/frontend/reference_origins.zig` owns origin-chain storage, projection/transform equality, deduplication, and merging, while typing retains semantic reference propagation.
- Live and saved flow facts use the same persistent buffers, with independent lengths and defaults for local values, local and field availability, initializer consumption, and definite consumption completion. Each buffer lazily allocates 16-slot pages behind a pointer table. Capturing freezes the root; a later write copies its pointer table and the changed page, freezing shared children before mutation. Restoring assigns the saved root, including default-valued slots. Snapshots borrow the workspace and need no reference counts, revision trackers, prefix reconstruction, or individual cleanup. Updates evaluate their new data before acquiring writable storage. `State` joins independent facts while value and storage selection remain with the control-flow builder; both skip shared pages where their join invariants permit it. A join clears values for bindings absent on any incoming edge before selecting values or generations; lexical absence never produces a block argument.
- Lifetime tables remain dense. `src/control_flow.zig` indexes incoming and outgoing edges without merging parallel edges and shares directional dirty-block scheduling across the three analyses. Availability and representations share forward traversal while retaining separate facts and joins. Representation joining and validation enumerate available generations from bitset words; edge cleanup computes word-wise availability and demand differences before enumerating only generations that end. Typing rebuilds the index after cleanup insertion for backward reference checks, preserving both invalidated and valid path states. Ownership forwarding hints are stably grouped by predecessor and successor ordinal, so edge lowering visits only matching hints. Opt-in `BodyMeasurements` records snapshot and dense lifetime-table allocations without changing cached IR or publishing accumulators; `zig build flow-benchmark -Doptimize=fast` exercises branch scaling.

## Storage design

`Array(T, N)` stores contiguous elements inline, without a heap header. Local
arrays use local storage; embedded and boxed arrays use their owner's storage,
and returned arrays construct in receiving destinations. `filled(imm value: T)`
evaluates its argument once and makes `N` ordinary copies, including custom
hooks. It requires element copy support even at zero length, where the argument
still evaluates but no copies run; this constructor requirement is separate
from the empty array's trivial capabilities. Whole-array copy, move, and drop
lower through typed loops over element operations. `get` checks bounds and
returns `ref T | none` with the array's permission and checked origin. Dynamic
element origins may conservatively cover the whole array. Collection literals
construct in source order directly into final storage, including immovable
elements. Permitted nonlocal exits clean completed fields and prefixes in reverse
order. Expected targets derive element types through existing converter
selection and inference; otherwise fixed-count literals construct an Array.
Pending `collection_literal(T, N)` has no ordinary runtime representation.
Standard `[]` checks bounds and panics, and `[]=` uses ordinary reference replacement.
Setters prepare owned arguments before bounds checks and retain automatic-drop,
direct-move, and reference-origin restrictions. Collection conversions, handled
initializers, and call preparation scope pending capture restrictions through
their synchronous construction boundary, retaining outer pending captures and
normal result origins. List and
Span use the same methods, with writable indexing only on writable spans. Default
construction and individual element consumption remain absent.

`List(T)` owns an allocation and initialized count. Its literal converter obtains
storage before evaluating elements and uses a typed allocation-array storage
projection to construct the deferred region directly in that storage. Allocation
failure terminates runtime execution with status 134, outside ordinary value
flow. `List(T).from(...)` instead returns `List(T) | none`; allocation refusal
leaves its deferred elements unevaluated. Optional element values remain ordinary
data. Completed Lists destroy elements in reverse order and release storage.
new/reserve/append return explicit optional results while preserving the initialized
prefix. Replacement storage is allocated before relocation. Supported relocation
uses ordinary slot construction, with no separate failure repair path. Removal
and consuming traversal use the same ownership and reference contracts.
Box, List, Ref, Span, and heap-backed text execute ordinary declarations in
the interpreter using typed slot and collection initialization, including Box
element and allocation-array projections. Host layout and checked allocation-size
rules are shared with native execution; compiler OOM remains retryable infrastructure
failure rather than ordinary allocation failure.

Runtime `for`/`if` clauses and runtime-sized spreads select List construction,
while static expansion and Array spreading retain `collection_literal(T, N)` and
its converter path. A static upper bound permits one allocation and construction
of fresh immovable elements. Unbounded growth requires directly movable,
automatically droppable elements. List helpers reserve before consuming each
initializer, construct in the final slot, and advance the initialized prefix only
after construction. Implicit allocation and growth failures panic; `List(T).collect`
receives the construction-only `init collection_sequence(T)` carrier. That type
selects recoverable bracket allocation for direct and indirect calls, including
fixed-count literals. Its logical `value: List(T) | none` field preserves contained
reference paths; consuming the initializer projects that field into the actual
optional List destination. Allocation refusal returns `none` after cleaning the
initialized prefix. Owning allocation extraction preserves contained references
without retaining a dependency on the released slot; general per-slot removal
and mutation provenance remain separate work.

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
`List` derives capacity from its allocation and tracks only its initialized
prefix. Do not introduce a thin allocation handle until retaining layout and
location has a demonstrated material cost. Compiler storage and lifetime checks
need not be expressible as ordinary library code.

References and `Ref(T).value` store one address; `Span(T)` stores a private typed
`StorageCursor(T)` and initialized length for checked indexing and slicing.
Reference fields preserve captured referent authority through const carriers;
owned storage paths retain readonly attenuation. Copies preserve this distinction
per field, array element, and variant member. Mutable bindings cannot upgrade
readonly captures. Reference-call preparation applies the same owned-shape
attenuation to contained origins rather than rereading unattenuated captures.
Referent-content substitution follows the type at each contract path: it crosses
an actual reference edge without inventing one for an owned value. Heap-owned
borrowed contents use logical element paths, independently of physical wrapper
fields. Safe constructors borrow initialized
arrays or List prefixes; unsafe allocation constructors require initialization
proof. Cursor identity and shape are validated at the standard-library analysis
boundary. Host layout resolves element offsets, including zero-sized elements.

Reference contracts preserve result and mutation dependencies through fields,
elements, and variants; unknown callables conservatively project possible inputs.
Returned readonly ranges depend on contents, including inside aggregates,
while Ref and writable range handles retain
storage dependencies. Writes invalidate contents even without automatic drop.
Replacing an aggregate does not itself write through independent handles stored in it;
effects through nested writable handles are tracked separately. Stable slot
handles can observe replacement, while nested owner borrows and readonly ranges
retain content dependencies. UTF-8 validation cannot outlive conflicting byte
writes. Owner transfer still invalidates earlier borrows.

### Future allocation interface

This is a conceptual interface, not public non-host declarations. Layout
resolution binds a target, location, type, count, and alignment before a provider
receives the request. Keep resolved byte `AllocationLayout` separate from that
typed request so a host layout cannot be paired with device storage, or a count
with inconsistent bytes:

```text
func resolve_layout(
		static T: type,
		target,
		location,
		count,
		alignment = natural_for(T, target, location),
) ResolvedAllocationLayout(T) | none

func allocate(
		mut provider,
		resolved: ResolvedAllocationLayout(T),
) Allocation(T) | none

func deallocate(static T: type, deinit allocation: Allocation(T))
```

Prefer `allocate` and `deallocate`; `release` is ambiguous with decrementing
shared ownership. The allocation retains the resolved request and provider
authority directly or through lifetime dependencies. Layout and location
accessors remain sketches. Host low-level operations stay under `std.memory`,
with matching `Allocation` methods; `Box` and `Ref` are prelude exports.
`unsafe_own_box` is internal ownership transfer, not a public constructor.
Consuming `take(T, owner)` uses deinit access without preliminary owner
relocation; `get_value` would obscure borrowing versus copying versus transfer.
Copying `Ref(T)` copies only the handle; owning a read of `.value` requires
pointee copy support.

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
	Chimera instead retains complete deallocation facts, uses ordinary optional
	failure, and requires distinct stable identities for successful zero-byte
	allocations.
- Mojo's [Pointer](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/pointer.mojo)
	combines pointee type, mutability, origin, and address space. It is non-null;
	arithmetic, raw-address access, initialization, and destruction are unsafe.
	`UnsafePointer` is a deprecated alias. This supports one non-owning Chimera
	Ref abstraction, with permission retained from its captured origin.
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
	returns an optional. Chimera keeps location separate and initially requires
	synchronous transfers unless a completion resource retains both allocations.

## Text and basic I/O

`ByteStrings` interns owned, decoded UTF-8 bytes by content. Compile-time literal
values and static storage cursors retain interner IDs and byte offsets; canonical
values never contain evaluator or native addresses. Materializing canonical
struct values preserves their private fields without granting source initializers
access to them. Literal default typing selects the registered `std.text.String`
identity even when prelude exports are disabled or shadowed. Registered text
types resolve through one memoized `TextType` query keyed by name. StaticString
carries no lifetime-tracked borrow: its bytes are permanent, so `BorrowShape`
treats it as borrow-free and reading its `bytes` field yields permanent readonly
origins. Text owners holding it therefore keep place-based borrowing.

`std/text.chi` owns StaticString, the `StaticString | OwnedBytes` String storage,
explicit clone,
optional growth, byte views, UTF-8 validation, and text slicing. `std/io.chi` owns
standard stream handles, optional progress results and ordinary printing.
`print` handles write failure in ordinary source with the `panic` keyword;
printing itself has no special compiler operation. The only byte-access and
OS operations are registered externs private to their owning storage modules.
BytesView wraps a readonly byte Span; StringView adds a maintained UTF-8 guarantee.
Writes consume initialized readonly byte spans. Reads initialize spare allocation
slots and extend `List(byte)`'s initialized prefix only after success. Reached
compile-time I/O is an execution capability error; ordinary optional matching
cannot turn it into compile-time effects. Allocation-backed strings execute
within the same evaluation-local storage publication boundary as other owners.
String conversion for scalar values, collections, byte views, Box/Ref, and ranges
also lives in ordinary standard-library source. Collection formatting borrows
elements through spans and invokes each element's String conversion once. Integer
formatting keeps a nonpositive remainder so the signed minimum needs no wider
numeric primitive. The generic print export uses an explicit conversion followed
by the existing borrowed-text write path. Its body validates composed conversions,
including identity and per-member variant conversion.

Borrow origins distinguish permanent static data from local and parameter
storage. Scalar argument copies do not introduce owner dependencies. Temporary
address-passed aggregates do. Taking the address of a by-value parameter through
an alias retains its local frame dependency. Borrowed variant conditions retain a path of field
and variant projections so aliases address the current owner through SSA joins.
The interpreter represents array-backed typed cursors as transient cells whose
snapshots preserve backing identity; such cursors cannot become canonical values.
Allocation-backed cursors compare the allocation's logical identity and frozen
contents across copied descriptors; inline backing retains its original cell identity.
Literal-backed readonly byte cursors and references instead publish symbolic
interner IDs and checked offsets. Copying and permission attenuation retain the
typed destination's cursor identity before publication. Snapshot format CHIMERAQRY45
validates their nominal standard identity, permission, bounds, and operation types, including source-free
intern restoration; transient storage addresses are never persisted.

Each compiled function owns its constant byte sequences and relocations refer
to function or data indices. The linker deduplicates immutable bytes across
functions and places them after code in the read-only ELF load segment. Empty
sequences retain an addressable byte without making it part of their length.
Native I/O uses the normal callable ABI, retries EINTR, and reports OS failures
as ordinary optional variant results. Output artifacts request one startup
SIGPIPE disposition change. Disk snapshots validate symbolic IDs, offsets,
projections, and data relocations under the updated format.

Mojo reference: [literal storage and owned String](https://github.com/modular/modular/blob/135c332fec9b326cab8e2f3951a0b2f31d017a5d/Mojo/stdlib/std/collections/string/string.mojo),
[UTF-8 validation](https://github.com/modular/modular/blob/135c332fec9b326cab8e2f3951a0b2f31d017a5d/Mojo/stdlib/std/collections/string/_utf8.mojo),
and [file-descriptor progress](https://github.com/modular/modular/blob/135c332fec9b326cab8e2f3951a0b2f31d017a5d/Mojo/stdlib/std/io/file_descriptor.mojo).
Chimera uses unique ownership and rejects ambient compile-time I/O.

## Backend and execution

- Codegen lowers the published graph and layout facts to a query-local x86 instruction stream in `src/backend/machine.zig` before allocating virtual scalar registers; fixed-only functions encode directly. It emits owned machine code and symbolic references without compiling callees. Machine liveness follows expanded branches and copies, not semantic SSA. Relocations and call-site positions become byte offsets after allocation; only final artifacts are published or cached. Reachability starts at the designated file's synthetic top-level entry, includes referenced callable values, and supplies a deterministic order for linking an x86-64 ELF executable. A function named `main` has no special entry role. The entry body returns unit and performs ordinary ownership cleanup. ELF startup exits 0 after its normal return.
- Cache restoration validates artifact alignment, nonempty code, relocation patch ranges, reference indices, and data kinds and addends before publishing artifacts. Linking trusts this metadata and treats duplicate artifacts, missing entries, and incomplete reachable closure as compiler invariants. Executable size and displacement limits remain recoverable backend errors.
- `ArgumentPassing` caches the structural derivation from ownership capabilities: arrays and containing structs or variants pass by address even when directly movable, as do types that cannot move directly. Source-invalid types publish a null result, preserving their diagnostic dependencies. Primitive passing remains a direct adapter fact. One backend `CallLayout` derives incoming and outgoing argument and return locations from type/representation pairs; each argument's slot layout and indirectness are classified together. Incoming parameters borrow their typed block descriptors directly. Discarded non-call values need no slots; discarded indirect call results still require storage. The calling convention is internal to the compiler, not a platform ABI.
- Aggregate construction uses addressable storage, including four-byte register returns. Constant field and variant projections of known stack storage fold into stack offsets without emitted pointers. Shared backend `copyRange` emits byte copies for any aggregate when the selected operation permits them, not just arrays; nontrivial element operations retain typed loops and hooks. Copies use direct stack operands or pointers prepared once per copy, eight-byte chunks with exact four-byte and byte tails, and `rep movsb` above 256 bytes. Scalar register and immediate transfers retain their own path. Dynamic element addressing sign-extends indices and uses native scales for sizes 1, 2, 4, and 8, with multiplication for other nonzero sizes.
- The encoder and assembly renderer share opcode bytes, operand widths, and display forms in `src/backend/x86_encoding.zig`, including selected zero/small displacements and signed-byte immediates. Relative branches and calls retain fixed-width relocation fields. Unknown bytes end decoding rather than permitting resynchronization inside an instruction.
- Native block emission is entry-first, then block-ID order. Terminators use the actual next emitted block for fallthrough and arrange predicate branches without crossing edge-copy code. This changes instruction selection, not the published graph: empty-block threading and algebraic simplification remain outside codegen. Divergence blocks emit an invalid-instruction trap so unexpected fallthrough cannot execute another block or outlined region.
- Functions containing loops use the backend's weighted live-range allocator for unaddressed integer and boolean values, saving and restoring only the preserved registers they use. Values requiring storage identity remain in memory. Independent scalar branch copies write their destinations directly; dependent copies retain parallel-copy scratch storage. [Optimization design](docs/OPTIMIZATION.md) owns the pass rules and allocation details.
- Embedded standard-library declarations use ordinary lookup, signatures, and instance identities. Supported compiler-owned externs, including exit and host-memory operations, publish artifacts under those identities. Allocation and extraction use host-only emitters; slot construction uses ordinary typed init calls into host storage. Another location will require its own provider and access path. A compile-time exit instead propagates compiler control to the driver without producing an executable. `src/runtime.zig` publishes and runs successful executables.
- Semantic analysis lowers optional-message `panic` syntax to an ordinary call
  to the registered private `std.text.panic_message` extern, independently of
  imports and shadowing. The default message is a literal; normal typing supplies
  StringView conversion, argument evaluation, ownership retention, and `never`
  control flow. The interpreter snapshots message bytes into the ByteStrings
  interner and returns an execution error with the caller span. Existing query
  diagnostics and call traces propagate it without compiler-control exit.
- Runtime bodies retain instruction and terminator spans. Compiled artifacts
  own call-site labels, return offsets, and the caller's fixed stack size,
  including relocated metadata for outlined initializer regions. SourceRegistry
  publishes source paths as owned inputs; path or source edits invalidate labels.
	`SourceLineStarts` indexes each file once per source revision; trace sites find
	line and column by binary search instead of rescanning source prefixes.
  The linker resolves these records into a read-only return-address table when
  panic is reachable. The panic runtime reports bytes and walks at most 1024
  known frames without allocation, frame pointers, or successful-call tracing
  instructions, then exits with status 134 even if stderr writes fail. The
  unrecorded startup call terminates the walk. Panic does not unwind live owners.
- Diagnostics, native trace labels, and SSA/assembly callable labels share
  source-style function naming. Instance identities supply canonical static
  arguments; lexical specialization arity places inherited arguments on their
  owners, as in `Item(int).stop(7)`. Type and value rendering includes nested
  types, aggregates, variants, function references, and escaped literal bytes,
  without evaluating values or specialization constraints. Function diagnostics
  retain the owning instance, including compile-time callers, so errors in
  different specializations remain distinguishable at the same source span.
- Standard calls are classified by registered declaration identity at the analysis boundary; lowering retains the resolved behavior instead of rediscovering names. Box, List, and reference-write type eligibility is checked when a signature is demanded, including acquisition as a function value. These capability constraints remain compiler-owned until the language can express them. Reference-write eligibility is shared with assignment typing. `Box.new` is an ordinary library init receiver returning Box(T) | none. The compiler-owned ordinary raw slot initializer publishes a typed body that selects an allocation element and invokes its init parameter into that destination; backend calls use the general init protocol.
- Standard memory structs retain nominal identity and specialization lookup over existing queries. Arrays instead retain canonical structural identity with a separate standard-source namespace association; representation and ownership checks remain type-specific.

## Persistence

- The in-memory engine handles every build, including builds using the optional disk cache. A successful whole-program executable is keyed by the loaded source and module snapshot plus compiler identity. A separate query snapshot restores interned identities and reuses typed runtime bodies and compiled functions only after validating their observed dependencies.
- The embedded std bundle supplies typed, prepared, and optimized bodies, call components, and native functions as lazy query results. Reuse validates the closed std sources and each record's variant representations; optimized bodies and native functions also track the producer's inline limit. The interpreter and runtime validation continue to read typed bodies, while inlining reuses optimized bodies. New specializations use ordinary queries.
- Only successful work populates these caches; source rejection and compile-time control do not become executables. Cache validation and atomic publication keep damaged or partial data from being reused.
