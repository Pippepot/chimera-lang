# Shared context design review

The central idea in [SHAREDCONTEXT](SHAREDCONTEXT.md) is worth adopting: context
selects defaults, while an existing resource retains the authority required to
grow and release its storage. Independent allocator and logger entries also make
sense. Borrowed method values would improve ordinary callbacks throughout the
standard library. Borrowed lexical closures would also be useful for synchronous
callbacks, sharing the same capture and effect foundations. Actual allocation and
output failures should use marked errors; `none` should describe ordinary absence.

The proposal needs foundational work and several explicit language decisions
before implementation. Its main gaps concern callable contracts, borrowing in
converters, storage provenance, restoration of arbitrary values, and compile-time
execution. TLS and default service-cycle detection add substantial machinery
without being necessary consequences of scoped context.

My recommendation is to implement the smaller coherent design described below,
with allocation and logging both included, after making the callable and storage
contracts sound. The examples using context, method values, or capturing function
expressions describe proposed behavior; they are not claims of current support.

## Agreement with the calculus and language

The [calculus explanation](../calculus/README.md) separates execution, static
reasoning, and elaboration. The proposal can preserve that separation:

| Part | Relationship to the existing model |
| --- | --- |
| Scoped defaults | Add a dynamic binding environment to execution and scoped restoration to elaboration. |
| Borrowed method values and closures | Add capture environments and borrowed callable views with authority and dependencies. |
| Retained allocator | Add references and deallocation authority to the allocation owner; element initialization remains separate. |
| Logging | Ordinary synchronous calls, marked error alternatives, readonly text views, and library filtering. |
| Restoration | An explicit mutation with cleanup and fresh content/tag versions. |
| Arena reset | Requires a storage extension beyond merely retaining the provider object. |

Last-use destruction, caller-directed ordinary exits, ordinary absence and marked
error results, destination construction, and nonexclusive mutable references remain
compatible. Error propagation uses the existing ordinary result and cleanup rules.
Installed bindings create real retention obligations; unrelated locals still end
at their ordinary last uses. This is an intentional exception to early cleanup,
similar in purpose to existing argument and replacement-target retention.

The mechanically checked [Lean subset](../calculus/Refinement.lean) proves
refinement soundness for initialized independent slots, aliases, writes,
Booleans, and branches. It does not model calls, ownership, allocation, cleanup,
or scoped context. It therefore neither certifies nor contradicts the new design.
The language-wide prose can accommodate it, but the theorem must remain scoped to
its actual subset.

A small execution rule is enough to state the contextual part. Let a binding
environment map declaration identities to handle values. A read copies the
selected handle. A binding first evaluates its replacement in the parent
environment, then evaluates the body and its outgoing cleanup in the child
environment. Ordinary continuation resumes the parent environment. Function calls
use the invocation environment; pending initializers use the environment where
they are forced. Result dependencies refer to the handle's owners, rather than
the environment record holding a temporary copy.

Static reasoning then extends ordinary call-origin substitution with sources for
captured places and one source per contextual entry. Elaboration makes binding
retention and cleanup environments explicit. This avoids a second lifetime
discipline for services. Extending the Lean theorem would still require modeling
these operations and their correspondence with compiler elaboration; the existing
proof's independent-slot write rule only supports the refinement part directly.

Several current [language rules](../syntax&semantics.txt) need explicit updates:

- Function references currently capture no runtime bindings. Method-call syntax
  inserts an explicit receiver; an instance method is not currently a bound value.
- Callable types have parameters, parameter modes, result type, and result mode.
  They have no public effect or receiver description.
- Planned closures have concrete environments and remain distinct from plain
  function references. An erased borrowed callable view needs an explicit rule;
  silently giving every function reference a capture environment changes this plan.
- Runtime converters use `imm`; capturing writable access to an ordinary owned
  provider requires another API or a deliberate converter extension.
- Top-level runtime bindings are entry locals, and module statics are immutable
  compile-time declarations. Neither already provides contextual runtime storage.
- Ordinary replacement may destroy an immovable value before constructing its
  replacement. Saving and later restoring that same value cannot use this rule.
- Allocation-provider effects change when allocation elision is permitted.
- Current allocation and I/O APIs still return `none` for failures. Migrate those
  contracts to the existing marked-error protocol rather than preserving them.

Restoring the previous bits must not restore old refinement evidence. A saved
Boolean test made before installation cannot become valid again just because the
original variant is restored. Restoration establishes current facts using a new
mutation version.

## Changes required before implementation

### Callable contracts must describe hidden inputs

The compiler has useful existing machinery: [reference contracts](../src/structures.zig),
[callable recovery and substitution](../src/frontend/typing.zig), and
[contract inference queries](../src/queries.zig). Immutable projections and
unambiguous factory returns recover known plain function targets. Reassigned
storage and disagreeing paths use conservative contracts.

This machinery currently assumes that function values carry no borrowed receiver.
Host layout gives a callable one machine word, ownership is trivial, and borrow
containment does not classify an ordinary callable as carrying references.
Returned callable recovery recognizes a function instance or a forwarded
parameter. Adding a second word alone would be unsound.

Contracts need separate sources for explicit parameters, each captured place or
reference, and each contextual entry. A bound method has one receiver capture;
a lexical closure may have several. Environment lifetime, permitted writes,
invalidation, returned dependencies, and caller-visible stored dependencies must
survive copies, fields, joins, forwarding, and recursive inference. Keep these
sources distinct from permanent storage and from temporary binding storage.

For example:

```chi
func invoke(factory: func() List(int) | AllocationError) List(int) | AllocationError
    return factory()

# Even a thin factory can allocate through the caller's contextual allocator.
# A borrowed callable view can additionally retain a captured provider.
# Neither result becomes permanent merely because there are no arguments.
```

