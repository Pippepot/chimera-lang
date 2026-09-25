# Storage, allocation, and references

This is a design note, not yet authoritative language semantics. Accepted rules
belong in [syntax&semantics.txt](syntax&semantics.txt) once the API has been
reviewed. The API sketches below are conceptual and do not settle
static-parameter application, lifetime-contract, dereference, or named-argument
syntax.

## Design constraints

- Evaluating an expression constructs a value; it does not select a storage
  location or allocation strategy. A struct initializer does not imply stack or
  heap allocation, and binding its result does not change that.
- The implementation may use registers, inline storage, automatic storage, or
  no storage when the difference is unobservable.
- Separately managed dynamic storage is explicit. Allocation does not construct
  values, and value construction does not allocate unless the called owning
  abstraction says that it does.
- A value type does not change according to whether its representation is on a
  host, a device, a stack, or a heap. Storage and reference abstractions carry
  the facts required to access it.

The implemented host subset uses `std.memory.allocate(T, count)` and explicit
`deallocate(T, allocation^)` with `Allocation(T)`. The `unsafe_initialize` and
`unsafe_take` element transfers require caller-proven bounds and initialization
state, and currently support only types with compiler-supported direct moves.
`make_ref(T, value)` and consuming `value(T, owner^)` use those transfers to
own one initialized value. The constructor requires an automatically droppable,
directly movable `T`; zero-sized allocations currently fail. `Ref(T)` has no
safe borrowed access, explicit duplication, or in-place immovable construction
yet. `Borrow(T)`, provider selection, device locations, and address spaces
remain design contracts, not implemented public APIs.

Keep these dimensions independent:

| Dimension | Meaning | Examples |
| --- | --- | --- |
| Value type | Meaning and operations of a value | `Foo`, `int` |
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
and alignment must be derived for the target representation used at the
requested memory location, with multiplication and rounding overflow rejected
before calling the provider. Host `sizeof(T)` must not be reused for another
target unless the language has established that their representations match.
Restricting early device buffers to explicitly portable scalar element types is
preferable to assuming every host type is device-compatible.

`AllocationLayout` is a clearer prospective name than `Layout`: it distinguishes
byte size and alignment from a future tensor or collection layout describing
shape, strides, or element order. Count may be retained alongside the resolved
byte layout by a typed allocation handle. Zero-sized allocation behavior remains
open.

### Allocation provider and location

The semantic allocation operation has three independent inputs: a provider, a
memory location, and an allocation layout. It is fallible and returns exclusive
ownership of uninitialized storage. The provider selects policy; the location
selects where the storage exists and which execution contexts can access it.
A provider may reject a location or layout it does not support.

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

`Allocation(T)` is the prospective low-level owning handle. It retains the
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

A `Borrow` from an allocation has a lifetime dependency on the allocation and
retains its location. Consuming the allocation invalidates all such borrows.
Safe access is rejected when the current execution context
cannot access the location.

### Reference types

`Borrow(T)` is non-owning and non-nullable. Copying it preserves access to the same
value without copying the value or acquiring ownership. Absence uses an explicit
variant rather than a null reference. Its lifetime depends on every owner and
resource needed for access. Mutation is permitted only when the borrowed access
path is mutable and the aliasing rules permit it; there is no separate `MutBorrow`
type.

When a returned or stored `Borrow` may refer to several sources, all possible
owners and resources must outlive it. A bodyless function returning `Borrow`
conservatively depends on every borrowed input. Without borrowed inputs, such a
return is a compile error. Other borrows with origins the compiler cannot prove
safe are also rejected; there are no user-written origin contracts for now.

Address space belongs on `Borrow`, not on `T`. A future spelling such as
`Borrow(T, S)` may use a static address-space parameter to distinguish generic,
global, workgroup, private, and constant access. The concrete device identity
remains runtime state owned by a host-side allocation or device resource; it
should not become a distinct value type for every device.

`Borrow(T)` grants access only to a live, initialized `T`. `Allocation` owns
the unsafe indexed operations for initializing, destroying, and obtaining a
borrow to an element whose initialized state the caller guarantees. Raw address
arithmetic and foreign-memory access are outside this host-first API; decide
their representation when those operations have a concrete use.

