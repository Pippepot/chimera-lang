# Standard library algorithms

`std.algorithms` provides adapters and algorithms for ordinary pull cursors. Call `.iter()` on a range,
Array, List, or Span to obtain a borrowed cursor; transfer a List through
`.consume_iter()` to obtain an owning cursor. Adapters own the cursors passed
to their constructors. Transfer a named noncopyable cursor with `^`.

`S`, `L`, and `R` name cursor types; `A`, `B`, and `T`
name item types, including every non-`End` alternative. A `borrowed` argument
selects reference delivery (`true`) or owned delivery (`false`). Reference
permission and lifetime follow the input; these arguments grant no authority.
Map infers static types when the source and callback signature supply them.
Filter also offers `filter(source, predicate)`, inferring delivery from the
source's poll signature. Write closure parameter types when static inference
does not yet provide a callable context. Other adapters retain explicit delivery
arguments.

| Function | Result and behavior |
| --- | --- |
| `map(S, A, B, source, transform)` | `Map(S, A, B, F)`, retaining the concrete callback type `F` and lazily calling `func(imm A) B` once per item. The callback borrows its input and constructs its output. |
| `filter(S, T, borrowed, source, predicate)` | `Filter(S, T, borrowed, F)`, retaining the concrete callback type `F` and lazily returning accepted items. Rejected owned items are dropped; accepted owned items move, and borrowed items remain references. |
| `zip(L, R, A, B, left_borrowed, right_borrowed, left, right)` | `Zip(...)`, yielding tuples with independently owned or reference members. Polls left before right and returns `End` when either ends. An unmatched left item is dropped when the right ends. |
| `enumerate(S, T, borrowed, source)` | `Enumerate(S, T, borrowed)`, yielding `(int, T)` or `(int, ref T)`, starting at zero. A further item after index `2147483647` panics rather than wrapping. |
| `find(S, T, borrowed, source, predicate)` | `T \| none`, returning the first match. Copies only the matching borrowed item; moves a matching owned item. |
| `any(S, T, source, predicate)` | `bool`, stopping at the first accepted item; false for an empty cursor. |
| `all(S, T, source, predicate)` | `bool`, stopping at the first rejected item; true for an empty cursor. |

Predicates have type `func(imm T) bool`. Terminal algorithms borrow a mutable
cursor and their concrete callbacks, leaving the cursor positioned after the
last inspected item. Map and Filter acquire callbacks through deferred `init`
parameters, constructing them directly in their fields; a named callback copies
unless transferred with `^`. Concrete callbacks introduce no environment
allocation, and support copyable immovable captures. Adapters poll
again when their `next()` is called again; they do not add an exhaustion latch
beyond their inputs. `End` denotes exhaustion; error or optional alternatives
included in an item type remain ordinary items. Owned items must support the
moves and automatic cleanup required by the algorithm. Borrowed traversal can
inspect immovable, noncopyable items. Mapping can construct immovable outputs.

```chi
import std.algorithms.{map, any}
import std.range.{RangeIterator}

func double(value: int) int -> value * 2
func even(value: int) bool -> value % 2 == 0

var transformed = map(RangeIterator, int, int, (1..=3).iter(), double)
for value in transformed -> print(value) # 2, 4, 6

var cursor = (1..=6).iter()
print(any(RangeIterator, int, cursor, even)) # true; cursor resumes at 3
```

Existing explicit Map/Filter type applications now include the callback type.
For a named `func(imm int) int`, use `Map(S, int, int, func(imm int) int)`.
Inferred bindings keep anonymous concrete callback types without naming them.

Array, List, and Span already provide stable `sorted()` methods, with optional
runtime or static comparators. They return a copied `List(T) | AllocationError` and retain
the input. `sort()` instead orders mutable storage in place, including
noncopyable movable elements. Use a comprehension and `List(T).collect` to
materialize a cursor before sorting it. Result allocation failure returns
`AllocationError`; sorting scratch allocation failure panics.

`std.math.min`, `max`, and `clamp` accept same-typed, copyable ordered values,
including every supported integer and floating-point width. The type can be
inferred from values or supplied explicitly. Comparisons preserve ordinary
operator behavior: ties select the right operand, floating-point NaNs follow
`<`/`>`, and `clamp(value, lower, upper)` is `max(min(value, upper), lower)`.
Integer specializations remain in the precompiled standard library.
As with other generic functions, storing a helper as a callable value requires
a type context, for example `const lower: func(int, int) int = std.math.min`.

## Owning callables

Fixed `func(...)` locals, fields, and collection elements own erased handles.
Capturing lexical closures allocate an environment; copies allocate and copy its
captures, while `^` transfers only the handle. Named functions, noncapturing
closures, and bound methods erase and copy without allocation.

`std.callables.erase(Signature, init callback)` accepts a concrete initializer and
returns `Signature | std.memory.AllocationError`. Reservation refusal does not
force the initializer. Already-erased inputs must use `clone` instead.
`std.callables.clone(Signature, imm callback)` borrows an existing erased handle
and reserves before copying captures; refusal leaves the source unchanged. Its
signature argument can be inferred:

```chi
import std.callables.{erase, clone}
import std.memory.{AllocationError}

func run() int | AllocationError
    const offset = 2
    const callback = erase(func(int) int, (value) => value + offset)?
    const copied = clone(callback)?
    return copied(40)
```

Implicit erasure and ordinary copying panic on reservation failure. These
operations use the current allocator for new environments and retain that provider
for release. Collection constructors and recoverable growth return `AllocationError`. See
[CLOSURES.md](../docs/CLOSURES.md) for capture, lifetime, and deferred-syntax rules.


## Scoped allocation and logging

The prelude exposes `std.context` as `context`. `context.allocator` and
`context.logger` are independent borrowed handles. Read a handle to save a
snapshot, or replace it for a synchronous scope:

```chi
import std.memory.{Allocator, AllocationError}
import std.logging.{Logger, LogLevel, log}

with context.allocator = Allocator.from(Tracker, tracker)
    with context.logger = Logger.from(Backend, backend, LogLevel.info)
        var values = List(int).new(0)?
        _ = values.append(42)?
        _ = log(LogLevel.info, "created values")?
```

The factories borrow stable provider/backend state and check their protocols.
`with` keeps those dependencies alive, performs body cleanup under the installed
handles, and restores previous handles on return, loop exits, and error propagation.
Direct contextual assignment and references to binding storage are unavailable.

New List, Box, typed allocation, and allocating String operations select the current
allocator. Their `_with` constructors select an explicit provider. Existing storage
retains its provider for growth and release; moving it transfers that dependency.
Empty List construction retains a provider. Static-backed String values select one
on their first allocating transition. Allocation errors distinguish refusal, invalid
layout, size limits, and provider budget rejection. Infallible converters and hooks
panic on allocation refusal.

`std.logging.emit(logger, level, message)` uses a saved Logger;
`std.logging.log(level, message)` selects the current logger. Both return
`unit | AllocationError | IoError`. Disabled events skip backend dispatch while
preserving argument evaluation. Backends may store lifetime-valid owned message
copies, but cannot retain a message view. Checked service dispatch detects cycles;
`from_unchecked` permits deliberate recursion. The native root logger writes to
stderr at info or above; the evaluator root logger is off. Logging leaves `print`
and explicit stdout/stderr APIs on their ordinary destinations.