The current call path can infer permanent origins when a borrowed result has no
explicit source. The new representation introduces both receiver and ambient
sources, so that inference must be reworked. A thin function has no receiver
captures, but can still use ambient services. An opaque borrowed callable view
with the same invocation signature cannot assume the absence of captures.

Treat capture authority as value information, independently of the callable
wrapper's mutability. Passing a writable bound method through an `imm` callback
parameter does not revoke its captured permission. An opaque call can affect every
captured location for which that value already carries writable authority; it
cannot upgrade a readonly capture. This needs a substitution rule for an unknown
capture shape, not simply the current fallback for explicit `ref` parameters.
Readonly bound predicates should still work in map/search/sort, while a stateful
predicate's counter writes remain visible to its caller. Conservative result
dependencies may include captures and ambient inputs without claiming that every
callback result actually retains them.

The current call path decides whether it needs reference contracts from explicit
parameter/result shapes. A zero-argument scalar-returning function can now read
or mutate contextual services, so that gate is insufficient. Discover ambient
requirements transitively, including implicit copy/move/drop hooks and deferred
initializer execution. Query consumers need these facts even when the public
signature contains no visible reference-bearing type.

Missing query state must remain unavailable/recomputable. A genuinely opaque
callable needs a sound conservative contract. A contract incompatible with a
service protocol needs a source diagnostic. These are different conditions.

### Borrowed closures are useful alongside bound methods

Plain function values already exist. The missing capability is retaining runtime
state needed by an invocation. A borrowed method captures one receiver; a lexical
closure can express a callback over several existing locals without requiring a
named adapter record for each use. This benefits synchronous sort comparators,
search predicates, and optional lazy logging. It is useful beyond shared context,
but allocator/logger scoping does not require closure syntax.

The [planned closure rules](../syntax&semantics.txt) already specify concrete
environments, ordinary capture ownership, and no implicit boxing. Preserve that
direction. Prefer these separate representations:

| Callable form | Storage and lifetime |
| --- | --- |
| Plain function reference | Existing thin symbolic/code reference, with no runtime captures. |
| Concrete borrowed closure | Inline environment of borrowed captures, with statically known invocation code. |
| Borrowed callable view | Code plus receiver/environment reference, retaining that storage and its capture dependencies. |

Use one invocation/capture contract model for all three. A bound method view
points directly at its original receiver; forming it needs no intermediate
environment. A view of a lexical closure points at the closure's concrete
environment. Copying a view copies the handle, and cannot prolong the environment's
lifetime. Plain functions can form views without runtime captures. Owning erased
callbacks and automatic heap storage remain deferred.

This changes the proposal's uniform representation choice: existing `func(...) R`
function references can remain thin, while an explicitly distinguished borrowed
view carries the erased environment. The remaining argument/result signature is
still ordinary function information. Existing callback APIs need generic concrete
callable overloads or borrowed-view parameters; current thin function parameters
cannot silently accept captures. Exact view spelling and generic invocation syntax
are language decisions, not library-only implementation details. Widening every
`func` instead is possible, but would change the planned distinction, layout, and
trivial ownership rules throughout the compiler and std.

For the first closure stage, borrow runtime captures and keep static captures
symbolic. Infer required read/write access from the body, preserving the original
place's permission. A write requires writable authority; an immutable handle does
not remove authority already carried by a capture. Do not introduce owning
capture transfers, snapshot-by-value defaults, or a family of invocation traits
merely to support synchronous predicates. Snapshot capture and consuming
invocation can be settled when concrete examples justify them.

For example, using the illustrative local function-expression syntax:

```chi
var comparisons = 0
const cutoff = 10
const matches = func(value: int) bool
    comparisons += 1
    return value > cutoff
# A synchronous search borrows matches, updates comparisons, and retains no view.
# Capture policy and generic/view parameter syntax are proposed, not implemented.
```

After the search, `comparisons` is still available and reflects all completed
calls. Passing this predicate to sort while it also captures the sorted owner
requires the ordinary overlap/effect checks. Capturing an independent counter is
compatible with nonexclusive borrowing; invalidating the sorted storage is not.
A callback returning a reference can leave a result dependency even when the
callback view itself is never retained. Nonescaping does not mean pure, readonly,
or incapable of returning borrows.

Define nonescaping use through retention contracts and environment validity,
rather than trusting an indirect callee or inlining. A synchronous terminal API
must not retain the callback view after its call. A map/filter adapter does retain
its callback. When it stores a borrowed view, a local adapter may remain valid
while the environment survives, but returning it after that environment ends is
invalid. A generic adapter storing the concrete environment inline has a different
storage plan: copying/transferring that environment can be valid if every captured
reference survives. Borrow-only capture does not itself forbid this. Returned
allocations retaining provider views have the same environment obligation. A view
of a closure created inside a provider factory cannot replace direct bound methods
if its environment ends when that factory returns, even when the provider itself
remains alive. This is why a blanket nonescaping callback feature is insufficient
for service handles.

An `init` parameter is affine deferred construction, so it cannot replace a
repeatable comparator or predicate. For lazy logging, a zero-argument callback can
defer the entire message computation; ordinary generic logging already skips its
internal formatting after filtering. A lazy helper should save the logger, filter,
then invoke the factory at most once and emit through the same saved logger.
Factory errors and backend errors stay visible in its result. This convenience
does not need owning closures or implicit whole-context capture. Ambient services
are selected at invocation, independently of the captured lexical objects.

A callback-based scoped library helper also does not replace contextual `with`.
Return and `?` target the callback's result; break/continue cannot target its
caller's loops. Language `with` preserves the enclosing callable's ordinary exits
and schedules restoration around them.

### Provider converters cannot invent writable permission

This proposed shorthand is not justified by current conversion semantics:

```chi
with context.allocator = tracker
    build_index()
```

