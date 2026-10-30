# Chimera

**An ergonomic systems language.**

Chimera brings native code and checked ownership to a small, expressive syntax.
Describe optional values and errors with variants, bind their alternatives
explicitly, and run ordinary functions at compile time.

Flow typing is implemented and Safe verification passes; performance acceptance remains.
See the [status and remaining work](docs/FLOW_TYPING_HANDOFF.md).

## A first look

```chimera
func double(value: int) int
  return value * 2

const answer = double(21)
exit(answer)
```

`func` defines a function. `value: int` is an integer parameter, and the `int`
after the parentheses is the return type. Indentation groups the function body;
`return` supplies its result.

`const` gives a value a name that cannot be reassigned. Code outside functions
runs when the program starts, so there is no required `main` function. `exit`
ends the program with an exit code: this program exits with `42`.

## Values with alternatives

Sometimes a value has more than one possible type. A setting, for example, can
hold an integer or be absent:

```chimera
const limit: int | none = 42

if limit is int
  exit(limit)
else
  exit(64)
```

`int | none` is a **variant**: here, either an integer or the value `none`.
Assign either directly; there is no wrapper to construct.

`limit is int` tests the active alternative. Inside that branch, reads of
`limit` have type `int`; otherwise, `else` runs. An annotation declares a type
and never filters alternatives.
Change `42` to `none` and the program uses the default exit code of `64`.

Variants are not limited to optional values. Combine types with `|` to describe
the alternatives your program needs, including your own structs.

## Explicit results

Functions return ordinary values. An operation that may have no result can
return an optional variant:

```chimera
func divide(numerator: int, denominator: int) int | none
  if denominator == 0 -> return none
  return numerator / denominator

const quotient = divide(84, 2)
if quotient is int
  exit(quotient)
else
  exit(1)
```

Try `divide(84, 0)` to take the second branch. A negative guard also refines
later reads when its failure branch exits:

```chimera
const quotient = divide(84, 2)
if not (quotient is int) -> panic "division by zero"
print(quotient)
```

The declaration stores `int | none`; the successful branch reads its `int`
payload. Assignment still accepts the declared type. `is` returns a normal
Boolean and introduces no names. Type patterns in `match` refine the matched
place in the same way. Use `T | Error` for informative error alternatives.
Comparisons and `and`, `or`, and `not` produce `bool`; optionals have no truthiness.

Allocation APIs also return explicit optionals:

```chimera
var numbers = List(int).new(4)
if not (numbers is List(int)) -> panic "allocation refused"
if not (numbers.append(10) is unit) -> panic "allocation refused"
if not (numbers.append(20) is unit) -> panic "allocation refused"
print(numbers[0])
```

Normal top-level completion cleans up and exits with status `0`. Scalar indexing
checks bounds and panics; `get` returns an optional reference for explicit handling.

## Compile-time code is still code

```chimera
func square(value: int) int
  return value * value

static capacity = square(8)
const area = square(7)
```

`static` asks the compiler to evaluate `square(8)` while building the program.
`capacity` is already `64` before the program runs. The `const` binding computes
`area` as part of the program and does not allow reassignment.

The same function works in both settings, without a separate compile-time
version. Types can be built by compile-time functions too.

Collection construction can expand a static shape while evaluating its elements
at runtime:

```chimera
const evens = [i * 2 static for i in 0..4]
const combined = [0, ..evens, 8]
const positives = [x for x in evens if x > 0]
```

`evens` and `combined` are fixed-size Arrays. The runtime filter makes `positives`
a List. `List(int).collect([x for x in evens if x > 0])` instead returns
`List(int) | none`, allowing allocation refusal to be handled explicitly.

Ranges use `..` for an exclusive end and `..=` for an inclusive end. Prefix `^n`
counts back from the collection's initialized length:

```chimera
const values = [10, 20, 30, 40]
const last = values[^1]
const tail = values[^2..]
const middle = values[1..=^2]
const prefix = values[..^1]
```

`^0` is the past-end boundary, valid for exclusive slices but not element access.
Invalid distances return `none` from checked APIs and panic when indexing;
they never wrap or clamp. Postfix `value^` still transfers ownership.

## Make change visible

```chimera
func increment(mut value: int)
  value += 1

var count = 0
increment(count)
```

`var` makes a binding mutable. `mut` lets a function change the caller's value;
ordinary parameters are read-only. Here, `count` becomes `1`.

Omitting the return type means the function returns `unit`, a type with a single
value, also written `()`. `value += 1` adds one to the existing value.

Chimera also tracks which code owns a resource and how long references to it can
be used. Owned resources are cleaned up automatically.

A `ref` binding aliases existing storage and inherits its permission:

```chimera
var scores = [20, 21]
const result = scores.get(1)
if result is int
  ref item = result
  item += 1
```

Array, List, Span, and BytesView indexing returns a borrowed element. Binding the result
with `const` or `var` copies it; binding with `ref` aliases it. Functions return
borrowed places with `ref T`. To store an explicit reference handle, use
`Ref.from(place)` and access its `.value` field. `Ref(T)` owns the handle;
`Box(T)` owns the referent. Readonly access cannot be upgraded by copying a
handle into a mutable binding.

Array and List `span()` return a `Span(T)` with the receiver's access permission;
`as_imm()` attenuates it. BytesView always exposes readonly bytes. Constructing or
slicing a view returns a new descriptor value, not a reference to that descriptor.

## Try it

With **Zig 0.17** installed, run a `.chi` file from the repository root:

```sh
zig build run -- program.chi
```

The compiler produces a native executable, runs it, and reports its exit code.
The current target is **Linux x86-64**.

Chimera is experimental. These examples work today, but the language is still
evolving and the standard library is small. UTF-8 strings and views, byte I/O,
Arrays, Lists, borrowed spans, iteration, and comprehensions work today.
More collection types and language features remain ahead. The [roadmap](ROADMAP.md) records upcoming work
and priorities.

## Go deeper

- [Compiler guide](docs/COMPILER.md): running, debugging, and testing.
- [Benchmarks](benchmarks/README.md): measurement protocols and commit history.
- [Language specification](syntax&semantics.txt): detailed rules and examples,
  including planned features.
- [Core calculus](calculus/README.md): a descriptive semantic model and a verified
  executable refinement core.
- [Compiler architecture](ARCHITECTURE.md): how the implementation fits together.
- [Query flow](PROGRAM_FLOW.md): demand, recomputation, and result lifetimes.
