Chimera: scoped context, allocation, and logging
1. Scope and invariants
Implement synchronous scoped context, general with statements, and borrowed bound functions for standard-library service handles. Allocation and logging are both in scope; neither requires service-specific scoping syntax.

Use the callable construction, representation, ownership, and reference rules in [CLOSURES.md](CLOSURES.md). [syntax&semantics.txt](../syntax&semantics.txt) remains the language source of truth, and [ARCHITECTURE.md](ARCHITECTURE.md) owns compiler/query boundaries. All three implementation slices are delivered; Section 13 records their acceptance. [ROADMAP.md](../ROADMAP.md#scoped-context-implementation-slices) owns future priorities and the revision's scope boundary.

Expose std.context as context through the prelude, with these initial entries:
Entry	Handle type	Native root default
context.allocator	Allocator	Execution environment's default heap provider
context.logger	Logger	Static stderr logger, minimum severity trace


Each entry has its own storage and synthetic dependency. Rebinding one leaves the other unchanged. Compiler analysis and lowering operate on registered contextual declarations, not a single hard-coded allocator slot.

Context supplies defaults. Existing resources retain handles needed to manage them; one-shot operations select their service when invoked. No implicit provider migration, reference counting, ownership extension, scratch redirection, or hidden context argument on ordinary calls is introduced.

Migrate allocation and output failures to ordinary marked error alternatives, together with their standard-library consumers. Keep none for ordinary absence. Logging is a separate library API: overriding the logger does not redirect print, stdout, or stderr. Allocating lexical-closure erasure and asynchronous context inheritance remain outside this context revision; context can use direct bound methods without waiting for allocating erasure. Further standard-library services may register borrowed-handle entries using the same declaration, factory, lifetime, and scoping rules; they need no new language primitive.
2. Surface syntax and access
var tracker = TrackingAllocator{upstream = context.allocator}

with context.allocator = tracker.allocator()
    build_index()
The right-hand side uses ordinary evaluation and copy/move rules. The provider's typed library factory borrows tracker with its declared receiver permissions and returns an Allocator. with itself performs no implicit borrowing or interface adaptation. An already constructed handle works identically:
const allocator = tracker.allocator()
with context.allocator = allocator
    build_index()
A concrete logging backend supplies a borrowed handle through its typed factory in the same way:
with context.logger = logger.logger(LogLevel.info)
    build_index()
Here logger owns the backend state; the installed Logger borrows it. Nest this with an allocator replacement when both services should change.

These factory methods declare mut receivers when they need writable access to provider-owned state; imm receivers may preserve writable references already captured inside the provider. Ordinary immutable converters cannot acquire writable authority over an immutable parameter's owned fields. Direct provider-to-handle conversion is allowed only where an ordinary declared converter has sufficient authority. Permission-preserving ref converters would be a separate language extension and are not required for this surface.

Support these two forms:
with target = expression
    body

with expression
    body
The first temporarily replaces a binding. The second retains an ordinary resource through the body and then performs its normal destruction. It does not unwrap fallible values or activate a context guard. Multiple replacements use nested statements; there are no named call arguments or context.override API.
Target	Ordinary assignment	Scoped replacement
Ordinary mutable location	Allowed	Allowed
Ordinary immutable location	Rejected	Rejected
Contextual entry	Rejected	Allowed


Reading a contextual entry produces its handle value, not a reference to its storage. Checked code cannot take a writable reference to that storage, swap it, move it out, or mutate it through aliases. Mutating the selected service's permitted internal state remains legal.

Mark registered standard-library declarations as contextual in compiler symbol metadata. Resolve this property by declaration identity, including through aliases and re-exports, not by matching source spelling. This revision adds no public slot type, binding descriptor, contextual-declaration keyword, or user-defined contextual-entry facility.
3. Scoped replacement lowering
For with target = expression:
1. Resolve the target location once. Evaluate and convert the replacement once under the old context. Do not change the target if evaluation exits early.
2. Retain the target location, save its previous value without destroying it, and install the replacement.
3. Execute the body. Ordinary locals retain existing last-use destruction.
4. Perform cleanup required when leaving the body while the replacement remains installed.
5. Restore the saved value. Destroy the displaced value after restoration, using ordinary destruction rules.
Keep hidden saved values and all required dependencies alive through restoration. Apply the exit sequence on normal completion, return, break, continue, and supported error-propagation exits. Nested replacements restore in reverse nesting order. Native panic continues to terminate without unwinding.

An ordinary target must remain valid and initialized at every exit. The body may assign it normally but may not move or invalidate its containing storage or leave the target moved-from. Restoration is an invalidating mutation: references into replaced contents cannot survive it unless ordinary reference analysis proves them valid.

Context entry installation/restoration copies or moves handles whose private callable fields were constructed from direct bound methods or named functions. Those ordinary callable copy/move/drop operations allocate nothing, invoke no provider ownership hook or service callback, and acquire no ownership of provider state. Check this construction invariant at service factories and preserve it in result contracts through copies, fields, joins, and opaque forwarding. Do not infer trivial copying from the func type alone. There is no user-visible active guard to escape or drop early.

For with expression, evaluate into a hidden retained local, perform body cleanup, then destroy that local. Its lifetime extension does not extend any referenced owner's lifetime beyond ordinary checked dependencies.
4. Callables and borrowed bound functions
For a method with a borrowed receiver, tracker.allocate constructs a callable with that receiver bound. Preserve its required reference permissions and ordinary method resolution. Consuming receivers are not supported by this borrowed-binding operation.

A concrete bound function contains a receiver reference and has statically known method code. It satisfies ordinary callable parameters without erasure. A stored func(...) uses the common two-word native handle from [CLOSURES.md](CLOSURES.md): a descriptor pointer and a payload word. The descriptor provides invocation, copying, and destruction/storage-release operations. A bound method's payload is the reference to its original receiver; a named function or noncapturing closure has an unused payload. Only the compiler forms these representations.

The receiver points directly to the original checked object, never to a temporary factory frame or temporary closure wrapper. Temporary receivers gain no lifetime extension. Constructing, erasing, copying, transferring, or destroying a bound callable does not copy, destroy, allocate, or reference-count the receiver, and requires no environment allocation. Copying an existing bound callable copies its receiver reference, not a reference to that callable's wrapper. A mutable receiver method requires writable authority when bound; invoking an immutable handle preserves that captured authority without granting additional permissions.

Hidden receiver references participate in existing lifetime, relocation, mutation, invalidation, and cleanup analysis. Stored or returned callables remain valid only while their receiver dependencies remain valid. They are not categorically restricted to nonescaping use.

Inferred named-function references remain lightweight; explicit stored func(...) annotations request the common erased handle. Concrete lexical closures store captures inline and can be borrowed by implicitly specialized callable parameters. Erasing a capturing lexical closure owns allocated environment storage, even when all its captures are references. An arbitrary lexical wrapper is therefore unsuitable for the nonallocating service factories; a provider needing lexical callback state can own that state and expose a forwarding method bound to its stable receiver. No separate borrowed erased-callable type is required for service handles.

Known direct calls remain direct. Foreign function pointers retain their existing ABI; bound callables are not implicitly convertible to raw foreign function pointers. Type.method remains an unbound function reference, and a callable instance field remains an ordinary field value. Overloads and generic methods require enough ordinary callable context to select a specialization.

Registered ambient entries are selected when a callable body executes. Merely naming context.logger or contextual logging in a body does not capture the current logger or the whole context. An explicit local snapshot captured by a lexical closure retains that earlier service and its dependencies. Capture initialization and copy/drop hooks use the context active when those operations execute.
5. Allocator representation and factories
The following specifies field types, not additional declaration syntax:
Allocator
    allocate: func(AllocationLayout) RawBlock | AllocationError
    deallocate: func(deinit RawBlock) unit
AllocationLayout describes checked byte size and alignment. RawBlock is an affine token identifying uninitialized storage and the layout and authority needed for release. Typed adoption transfers its authority into an owning Allocation; release consumes it exactly once. Extend the existing low-level storage model to preserve backing-storage dependencies through these operations rather than reducing blocks to untracked addresses. Neither type is a new language primitive. Validate size arithmetic, alignment, host accessibility, and resource limits before provider dispatch or typed adoption at their owning boundaries.

A typed library factory binds both operations directly to the same provider, or uses permanent named functions for stateless services. Keep the callable fields private and expose dispatch through library methods. Validate their nonallocating construction and issued-storage provenance/release contracts at the factory boundary, and retain those facts when invocation targets become opaque. There is no construction from arbitrary erased callbacks, universal conversion from arbitrary structs, or trait/interface declaration.

Conceptually, the factory forms two borrowed functions over tracker: allocation and deallocation. Its adapters are ordinary statically specialized library code using bound functions, not allocator-specific callable types.

A provider must satisfy layout requirements, preserve live blocks until authorized invalidation, and release blocks through their original authority. Standard wrappers capture their upstream provider before installation and retain it. Bookkeeping uses that upstream explicitly. Type-correct adapters do not prove arbitrary raw-memory implementations correct; existing low-level memory safety obligations still apply.

Allocator has no destructor for provider state. Its two callables retain borrowed dependencies. The default root provider has execution-environment lifetime; custom providers are not silently promoted to heap/shared ownership.

AllocationError and IoError are standard service-domain marked errors, using the existing error marker, ordinary result unions, catch, and ?. Define nonallocating error payloads that preserve useful causes: invalid layout or representable-size limits, exhaustion, provider budget refusal, and I/O failure with progress where relevant. The stored service signature fixes its supported alternatives. A provider returning unrelated errors needs an explicit translating adapter or a statically typed API exposing them; there is no universal error type or implicit loss of causes. Narrower provider results may widen into the declared ordinary union.
6. Allocation and collection behavior
Store the provider once in owning Allocation, alongside its storage metadata, not independently in every owning wrapper. Replacement allocation, destruction, moves, swaps, and owning iterators retain or transfer it with the storage.
Operation	Required provider behavior
Successful List.new, including zero capacity	Capture explicit/current provider; preserve distinct-allocation semantics
New owning allocation or Box	Capture explicit/current provider
Existing list grows	Allocate replacement through its retained provider
Move or swap	Transfer provider and storage together
Allocating clone	Select explicit/current provider for the new storage
Static/literal or empty static-backed string	Remain provider-unbound
First allocating transition of an unbound string	Select explicit/current provider and become bound
Further string growth	Use retained provider, even after length becomes zero


List.reserve must use an explicit-provider path, not the ambient allocation entrypoint. Allocate replacement storage before changing the existing value; on allocation failure, preserve its contents, length, capacity, storage, and provider. Preserve existing typed element relocation and cleanup. No raw bytewise relocation of arbitrary elements is introduced.

Use List(T) | AllocationError for List.new, Box(T) | AllocationError for Box construction, and unit | AllocationError for recoverable reserve/append operations. Migrate typed allocation, String construction/clone/growth, collection construction, scratch allocation, and their callers together; replace allocation-failure none tests with ordinary marked-error handling. Preserve none for searches and optional values, End for iteration, and successful zero-byte reads for end of input. Invalid UTF-8 remains a distinct marked text error, not absence or allocation failure.

A failure before allocation produces no allocation owner and skips deferred element initialization. Error payloads retain any dependencies of their own; an error is not a borrow-escape exemption. Failed reserve preserves the original container. An ordinary append(var item: T) has already acquired its argument during eager preparation and may destroy it on failure; a deferred construction path can reserve before forcing its item. Completed bookkeeping, callback writes, transfers, and partial output are not rolled back by catch or ?.

`type_layout(T)` requires a runtime-capable type whose native byte size fits `int`; an unrepresentable layout is a source diagnostic, not an internal compiler error. `layout_for(T, count)` instead returns `AllocationError.invalid_layout` for negative counts and `AllocationError.size_limit` for unrepresentable layouts or size products. Successful zero-count and zero-sized layouts retain their element alignment.

Pending init operations use the context active where they are forced, not where their source expression was passed. Their errors remain within their own declared construction region: ? inside an init expression does not return from the enclosing caller. Consumers must explicitly handle/forward a declared fallible initializer result, or callers must perform the fallible work eagerly.

Allocating an outer container does not migrate its elements' independently owned storage. Ordinary element hooks run under the caller's current context, not a temporarily installed container provider.

When allocating lexical-closure erasure is implemented, each environment allocation retains its selected allocator under these same rules. Copying an erased capturing closure selects the current/explicit allocator for the new environment; each environment releases through its own retained provider. Retaining an Allocator handle cannot recursively allocate another callable environment. Implicit erasure/copying remains infallible with panic on environment-allocation refusal; explicit fallible erasure and cloning return AllocationError and reserve before capture construction/copying, as specified in [CLOSURES.md](CLOSURES.md). A collection's recoverable insertion result does not itself make implicit callable erasure recoverable.

Library scratch buffers use explicit internal providers and bounded lifetimes. Do not rebind the ambient provider around user callbacks to implement scratch optimizations.
7. Logger representation and behavior
Use an ordinary library handle with these field types:
Logger
    minimum_level: LogLevel
    emit: func(LogLevel, StringView) unit | AllocationError | IoError
LogLevel is a library-defined scalar record, not a new primitive or enum feature. Define ordered constants for trace, debug, info, warning, error, and off. off disables the handle and is not an emitted severity. Keep handle fields private; a typed library factory binds emit directly to the backend and sets the threshold, or uses a permanent named function for a stateless service. The factory checks nonallocating callable construction and the synchronous message-nonretention contract. There is no implicit provider ownership, heap allocation, or whole-context capture.

Provide an explicit logging.emit(logger, level, message) operation and contextual convenience functions such as logging.info(message) and logging.error(message). Their result is unit | AllocationError | IoError. Contextual functions read context.logger once, after ordinary argument evaluation, then delegate using that saved handle. Filtering happens before backend dispatch: a disabled event succeeds with unit without invoking the backend; otherwise the operation forwards the backend's success or marked failure. A logging failure does not automatically log again, change destinations, or terminate the program. Nonallocating backends do not produce AllocationError; buffering backends may produce it.

Expose logging.enabled(logger, level) for callers that want to avoid expensive message construction. The test uses the handle's threshold and does not call the backend. Ordinary function arguments are still evaluated normally, even for disabled events. A caller that tests a saved handle should emit through that same handle. General formatting remains library functionality; no lazy arguments or capturing closures are required.

StringView carries a readonly borrow of message bytes independently of an owning String. The backend may inspect the bytes during the synchronous call but must not retain the view or its borrow, including through stored state, callbacks, or returned errors. A buffering backend must copy the message into owned storage using a lifetime-valid current or explicit allocator; that storage retains its selected provider. Enforce the no-retention requirement in the callable contract/factory compatibility check; do not rely on convention. Formatting completes before entering the backend callback or acquiring backend locks. Recoverable formatting exposes its own marked errors and does not use an infallible String converter that panics on allocation refusal. A backend's permitted retained state and mutation effects remain visible through the callable contract.

Each contextual log operation selects its destination at invocation. A saved Logger continues targeting the original backend across later overrides. Such a handle may escape the binding scope only while its receiver and nested dependencies remain valid. Installing a local backend does not automatically make unrelated returned allocations depend on it. Body cleanup logs through the binding still active during that cleanup; destroying an object does not reinstall its creation-time logger.

The native root backend writes a severity prefix, borrowed message bytes, and a newline directly to stderr without ambient allocation, print, or recursive logging. These are separate writes; message/newline output is not atomic. Output failure returns IoError and may follow partial output; emission is not transactional. Test backends may collect owned records instead. A no-op backend is also available. Logger handles do not own or close their backends; flushing, closing, and other backend cleanup remain the backend owner's responsibility. Explicit flush/close operations may return marked errors. Release/drop stays infallible; cleanup that logs must explicitly handle or acknowledge logging errors rather than adding a fallible destructor channel.

Tracing, contextual stdout/stderr, and user-defined context-entry declarations are not implemented here. Their later addition must reuse registered service handles rather than allocator-specific machinery. A future span must retain the backend/identifier pair needed to finish it; it must not rediscover an unrelated backend at completion. No tracing implementation is required for contextual logging.
8. Existing reference analysis and contracts
Extend existing analysis rather than adding a second borrow checker.

Expose provider references independently of contained element references: List(int) and an empty Allocation(int) may borrow provider state. Update containsBorrowAt, result projections, cleanup, and nested allocation/container paths accordingly.

Analyze each contextual entry as a synthetic function input, separately from explicit inputs and other entries. At a call, substitute the actual active binding. A callee's internal replacement changes the source used for operations inside that region. Results that retain service handles depend on the selected service owner, not on temporary binding storage. For example, returning context.logger retains its backend dependency, whereas merely emitting a synchronous log does not make the function result borrow that backend.

Consequently, a result may survive with when its service owner survives. Returning an allocation depending on a local tracker or a Logger depending on a local backend is rejected. Installing a binding keeps its service owner alive for the full dynamic scope, including otherwise unused bindings and cleanup.

Preserve dependencies through result alternatives, caller-owned mutations, nested containers, callbacks, recursive contracts, and publication into longer-lived storage. Global publication requires a sufficiently long-lived provider or explicitly chosen root storage.

Callable contracts distinguish explicit arguments, direct receivers, owned environment storage, captured references, retained allocation providers, and ambient inputs. Preserve construction, invocation, copy, and cleanup effects through erasure, assignment, conversions, containers, alternatives, factories, and forwarding. Copies of allocated environments create fresh environment ownership while retaining dependencies/effects from capture-copy contracts; copies of bound methods preserve the original receiver dependencies.

Track descriptor construction forms independently of invocation-target identity. Opaque invocation may conservatively widen capture and ambient effects but cannot discard the factory-proven nonallocating service-handle storage forms. An arbitrary unknown func copy/drop must account for possible environment allocation and capture hooks; known service handles have neither. Discover ambient requirements transitively even for zero-argument scalar-returning callables, through implicit hooks and deferred initializer execution. An unknown zero-argument factory is not presumed to return permanent storage. Missing/stale query state requires recomputation, incompatible source contracts require rejection, and violated compiler invariants require assertions. Never substitute an assumed-safe contract for any of these conditions.
9. Reset, mutation, and aliasing
Distinguish provider-object lifetime from validity of issued storage. Arena reset or backing replacement invalidates the latter; changing counters does not.

Preserve backing-allocation identity through raw blocks, allocator wrappers, bound-callable contracts, and owning allocations. Reject invalidation while dependent uses or required cleanup remain. Reset may become legal after last-use cleanup even before lexical scope exit. An allocator handle alone does not prohibit resetting storage it is not using.

Do not assume exclusive mutable references. Express invalidation through existing effects, extended to the relevant storage paths where needed. Mutations that would destroy outstanding deallocation authority are likewise invalidating.

Arena suballocations and accessible backing bytes may alias. Different element types or allocation wrapper objects do not establish disjointness; require independent storage roots or proven-disjoint ranges.
10. Reentrancy and diagnostics
print and logging remain legal under allocator/logger overrides and inside backend code. No general callback-effect prohibition is introduced. Correct code must avoid unintended cycles through its selected services.

Standard allocator and logger wrappers capture upstream handles before installation and forward explicitly through them. Allocator bookkeeping uses the captured upstream allocator. A logging allocator captures an explicit diagnostic logger whose backend does not allocate through that same allocator; a collecting logger uses its retained allocator. Do not temporarily rebind ambient services around backend callbacks or silently substitute defaults. Primitive integer formatting should support stack-buffer output; general printing is not promised allocation-free.

The allocator and logger factories provide checked reentrancy by default, using one nonallocating active-service stack. Key entries by service kind, concrete backend type, and receiver identity. Allocation and deallocation share the same allocator identity; logger emission uses the logging service kind. Static type/service keys are adapter data, not additional fields in every bound function. Keep active identities consistent with ordinary receiver relocation rules.

Enter the guard only when invoking the backend, after filtering and message construction for logging. Reject re-entry into an already-active checked service before calling it. Thus allocator A -> logger L -> allocator A and logger L -> allocator A -> logger L are detected, while logger L -> a distinct upstream logger and ordinary recursive application functions remain valid.

A detected service cycle terminates with a fixed nonallocating diagnostic through runtime emergency output, bypassing context entirely. Do not silently select another allocator/logger, suppress the event, or report the cycle as ordinary allocation/output failure. All ordinary callback exits, including marked errors, remove the active entry. Deliberately reentrant backends may select unchecked dispatch through a compile-time factory option and bear that obligation themselves. General bound functions receive no automatic recursion guard.
11. Native execution, evaluation, and boundaries
Native execution uses private TLS handles for both entries. Ordinary calls pass no context pointer. The evaluator keeps equivalent bindings in isolated evaluation state, never host TLS. Represent callable descriptors symbolically and bound payloads with evaluator references; invoke their interpreted adapters with the same receiver, copying, cleanup, and lifetime rules. Reentrancy checks also use evaluation-local state.

The evaluator root allocator remains evaluation-local. Its root logger is the no-op logger with threshold off, so implicit compile-time logging performs no host I/O. Explicit overrides may target evaluation-local collecting backends, with the same borrowing, failure, and reentrancy rules. Host-only backends are unavailable during evaluation; existing compile-time print behavior is unchanged.

Recoverable program allocation refusal produces AllocationError, including deliberately simulated refusal during evaluation. Strict allocation paths apply their specified panic policy. Evaluator implementation OOM remains a compiler infrastructure failure, not a program error or ordinary absence.

Preserve evaluation-local allocation and constant-export rules. Never serialize an evaluation-local service address or silently replace a custom service to make a result exportable. Reject exports retaining nonexportable provider or logger state.

A new thread or foreign-origin thread entry starts with root defaults for both allocator and logger. Synchronous callbacks on an already-attached thread use its current bindings. Capturing a bound receiver does not capture the invocation context.

No automatic propagation to new threads, asynchronous suspension, signal handlers, or GPU execution is included. Reject suspension across active bindings until task-aware integration exists. GPU execution IDs remain separate intrinsics. Foreign nonlocal jumps across these scopes are unsupported.
12. Optimization, layout, and compatibility
Treat contextual reads and scoped writes as real IR dependencies, separately for each entry. Do not move reads across relevant replacements or callbacks that may replace a binding. Custom-provider operations and delivered log events are observable; escape analysis alone does not justify eliminating them. A disabled log skips backend dispatch but does not justify removing observable argument evaluation.

With the native callable representation in [CLOSURES.md](CLOSURES.md), Allocator contains two descriptor/payload handles, and Logger contains one such handle plus its threshold. Their factories restrict payloads to direct receiver references or unused named-function payloads. Ordinary handle copying, movement, destruction, and context installation/restoration allocate nothing and call no provider. Do not promise a target-independent byte size or zero instruction cost. No context lookup is required for existing-buffer list operations; element hooks can independently access context. Growth/free dispatch through retained providers, including applicable reentrancy checks. A contextual log performs a handle read and level test, followed by checked indirect dispatch only when enabled. No logging work is added to unrelated operations.

Update native/evaluator callable ABI handling, reference relocation, recursive inference, incremental dependencies, bundled standard-library contracts, and disk-cache schemas. Serialize symbolic identities and effects, never runtime addresses. Invalidate incompatible caches and compiled artifacts.
## 13. Delivery order and acceptance tests

All three slices below are implemented and accepted. Qualification on 2026-11-09:

- `zig build test --seed=0 -Doptimize=safe --summary all`: all 64 build steps
  succeeded; 2,556 executed tests passed and 24 were skipped. The successful
  85-test disk-cache and 18-test portable-artifact roots were reused from cache.
  The shared-context root passed all 45 tests.
- Lifetime/authority regressions include backing reset versus counter updates,
  destructor output ordering and chained cleanup, return snapshots versus
  terminator outputs, loop/recursive retention, and nested opaque callable
  ownership. Incremental body edits, disk restoration, portable identities,
  malformed contextual/service IR, and embedded std reuse are covered.
- Query snapshots, portable artifacts, and embedded standard bundles use
  `CHIMERAQRY64`, `CHIMERAART22`, and `CHIMERASTD20`. The installed Fast CLI was
  rebuilt and its help entrypoint checked.
- All 36 [runtime variants](../benchmarks/shared-context/README.md#recorded-qualification)
  qualified before measurement, with 200,000 rounds and seven samples each.
  Element-hook and real stderr-pipe costs are reported separately from the
  27 core service variants. Raw samples and observed-repeatability flags remain
  in the [measurement report](../benchmarks/results/shared-context/runtime.json).
- Modified Zig formatting and `git diff --check` pass. Exhaustive compiler
  allocation-failure sweeps were not enabled; they remain opt-in.

Scoped context has separate acceptance from closures. Callable slice 3 in [CLOSURES.md](CLOSURES.md#7-implementation-slices) provides its borrowed-handle foundations; owning lexical environments use the same retained-provider rules. Each numbered item below is one complete slice, including native/evaluator behavior, ownership, failures, incremental recomputation, and cache qualification.

1. **Explicit services and retained providers.** Implement raw-storage ownership/provenance, typed adoption, provider-retaining allocation owners, and explicit allocator/logger factories over the callable foundations. Validate nonallocating handle construction, provider lifetimes, release authority, and message nonretention. Preserve those guarantees through copies, fields, joins, and opaque forwarding. Qualify explicit allocation/release and logging before introducing ambient selection.
2. **Scoped bindings and execution.** Implement registered allocator/logger entries, scoped replacement, binding retention, and cleanup/restoration on every ordinary exit. Add native TLS and isolated evaluator bindings with the specified roots. Preserve invocation-time context, forcing-time selection for pending initializers, and transient evaluation/publication policy. Qualify nested scopes, early exits, invalidation, saved handles, and independent allocator/logger replacement.
3. **Standard-library allocation and logging integration.** Route constructors through context and existing-resource growth/release through retained providers. Migrate marked allocation/I/O errors with direct and indirect consumers, literals, hooks, and converters, preserving infallible hook policy. Add contextual logging with filtering, checked message nonretention, and explicit error forwarding. Qualify empty/nested allocations, failed growth, cleanup-time logging, reentrancy, root output, layout, and matched runtime costs. Logger support is part of this slice's acceptance.

Do not enable contextual constructors before safe indirect contracts and provider retention are implemented. Service factories must enforce nonallocating callable construction and their protocol contracts before accepting providers. Logger factories must reject retention of message borrows. Apply the marked-error migration to direct calls, indirect callable signatures, collection construction, and implicit hooks/converters together; infallible hooks retain an explicit panic or error-handling policy.
Test	Required result
Bound method returned through an adapter	Refers to original provider, not adapter storage
Copy a bound callable; destroy original wrapper	Copy remains valid while receiver remains valid
Copy/install/restore service handles through opaque forwarding	No allocation, service callback, or provider ownership hook; construction facts retained
Service factory constructing a lexical callback or incompatible bound method	Rejected; permitted callable construction and protocol contracts enforced
Mutable factory on writable versus readonly provider	Required authority preserved; readonly source cannot acquire writable access
List grows under another context	Original provider handles growth and release
Empty list or nested value depends on local tracker	Dependency retained; invalid escape rejected
Opaque zero-argument factory; callee-local override	Correct selected-provider dependency retained
Recursive contracts, mutation, alternatives, global publication	No loss of provider/effect requirements
Nested with, unused binding, all ordinary early exits	Correct retention, cleanup, and restoration
Ordinary scoped target overwritten inside body	Original value restored; displaced value dropped once
Plain contextual assignment or mutable alias attempt	Rejected
Reset before dependent cleanup, then after cleanup	First rejected; second accepted
Failed growth, string transition, allocating clone	Behavior matches Section 6
Allocation refusal, invalid layout/size, and provider budget rejection	Marked AllocationError with cause; no none or fabricated allocation owner
Eager append argument versus deferred item on reservation refusal	Eager ownership handled normally; deferred item not forced; existing container unchanged
Initializer forced under a changed context	Uses forcing-time provider; initializer errors do not escape their declared region
Wrapper forwarding, recursive formatting, ordinary recursion	Correct forwarding; checked service cycle terminates; ordinary recursion allowed
Nested logger override; allocator override alongside it	Independent selection, retention, and restoration
Saved logger used after an override; escape with local backend	Original backend retained; invalid backend escape rejected
Callable invoked under a later override versus an explicitly captured service snapshot	Body selects invocation-time context; snapshot retains original service
Logger selected during body cleanup and early exit	Inner logger active through cleanup, then previous logger restored
Disabled event with side-effectful message construction	No backend call; argument side effects preserved
Backend retains message borrow versus storing an owned copy	Borrow retention rejected; lifetime-valid owned copy accepted
Backend returns AllocationError or IoError	Actual marked failure returned without recursive reporting; active entry removed
Root output failure after partial writes	IoError preserves available cause/progress; no rollback or recursive logging
Allocator/logger cycles in either direction; distinct upstream loggers	Cycles detected; valid forwarding accepted
print under logger override	Existing stdout destination unchanged
Evaluator root logger and explicit collecting backend	No root host output; deterministic local collection and borrowing
Native/evaluator, cold/incremental/disk-cached compilation	Specified root defaults, consistent safety rules, and cache-stable results

When both context allocation support and callable slice 4 are available, additionally verify separate providers for copied environments, original-provider release, allocation-before-capture initialization, recoverable erasure/clone refusal, and rejection of closure escape past captured referents or retained providers. These are cross-feature integration tests; neither implementation task waits for the other to deliver its independent slices.


Benchmark actual Chimera for callable/service-handle/allocation layout, collection construction, spare-capacity append, growth, destruction, wrapper nesting, disabled logging, and enabled logging into a no-op backend. Report element-hook and actual I/O costs separately.
Non-normative implementation references
- P2472R3, bound callable construction: https://open-std.org/JTC1/SC22/WG21/docs/papers/2022/p2472r3.html
- Rust allocator safety and growth contracts: https://doc.rust-lang.org/std/alloc/trait.Allocator.html
- Java scoped-value binding/restoration semantics: https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/ScopedValue.html
These are implementation references, not substitutes for Chimera's ownership, mutation, or syntax