An `imm tracker` converter cannot bind a method that mutates tracker-owned fields
such as counters, an offset, or a free list. It can preserve writable references
already stored inside a handle; carrier immutability does not revoke the captured
referent's authority. That distinction does not help a tracker owning its state
directly.

Two sound choices exist:

1. Use an explicit borrowed factory, such as `tracker.allocator()` or
   `backend.logger()`, whose receiver mode and effects express the required access.
   This is the smallest initial language change.
2. Add permission-preserving `ref` converters deliberately. Their capture follows
   the original place and its actual authority. They must not upgrade readonly
   sources, consume ownership, borrow an unsupported temporary, or lose effects.
   This would make the shorthand useful for other borrowed handles too.

Some downstream converter code already handles `ref`, but declaration validation
rejects it. It is not an implemented language feature. Do not bypass that owning
boundary to obtain the desired behavior.

Binding a borrowed receiver must point to the original object. Binding to a
converter's copied parameter or a temporary adapter object would return a dangling
callable. Initially require a checked existing place; temporary-receiver lifetime
extension belongs to the already deferred temporary-borrowing decision.

Define method-value resolution alongside formation. `Type.method` remains an
unbound function value; `place.method` binds one borrowed receiver after normal
field/member visibility and overload selection. A callable instance field remains
an ordinary field value. Generic or overloaded methods need enough information
from the receiver and expected remaining signature to choose a specialization;
otherwise diagnose ambiguity rather than inventing a service-specific preference.
Consuming receivers remain outside borrowed formation. Receiver access, remaining
argument modes, and result ownership are independent facts.

### Raw storage needs a real ownership and provenance boundary

At review time, private host storage supplied raw bytes, while typed allocation
supplied element count, initialization, and typed access. `Allocation(T)` then
had exactly `storage` and `count`, and native allocation/deallocation knew that
representation. The implemented boundaries now use
[raw storage](../std/memory/raw.chi) and
[provider-retaining typed allocation](../std/memory/allocation.chi), with
[intrinsic validation](../src/intrinsics.zig) checking registered shapes.

There is no general existing operation that turns arbitrary bytes into a safe
typed allocation or lends independently owned typed subranges from an arena.
`RawBlock` and `AllocationLayout` can be ordinary library records, but the
operations creating, transferring, lending, typing, and releasing their storage
still require compiler-supported contracts. Calling them records does not supply
those contracts.

Make `RawBlock` an affine owner or explicitly define its release obligation.
Deallocation must receive consuming access, not merely borrow a copyable block.
The proposed spelling `func(RawBlock) unit` defaults to `imm` and does not express
that consumption. Preserve the exact original layout and release authority.
Transfer from raw storage to `Allocation(T)` must transfer responsibility once;
typed construction and destruction continue to use the existing hooks.

A valid request checks count, stride, size overflow, and alignment before provider
dispatch. Preserve zero-byte allocation identity and logical count independently
of physical bytes. Keep the initial location explicitly host-accessible; selecting
an allocator must not silently change `T`'s representation or memory location.

Arena support introduces a second problem. Resetting a cursor to zero can reuse
issued bytes without ending the backing allocation. Block dependencies must
therefore describe issued-storage validity, not just the arena object's lifetime
or its backing owner. Reset needs an explicit invalidation contract. Changes to
unrelated counters must remain legal.

An allocator handle may continue to designate the arena's stable object while an
old block becomes invalid. Deallocation itself is a dependent use: even a block
that will never be read again cannot outlive the authority its cleanup requires.
A no-op arena deallocator does not automatically make cleanup independent of the
arena.

Specify release behavior independently of allocation failure. Release consumes
the block, completes its storage lifetime, and is infallible under the proposed
protocol. A forwarding tracker must transfer the block
to its captured upstream release operation exactly once. If a different provider
model needs fallible release or explicit bulk finalization, that is another
resource protocol, rather than an implicit exception inside `Allocation.drop`.

Also distinguish a stable provider slot from stable release authority. If a
tracker reads `self.upstream` when freeing, replacing that field while old blocks
remain can route release through a different provider even though the tracker
object stays alive. Capturing two methods on the same object does not prove that
its future state preserves the original release protocol. Retain the needed
authority by value, model replacement of its relevant storage as invalidating,
or make its preservation an explicit low-level provider obligation. Counter writes
need not invalidate blocks. General borrowed method values can observe new
receiver contents; allocation safety needs the stronger storage contract.

### Arena aliasing changes an optimizer invariant

[Optimizer memory effects](../src/optimizer/effects.zig) currently assume a typed
allocation is not part of another object. Heap resources distinguish allocation
types, and different allocation types can be classified as nonoverlapping. A
whole scalar heap element can also be separated from an aggregate parameter.

An arena's byte backing and a typed suballocation can violate those assumptions.
Distinct wrapper types, element types, or allocation identities do not prove
physical disjointness. Storage roots and proven ranges must carry that proof, or
the optimizer must conservatively classify the possible overlap.

Choose one clear first-stage boundary: either implement the required storage and
alias model, or support providers that forward independent host blocks and defer
typed arena suballocation/reset. Tracking, failure injection, budgets, and
forwarding wrappers are already valuable without exposing unsafe suballocation.

That first stage improves control and testability, not the root provider's
allocation throughput. The native root currently obtains each block through
`mmap`; arenas could remove many such system calls, but that larger performance
benefit depends on the storage foundation. Keep the arena milestone visible if
it is a primary reason to adopt configurable allocation.

The [interpreter](../src/frontend/comptime_interpreter.zig) also needs this boundary.
Its allocation record has one element type and sparse per-index logical cells;
it is not a byte-addressed memory image. Typed projections assert that element
types agree. Arbitrary byte backing, typed subranges, and overlapping views need
one coherent identity, contents, and invalidation model during evaluation too.
They cannot be represented as unrelated typed records merely because the native
adapters share an address.

