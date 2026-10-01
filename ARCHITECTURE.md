# Architecture

This is a high-level map of the compiler's ownership and stage boundaries. [syntax&semantics.txt](syntax&semantics.txt) owns language rules, [ROADMAP.md](ROADMAP.md) tracks implemented features and gaps, and [PROGRAM_FLOW.md](PROGRAM_FLOW.md) describes the current queries, invalidation, and result lifetimes in detail.

## Queries and stages

- `src/main.zig` registers source inputs and requests `BuildExecutable`. Compiler queries in `src/queries.zig` coordinate parsing, semantic analysis, typing, compile-time interpretation, and code generation; the engine in `src/query/` schedules and memoizes work without depending on compiler stages. `src/structures.zig` holds shared data, and frontend and backend stages do not import query orchestration.
- The engine records input and query dependencies, including reads of absent inputs. It can run independent queries on workers, but a result publishes only after its dependencies settle. Recomputations commit owned results, dependencies, and diagnostics together; equal observable results stop invalidation from propagating. Inputs are refreshed only while the database is idle.
- A missing optional result can mean source rejection or unavailable state; source diagnostics are emitted separately. Infrastructure failures remain errors, and broken compiler invariants use assertions. `src/diagnostics.zig` owns presentation, not semantic decisions.

## Sources and identity

- `SourceRegistry` publishes source text, file-to-module ownership, module membership, and existence as query inputs, preserving file IDs across directory refreshes. It also registers the embedded `std` files. The module catalog, not interner presence, determines whether a module currently exists.
- Declarations are shared across a module, while imports and implicit prelude bindings belong to individual files. The module graph validates imports, exports, and declaration ownership before compiling the entry, without evaluating unused declarations or bodies. Resolution uses the defining file's effective scope.
- `ItemId` names a declaration independently of its current source location; `InstanceId` adds canonical compile-time specialization arguments. Resolution goes through current module membership, so moving or removing a declaration invalidates its users. The interner gives variants and callables canonical identities and declared or generated structs nominal identities; both struct forms expose the same definition to downstream stages. Query keys and cached results retain owned data or stable, session-local identities rather than references into replaceable source.

## Analysis and compile time

- Semantic analysis validates source and lexical structure in a query-local expression graph. Typing resolves names, specializes static arguments, checks operations and calls, and publishes a single typed SSA control-flow graph for each demanded function or compile-time thunk. Signatures and bodies are separate queries, so a caller can refer to a function without analyzing its body.
- `AnalyzeFunctionInstance(InstanceId)` owns all runtime bodies, including unspecialized declarations. `AnalysisContext` supplies source-dependent resolution, visibility, and specialization. Its `TypeFacts` view owns context-free structural and ownership lookups and is also used directly by diagnostics and cache validation. `HostTypes` adds physical layout for codegen; compile-time interpretation uses its own call executor. These adapters derive existing query facts without adding caches.
- Typing chooses type-specific operations and explicit coercions before publication; a selected converter is published as an ordinary call. Joins, ownership uses, and fallible success/failure paths are represented in the graph; later stages do not rediscover their legality or build another general-purpose lowering IR. Source evaluation order is preserved.
- Shared IR owns direct operand and successor enumeration. Normalization, cache validation, lifetime traversal, and backend use marking reuse it; array ranges, operation legality, and addressability remain with their consumers. Block arguments describe their logical type and whether the join passes storage. Storage selection is independent of a type's move capability, and cleanup edge splitting preserves it.
- Calls share one operation with independent direct/indirect targets and optional result destinations. Owning initialization of a type that cannot move directly constructs in the destination its consumer supplies: `local_storage` for locals, temporaries, and owned arguments, `result_storage` for the caller's result, and logical storage projections for fields and variant payloads. Ordinary calls, copies, moves, and variant coercions write those destinations; conditional and loop results propagate them, and fallible results construct in storage instead of crossing the success edge. Typing never relocates a completed value of such a type and rejects forms that would need it. Inferred-return compile-time thunks publish their result as a value instead. Known direct `Box.new` calls obtain storage before lowering their unresolved initializer through this same construction path. A private standard-library owner releases unfinished storage through ordinary lifetime planning; query-local construction scopes collect initializer failures and retain storage through early exits. Successful construction transfers the initialized value and allocation to Box together. The constructor interception remains temporary until general deferred `init` parameters replace it. Typing owns evaluation order, captures, and cleanup paths; codegen and the compile-time interpreter consume explicit destinations and operations.
- A value that cannot move directly is denoted by its storage. Field reads are storage projections, and a mutable local keeps one storage value across field updates, replacements, `mut` arguments, and loops: `call_mut_argument` writes its destination, and loops carry only the local's lifetime generation, not a block argument. Replacement ends the old value before constructing in the same storage; a replaced field leaves its root's generation first, so an exit from the right-hand side sees the field missing. Joins that select such values pass addresses; codegen gives their block arguments address slots, and the compile-time interpreter passes storage cells, promoting a runtime slot before a storage projection or address-passed join creates a view. Compile-time field reads materialize only the selected field, so an unfinished sibling does not prevent access.
- For a borrowed variant argument that cannot move directly, its known type follows conditional results and loop breaks. Fresh initializers construct into storage of that type; existing values of the same type retain their borrowed storage. Widening an existing narrower value still requires direct movability. Typing carries the borrow context separately from an owning destination and preserves the source's cleanup and reference origins when widening directly movable values.
- Compile-time expressions that require evaluation, including initializers, static arguments, and expressions in type positions, are typed before interpretation; direct type aliases and declared struct identities can resolve without it. Compile-time calls are memoized by concrete instance and canonical argument values. Interpreted outcomes distinguish values, fallible failure, and compiler control; type values have no runtime representation.

