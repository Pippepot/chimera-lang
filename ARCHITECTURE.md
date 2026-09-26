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
- Typing chooses type-specific operations and explicit coercions before publication. Joins, ownership uses, and fallible success/failure paths are represented in the graph; later stages do not rediscover their legality or build another general-purpose lowering IR. Source evaluation order is preserved.
- Compile-time expressions that require evaluation, including initializers, static arguments, and expressions in type positions, are typed before interpretation; direct type aliases and declared struct identities can resolve without it. Compile-time calls are memoized by concrete instance and canonical argument values. Interpreted outcomes distinguish values, fallible failure, and compiler control; type values have no runtime representation.

## Ownership and layout

- Declared and generated structs publish a common definition with fields and validated ownership hooks. `OwnershipCapabilities(TypeId)` composes move, copy, and drop facts across types; separate layout queries determine size, alignment, and field or variant placement, rejecting recursive by-value struct containment. `TypeLayout(TypeId)` currently describes the x86-64 host representation; a non-host layout must be derived for its target's location-specific layout domain, never inferred from host layout. The accepted provider, location, layout, and access contracts are in [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md).
- Typing tracks ownership at control-flow edges. After constructing the graph, `src/frontend/lifetime.zig` plans path-sensitive cleanup and explicit-drop obligations from query-local metadata. Typing rejects abandonment before materializing the plan as ordinary typed operations; neither the solver's state nor a generic destruction operation enters published IR.

## Backend and execution

- Codegen consumes the published graph and layout queries directly, producing owned machine code and symbolic references per function without compiling callees. Reachability starts at the designated file's synthetic top-level entry, includes referenced callable values, and supplies a deterministic order for linking an x86-64 ELF executable. A function named `main` has no special entry role.
- `TypeInterner.argumentPassing` derives a shared caller/callee passing mode from `OwnershipCapabilities(TypeId)`; values that cannot move directly pass by address. Mutable calls write their updated arguments back. The calling convention is internal to the compiler, not a platform ABI.
- Embedded standard-library declarations use ordinary lookup, signatures, and instance identities. Supported compiler-owned externs, including exit and host-memory operations, publish artifacts under those identities. A compile-time exit instead propagates compiler control to the driver without producing an executable. `src/runtime.zig` publishes and runs successful executables.

## Persistence

- The in-memory engine handles every build, including builds using the optional disk cache. A successful whole-program executable is keyed by the loaded source and module snapshot plus compiler identity. A separate query snapshot restores interned identities and reuses typed runtime bodies and compiled functions only after validating their observed dependencies.
- Only successful work populates these caches; source rejection and compile-time control do not become executables. Cache validation and atomic publication keep damaged or partial data from being reused.