An opaque affine block with one transfer into typed, initially uninitialized
storage is a useful smaller foundation. Forwarding wrappers can inspect layout
and record bookkeeping without accessing the block's bytes. This permits focused
logical ownership/adoption support before general byte reinterpretation or arena
aliasing. It still requires explicit compiler contracts; it is not implemented by
adding library fields alone.

### Actual failures use marked errors

The language's [error rules](../syntax&semantics.txt) already provide the required
mechanism: ordinary structs marked `error = true`, ordinary unions, `catch`, and
explicit propagation with `?`. The [error behavior tests](../tests/language_test.zig)
cover native/evaluator parity, ownership transfer, borrowed errors, cleanup, and
incremental changes to error marking. No `Result` wrapper, universal `Error`, new
fallible function category, or automatic propagation is needed.

Replace the proposal's preservation of allocation-failure `none` contracts.
Exhaustion, budget rejection, invalid allocation requests, size overflow, and
failed system calls are failures. Absence remains appropriate for optional
lookups and searches; end of iteration remains `End`, and end of input is a
successful zero-byte read. A disabled log is successful `unit`.

An illustrative standard domain error `AllocationError` can carry a nonallocating
reason and request information, distinguishing invalid layout, representable-size
limits, exhaustion, and provider budget rejection. `IoError` can carry the system
cause and useful progress information. These are service-domain errors, not a
universal error type. Their exact public fields and alternatives need a std
decision; a structural alias over several marked domain types is also possible.
With those illustrative names:

| Operation | Proposed ordinary result |
| --- | --- |
| Allocator allocation | `RawBlock | AllocationError` |
| Typed allocation, List/Box construction, String clone | Owner type `| AllocationError` |
| Reserve and append | `unit | AllocationError` |
| Checked UTF-8 construction | `String | InvalidUtf8 | AllocationError` |
| Byte output | `int | IoError`, or `unit | IoError` for complete output |
| Reading into a growing List | `int | AllocationError | IoError`, with invalid request errors defined explicitly |
| Logger backend and erased logging handle | `unit | AllocationError | IoError` when buffering is supported |
| Search without an operational failure | Match type `| none` |

An erased service handle has a fixed result contract. Define the supported domain
error alternatives at its factory boundary. A custom provider/backend returning
an unrelated marked error needs an explicit translating adapter or a statically
typed API exposing that error; it cannot implicitly widen into a universal error.
Parameterizing every Allocation, List, String, and stored logger by arbitrary
backend error sets would add considerable machinery. Prefer small standard
service-domain errors for contextual dispatch, with explicit cause translation
where needed. A nonallocating logger simply never produces the allocation error
alternative; its adapter may widen its narrower result into the declared union.
General user formatting may have additional errors, which its generic convenience
API must expose or handle explicitly.

Both absence and error can occur in one result. A fallible search predicate needs
an explicitly fallible algorithm returning `Item | none | PredicateError`:
propagating with `?` leaves `Item | none`, and no match is still successful absence.
Keep `any`/`all`'s `false`/`true` outcomes equally separate from predicate errors.
Current iterator semantics treat non-`End` alternatives, including marked errors,
as items unless interpreted explicitly. An adapter or terminal algorithm must not
quietly discard them or translate them into exhaustion. Borrowed closure support
does not itself change this result protocol.

Propagation forwards the actual error alternative and preserves its ownership
and reference dependencies. Do not turn an error into `none`, print it recursively,
or retry through a different provider. Errors before allocation/construction
produce no allocation owner, and deferred element initializers are skipped.
Error payloads should not need the failing service to allocate their own storage.
An error carrying a borrowed backend/provider reference still has that dependency;
returning an error is not a general escape exemption.

Failed growth leaves the original container, initialized prefix, storage, and
retained provider intact when allocation fails before transfer. An ordinary
`append(var item: T)` already consumes its argument during eager preparation;
failure may destroy that argument even though the container is unchanged. Deferred
literal append can instead reject growth before forcing its item. State these
different guarantees explicitly. Completed provider bookkeeping, callback writes,
transfers, and partial output are not rolled back by `catch` or `?`.

Fallible initialization is a separate dimension. Existing `init item: T` does not
allow `attempt()?` to return an error to the enclosing caller from inside that
initializer region. A fallible initializer must admit the error in its own
declared result and have its consumer handle/forward it, or the caller must do
the fallible work eagerly. A closure similarly returns errors to its own caller.
Changing allocation's result type must not silently relax these boundaries.

Keep release/drop infallible under the chosen protocol. Explicit flush or close
can have a fallible ordinary result, but introducing fallible destruction would
require a separate cleanup design. Default destructors also must explicitly handle
or acknowledge errors from diagnostic logging. Fatal service-cycle policy and
compiler invariant violations are separate from recoverable allocation/I/O
errors. Evaluator implementation OOM remains a compiler infrastructure failure;
deliberately simulated program allocation failure produces the language error.

Migration must update intrinsic signature validation, native syscall result
construction, evaluator refusal behavior, collection construction carriers,
formatting, std callers, and relevant tests together. Collection literals and
implicit String conversion currently have deliberate panic policies: recoverable
factories should return marked errors, while a strict convenience path may remain
an explicit panic-on-error adapter. Do not make an expected owner type catch or
discard errors implicitly. Recoverable `List.collect` must carry allocation
errors throughout both fixed and growing literal construction. The current
optional APIs remain implementation facts until this migration is completed.

### Arbitrary scoped replacement is a separate language feature

Context handles are copyable nonowners, so saving and restoring them is simple.
The proposal's general ordinary-target form has much stronger obligations:

```chi
var current = make_resource()
with current = make_temporary_resource()
    current = make_another_resource()
```