## Deferred construction (planned)

General `init` parameters are not implemented. The following boundaries guide
their implementation; [ROADMAP.md](ROADMAP.md#1-destination-construction-and-consuming-access)
owns the remaining checkpoints and [syntax&semantics.txt](syntax&semantics.txt)
owns the language contract.

- Keep a parameter's pending/consumed obligation separate from the result type's
  move, copy, and drop capabilities. A pending initializer is neither a live T
  nor T's storage. Its representation must remain distinct in typed operands,
  entry arguments, execution, and cache validation.
- Type the complete deferred expression in its caller's lexical context,
  including blocks, conditionals, loops, and nested construction. Publish owned
  typed regions and explicit captures with the analyzed caller. Lower those
  regions to private callbacks with call-lived environments; invoke them with a
  destination, and forward their handles without executing them. This needs no
  public capturing-closure API. Raw source pointers and frame addresses never
  enter query results or disk snapshots.
- Typing owns capture authority, lifetime retention, reference origins, and
  effects across eager argument preparation and receiving calls. Deferring a
  transfer retains access without performing it. Runtime cleanup must know
  whether each captured root or field remains live after skipped or completed
  evaluation; a conservative source diagnostic alone cannot resolve that
  destruction obligation. Direct and indirect calls share this contract.
- Separate declared source fallibility from deferred evaluation outcomes. An
  ordinary `materialize(init item: T)` can encounter initializer failure;
  receiving `init` does not authorize arbitrary fallible statements in its body.
  The private execution protocol must also preserve caller-directed return,
  break, and continue, unwinding receiving calls before dispatching the lexical
  continuation. Choose the outcome encoding and typed-region layout with the
  first executing implementation, rather than extending the current boolean
  failure convention independently.
- Interpret frame-bound initializer handles within the active execution, using
  the same destinations and outcomes as native code. They cannot enter canonical
  `CompileTimeValues` or memoized argument tuples. Keep memoization for completed
  values and cover call-cycle detection on the frame-local path. General `init`
  tests can use local storage; host allocation remains a runtime capability.

## Ownership and layout

- Declared and generated structs publish a common definition with fields and validated ownership hooks. `OwnershipCapabilities(TypeId)` validates logical by-value containment and composes move, copy, and drop facts without requesting physical layout. Layout consumes that validated fact before determining size, alignment, and field or variant placement. Direct movement is derived from these capabilities, not stored separately. `HostTypeLayout(TypeId)` describes the x86-64 host representation; a non-host layout must be derived for its target's location-specific layout domain, never inferred from host layout. The accepted provider, location, layout, and access contracts are in [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md).
- Typed borrowed places carry field-index paths, not byte offsets. Borrowing, consuming arguments, and receiver resolution share source-place traversal and field-name and visibility validation; codegen resolves physical offsets from the trusted path. Reference origins retain independent field, variant, and owned-element projections. Slot-storage identity is separate from the current contents' identity, including at loop joins.
- Custom copy and move hooks may rearrange reference-bearing fields, so their results conservatively retain all possible source origins rather than assuming field correspondence. Hook effects invalidate writable referents, including during in-place copies. Call arguments retain the provenance of their prepared values, and indirect callees retain borrow metadata through argument evaluation.
- `deinit` call arguments carry exact-typed source storage; typing propagates consuming access through conditional and loop results and materializes fresh argument coercions before publishing their addresses. Storage joins preserve the selected address in codegen and the selected cell in compile-time interpretation, including directly movable and zero-sized types. Preparing an owned root retains its generation until the call or failure cleanup. Typing rejects overlapping writes to any retained source while later arguments are prepared. Move hooks receive consuming access, and nested hooks dispatch normally. Local deinit authority is separate from a generation's fields-only cleanup policy. Typing derives remaining explicit-field obligations before lifetime planning; the solver does not interpret structural ownership. Milestone 1 still needs deferred `init` effects across callable acquisition, indirect calls, and query/cache boundaries; the language document owns those contracts.
- `AnalysisContext` derives `copy` and `move` member availability from validated ownership capabilities and specializes private declarations in `std/ownership.chi`. These use ordinary instance identities and canonical callable types, with capability checks also applied when their signatures are demanded. Typing builds their bodies with the existing selected ownership operations and lifetime machinery; runtime codegen and compile-time interpretation consume ordinary typed IR. No member query, recursive source wrapper, or backend ownership dispatch is added.
- Typing tracks ownership at control-flow edges. Lifetime effects are recorded in a boundary of the block where their operation executes; block statements and results never record into an enclosing expression's boundary. A `mut` parameter root is caller-owned and carries no generation; a value assigned to the whole root passes to the caller's place. After constructing the graph, `src/frontend/lifetime.zig` plans path-sensitive cleanup and explicit-drop obligations from query-local metadata. Typing rejects abandonment before materializing the plan as ordinary typed operations; neither the solver's state nor a generic destruction operation enters published IR.
- Cleanup values retain reference provenance through ownership forwarding. After materialization, typing checks paths from expression-borrow reads through mutating destructor calls to later uses, stopping at fresh reads. Fieldwise and standard Box destruction visit only contained destructors; user hooks conservatively receive all writable references in their argument. Read identities and cleanup effects are query-local and do not enter cached IR.
- Immutable local-binding metadata has one allocation owner. Query-local snapshots retain only the value prefix through the last bound local, with full-sized availability arrays; restoring a snapshot clears the omitted tail. `State` owns cloning and cleanup of these slices. Lifetime tables remain dense. Opt-in `BodyMeasurements` records their footprint without changing cached IR or publishing accumulators; `zig build flow-benchmark -Doptimize=ReleaseFast` exercises branch scaling.

## Backend and execution

- Codegen consumes the published graph and layout queries directly, producing owned machine code and symbolic references per function without compiling callees. Reachability starts at the designated file's synthetic top-level entry, includes referenced callable values, and supplies a deterministic order for linking an x86-64 ELF executable. A function named `main` has no special entry role.
- Argument passing is derived from `OwnershipCapabilities(TypeId)`; values that cannot move directly pass by address. One backend `CallLayout` supplies storage planning, argument emission, returns, mutable copy-back, and copy hooks. Mutable calls write their updated arguments back. The calling convention is internal to the compiler, not a platform ABI.
- Aggregate construction uses addressable storage, including four-byte register returns. The encoder and assembly renderer share opcode bytes, operand widths, and display forms in `src/backend/x86_encoding.zig`; unknown bytes end decoding rather than permitting resynchronization inside an instruction.
- Embedded standard-library declarations use ordinary lookup, signatures, and instance identities. Supported compiler-owned externs, including exit and host-memory operations, publish artifacts under those identities. Typed allocation and slot transfers use host-only emitters; another location will require its own provider and access path. A compile-time exit instead propagates compiler control to the driver without producing an executable. `src/runtime.zig` publishes and runs successful executables.
- Standard calls are classified by registered declaration identity at the analysis boundary; lowering retains the resolved behavior instead of rediscovering names. Box, Buffer, and reference-write type eligibility is checked when a signature is demanded, including acquisition as a function value. These capability constraints remain compiler-owned until the language can express them. Reference-write eligibility is shared with assignment typing. The analysis boundary validates the private uninitialized-storage owner's signature, nominal identity, fields, and automatic cleanup capability before typing uses it.
- Standard memory types share nominal identity and specialization lookup over existing queries. Their representation and ownership checks remain type-specific.

## Persistence

- The in-memory engine handles every build, including builds using the optional disk cache. A successful whole-program executable is keyed by the loaded source and module snapshot plus compiler identity. A separate query snapshot restores interned identities and reuses typed runtime bodies and compiled functions only after validating their observed dependencies.
- Only successful work populates these caches; source rejection and compile-time control do not become executables. Cache validation and atomic publication keep damaged or partial data from being reused.
