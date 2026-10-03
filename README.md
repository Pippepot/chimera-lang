# Chimera

**An ergonomic systems language.**

Chimera brings native code and checked ownership to a small, expressive syntax.
Describe alternatives with variants, handle success and failure with `fallible`,
and run ordinary functions at compile time.

## A first look

```chi
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

```chi
const limit: int | none = 42

if const value = limit as int
  exit(value)
else
  exit(64)
```

`int | none` is a **variant**: here, either an integer or the value `none`.
Assign either directly; there is no wrapper to construct.

`limit as int` checks whether `limit` holds an integer. If it does, `if const`
names that integer `value` inside the first branch. Otherwise, `else` runs.
Change `42` to `none` and the program uses the default exit code of `64`.

Variants are not limited to optional values. Combine types with `|` to describe
the alternatives your program needs, including your own structs.

## Success and failure, built in

A missing setting is a possible value. A failed operation is different:

```chi
fallible divide(numerator: int, denominator: int) int
  denominator <> 0
  return numerator / denominator

if const quotient = divide(84, 2)
  exit(quotient)
else
  exit(1)
```

`fallible` replaces `func` for a function that can fail. On success, this function
returns an integer. On failure, it returns no value.

`<>` means "not equal." The standalone line `denominator <> 0` is a check:
if it succeeds, execution continues to `return`. If it fails, `divide` fails
immediately and skips the remaining body. It is not a Boolean result that gets
computed and ignored. In Chimera, comparisons succeed or fail.

The caller uses `if const` to name the successful result `quotient`. If the call
fails, `else` runs instead. Try `divide(84, 0)` to take the failure branch.

The same rule applies to a standalone fallible call inside a fallible function:
success continues to the next statement, while failure makes the enclosing
function fail too. Use `if` when you want to handle failure at that point.

Use the bare statement `fail` to propagate failure explicitly, including after
local cleanup. It is allowed in a `fallible` function or a deferred initializer,
not an ordinary `func`. Consuming a deferred initializer is always potentially
fallible, so its construction site must handle or propagate that failure.

## Compile-time code is still code

```chi
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

## Make change visible

```chi
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

## Try it

With **Zig 0.16** installed, run a `.chi` file from the repository root:

```sh
zig build run -- program.chi
```

The compiler produces a native executable, runs it, and reports its exit code.
The current target is **Linux x86-64**.

Chimera is experimental. These examples work today, but the language is still
evolving and the standard library is small: text, basic I/O, and general-purpose
collections are still ahead. The [roadmap](ROADMAP.md) records what works and
what comes next.

## Go deeper

- [Compiler guide](docs/COMPILER.md): running, debugging, testing, and benchmarking.
- [Language specification](syntax&semantics.txt): detailed rules and examples,
  including planned features.
- [Compiler architecture](ARCHITECTURE.md): how the implementation fits together.