The original value must survive somewhere while the temporary occupies its slot.
An immovable value cannot be moved into hidden storage. A custom move hook cannot
be silently skipped; invoking it does not necessarily preserve the original
value promised by restoration. Explicit-drop obligations cannot acquire implicit
destruction merely because a new statement was used.

If this form is included, restrict it initially to directly movable values with
automatic destruction and valid reference/storage plans. Define whether only local
roots and fields are supported. A user indexer may be an operation rather than a
stable location, so `with object[index] = value` needs a place-producing contract.
Retain the containing storage, prevent overlapping invalidation, and enforce
initialization on every outgoing edge.

The required exit order is body cleanup, restoration, then destruction of the
displaced value. Intermediate assignments destroy their previous temporary under
ordinary rules. Restoration must be an explicit scheduled operation before final
lifetime/effect validation, because destructors can read context and write caller
storage. It cannot be a late backend repair pass.

`with expression` is independently useful for retaining a lock/resource through a
body under last-use cleanup. Define ordinary owning initialization: a fresh result
constructs, a named value copies when permitted, and `^` transfers. An explicit-drop
resource still requires explicit disposal. An optional resource is not unwrapped;
acquisition errors must be propagated or handled before entering a body that
requires the resource. An error alternative is not an acquired guard.

For the smallest context feature, initially allow only contextual targets and
settle ordinary replacement/resource retention separately with the roadmap's
`defer` work. If general replacement is retained, it should be justified by its own
examples and tests, rather than treated as free allocator syntax.

### Compile-time execution must account for context effects

[Compile-time call execution](../src/queries.zig) memoizes suitable calls using
their instance and canonical explicit arguments. Other calls run transiently with
the shared evaluation heap. Returning a scalar currently does not require a
context input.

Consider a scalar-returning function that increments a contextual tracker or emits
into a collecting logger. Repeating it, or invoking it under another binding,
must perform those effects again. Adding context handles to the evaluator while
leaving memoization unchanged can skip the effects and reuse a wrong result.

The simplest correct initial policy is transient execution for calls with
context/receiver effects, propagated transitively. Scalar results may publish
after execution if their actual contents are publishable. More selective
memoization needs a proof of independence or a complete representation of the
relevant state and effects; pointer identity alone is insufficient.

Transient recursion detection currently compares function instances and argument
snapshots. Include relevant captured and contextual state in that reasoning:
recursion with identical explicit arguments can progress by changing a provider or
logger state. Keep snapshot storage scoped to the executing call.

The proposal's evaluation-local allocator, disabled root logger, and recursive
publication checks fit the current staging boundary. A bound callable retaining
an evaluator cell must not enter canonical values or disk snapshots. A plain
function with no runtime receiver can remain publishable.

Root handles also need an explicit symbolic rule. A root allocator represented
by permanent plain operations can be publishable without carrying an evaluator
address; actual allocations it creates remain evaluation-local. A root no-op
logger published during evaluation must remain that no-op handle at runtime,
rather than silently becoming the native stderr default. Publication examines
the actual handle and its captures, not a blanket ban on service types.

### Deferred initializers select context when forced

An `init` argument captures lexical objects but defers execution. It must not
capture the creation-time context implicitly:

```chi
func under_allocator(allocator: Allocator, init value: String) String
    with context.allocator = allocator
        return value

with context.allocator = first
    text = under_allocator(second, String(42))
```

Formatting executes under `second`. The initializer's explicit references still
refer to the caller's original objects. If construction is skipped, no contextual
operation executes. Static effect reasoning must nevertheless account for the
initializer's permission to execute.

[Initializer regions](../src/frontend/typing.zig) already import captured origins
and effects. Contextual origins must remain latent until substitution at the
forcing point, including through forwarding and callee-local overrides. Simply
attaching the caller's active allocator to every pending initializer gives the
wrong runtime/analysis correspondence.

### Native TLS should be a measured implementation choice

The [native linker and startup](../src/backend/codegen.zig) produce a standalone
ELF with one read/execute segment and direct syscalls. There is no TLS allocation,
thread-pointer setup, or runtime thread-entry facility. The compiler's Zig worker
threads are unrelated to threads of a generated program.

Compare two implementations before requiring TLS:

| Choice | Benefits and costs |
| --- | --- |
| Private TLS | Ordinary calls need no context argument; requires startup storage, thread-pointer/access support, and a later attachment policy. |
| Private execution-context pointer | Reuses an explicit runtime record and naturally matches evaluation state; adds ABI forwarding and must reach indirect calls and initializer regions. |

A pointer allocated in startup stack storage can contain the two entries and any
optional runtime bookkeeping. It need not alter source function signatures or
introduce user-visible context passing. Passing it uniformly is simpler than
prematurely making its presence depend on sparse effect inference. It also avoids
changing caller ABI layouts whenever a body edit introduces a contextual effect;
semantic consumers still recompute when their inferred requirements change.
Measure call and code-size cost before selecting that approach.

Both choices require new ABI/codegen work; neither is already available. Keep
foreign-thread entry, asynchronous suspension, signal handlers, and device context
as future integration requirements. There is no current general FFI or GPU
execution API whose compatibility can be claimed here.

Restricted contextual mutation offers a stronger invariant: every synchronous
ordinary call returns with its caller's bindings intact. No writable alias to an
entry escapes, and a nested replacement restores on every ordinary exit. With
private context forwarding, implement a binding as an immutable child environment
in stack storage. It references a new handle for the changed entry and inherits
the others. Calls and cleanup receive that environment; leaving the region resumes
the parent environment without writing back saved TLS values. Returned resource
handles retain their actual providers, never the child environment's stack slot.

This could make contextual `with` substantially simpler than arbitrary location
replacement. Keep inherited entries independently addressable and measure record
copying/indirection against direct handles. The optimizer can use the binding
environment as an ordinary data dependency; a completed ordinary call cannot
silently leave a different contextual handle selected. Backend state mutations
and delivered service effects remain observable. This invariant would need
revision for future suspension or foreign nonlocal exits.

