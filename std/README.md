# Standard library algorithms

`std.algorithms` provides adapters and algorithms for ordinary pull cursors. Call `.iter()` on a range,
Array, List, or Span to obtain a borrowed cursor; transfer a List through
`.consume_iter()` to obtain an owning cursor. Adapters own the cursors passed
to their constructors. Transfer a named noncopyable cursor with `^`.

Static arguments are explicit because cursor item types and callable result
types are not inferred. `S`, `L`, and `R` name cursor types; `A`, `B`, and `T`
name item types, including every non-`End` alternative. A `borrowed` argument
selects reference delivery (`true`) or owned delivery (`false`). Reference
permission and lifetime follow the input; these arguments grant no authority.

| Function | Result and behavior |
| --- | --- |
| `map(S, A, B, source, transform)` | `Map(S, A, B)`, lazily calls `func(imm A) B` once per item. The callback borrows its input and constructs its output. |
| `filter(S, T, borrowed, source, predicate)` | `Filter(S, T, borrowed)`, lazily returns accepted items. Rejected owned items are dropped; accepted owned items move, and borrowed items remain references. |
| `zip(L, R, A, B, left_borrowed, right_borrowed, left, right)` | `Zip(...)`, yielding tuples with independently owned or reference members. Polls left before right and returns `End` when either ends. An unmatched left item is dropped when the right ends. |
| `enumerate(S, T, borrowed, source)` | `Enumerate(S, T, borrowed)`, yielding `(int, T)` or `(int, ref T)`, starting at zero. A further item after index `2147483647` panics rather than wrapping. |
| `find(S, T, borrowed, source, predicate)` | `T \| none`, returning the first match. Copies only the matching borrowed item; moves a matching owned item. |
| `any(S, T, source, predicate)` | `bool`, stopping at the first accepted item; false for an empty cursor. |
| `all(S, T, source, predicate)` | `bool`, stopping at the first rejected item; true for an empty cursor. |

Predicates have type `func(imm T) bool`. Terminal algorithms borrow a mutable
cursor and leave it positioned after the last inspected item. Adapters poll
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

Array, List, and Span already provide stable `sorted()` methods, with optional
runtime or static comparators. They return a copied `List(T) | none` and retain
the input. `sort()` instead orders mutable storage in place, including
noncopyable movable elements. Use a comprehension and `List(T).collect` to
materialize a cursor before sorting it. Result allocation failure returns
`none`; sorting scratch allocation failure panics.

`std.math.min`, `max`, and `clamp` accept same-typed, copyable ordered values,
including every supported integer and floating-point width. The type can be
inferred from values or supplied explicitly. Comparisons preserve ordinary
operator behavior: ties select the right operand, floating-point NaNs follow
`<`/`>`, and `clamp(value, lower, upper)` is `max(min(value, upper), lower)`.
Integer specializations remain in the precompiled standard library.
As with other generic functions, storing a helper as a callable value requires
a type context, for example `const lower: func(int, int) int = std.math.min`.
