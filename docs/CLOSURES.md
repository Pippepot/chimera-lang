# Chimera — Closures and Callables (v1)

This document develops the callable rules in [syntax&semantics.txt](../syntax&semantics.txt). [ARCHITECTURE.md](ARCHITECTURE.md#closures-and-bound-methods) owns compiler boundaries, and [ROADMAP.md](../ROADMAP.md#callable-implementation-sequence) owns remaining work. Callable v1 (slices 1 through 4) is implemented: concrete closures, callable parameters, concrete adapter results, bound methods, and owning erasure. Fixed `func(...)` storage accepts all these callable forms through the common descriptor/payload representation.

## 1. Syntax and typing

Closures use `=>` and ordinary call syntax. Each closure expression has a concrete compiler-generated type. `func(Args...) Return` describes a callable requirement in a function declaration's runtime parameter position. A callable signature used as a generic type argument in its result annotation is likewise a specialization pattern. In fixed storage positions, the signature denotes a common erased callable value.

An erased callable owns its captured values, including any reference values; it does not thereby own their referents. A bound method stores its captured receiver reference directly in the callable handle. An erased lexical closure owns its environment storage. These use the same public `func(...)` type and ordinary reference lifetimes. Existing `ref` bindings, parameters, fields, and results keep their aliasing semantics.

```chi
func apply(f: func(i32) i32, x: i32) i32
    return f(x)

func square(x: i32) i32
    return x * x

var offset = 5
const adder = (x: i32) => x + offset

apply(square, 10)
apply(adder, 10)
apply((x) => x + offset, 10)
```

- An inferred closure binding retains its concrete type; no user-written environment type is required.
- An inferred named-function reference retains a lightweight, copyable function-reference type.
- A runtime parameter annotated with a callable signature implicitly introduces a concrete callable type parameter. The compiler infers it from the argument; neither declaration nor call requires a named generic parameter or a `where` clause.
- Each callable parameter specializes independently. Hidden callable types add no positional static arguments, and runtime capture values do not participate in specialization.
- Direct calls retain the argument's representation. Passing a concrete closure to `apply` above introduces no erasure or environment allocation.
- A bound method also satisfies the callable requirement. Passing an existing erased value preserves its representation; specialization does not recover its hidden receiver type.
- Ownership modes remain independent of specialization: `imm` borrows the concrete callable, while `var` acquires it using ordinary copy or transfer rules.
- A local, field, collection element, or direct return type annotated `func(...)` requests the common erased representation. Callable types nested inside other parameter types remain stored types; a parameter typed `List(func(i32) i32)` has erased elements.
- In a generic struct result annotation such as `Map(S, A, B, func(A) B)`, the callable type argument is inferred from the returned value. The result keeps the actual concrete specialization; the annotation does not force its callback into erased storage.
- These rules follow resolved annotations, including aliases, rather than the annotation's source spelling. Explicit static callable parameters retain their compile-time argument rules.
- Parameter types may come from an expected callable signature; otherwise they must be written. An expression body's result type is inferred, or checked against that signature.
- Parameter access modes and result ownership remain part of the signature. An uncontextualized result is owned; a callable context may require a reference result.
- Named functions still declare their result shape. Inferring callable arguments within that declared shape does not permit an omitted result annotation or infer unrelated type arguments.
- v1 supports expression bodies after `=>`. Mutable and consuming invocation are deferred.

Taking an implicitly specialized function as a function value specializes it from the expected fixed signature. Calls through that stored function value use its fixed parameter types, which may require owning erasure of callable arguments.

Callable result patterns are resolved separately for each function specialization, from the types of returned values and struct field initializers. Ordinary type parameters in the generic struct connect those fields to the callable slots in the result annotation. Each slot is independent; matching signature text does not connect it to a particular parameter or make two slots share one concrete type. Forwarding an already constructed adapter preserves its actual callable type arguments.

- The declared generic struct and its noncallable arguments remain fixed. This is constrained callable-type inference, not inference of an arbitrary result type or inversion of arbitrary type-valued functions.
- Construction against a result pattern infers its callable slots from the corresponding field values before choosing the concrete layout. It does not first build an erased adapter and convert it afterward.
- All returns must agree on one concrete type for each slot within a function specialization. Different runtime capture values do not matter; different closure types do. Conflicting or otherwise unresolved slots are source errors.
- Runtime alternatives can use an explicitly erased callback binding before adapter construction. Its fixed `func(...)` type then becomes the adapter's inferred callable argument.
- A fixed local annotation such as `Map(S, A, B, func(A) B)` still names erased storage. Result patterns do not introduce implicit conversions between different nominal struct specializations.
- Inference inspects types without evaluating initializers, copying captures, allocating environments, or consuming `init` operations. No type-reflection operation is required.

Stored `func(...)` values remain copyable. Nonowning forms copy without allocation or provider hooks; owned environments allocate and run capture copy hooks. Declaration parameters become implicitly specialized callable requirements. Compiler-owned external declarations retain fixed callable parameter and result types, except `std.callables.erase`, whose deferred initializer deliberately retains its concrete type. Inferred plain references remain lightweight and trivially copyable. Matching signatures do not make unrelated concrete closure types identical. Signature tests with `is func(...)` preserve the tested value's concrete storage type; they do not erase it.

## 2. Captures

Runtime free bindings are captured when the closure is constructed, including bindings needed to construct nested closures. Module statics, named functions, and enclosing static arguments do not require runtime captures.

- Owned bindings are copied into the environment. Capturing a noncopyable owned binding is a source error in v1; there are no implicit move captures.
- A captured `ref` binding preserves its alias rather than copying the referent. Captured `Ref(T)` values retain their referent's provenance and permissions.
- Inferred captures initialize once, in order of first lexical occurrence in the body. Copy hooks and their effects follow ordinary rules.
- Copy capture leaves the original binding available; it does not promise effect-free construction.

```chi
var offset = 5
const adder = (x: i32) => x + offset

ref live_offset = offset
const observer = (x: i32) => x + live_offset

offset = 10
assert(adder(1) == 6)
assert(observer(1) == 11)
```

Captured values are owned by the closure. Captured references remain nonowning.

- Borrow a noncopyable value by introducing an ordinary `ref` binding before the closure. Its owner must remain valid through dependent uses; borrowing does not transfer ownership into the closure.
- Capture lists, capture initializer expressions, and construction-time ownership transfer into captures are deferred. Moving a value into another local does not make it copyable or permit implicit move capture.
- `resource^` inside the body is an invocation-time transfer, never a construction-time capture instruction. Consuming an owned capture is rejected in v1.
- Invocation borrows the environment immutably. It cannot replace or consume owned captures; effects through captured references retain ordinary immutable-receiver rules and captured authority.
- Captures requiring explicit destruction are rejected in v1. Copyable immovable captures may initialize directly in final environment storage under ordinary construction rules.
- Pending `init` parameters remain call-lived construction operations and cannot be captured as stored values.

Registered ambient context entries are read when the body executes, not captured merely because the body names them. A local snapshot is an ordinary captured binding:

```chi
const current = (message: StringView) => logging.info(message)

const saved_logger = context.logger
const saved = (message: StringView) => logging.emit(saved_logger, LogLevel.info, message)
```

`current` selects the invocation-time logger. `saved` retains the earlier logger and its provider dependencies. Constructing either closure does not snapshot the whole context. Capture initialization and copy/drop hooks use the context active when those operations execute.

## 3. Representation

Concrete closures store their captures inline, with compiler-generated invocation code taking an ordinary environment receiver. They use ordinary layout, destination construction, fieldwise ownership operations, and reference analysis.

- Concrete closure construction introduces no environment allocation.
- Concrete closures may be stored inline or constructed in explicit allocated storage.
- Plain function references retain their lightweight representation.
- Implicit callable specialization preserves these representations, including when a parameter acquires ownership of the concrete value.

Selecting a method with a borrowed receiver, such as `tracker.record`, forms a bound callable over the original receiver. Ordinary lookup, overload selection, and receiver permissions apply. Consuming receiver methods cannot form borrowed bound callables.

- The concrete bound callable contains a receiver reference, with statically known method code. It retains the receiver and its nested dependencies without copying provider state or allocating an environment.
- Erasing it copies that reference directly into the common callable handle. The result depends on the original receiver, not on the bound-callable wrapper or factory frame. This is a defined construction rule, independent of optimization.
- Copying, transferring, or destroying an erased bound method allocates nothing and invokes no receiver ownership hook. Its reference capture follows ordinary alias-copy rules.
- Invocation cannot upgrade captured permissions. A mutable receiver method requires writable authority at binding; immutable invocation of the callable can use that already captured authority.
- Bind only checked existing receiver places. Temporary receivers gain no lifetime extension. A callable instance field remains an ordinary field value, and `Type.method` remains an unbound function reference.
- Bound methods satisfy generic callable parameters and may be copied into concrete adapters under the same receiver contracts. Runtime receiver addresses do not participate in specialization.

An explicit stored `func(...)` annotation requests erasure:

```chi
const adder = (x: i32) => x + offset
const callback: func(i32) i32 = adder

apply(adder, 10)     # borrows the concrete environment
apply(callback, 10)  # borrows the existing erased handle
```

Erased `func` values use a uniform two-word native representation:

```text
func(Args...) Return
    descriptor: pointer
    payload: machine word
```

The immutable, compiler-generated descriptor provides:

- Invocation thunk.
- Callable copy operation.
- Callable destruction and storage-release operation.

The descriptor determines how the payload is interpreted and copied:

| Callable form | Payload | Copy and destruction |
| --- | --- | --- |
| Named function or noncapturing closure | Unused; the descriptor identifies the code | Representation copy; no allocation or cleanup |
| Bound method | Checked reference to the original receiver | Reference copy; no allocation or receiver destruction |
| Capturing lexical closure | Pointer to an owned concrete environment | Allocate and copy captures; destroy captures and release storage |

Only the compiler forms these representations. The distinction follows the callable's construction, not a new annotation or a guessed escape lifetime. Copying a bound method copies its one reference capture; copying a lexical closure copies its environment. An arbitrary lexical closure is not converted to a borrowed environment view, even when all its captures are references.

- Erasing a named function or bound method allocates nothing. It never borrows the source function-value wrapper.
- Erasing a capturing lexical closure allocates owned environment storage independently of the creating frame. Size and alignment follow ordinary layout and resource limits.
- Use existing typed allocation, destination construction, destruction, and deallocation facilities. Erasure introduces no separate allocator or ownership system.
- With scoped context, each environment allocation retains the allocator selected for that allocation. Release uses that retained allocator; allocating a copy selects a provider for the new environment. Allocator handles contain direct bound methods or named functions, so retaining them does not recursively allocate another environment.
- A fresh capturing lexical closure in an erased context allocates its environment before evaluating capture initializers, then constructs them directly in that storage.
- Erasing an existing capturing concrete lexical closure copies it, or transfers it with `^`, into allocated storage. Resolve the source once, reserve storage, then perform the requested copy or move directly into that destination.
- Erasure introduces no additional capture copies or moves beyond the requested construction operation. An existing immovable closure cannot be transferred.
- Owning erasure requires a copyable, automatically destructible concrete callable. A callable parameter's signature requirement alone does not impose copyability.
- Copying an erased lexical closure with captures reserves new environment storage before running capture copy hooks. Plain functions and bound methods need no reservation.
- Implicit environment-allocation failure during erasure or ordinary copying panics. It adds no recoverable alternative to a copy hook or assignment.
- Inlining, direct dispatch, and allocation elision are permitted when they preserve defined effects and lifetime behavior. Stack placement is an optimization, not an escaping restriction.

Construction owns the allocation and initialized captures until the complete callable is published. Ordinary construction exits use existing partial-initialization cleanup: destroy initialized owned captures in reverse order and release storage. Capture copy hooks are infallible; this adds no recoverable construction-error channel. Native panic retains its existing behavior and does not unwind owners.

`std.callables` exposes recoverable erasure and environment cloning:

```chi
import std.callables.{erase, clone}
import std.memory.{AllocationError}

func make(offset: int) (func(int) int) | AllocationError
    return erase(func(int) int, (value) => value + offset)

func run() int | AllocationError
    const first = make(2)?
    const copied = clone(first)?
    return copied(40)
```

`erase(Signature, init callback)` returns `Signature | AllocationError` and requires a concrete callable initializer. Already-erased inputs are rejected; use `clone` instead. `clone(Signature, imm callback)` returns the same union and borrows an existing erased handle; its signature argument may be inferred, as above.

Fallible erasure reserves any required environment before forcing its initializer, so runtime refusal performs no capture initialization or transfer. Fallible cloning reserves before copying captures; refusal leaves the source usable and unchanged. Named functions, noncapturing closures, and bound methods need no reservation and succeed directly. Argument effects already executed remain executed. These operations do not catch panic or make arbitrary capture hooks fallible. Implicit infallible operations use the same construction paths and panic on reservation failure.

Deferred-initializer availability analysis does not necessarily correlate an error alternative with a requested `^` transfer. After a refused `erase(Signature, concrete^)`, that binding can remain statically possibly transferred despite not being transferred at runtime. Fresh initializers and copy construction avoid relying on that correlation.

## 4. Ownership and lifetime

A concrete closure derives its ownership capabilities from its captures:

- Generated copy is fieldwise when every capture supports copying, otherwise unavailable. This is an explicit generated-type policy; ordinary structs still default to no copy.
- Generated move is fieldwise when every capture supports moving, otherwise unavailable.
- Reference captures copy or move their aliases independently of the referent's ownership capabilities.
- Destruction follows ordinary capture cleanup, including user-defined hooks and their effects. Reference captures never destroy their referents.

Every accepted v1 capture can be copied, including reference aliases, so accepted concrete closures are copyable. Movability remains independent of copyability.

Bound-method values copy only their receiver reference and checked dependencies. Standard service-handle factories construct their private callable fields from direct bound methods or named functions. Their ordinary fieldwise copy operations therefore allocate nothing, call no provider, and acquire no ownership of provider state. Installation/restoration of those handles has the same property. This guarantee follows from the factory's permitted constructions, not from assuming that every value of type `func(...)` has a trivial copy.

An erased lexical closure owns its environment and storage; an erased bound method owns its captured reference value, not its receiver:

- Copying an allocated environment constructs a separate environment using fieldwise capture copying, including custom hooks in capture order. It uses the existing captured values, without re-running the closure body or re-reading the original free bindings. Copying never implicitly introduces shared ownership or reference counting.
- Moving the handle transfers its payload and ownership without relocating an allocated environment or invoking capture move hooks.
- Destroying a handle releases the captures it owns, including allocated environment storage when present. A bound method never destroys its receiver.
- Copying reference captures preserves their referents and permissions. Custom copy hooks may introduce further dependencies or effects under their ordinary contracts; separate environment storage does not promise independent referents.
- Environment indirection permits a movable handle to own an immovable environment constructed in place.

```chi
const first: func(i32) i32 = make_adder(5)
const second = first   # allocates and copies the environment
const third = first^  # transfers the handle without allocation

const plain: func(i32) i32 = square
const another = plain # copies the function handle without allocation
```

Copyability is a uniform guarantee of the erased type, not a property checked against the runtime target. Future noncopyable concrete closures cannot be erased into this `func` type without an explicit change of representation or capability; they do not silently make existing `func` values move-only.

Existing parameter semantics remain unchanged:

- `imm`, including an omitted mode, borrows the callable for the call.
- `var` acquires ownership: it may copy a copyable source or accept a fresh value or explicit transfer. Passing an erased `func` without `^` copies it according to its descriptor: a receiver reference for a bound method, an owned environment for a capturing lexical closure. Passing it with `^` transfers the handle.
- `deinit` consumes according to ordinary consuming-parameter rules.
- `init` defers the entire construction expression, including capture effects and any requested erasure allocation. Signature and callable-type inference do not execute it.

Matching a declaration parameter's callable requirement does not convert the argument to an erased handle. Erasure copies or transfers captured values according to their ordinary capabilities; it never turns a reference capture into ownership of its referent. Passing an existing erased handle to an `imm` callable parameter borrows it without copying or allocating. An ordinary `ref` to a callable aliases that callable's storage; it does not perform erasure or acquire an independent handle.

## 5. Returns and reference lifetimes

Owned captures may outlive the function invocation that created the closure.

```chi
func make_adder(offset: i32) func(i32) i32
    return (x: i32) => x + offset
```

This returns an owning erased callable. Its integer capture belongs to the returned environment, not the factory's frame. The declared `func` result supplies the erased type; general return inference is unnecessary.

- Captured borrows cannot outlive their referents. Returning a closure borrowing a factory local remains a source error.
- A reference returned into owned environment storage depends on the closure's ownership and storage lifetime.
- A returned captured reference retains its original referent dependency; it does not inherently borrow the closure's storage.
- An allocated environment also depends on its retained allocation provider. Owning captures do not permit escape past that provider's lifetime.
- Owner transfer, replacement, destruction, and writes retain ordinary invalidation rules. Stable environment addresses do not override those rules.

Native execution and compile-time evaluation use the same ownership operations. Evaluator snapshots retain allocation identity and initialized contents. Owned environments remain evaluation-local storage: they cannot be published as canonical static callable constants. Receiver-free named functions and noncapturing closures can be published.

Service factories return ordinary function values bound directly to caller-owned providers:

```chi
struct Tracker
    calls: int

    func record(mut self: Tracker, amount: int) unit
        self.calls += amount

func recorder(mut tracker: Tracker) func(int) unit
    return tracker.record

var tracker = Tracker{calls = 0}
const record = recorder(tracker)
const again = record
record(2)
again(3)
assert(tracker.calls == 5)
```

Neither construction nor copying allocates. Both handles retain the original tracker, independently of the factory frame and each other's wrapper storage. Returning a handle by value copies its captured receiver reference; returning an ordinary `ref` to a factory-local handle would still be invalid.

An explicit lexical wrapper is also valid, but follows lexical-closure erasure and allocates:

```chi
func allocating_recorder(mut tracker: Tracker) func(int) unit
    ref provider = tracker
    return (amount: int) => provider.record(amount)
```

The allocated environment owns the reference capture, while tracker remains borrowed. This form is unsuitable for the nonallocating service-handle factories. Conversely, binding a method of a factory-local tracker is rejected:

```chi
func bad_recorder() func(int) unit
    var tracker = Tracker{calls = 0}
    return tracker.record  # receiver would outlive its owner
```

Capture lists and mutable closure invocation are unnecessary for these service factories. Direct method binding preserves the original provider; an ordinary value capture of provider state would instead copy that state.

The compiler preserves capture dependencies and construction, copy, invocation, and destruction effects through assignments, conversions, calls, returns, containers, and structural unions. Erasure does not discard lifetime facts or reference authority.

Each erased value retains compiler-visible ownership and reference facts for its payload. Reference contracts distinguish owned environment storage, direct receivers, captured referents, and ambient inputs. Allocated copies create fresh environment ownership while retaining dependencies and effects produced by ordinary capture copy contracts. Bound-method copies retain the same receiver dependencies. Nonowning construction facts survive factories, copies, fields, joins, and forwarding independently of invocation identity. Opaque storage mutation or an owning alternative prevents that proof.

Known invocation targets retain precise reference contracts. Unknown erased targets use conservative contracts covering possible environment storage, captured references, writes, and returned dependencies. Copy/drop effects apply only to owned environments, so forwarding or joining bound handles does not manufacture receiver writes. Invocation may still mutate referenced provider state. Implicit cleanup contributes its real hook effects to helper contracts. Consuming and replacing opaque handles destroy remaining environments through their descriptors, not through synthetic handle fields. Ordinary borrow exclusions apply to invocation and ownership operations; the runtime descriptor is not a substitute for compile-time lifetime checks.

Service protocols may require stronger contracts than their invocation signatures alone express. Allocator factories must preserve issued-storage provenance and release authority; synchronous logger factories must reject retention of message borrows. Validate those requirements at factory construction. An incompatible contract is a source error; missing query state requires recomputation, not an assumed safe contract. Ambient requirements must be discovered even for zero-argument, scalar-returning callables and through implicit hooks.

## 6. Collections

Collections may own heterogeneous callable values through the common `func` type.

Collection construction and recoverable growth return `AllocationError`; new closure environments and copies use the current allocator and retain their original release provider, as specified in [shared context](SHAREDCONTEXT.md).

```chi
import std.memory.{List, AllocationError}

func run() unit | AllocationError
    var callbacks = List(func(i32) i32).new(0)
    if callbacks is AllocationError -> return callbacks^

    for offset in 0..3
        _ = callbacks.append((x: i32) => x + offset)?
    _ = callbacks.append((x: i32) => x * 2)?

    for ref callback in callbacks
        assert(callback(10) >= 10)
```

- The collection owns the function handles.
- Each erased lexical closure with captures owns its distinct allocated environment. A stored bound method instead retains its receiver without an environment allocation.
- Moving or reallocating collection elements does not relocate environments.
- Stored callbacks retain any dependencies on borrowed referents.
- The collection's own allocations follow its normal allocator rules.
- Failed insertion follows ordinary `var` argument semantics: prepared callback ownership has already transferred, and capture effects are not rolled back.
- The checks handle collection allocation refusal. Implicit owning erasure used to prepare an append argument still panics on environment-allocation failure; fully recoverable construction must use explicit fallible erasure first.
- Borrowed iteration with `for ref` avoids copying callback environments. Owned loop bindings follow ordinary element-copy rules and may allocate.

Repeated construction sites require no special retention restriction. Homogeneous collections may instead store concrete closures inline; instances of one expression and specialization share a concrete type.

Lazy adapters acquire ownership of callbacks they store. Terminal algorithms borrow callbacks they invoke. Their public callback parameters use ordinary `func(...)` annotations with implicit specialization.

Generic adapters use ordinary callable signatures in result annotations. Struct field inference carries the callback's concrete type into the returned specialization:

```chi
import std.iteration.{End}

struct Map(S: type, A: type, B: type, F: type)
    source: S
    transform: F

    func next(mut self: Map(S, A, B, F)) B | End
        const result = self.source.next()
        if result is End -> return End{}
        return self.transform(result)

func map(static S: type, static A: type, static B: type,
         var source: S, init transform: func(imm A) B) Map(S, A, B, func(imm A) B)
    return Map{
        source = source^,
        transform = transform,
    }
```

The adapter's implementation names its concrete field type through `F`; its public constructor keeps the ergonomic callback annotation in both parameter and result positions. The result annotation supplies `S`, `A`, and `B`; the `transform` initializer determines `F`. Passing a concrete closure returns a `Map` containing that closure inline. Passing an erased callback returns a `Map` containing the erased handle. The callback type is inferred whether callers supply the declared static arguments or use ordinary static inference. Hidden callable types never become additional positional arguments.

`init transform` constructs the callback directly in the returned field, supporting copyable immovable environments without an intermediate relocation. A named callback copies unless the caller supplies `^`; its construction effects remain deferred under ordinary `init` rules. Inferring the field type does not construct or consume the initializer.

An adapter with two callback fields may infer two different concrete types even when their signatures match. The field initializers determine which type goes in which slot; declaration order and signature matching do not choose a callback on the programmer's behalf.

A field explicitly typed `func(...)` instead requests erased storage. Accepting a callback through an implicitly specialized parameter does not itself force that storage choice.

Shared-context service fields use the same stored `func(...)` type:

| Operation | Stored field type | Factory construction |
| --- | --- | --- |
| Allocator allocation | `func(AllocationLayout) RawBlock \| AllocationError` | Direct bound method or named function |
| Allocator release | `func(deinit RawBlock) unit` | Direct bound method or named function |
| Logger emission | `func(LogLevel, StringView) unit \| AllocationError \| IoError` | Direct bound method or named function |

Keep these fields private and expose provider factories rather than construction from arbitrary erased callbacks. The factories form direct bound methods over the original provider, or use permanent named functions for stateless services. Check this construction invariant at the service factory boundary and preserve it in result contracts, even when invocation targets later become opaque. It guarantees nonallocating handle copying without changing the meaning of stored function fields. Copy the fields through ordinary callable copy operations; do not declare every `func` value trivially copyable.

An allocation can retain its allocator without allocating to copy that handle. A provider needing lexical callback state can own that state itself and expose forwarding methods; those methods bind directly to the stable provider. Use explicit borrowed factories when writable access is needed; existing immutable converter parameters do not acquire writable authority. Service invocation may allocate or mutate provider state according to its protocol even though handle copying does neither.

## 7. Implementation slices

All four v1 slices below are implemented. Each includes diagnostics, native/interpreter behavior, ownership and reference checks, incremental recomputation, and compatible publication/cache handling. These describe implementation boundaries, not user-visible capability traits. [ROADMAP.md](../ROADMAP.md#callable-implementation-sequence) tracks deferred extensions.

1. **Concrete closures and callable parameters.** Parse `=>` and contextual signatures; infer captures and their initialization order. Generate inline environment structs and ordinary receiver-based invocation, with stable identities based on expression sites and enclosing specialization. Implement implicit concrete-type specialization of runtime callable parameters without adding positional static arguments. Preserve aliases, parameter modes, result ownership, and ordinary copy/move/drop behavior. Extend capture/reference effects and lifetime planning for these concrete values; reject unsupported captures and invalid borrowed-data escape. Verify snapshot versus reference capture, hook effects and ordering, deferred construction without early effects, independent callbacks, and specialization reuse across different runtime capture values. Stored capturing-callable erasure belongs to slice 4.
2. **Concrete adapter results.** Extend struct field inference to combine declared generic result patterns with actual callback types, including eventual `init` types. Resolve each result slot through a selected-instance query before publishing the concrete call result and destination layout. Keep candidate discovery independent of body analysis and diagnose conflicting returns or unresolved inference cycles. Update retained std callbacks to acquire ownership and keep concrete fields; terminal consumers continue borrowing. Verify ergonomic public signatures, explicit/inferred static arguments, aliases and forwarding, independent or reordered callback fields, and direct construction of copyable immovable environments.
3. **Bound methods and nonallocating erasure.** Bind methods to checked original receivers after ordinary member/overload selection and permission checks. Implement the common descriptor/payload representation for named functions, noncapturing closures, and bound methods, with allocation-free copy/drop operations that never destroy providers. Track descriptor storage forms independently of invocation-target identity, preserving receiver and result-reference dependencies across copies, fields, joins, and opaque forwarding. Include expected-signature specialization of function references and fixed indirect-call signatures. Verify factory-returned methods, copies surviving original wrapper lifetimes, readonly versus writable receivers, local/temporary receiver rejection, and native/evaluator descriptor reachability and ABI/cache changes. Expose the construction/effect facts needed by later service factories; scoped context itself belongs to its separate task.
4. **Owning lexical-closure erasure.** Add allocated environments using existing typed allocation, destination construction, and cleanup. Implement fieldwise environment copying, handle transfer, destruction/storage release, and explicit fallible erasure/cloning alongside infallible copy operations. Reserve before capture initialization or copying; preserve partial-construction cleanup and marked allocation errors. Extend opaque invocation/copy/drop contracts and container provenance for allocated environments, then qualify heterogeneous callable collections, returned references, repeated construction, immovable captures, copy-hook effects, and allocation refusal. This slice uses the existing allocation path and does not wait for scoped context. When retained providers are available, use the common allocation owner so copying selects a new provider and release retains the original provider.

The [scoped context task](../ROADMAP.md#scoped-context-implementation-slices) depends on slice 3. It can proceed independently of slice 4. Service-specific nonallocating factory validation, message nonretention, storage authority, and ambient input registration belong to that task; cross-feature integration verifies invocation-time context versus saved handles and environment/provider lifetimes when both features are present.

## 8. Deferred functionality

- Explicit capture lists, capture initializer expressions, and construction-time ownership transfer into captures.
- General borrowed erased views of lexical closure environments. Generic parameters already borrow concrete closures; service handles use direct bound methods. A separate public borrowed-callable surface is unnecessary for these use cases.
- Mutable and consuming closure invocation.
- Captures with explicit-drop obligations.
- Multistatement closure bodies and general function return inference.
- Directly returning anonymous concrete closure types without an erased result annotation; settle return-type inference, naming, or opaque results first.
- Move-only erased callable representations.

Concrete environments are the implementation foundation. Callable parameters specialize implicitly. The common `func(...)` value stores receiver references directly for bound methods and owns allocated environments for capturing lexical closures. Its versioned descriptor ABI is distinct from the inferred thin-function-reference ABI.