### Context declarations need an owning representation

Declaration identity through aliases and re-exports is the right rule.
[Registered standard declarations](../std/library.zig) and
[symbol resolution](../src/queries.zig) provide a precedent. However, the proposal
must still say what declaration owns each contextual entry and how it resolves.
An ordinary `static` cannot silently become an effectful runtime lookup.

Choose either a dedicated internal registered declaration form, with source rules
for contextual reads/replacements, or initially expose registered accessors and a
clear scoped-binding target. Validate registration, type, and shape once at the
owning boundary. Do not recognize arbitrary source spelling in typing or codegen.

Keep contextual entry identities distinct from query-engine contexts. Runtime
bindings are execution state; the query system caches symbolic contracts and
declared dependencies. It must never cache the active receiver address.

### Logger compatibility needs an enforceable nonretention contract

`Ref(String)` describes a handle to an owning descriptor and can carry writable
authority. [StringView](../std/text.chi) already supplies readonly validated UTF-8,
literal conversion, and independent backing dependencies. Prefer a borrowed
backend callable view with this invocation signature:

```chi
func(LogLevel, StringView) unit | AllocationError | IoError
```

Readonly access alone does not prevent retention. The factory must verify that
message origins cannot flow into receiver state, other longer-lived storage, or
an escaping result. A collecting backend stores an owned copy made with its
retained allocator. Writes to its own counters and records remain legal.

Current function-type equality does not express this restriction. Identify a
generic contract predicate/protocol check or a registered factory validation
boundary. A `where` check that only compares callable signatures is insufficient.
Do not accept a backend with an unknown contract and rely on convention.

That guarantee must survive erasure into `Logger`, contextual storage, copying,
and opaque parameters. Recovering a particular factory's known target at one
call site does not establish it for all Logger values. An unconstrained unknown
callback must allow possible message-to-receiver retention; that would reject
ordinary temporary formatted messages even for a well-behaved backend. Use one
validated protocol guarantee for the private callback field, and ensure every
construction path establishes it. Receiver-state effects still vary with the
actual handle and must remain visible. This is a real addition to callable
compatibility, not merely a `where` spelling around existing signature equality.

Keep the backend text API separate from formatting ergonomics. A `StringView`
parameter does not infer the chain `int -> String -> StringView`; implicit
conversion chains are prohibited. A print-like convenience function must format
explicitly and borrow the resulting view, with its error policy defined.

Prefer a generic convenience function that receives an ordinary eager argument,
saves the logger, tests its threshold, and formats only an enabled event. Argument
effects still occur even when disabled; formatting performed inside that library
function can be conditional. This needs no `init` parameter or capturing closure.
Passing an already constructed `String(expensive_value())` still performs that
construction before filtering. Make this distinction explicit, because changing
from an implicitly converted String parameter changes when formatting itself
executes. The saved logger supplies both the check and the dispatch destination.

Recoverable convenience logging must use a fallible formatting helper. Current
`String(value)` converters call panic-on-failure helpers, including for nested
formatting; a recoverable backend cannot undo that earlier panic. Propagate
formatting's marked errors through the convenience result, then dispatch only
after successful formatting. Primitive integer output into caller-provided storage
can avoid allocation entirely. Keep any strict String conversion or print wrapper
an explicit error-handling policy, rather than using it inside the recoverable path.

Define how `off` behaves when supplied as an event level, not only as a threshold.
It must not accidentally be emitted as the highest severity. Logger thresholds
are handle snapshots; copying a logger does not observe later changes to another
handle's threshold.

## Recommended minimal design

1. Keep independent registered allocator/logger entries, value reads, and scoped
   replacement as the only mutation authority for those entries.
2. Add borrowed method values over checked places and a generic borrowed callable
   view, preserving thin plain function references and concrete closure environments.
   Extend capture/effect contracts first. Include borrow-only local closures as a
   useful adjacent stage; defer owning captures and owning erased callbacks.
3. Start with explicit borrowed factories. Add `ref` converters only as a separately
   stated language decision if the shorthand is worth the wider conversion change.
4. Define affine raw storage, consuming release, original layout, provider
   dependencies, and typed adoption at a single validated boundary. Start with
   independent host blocks unless the full arena storage/alias foundation is ready.
5. Retain the provider in `Allocation`, and route new construction through a
   contextual convenience wrapper over an explicit-provider primitive/library API.
   Growth and release use retained authority; element hooks use invocation context.
   Migrate actual allocation failures to marked domain errors.
6. Give logging an explicit handle/text operation and contextual convenience calls.
   Validate readonly message access and nonretention, and retain an explicit
   allocator for buffering backends. Return marked allocation/output errors and
   successful `unit` for filtered events.
7. Make effectful evaluation transient, preserve latent context selection for
   initializers, and reject publication of actual local captures.
8. Choose TLS or private context forwarding from matched implementation cost and
   performance evidence. Keep future concurrency constraints in the design without
   implementing thread/FFI/device systems now.

Automatic service-cycle detection should be opt-in library/runtime support. The
proposal already permits unchecked dispatch; I would change the ordinary factory
default rather than remove that choice.
A checked backend wrapper with retained state can guard its own dispatch and
forward explicitly through captured upstream handles. Guarding the default
allocator dispatch changes runtime behavior and cost, including valid
deliberate reentrancy. A central nonallocating active-service chain is possible,
but needs stable identities, exit handling, emergency output, and evaluation
support. It is not required to make borrowed context safe.

If checked dispatch remains the default, define it as an intentional semantic
requirement and benchmark it separately. Avoid arbitrary fixed stack-depth limits;
stack-linked active records can be allocation-free. Filtering and formatting
precede logger backend entry, and every ordinary result, including a marked error,
removes the record.

