# Storage, allocation, and references

This is a design note; accepted language rules belong in
[syntax&semantics.txt](syntax&semantics.txt). The host API uses `Box(T)` for
the unique allocated owner, `Ref(T, writable)` for the storable non-owning
handle, and `borrow item = ...` for a scoped alias. Future provider, location,
and target API sketches remain conceptual.

## Design constraints

- Construction uses the destination supplied by its context. A struct
  initializer does not itself select a storage location or allocation strategy;
  the same expression can initialize a local, a field, or allocated storage.
- The implementation may use registers, inline storage, automatic storage, or
  no storage when the difference is unobservable.
- Separately managed dynamic storage is explicit. Allocation does not construct
  values, and value construction does not allocate unless the called owning
  abstraction says that it does.
- A value type does not change according to whether its representation is on a
  host, a device, a stack, or a heap. Storage and reference abstractions carry
  the facts required to access it.

The implemented host API provides typed allocation and unsafe indexed access,
`Box(T)` owners, copyable `Ref(T, writable)` handles, scoped aliases, and
`Buffer(T)` with checked element access and borrowed `BufferView(T)` slices.
The accepted ownership, access, construction, and failure rules are recorded in
[syntax&semantics.txt](syntax&semantics.txt). Box constructors allocate before
evaluating their initializer through general init forwarding and destination
construction, including aliases and indirect calls. Nonescaping init parameters
retain captured writes, transfers, checked-reference results, failure, and
caller-directed lexical exits. Further allocating-consumer verification remains
in [milestone 1](ROADMAP.md#1-destination-construction-and-consuming-access).
The target, provider, location, and address-space contract below is accepted,
but provider selection, device locations, and address spaces are not public APIs.

Keep these dimensions independent:

| Dimension | Meaning | Examples |
| --- | --- | --- |
| Value type | Meaning and operations of a value | `Foo`, `int` |
| Target representation | Layout rules for a target's storage domain | x86-64 host ABI, a device's validated global-storage ABI |
| Allocation provider | Policy and mechanism used to obtain and release storage | system allocator, arena, device allocator |
| Memory location | Concrete memory domain and accessible execution contexts | host memory, pinned host memory, a particular device |
| Allocation layout | Required byte size and alignment at that location | 128 bytes aligned to 16 |
| Address space | Target-level class used by code accessing memory | generic, global, workgroup, private, constant |
| Lifetime dependency | Owners and resources that must remain live for access | a local, allocation, collection, or device |

Stack and heap are allocation or lifetime strategies, not memory locations or
address spaces. A device identity is a memory location, not an address space.
For example, two GPUs may both expose global address space while referring to
different, mutually inaccessible allocations.

## Working semantic model

### Allocation layout

An allocation layout is the resolved byte size and alignment requested from an
allocation provider. Alignment is a nonzero power of two. A successful result
satisfies both requirements; the provider may reserve more storage internally.

Typed allocation additionally takes an element type and count. Its byte size
and alignment must be derived from a layout for `T` in the layout domain selected
by the execution target and memory location. That representation includes the
element stride and any field or variant offsets. The resolved element stride
must be a multiple of its alignment, even when
count is zero; `count * stride` is checked before calling the
provider. Alignment must be a nonzero power of two and at least the target's
natural alignment for `T`; a provider may reject a stricter alignment. Target
compatibility must be established for `T` and its contained types, not inferred
from a coincidental host byte size. `HostTypeLayout(TypeId)` is the x86-64 host
representation only; a future layout must be keyed by type and the target's
location-specific layout domain, and must not silently fall back to host layout.
Initially restrict device buffers to validated scalar element types rather than
assuming every host struct is device-compatible.

`AllocationLayout` contains resolved byte size and alignment, not the logical
element count. A typed allocation request binds that layout to `T`, its target
representation, location, and count; the owner retains those facts alongside
deallocation authority. For a zero-byte host layout, the current provider
reserves one byte to retain a distinct, stable address and records the reserved
size for deallocation; the logical count and layout remain unchanged. Any other
supported location must likewise give each successful zero-byte allocation a
distinct, stable identity suitable for zero-sized element access and destruction,
or fail the allocation. No address arithmetic or foreign-memory access follows
from that guarantee.

### Allocation provider and location

The semantic allocation operation has three independent inputs: a provider, a
memory location, and an allocation layout already resolved for a target and
element type. It is fallible and returns exclusive ownership of uninitialized
storage. The provider selects policy; the location selects where the storage
exists and which execution contexts can access it. The target and location select
a compatible layout domain; neither the provider nor the value type selects it.
A provider may reject a location or layout it does not support, but cannot
change the element stride or reinterpret bytes as another target representation.

The surface API may bind a provider to a location for convenience, but that must
not erase the distinction. In particular, a device context can be both the
location authority and the provider-facing resource without making "device" an
allocation strategy.

Implement host-accessible allocation first. Device allocation comes later and
would be a host-side operation: allocating device global memory does not imply
that ordinary allocation is callable from a kernel. Workgroup and private
storage have different lifetime and scheduling rules and should use explicit
kernel storage constructs rather than the dynamic allocation API.

Moving data between locations is a separate explicit operation. Device copies
may eventually be queued or asynchronous, but the first API should remain
synchronous unless the language also has a resource that represents completion
and keeps both allocations alive until it completes.

### Allocation ownership and initialization

`Allocation(T)` is the low-level owning handle. It retains the
provider, location, and original layout needed to deallocate its storage. More
precisely, it either owns self-contained deallocation authority or has lifetime
dependencies that keep the provider and location resources alive. It is an
explicit-drop value: every path must pass it to `deallocate`, transfer it, or use
an explicitly unsafe operation that assumes its obligation.

`deallocate` consumes an allocation; it does not destroy initialized elements.
Before deallocation, every live element must be destroyed or transferred out.
The low-level handle need not maintain a runtime initialization bitmap:
initializing, destroying, or accessing an element through `Allocation` is
unsafe unless the caller establishes its current state. Higher-level containers
track their initialized range as part of their own invariants.

The current `unsafe_borrow_initialized` is expression-only. The separate
`unsafe_borrow_element` produces a storable `Ref(T, false)` whose lifetime
depends on the allocation. Consuming or mutating
the allocation invalidates dependent
borrows. Both operations require caller-proven bounds and initialization; they
are not safe initialized access. Other locations have no access API yet.

### Reference types

`Ref(T, writable: bool)` is non-owning and non-nullable. Its required static
permission distinguishes read-only from writable access; either handle can be
copied without copying the referent or acquiring ownership. Absence uses an
explicit variant rather than a null reference. Its lifetime depends on every
owner and resource needed for access. Borrowing an immutable `Box(T)` or place
grants read-only access; borrowing mutably requires a mutable access path.
`Ref.as_imm` explicitly attenuates writable permission, without any safe
conversion in the other direction. `const` prevents rebinding a handle but
does not remove its type-level writable permission. Assigning to a `var Ref`
changes which value it refers to; assigning through a writable dereference
replaces the referent and destroys its old value, provided that value can be
automatically destroyed. Multiple writable handles may coexist. Calls still
reject overlapping mutable arguments and borrowed arguments that may alias
them; there is no global exclusive-borrow rule.

`borrow item = place` binds a local read-only alias to the initialized place
without copying T; `borrow mut item = place` requires writable access and
binds a writable alias. A borrow binding is neither an owned T nor a storable
Ref, and cannot be retargeted. Assigning to a writable binding replaces the
captured value. Binding an expression-only borrow with an ordinary `const` or
`var` instead copies T when copying is supported. A borrow from a Ref retains
the referent's origin even if the handle is rebound, and cannot be used after
its owner or storage is invalidated. It cannot transfer ownership of T.

When a returned or stored `Ref` may refer to several sources, all possible
owners and resources must outlive it. A bodyless function returning `Ref`
conservatively depends on every borrowed input. Without borrowed inputs, such a
return is a compile error. Other borrows with origins the compiler cannot prove
safe are also rejected. A `from(name, ...)` contract on a borrowed return
narrows the permitted parameter origins; a `mut` parameter names the caller's
owner after copy-back, whether the callee returns normally or fails.

Address space belongs on `Ref`, not on `T`. A future address-space parameter
would be independent of the existing `writable` permission; each target defines
its supported spaces and which can access a particular location. The concrete
device identity remains runtime state owned by a host-side allocation or device
resource, not a distinct
value type for every device. A borrow retains that location and the owner as
lifetime dependencies. Host code cannot dereference a device-only borrow;
cross-location transfer is explicit, not a cast of `S` or `T`. Access from a
second target needs a verified compatible representation, or an explicit
elementwise conversion rather than a bytewise copy.

`Ref(T, writable)` grants access only while its initialized referent remains
live.
`Allocation` owns unsafe indexed initialization, destruction, and borrowing;
the caller proves element initialization. `Box` exposes read-only and writable
Ref handles of its initialized value, while `Buffer` exposes checked read-only
and writable element handles (writable access needs a mutable buffer place). Raw
address arithmetic and foreign-memory access remain outside this host-first
API; decide their representation when those operations have a concrete use.

`Box(T)` exclusively owns one initialized `T` in separately allocated
storage. It does not copy implicitly. Construction combines allocation and
initialization and is therefore fallible; destruction destroys `T` and
deallocates the storage. Moving the owner preserves the allocation and its
location. Under the implemented `Box.new(init value: T)` contract, allocation
precedes evaluation of the entire initializer expression. Fresh values construct
directly in the allocation, existing copyable values copy into it, and explicit
transfers require move support. This also permits copying an existing immovable
value when it supports copy. A named, noncopyable immovable value cannot be
relocated into a Box.

`Box.new(owner.borrow()[])` explicitly creates a distinct allocation by copying
the pointee. The ordinary library constructor allocates a temporary storage
owner, forwards the initializer to raw slot initialization, and consumes the
storage owner into a Box after successful construction. Aliases and indirect
calls use the same deferred capture and lexical-exit protocol. Partial fields
clean before receiving frames release unfinished storage. There is no separate
duplication API.

An eventual shared owner (name unsettled) would share ownership of one initialized
`T` and its control block.
Copying it increments a synchronized reference count; ending an owner decrements
it, and the final owner destroys the value and releases storage. This does not
synchronize access to `T`. It would initially be available only where the provider and
location support the required atomic operations. Strong-reference cycles either
remain forbidden by API design or leak; no upgradeable weak-reference type is
proposed here.

## What Mojo implements

This section reflects Modular's repository at commit
[`975baa7`](https://github.com/modular/modular/tree/975baa793c02665a36194c285496e133c9452068),
inspected on 2026-09-17.

Bracketed parameter lists and the term *origin* in this section are Mojo's own
syntax and terminology, not proposals for this language.

### Heap allocation

Mojo's
[`alloc.mojo`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/alloc.mojo)
has a layout-aware API:

- `Layout[T, alignment]` stores an element count at runtime and alignment as a
  compile-time parameter. It can derive the equivalent byte count.
- `alloc(layout)` returns `Allocation[T]`, which owns uninitialized storage and
  bundles the layout required by `dealloc`.
- `Allocation` is explicitly destroyed. `dealloc(allocation^)` consumes it;
  borrowed pointers carry its origin, so consuming it also invalidates them.
- `ThinAllocation` retains only the owning pointer. Reattaching the exact layout
  is unsafe. Mojo uses this smaller representation inside containers and smart
  pointers that already know their capacity or single-element layout.
- `ManagedAllocation` automatically frees storage but may contain only
  trivially destructible elements, because freeing the allocation does not run
  element destructors.
- Allocation failure currently aborts rather than using Mojo's error path.
  Negative counts also abort, and zero-sized types use a dangling sentinel.

The useful lesson is to bundle deallocation facts with the owning handle and
make deallocation consume it. `ThinAllocation` is an optimization to defer
until a container has a demonstrated representation need. This language should
use its ordinary fallible control flow for allocation failure instead of
adopting Mojo's abort behavior.

### References and owning pointers

Mojo's unified
[`Pointer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/pointer.mojo)
is parameterized by pointee type, mutability, origin, and address space. It is
non-nullable; unsafe operations cover arithmetic, raw addresses, initialization,
and destruction. `UnsafePointer` is now only a deprecated alias of `Pointer`.
This supports keeping one non-owning `Ref(T, writable)` abstraction here.
Borrowing can only grant permission available from the access path; writable
permission remains part of the resulting handle's type.

Mojo's
[`OwnedPointer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/owned_pointer.mojo)
allocates a single-element layout, moves or copies a value into it, and on
destruction destroys the value before deallocating storage. Its interior
reference receives a lifetime tied to the owner. This is the direct model for
`Box(T)`, but retaining the complete allocation
initially is simpler than Mojo's `ThinAllocation` plus reconstructed layout.

Mojo's
[`ArcPointer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/arc_pointer.mojo)
allocates one control block containing atomic strong and weak counts plus the
payload. Its atomic bookkeeping does not make payload access thread-safe. The
control-block pattern applies to a future shared owner; the `Arc` and
`WeakPointer` names and upgradeable weak semantics do not.

### Address spaces and devices

Mojo places `GENERIC`, `GLOBAL`, `SHARED`, `CONSTANT`, and `LOCAL` on its
[`AddressSpace`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/address_space.mojo)
and makes the address space a pointer parameter. Its
[`stack_allocation`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/stack_allocation.mojo)
uses a compile-time address space and lowers GPU shared, constant, and local
storage differently. This reinforces that address space and heap allocation
policy are separate dimensions.

Mojo does not generalize ordinary `alloc` over a memory location. Its
[`DeviceContext` and `DeviceBuffer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/max/mojo/max/gpu/host/device_context.mojo)
form a separate host-side GPU API. A `DeviceBuffer` is allocated in device
global memory, is freed through its context, and maps to a device `Pointer` at a
kernel boundary. Host/device copies are explicit and asynchronous. Mojo also
has pinned `HostBuffer` storage. `DeviceBuffer` is restricted to scalar `DType`
elements rather than arbitrary host types; kernel arguments use a
`DevicePassable.device_type` mapping and target-aware ABI size and alignment
checks. This separation prevents host code from directly dereferencing
inaccessible device memory, but it duplicates allocation surfaces and does not
expose one general location model. Unlike ordinary `alloc`, buffer creation is
fallible.

## API suggestions

### Recommended minimal core

Prefer `allocate` and `deallocate` for the raw storage operations. `release` is
too easily confused with decrementing shared ownership. The semantic interface
should be equivalent to the following pseudocode; it does not introduce public
non-host declarations yet:

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

`ResolvedAllocationLayout(T)` binds a byte `AllocationLayout` to the selected
target, location, and nonnegative count. This avoids pairing a host layout with
a device location or passing a count inconsistent with the resolved byte size.
The request must not outlive a resource required to validate its location;
allocation failure leaves provider and location ownership with the caller.
`Allocation(T)` retains the resolved request and provider authority, directly
or through a lifetime dependency. The implemented host API fixes target,
location, and provider implicitly; it stores the logical count separately from
the mapped byte size. Its public count is `int`, while byte-size arithmetic is
checked in wider unsigned storage before requesting host memory. Larger public
counts and other targets require a concrete provider and target ABI first.

The host low-level operations are available as standalone `std.memory`
functions, and `Allocation(T)` exposes methods for the same operations:

```text
unsafe_initialize(T, allocation, index, value)
unsafe_take(T, allocation, index)
unsafe_destroy(T, allocation, index)
unsafe_borrow_initialized(T, allocation, index)  # expression-only borrowed T
unsafe_borrow_element(T, allocation, index)      # storable Ref(T, false)
```

`Allocation(T).capacity()` returns the logical element count retained by the
allocation, including zero-sized elements; it does not expose storage fields.

Accessors for layout and location remain design sketches.
The implemented `unsafe_initialize` contract takes its value as an `init` parameter
and constructs directly in the uninitialized element slot, including immovable
values. This is the general storage primitive used by owning abstractions;
it does not require Box-specific expression recognition.
These operations do not transfer storage ownership; initialized state and
bounds are the caller's obligation at this low level.

The accepted safe host owner and borrowed access use that core. The constructor's
`init` mode and the consuming-access interpretation of `deinit` belong to
milestone 1:

```text
struct Box(T: type)
  fallible new(init value: T) Box(T)
    ...

func borrow_box(static T: type, imm owner: Box(T)) Ref(T, false)
func borrow_mut_box(static T: type, mut owner: Box(T)) Ref(T, true)
func borrow_local(static T: type, imm item: T) Ref(T, false)
func read(static T: type, static writable: bool, imm reference: Ref(T, writable)) T
func write(static T: type, imm reference: Ref(T, true), var item: T)
func value(static T: type, deinit owner: Box(T)) T

const constructed = Box.new(value)
const explicit = Box(T).new(value)
const borrowed = borrow_box(T, owner)
const extracted = value(T, owner^)
```

`value` consumes the owner in place because its parameter is `deinit`. Both
`value(T, owner)` and `value(T, owner^)` supply that consuming access without
first relocating the owner; its name does not need an `into_` prefix.
`get_value` would not distinguish borrowing, copying, and transfer.

`Box(T)` uses a one-element host layout, initializes exactly once,
and makes destruction plus deallocation automatic. Host allocation remains the
default; provider and location selection remain future work. With `init`,
`Box.new(make(argument()))` allocates before evaluating `argument()` or calling
`make`. Allocation failure skips the whole expression. Failure during
initialization cleans up completed subobjects and frees the allocation; it does
not destroy an object whose initialization never completed or roll back prior
ownership transfers. Returning a named local from `make` still requires copy or
move support; a fresh return expression constructs directly in the allocation.

The host owner/handle/binding model makes access and attenuation explicit.
These expressions illustrate supported methods, dereference, and scoped aliases:

```text
var first = Box.new(value)
var second = Box.new(other_value)
var handle: Ref(T, true) = first.borrow_mut()
borrow item = handle[]
borrow mut writable_item = handle[]
handle = second.borrow_mut()  # rebinds the handle, not either alias
writable_item = value         # replaces the first value
handle[] = other_value        # replaces the second value
const read_only = handle.as_imm()
```

`Box` owns the initialized value and stable allocation; `Ref.copy` copies only a
handle. The old pointee-copying `Ref.copy` method becomes `Ref.read`, requiring
copy support from the pointee. A borrowed binding retains the captured referent
and its origins, not the variable used to obtain it. Ordinary `const`/`var`
bindings to a borrowed T instead copy it when supported. Pointee replacement requires writable
authority and automatic destruction of the old value. Origin checks apply to
borrowed returns and stored handles across calls and invalidation, using the
existing `from(...)` contract where appropriate. `Box.new` applied to a borrowed
copyable T allocates a separate owner; extracting T from Box still
requires a directly movable T. Low-level allocation remains explicit-drop.

`Buffer(T)` keeps `Allocation(T)` plus an initialized count; capacity is derived
from the allocation's logical count, with no second stored capacity.
`get(index)` and `get_mut(index)` check initialized bounds and return read-only
and writable element Refs respectively; `get_mut` requires a mutable buffer
place. Mutating the buffer invalidates prior element and `BufferView(T)` borrows,
even if capacity did not change. A higher-level List and text API follow in
later milestones. Do not add a thin allocation handle until retaining layout
and location is shown to be a material cost.

Place public declarations under `std.memory`. Re-export `Box` and `Ref`
through `std.prelude`; require an explicit
`std.memory` import for low-level allocation and layout APIs. Compiler support
for storage and lifetime checks need not be expressible as ordinary library code.

### Location-specific conveniences

The standard library can offer concise wrappers without weakening the semantic
model:

```text
host.allocate(layout, using = allocator)
device.allocate(layout)
copy(source, mut destination)
```

Here `device` is a runtime resource identifying a particular device, not an
enum case. Its allocation result retains that identity. Passing it to a kernel
produces an address-space-qualified read-only `Ref` or view whose device
representation is validated for
that target; host code cannot safely dereference it. Workgroup and private
storage remain kernel declarations rather than calls to this API.

### Remaining non-host prerequisites

- Select a concrete target and location, then implement and test its layouts,
  compatible element types, address-space mapping, provider resource lifetime,
  and zero-byte allocation or failure behavior. Do not add a device `TypeLayout`
  query or a general provider dispatcher before that target exists.
- Settle the surface spelling of address spaces and larger count types when
  non-host allocation and origin-aware `Ref` become implementable. Initial
  cross-location transfers remain synchronous; asynchronous operations require
  an explicit completion resource retaining both allocations.
- Determine atomic support per location before adding shared-owner control blocks.