`Ref(T)` exclusively owns one initialized `T` in separately allocated
storage. It does not copy implicitly. Construction combines allocation and
initialization and is therefore fallible; destruction destroys `T` and
deallocates the storage. Moving the owner preserves the allocation and its
location. Explicit duplication, when `T` supports copy, creates a distinct allocation.
For an immovable `T`, a separate construction-in-final-storage operation must
initialize directly in the allocation instead of first producing a temporary;
its surface syntax depends on the language's later in-place construction design.

`SharedRef(T)` shares ownership of one initialized `T` and its control block.
Copying it increments a synchronized reference count; ending an owner decrements
it, and the final owner destroys the value and releases storage. This does not
synchronize access to `T`. It is initially available only where the provider and
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
This supports keeping one non-owning `Borrow` abstraction here, although this
language should derive mutation permission from the borrowed access path rather
than duplicating it as a type parameter.

Mojo's
[`OwnedPointer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/owned_pointer.mojo)
allocates a single-element layout, moves or copies a value into it, and on
destruction destroys the value before deallocating storage. Its interior
reference receives a lifetime tied to the owner. This is the direct model for
`Ref(T)`, but retaining the complete allocation initially is simpler than
Mojo's `ThinAllocation` plus reconstructed layout.

Mojo's
[`ArcPointer`](https://github.com/modular/modular/blob/975baa793c02665a36194c285496e133c9452068/Mojo/stdlib/std/memory/arc_pointer.mojo)
allocates one control block containing atomic strong and weak counts plus the
payload. Its atomic bookkeeping does not make payload access thread-safe. The
control-block pattern applies to `SharedRef(T)`; the `Arc` and `WeakPointer` names
and upgradeable weak semantics do not.

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
should be equivalent to the following pseudocode:

```text
fallible layout_for(
    static T: type,
    location,
    count,
    alignment = natural_for(T, location),
) AllocationLayout(T)

fallible allocate(
    static T: type,
    mut provider,
    location,
    layout: AllocationLayout(T),
) Allocation(T)

func deallocate(static T: type, deinit allocation: Allocation(T))
```

`Allocation(T)` should provide only the operations needed by its first users:

```text
allocation.layout()
allocation.location()
allocation.unsafe_initialize(index, value)
allocation.unsafe_destroy(index)
allocation.unsafe_borrow_initialized(index)  # caller guarantees a live T
```

The exact generic and method syntax remains open. For an immovable `T`, an
in-place initialization operation constructs directly in the element slot.
These operations do not transfer storage ownership; initialized state and
bounds are the caller's obligation at this low level.

Build the first safe owner directly on that core:

```text
fallible make_ref(
    static T: type,
    var value: T,
    mut provider,
    location,
) Ref(T)

func borrow(static T: type, owner: Ref(T)) Borrow(T)
func value(static T: type, deinit owner: Ref(T)) T

const borrowed = borrow(T, owner)
const extracted = value(T, owner^)
```

`value` consumes the owner because its parameter is `deinit` and the call passes
`owner^`; its name does not need an `into_` prefix to restate that transfer.
`get_value` would not distinguish borrowing, copying, and transfer.

`Ref(T)` uses a one-element target-aware layout, initializes exactly once,
and makes destruction plus deallocation automatic. A host convenience
constructor may default the provider and location, but the low-level API should
not. An additional in-place form is required for immovable `T`; do not force it
through this value-taking convenience.

For collections, keep `Allocation(T)` plus an initialized count and capacity in
the collection. Do not add a thin allocation handle until retaining layout and
location is shown to be a material cost.

Place public declarations under `std.memory`. Re-export `Ref`, `make_ref`, and `Borrow`
through `std.prelude`; require an explicit `std.memory` import for low-level
allocation and layout APIs. Compiler support for storage and lifetime checks
need not be expressible as ordinary library code.

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
produces a `Borrow(T, global)` or view whose device representation is validated for
that target; host code cannot safely dereference it. Workgroup and private
storage remain kernel declarations rather than calls to this API.

### Decisions still required

- The integer type used for byte sizes, counts, and overflow reporting.
- Whether `AllocationLayout` stores resolved bytes only or also typed count.
- Zero-sized allocation identity and deallocation behavior.
- How target-specific representation compatibility is declared.
- Static spelling for address spaces on `Borrow`.
- Whether device transfers are initially synchronous or introduce an explicit
  completion resource.
- Which locations support `SharedRef` control blocks and atomic reference
  counting.