## Standard library migration

| Area | Concrete change and assessment |
| --- | --- |
| [Allocation and List](../std/memory/allocation.chi) | Add provider/release facts to `Allocation`; update its registered shape and native/interpreter access. This centralizes ownership correctly. |
| List construction and literals | Replace allocation-failure absence with marked errors, preserving deferred initialization. Update the recoverable construction carrier and keep any strict panic policy explicit. Contextual calls delegate to explicit-provider construction. Successful zero-capacity construction still captures a provider. |
| List growth | Allocate through retained authority and propagate allocation errors. Allocation failure preserves the existing owner and initialized prefix; eager append argument consumption and provider bookkeeping still occur normally. |
| Box and consuming iterators | Move the containing `Allocation`; avoid separate provider fields. Destruction and extraction preserve the existing element/release separation. |
| [String](../std/text.chi) | Return allocation errors from reserve/append/clone and distinguish invalid UTF-8. Static storage remains unbound. First allocating mutation selects a provider; further growth uses it. A clone selects the current/explicit provider when allocating; an empty clone can remain unbound. |
| [Sorting](../std/memory/sort.chi) | Return scratch allocation errors instead of panicking in the recoverable API. Capture the current allocator once for both buffers without rebinding around comparators. Clean the first buffer if the second allocation fails. Add callable overloads for concrete closures/views. |
| [Algorithms](../std/algorithms.chi) and [search](../std/search.chi) | Add generic callable or borrowed-view overloads while retaining plain-function use. Stored adapters retain callback environments and captures. Ordinary missing matches remain `none`; a fallible predicate would require explicit error forwarding. |
| [I/O](../std/io.chi) | Return marked system errors from reads/writes; EOF remains a zero count. Keep stdout/stderr selection independent of logger overrides. Strict print can explicitly panic on errors, while a recoverable output API exposes them. Emergency reporting stays independent of contextual services. |
| [Library registration](../std/library.zig) and [prelude](../std/prelude.chi) | Add context/logging modules, identities, and exports. No change to ordinary user-module discovery is needed. |

The retention change is positive, but it makes allocation ownership visibly depend
on provider lifetime even for `List(int)` and empty allocations. A function can no
longer return storage allocated by a provider whose local state has ended. Either
the caller supplies the provider, the result uses a sufficiently long-lived/root
provider explicitly, or an owning design carries the provider with a valid storage
plan. Context does not create that ownership automatically.

Keep one explicit allocation path. Named helpers such as `allocate_using` are a
reasonable choice; overloads with distinct counts can preserve constructor names.
Neither named arguments nor ambient rebinding is needed to grow an existing owner.

There is one useful std cleanup to make alongside this change. `std.io.print`
currently constructs `String(value)`, and integer formatting allocates an
11-byte buffer. Printing a number inside a custom allocator can therefore call
that allocator again after constructors become contextual. Factor primitive
integer formatting into a caller-supplied buffer helper, reusable by owning String
formatting and direct stack-buffer diagnostics. This is a positive library change
with no new language primitive. General user formatting can still allocate;
neither ordinary print nor logging should promise universal allocation freedom.

Two code/receiver pairs make the proposed allocator four machine words before
other fields. Under ordinary x86-64 record alignment, adding that 32-byte handle to
the current 16-byte `Allocation` suggests a 48-byte allocation owner and a 56-byte
List header instead of the current 20-byte header. These are layout projections
for that stated representation, not measured implemented results. A shared
operation table plus one receiver could reduce duplication, but needs an honest
erasure/provenance design; generic provider parameters on every List would instead
expand types and specializations throughout std.

Benchmark header size and callback-heavy loops as well as dispatch. Spare-capacity
append should not look up context, though element hooks can still do so. Growth,
free, wrapper chains, and disabled logging need separate measurements.

## Distinguishing examples

### Storage survives a binding when its provider survives

```chi
var tracker = TrackingAllocator{upstream = context.allocator}
var values: List(int) | none = none
with context.allocator = tracker.allocator()
    values = List(int).new(0)?
# Accepted: tracker remains live through values and its eventual cleanup.
# Growing values under another binding still uses tracker.
# The enclosing callable's result must admit AllocationError.
# none means the outer slot has not acquired a List; allocation errors propagate.
```

Returning the same List from a function declaring its tracker locally is rejected.
An allocation error creates no owning allocation dependency, although executed
provider effects remain. An outer List does not migrate its elements' independent
allocations; moving the List transfers provider and storage together but preserves
the current language rule that prior owner borrows are invalidated by transfer.

### A logger snapshot retains its backend

```chi
var saved = context.logger
with context.logger = backend.logger()
    saved = context.logger
    logging.info("inside")?
logging.emit(saved, LogLevel.info, "still the selected backend")?
# The enclosing result admits the logging error alternatives.
```

This is valid only while backend and its nested dependencies survive. Rebinding
the contextual entry does not retarget `saved`. Merely emitting synchronously
through a local backend does not attach that backend to an unrelated return value.

### Cleanup and restoration have observable order

Inside an allocator/logger binding, an object's last-use destructor uses the
current logger. Early return constructs/prepares its result first, cleans
nonreturning owners while the binding remains installed, then restores the outer
binding. A returned allocation continues using its captured allocator afterward;
its later destructor uses the logger active when that destructor runs.

For an ordinary target, a final displaced object's destructor runs after the
original target is restored. A destructor that reads that target must observe the
restored value. A borrow into destroyed temporary contents cannot escape this
transition; a valid alias to a stable slot has different dependencies.

### Reset distinguishes provider state from issued storage

```chi
with context.allocator = arena.allocator()
    const values = List(int).new(8)?
    arena.reset()         # Rejected: values and its cleanup still depend on it.
    consume(values^)      # A helper that consumes and destroys the List.
    arena.reset()         # Accepted if the first reset is removed.
```

The example assumes a future reset contract, not a counter write masquerading as
invalidation. Keeping an unused allocator handle can be compatible with reset if
it captures the stable arena object rather than the old issued-storage epoch.

### Filtering preserves ordinary argument effects

```chi
logging.info(expensive_message())?
```

`expensive_message()` runs even when info is disabled. To avoid construction,
save a logger, test `logging.enabled(saved, level)`, and emit through that same
saved handle. Testing one handle and emitting contextually later can select a
different threshold or destination. A borrowed zero-argument message closure
allows a separate lazy helper to defer the whole computation. Its declared errors
are forwarded on an enabled event; a disabled event does not invoke the factory.

### Buffering owns message data

A backend storing a borrowed `StringView` in a longer-lived record fails factory
compatibility. A backend allocating a String copy through its retained allocator
can store it. Allocation/output failure returns the corresponding marked error;
partial output and completed state changes persist. Failure does not trigger
recursive logging or provider substitution.

### Stored adapters capture receivers, not service defaults

A map adapter storing `formatter.format` retains `formatter` and its nested
dependencies. Creating the adapter under allocator A does not capture A merely
because later calls may allocate. Polling it under B formats through B; polling
later under C formats through C. Each successfully allocated result retains its
own selected provider. A formatter with an explicit retained allocator instead
uses that allocator, by ordinary receiver semantics.

A filter returning a borrowed source item does not acquire the predicate's
receiver as a result dependency merely because the predicate ran. Predicate
writes into captured state still participate in call effects and overlap checks.
This distinction matters for the existing map/filter storage and lending iterator
contracts, and for counter-bearing search/sort callbacks.

## Features the context should anticipate

Keep the registration and contract model service-independent, but do not add a
general context bag or more entries in this revision. A later entry needs a stable
identity, handle type, read/capture/effect rules, native root, evaluator root, and
scope restoration. Nonowning copyable value handles can represent services or
small immutable settings; there is no need to assume every future handle owns a
heap object.

Tracing/span identity, cancellation tokens, random generators, clocks, and I/O
destinations are plausible users; locale/formatting settings can be small immutable
values rather than borrowed service objects. Their phase capabilities differ:
a clock or random generator cannot acquire a silent compile-time host effect because
root logging is disabled. A future span must retain its finishing backend and
identifier; its destruction cannot rediscover the current backend.

Scratch storage, allocation location/address space, ownership transfer, and task
suspension need independent contracts. A whole-context snapshot would retain all
its contained loans and should be explicit if added. A borrowed method captures
its receiver, while ambient service reads happen at invocation; these must remain
separate dimensions.

## Delivery and verification

The [architecture](ARCHITECTURE.md) already supplies the right owning boundaries:
name/registration and signature validation; typed reference and cleanup analysis;
trusted optimizer/backend IR; isolated evaluation state; symbolic persistent
results. Extend those boundaries rather than adding a second borrow checker or
service-specific repair passes.

Implement and qualify in this order:

1. Define callable capture/effect sources and opaque-call behavior; add borrowed
   method formation and views, environment/receiver relocation rules, and
   native/evaluator representation. Borrow-only lexical closures can follow on this
   foundation without changing plain function ownership or adding implicit boxing.
2. Define raw-storage ownership/adoption and provider provenance; update all
   containment/result/cleanup paths and the optimizer alias model as needed.
3. Validate explicit allocator/logger factories, including release consumption and
   message nonretention. Test explicit services before ambient convenience calls.
4. Add registered context reads and scoped restoration, including ordinary exits,
   cleanup effects, latent initializer selection, and transient evaluation policy.
5. Migrate std construction/growth, recoverable formatting, and I/O to marked
   service errors; add contextual logging. Update intrinsic signatures and
   recoverable literal carriers, regenerate bundles, and invalidate incompatible
   cache/artifact representations.
6. Run matched cold/incremental/runtime checks for the chosen ABI and dispatch
   policy before accepting optional general replacement or default dispatch guards.

Acceptance must include receiver/view copies surviving their original handle
wrapper; closure environment retention and escape rejection; repeated stateful
predicates and readonly capture enforcement; local receiver escape rejection;
empty/nested allocations; recursive and opaque contracts; retained writes into
caller storage; provider changes during growth;
all ordinary exit kinds; restoration proof invalidation; initializer forwarding;
repeated scalar-returning contextual evaluation; disabled/effectful messages;
buffered owned messages; reset before/after cleanup; and declaration/body edits
that alter effect requirements without changing public signatures.

Error acceptance includes provider failure before initializer effects; failed
growth preserving the old container; eager versus deferred argument consumption;
all defined domain failure reasons; buffered logger allocation failure; partial
output followed by an I/O error; disabled logging returning unit; active-service
guard removal and context restoration on propagation; and `none`/`End`/zero-byte
read remaining successful absence or completion. Also cover nested formatting
errors and rejection of propagation targeting a caller across an initializer or
callback boundary. Verify error payload ownership and returned borrow origins
alongside success origins.

Cache checks need more than a schema bump. A body edit from pure work to contextual
allocation/logging must invalidate execution-policy consumers. A backend edit
that starts retaining a message must invalidate factory acceptance. Equal safe
contracts should continue stopping unrelated propagation. Plain symbolic callable
identities can persist; actual evaluator receivers cannot.

Existing reference, interpreter, List, and text suite checks succeeded using their
cached passing results with Zig 0.17.0, safe mode, and seed zero. Fresh native
probes confirmed an explicit mutable factory and a converter preserving an
existing reference, both returning 42; borrowing an owned field through the
immutable converter, instance method value formation, and `ref` converter
declarations were rejected. Lean tooling was unavailable locally, and no new
Lean proof or implementation of the proposed features is claimed.
