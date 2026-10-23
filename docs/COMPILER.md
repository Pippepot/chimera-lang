# Chimera Compiler

An experimental language compiler written in Zig 0.17, targeting Linux x86-64. The root pipeline uses incremental queries to analyze functions, emit relocatable machine code, and link an ELF executable.

For an introduction to the language, start with the [Chimera README](../README.md).
All commands below run from the repository root.

Install Zig 0.17 and make `zig` available on `PATH`.

Comparisons and logical operators use success and failure uniformly. Store an outcome with `bool(value < limit)` and query stored data with `enabled?`. A parameter such as `value: int | none` eagerly receives a successful integer or `none` when argument preparation fails; `if const found = value as int` extracts the payload. The same rule applies to expected variants containing `none` at typed bindings, assignments, field initialization, and returns. Ownership modes and the function's declared fallibility retain their ordinary meanings. See [syntax&semantics.txt](../syntax&semantics.txt) for argument order, ownership, and failure-boundary rules.

## Run

```sh
zig build run -- --help
zig build run -- program.chi
zig build run -- --debug=ast,ssa,asm,timing program.chi
zig build run -- --workers=2 program.chi
zig build run -- --disk-cache program.chi
```

`--debug=timing` prints one row per compiler stage, in milliseconds. `wall ms`
is elapsed time; `thread ms` sums exclusive query time across all workers, so it
exceeds wall time when workers run in parallel. Stage `%` and bars are shares of
`compile`, the sum of compiler stages; `run program` and `total` follow it and
take no share. Stages with more than one kind of query work expand it, sorted
by time: parsing, declarations, signatures, body analysis, type facts, compile-time
evaluation, codegen, and other queries. Body analysis expands into expression
construction, typing/SSA, lifetime analysis/cleanup, IR finalization, and body
setup. Work `%` is a share of the stage's thread time, and each work row ends
with `count × average`. Nested queries are charged to their own categories;
group rows sum their children. Counter-update time is excluded from parent
categories. Query/function counts exclude memo hits; phase counts are
invocations. `dependency wait` counts requests for dependencies that were not
already complete and the time spent blocked on them; it is listed last and
excluded from thread time and shares.
Thread time is elapsed time on each worker, not CPU time. Collection is disabled
without the flag and adds measurement overhead when enabled. Cache stages appear
only when those operations occur.

The build generates and embeds precompiled concrete std functions and their
reachable specializations. Fresh projects index that bundle automatically, without
`--disk-cache` or adjacent std files. Generic instantiations that are absent from
the bundle compile normally. Artifact IDs are translated into each project
database, and dependency and representation checks retain normal invalidation.
Bodies, native functions, and required intern values decode only when requested.
AST, SSA, and assembly debug views bypass the bundle; `--debug=timing` reports
body/function counts loaded on demand and an `index precompiled std` stage.

`zig build run` defaults to `debug`, which favors fast compiler builds and keeps
runtime safety checks, and enables incremental compilation of the compiler.
Use it for everyday edits. Zig caches the compiler binary,
so changing only `.chi` files does not rebuild the Zig compiler sources. Add
`--summary all` before `--` to see compilation time and cache hits.

To rebuild and rerun when Zig sources change, use
`zig build run --watch -- program.chi`. Stop watching with Ctrl+C.

`-Doptimize=safe` uses release mode with runtime safety checks; it is useful for
broad test runs. `-Doptimize=fast` disables runtime safety checks. Keep the same mode
between runs to reuse its cache. These modes control the Zig-built compiler,
not optimization of the generated Chimera program.

`-Doptimize=fast` builds the compiler, benchmarks, and tests with LLVM and its
optimizations. Every other mode, including the default `debug`, uses Zig's
self-hosted backend, so everyday and test builds stay fast. There is no separate
backend option. For example:

```sh
zig build run -Doptimize=fast -- --debug=timing example.chi
```

The `-fllvm` and `-fno-llvm` flags belong to direct commands such as
`zig build-exe`; `zig build` derives the backend from the optimization mode.

`-h` and `--help` print usage and exit successfully when given before the source
path. Options after the source path are passed to the generated program instead.

Explicit overload declarations use `pub overload name(first, second)`, including
operator names such as `pub overload [](get, slice)`. Alternatives are separately
named ordinary or generic functions. Calls select one signature; function-type
annotations select callable values. See [syntax&semantics.txt](../syntax&semantics.txt)
for the selection rules.

The CLI loads the entry directory tree except its root `std/` directory, which
is reserved for embedded standard-library modules. It shares declarations
within each module, compiles the designated entry file, writes `./prog`, runs
it, and reports its exit code. Imports are file-scoped; qualified and selective
names work in types, values, calls, and compile-time expressions. The embedded `std/prelude.chi`
exports are in every user file's unqualified scope by default; compiler-owned
standard-library files do not implicitly import the prelude. An explicit
`import std.prelude.{}` disables the defaults for a user file. Only the
designated file's top-level statements execute. Extra arguments after the
source path are passed to the generated program.

Fixed-count collection literals default to inline `Array(T, N)` or construct a known expected
target through its consuming converter. `List(T)` is a prelude export; implicit
List allocation failure terminates with status 134. `List(T).from([elements])`
is the explicitly fallible alternative. Ordinary element failure cleans partial
construction and releases List storage. Box, List, Ref, Span, and text views execute at
compile time through their ordinary declarations. Evaluation-local storage can
be passed between nested calls but cannot escape into published values, static
arguments, or runtime storage; copied or extracted ordinary data can leave evaluation.

Collection literals support Array spreading (`[1, ..values, 5]`) and
comprehensions (`[x * 2 for x in values if x > 0]`). Static clauses use
`[f(i) static for i in 0..N static if condition(i)]`: shape and static filtering
execute during compilation, while element expressions retain their construction
phase. Static expansion and Array spreads default to fixed Arrays. Runtime
clauses and other iterable spreads default to Lists; an expected Array requires
a static count. Parenthesize an open range used as an element: `[(..limit)]`.
`List(T).collect?([elements or comprehensions])` makes allocation failure
recoverable for the deferred construction. Implicit List construction retains
its panic policy. A known static upper bound supports fresh immovable elements;
unbounded growth requires movable, automatically droppable elements.

`List(T).new`, `reserve`, and `append` provide fallible dynamic growth, including
reference-containing elements. `remove?(index)` returns the owned element and
shifts the suffix without allocation; bounds failure preserves the List.
`for item in values^` yields owned elements in order and cleans up on early exit;
ordinary iteration borrows. Growth, removal, and consuming iteration require
directly movable, automatically droppable elements. Consuming iteration excludes
owned End alternatives, which signal exhaustion.
Array and List expose `span()` over their initialized elements.
Array, List, and Span expose checked `slice?(bounds)`, for example
`values.slice?(1..3)`, `values.slice?(..3)`, `values.slice?(2..)`, or
`values.slice?(..)`. Bounds are reusable `Range` values with two `int | none`
endpoint fields whose presence can vary at runtime. Equal exclusive endpoints
are empty, reversed and out-of-bounds slices fail, and inclusive ends must name
elements.
The same bounds work in brackets: `values[1..3]`, `values[..3]`,
`values[2..]`, and `values[..]`. Explicit standard-library index overloads select
the integer getter or slicing function; no range-specific compiler dispatch is
involved. Positions relative to the end use explicit length arithmetic:
`values[values.len() - 1]`, `values[values.len() - n..]`, and
`values[..values.len() - n]`. `..` excludes its upper endpoint and `..^` includes
it. Standard integer indexing rejects negative indices. There is no dedicated
from-end syntax, bound type, or factory, public start/size slicing alternative,
or bulk range assignment.
`Span(T)` provides borrowed `get`/index access with permission
captured from the receiver; owned bindings copy elements, and `as_imm()` attenuates
permission. Copies and mutable bindings cannot upgrade readonly backing. Spans own no storage and
cannot escape local backing or survive owner transfer. Readonly spans do not
freeze their owners; conflicting writes invalidate content-dependent views.

`for item in source` iterates ranges, Array/List/Span, and ordinary custom
cursors. A bare item owns an owned result or aliases a borrowed result readonly;
`for const item` and `for var item` explicitly own/copy, while `for ref item`
aliases an available item place with its permission. An optional `iter` factory
supplies a cursor; otherwise named cursor state resumes in place. Cursors expose
`next`, returning an owned or borrowed item in a variant with `End`. Only `End`
means exhaustion; declared failure propagates before item matching. The compiler
polls once per step, including `_` bindings, and cleans up the acquired item.
An alias into an owned poll payload cannot outlive its carrier. Ranges use `a..b` or
`a..^b`, with ordinary `reversed()` and fallible `step_by?(positive_factor)`
methods. Inclusive endpoints and composed steps terminate without int overflow.
Only fully bounded integer ranges iterate. Iteration and reversal panic when
either endpoint is omitted; `step_by` fails. Stepping and reversal return reusable
`RangeSequence` traversal values, which cannot be passed as contiguous slice bounds.

UTF-8 literals default to the prelude `String`. Literal-backed strings allocate
nothing; mutation grows unique owned storage, and `clone` is explicitly fallible.
`StringView` and `BytesView` are read-only views with byte counts; BytesView wraps
`Span(byte)` with readonly backing, while StringView additionally guarantees UTF-8.
BytesView `get`/index results are readonly `ref byte`; owned bindings copy the byte.
`byte_int` is the
named widening operation. `BytesView.validate_utf8` validates arbitrary byte
input, and text views use the same range-based slicing API, with StringView
additionally checking codepoint boundaries. String-to-view converters
borrow their source. A literal used as a runtime value materializes as the prelude
`StaticString`, a copyable view of permanent bytes; literal views and literal-backed
Strings refer to those bytes, and one ordinary converter instance per target serves
every literal.
`String` and `StringView` support `==` and `<>` with exact byte equality,
including embedded NUL bytes and either order of owned strings, views, and
literals. `ref item = items[index]` aliases a checked borrowed element with the
receiver's permission; `const item = items[index]` copies it. Box.borrow and
collection get/index access return ref T. Box.take consumes its owner and extracts
the value; raw Allocation methods match the allocate/deallocate and unsafe
initialize/borrow/take/destroy free functions. Explicit handles use Ref.from(place)
and expose a reference field, value. Ref(T) owns only its handle; Box(T) owns T.
Readonly access restricts owned fields; a reference field preserves its captured
authority even in a const carrier. Copying a readonly referent capture into a var
cannot upgrade it. Owned storage views retain their readonly-backing rules.
`if ref part = value as Part` borrows a variant payload without
copying. Borrowed function results are declared with ref T, including in callable
types. `ref` and `mut` parameters preserve caller storage identity; `mut` requires
writable access. Owned getters remain owned and cannot initialize a ref binding.
Type annotations distinguish `ref T | End`, an owned variant with a reference
alternative, from `ref (T | End)`, a borrow of an existing whole variant. Matching
uses logical type; reference alternatives retain their own captured authority
and origins. Explicitly typed tuples such as `(ref A, B)` use positional `.0`
and `.1` access and ordinary elementwise ownership. Tuple literals infer their
structural types without annotations; `(x,)` is a singleton and `(x)` groups x.
Nested `(x, y)` and `[x, y]` binding patterns support tuples and Array/List/Span
in declarations, conditional bindings, loops, and comprehensions, with per-element
const/var/ref modes. List/Span length mismatches follow ordinary failure flow;
Array lengths are checked during typing. Compiler lowering and standard range/span cursors
use only `next/End`; no protocol build option or legacy fallback remains.
The next result must contain an owned `std.iteration.End` alternative,
independently of caller imports or shadowing. Bare bindings preserve
the storage kinds of multiple item alternatives; owning bindings copy reference
payloads according to ordinary ownership. Fresh immovable owned payloads can
bind in their poll carrier without relocation. Source-level generic map, filter,
and mixed/nested zip cases exercise explicit static type arguments and separately
declared failure shapes; computed member specifications and one-definition exact
generic fallibility are not yet a standard-library interface. Existing type
factories select exact effects and delivery kinds from explicit static arguments;
automatic discovery and type builders are deferred proposals,
not prerequisites for iteration. For focused verification, run
`zig build test --seed=0 -Dtest-source=tests/iteration_test.zig`.
`if const item = source^ as T` consumes a variant on both paths; success owns the
payload and failure cleans the unmatched temporary. Fresh variant results extract
by ownership as well. Type arguments accept unions and callable types directly,
such as Array(int | none, 2).
Integer `%` is truncating remainder (`-7 % 3`
is `-1`), and `%=` uses the same operation. Delimited calls, arrays, struct
initializers, imports, and parameter lists accept multiline continuation layout.

`import std.math.{min, max}` provides infallible integer minimum and maximum.
The same module exports infallible `clamp(value, lower, upper)`, which restricts
an integer to the inclusive bounds using `max(min(value, upper), lower)`.
Reversed bounds return `lower`; equal bounds return that bound. All three are
ordinary library functions and also execute at compile time.

```chi
fallible output()
    var text = "hello"
    text.append?(" 🌍")
    print(text)
if output() -> exit(0)
exit(1)
```

`std.io` exports `stdin`, `stdout`, and `stderr`, plus fallible `read_bytes`,
`write_once`, `write_all`, and `write_text`. `print` is an infallible prelude
export that converts its argument to String and writes it with a newline. It
terminates with panic status 134 on allocation or output failure. String inputs
remain borrowed. Callable references need an explicit
function-type context, for example `const writer: func(imm int) unit = print`.
Reads append to `List(byte)` and expose only the initialized
prefix through `bytes()`. Short
counts are successful progress; a nonempty read returning zero indicates EOF.
Failures keep existing initialized contents and earlier I/O effects. Programs
using output ignore SIGPIPE so a broken pipe becomes ordinary write failure.
Pure literal/view operations execute at compile time, while reached I/O is
rejected. Heap-backed text mutation and cloning also execute at compile time,
subject to the same storage publication boundary.

`String(value)` formats integers and bytes in decimal, booleans as `true`/`false`,
unit as `()`, and none as `none`. StringView conversion owns a copy. Arrays,
Lists, and Spans format recursively as `[1, 2]`; text elements appear without
quotes. BytesView uses decimal byte values, including invalid UTF-8. Box/Ref use
`Box(value)`/`Ref(value)`, and ranges preserve `..`, `..^`, and omitted bounds.
Inputs and collection elements remain borrowed. Collection literals also
initialize String directly, for example `String([1, 2])`. Their element failures
propagate with ordinary partial-construction cleanup. For example,
`print([[1, 2], [3, 4]])` writes `[[1, 2], [3, 4]]` followed by a newline. A public
converter from a user type to String enables the same printing and recursive
collection support.
Variants convert when every member supports the expected type; the active member
selects the conversion at runtime. This also enables mixed collections such as
`print([10, "Hello", [1, 2, 3]])`, which writes `[10, Hello, [1, 2, 3]]`.
Float support remains unimplemented.

`where` clauses use ordinary compile-time conditions. Callable membership uses
`is`, for example `where T.copy is func(imm T) T`. Conditions cannot capture
runtime parameters. The colon requirement syntax is not supported, and
converters never chain.

`T.U` exposes a declared converter as a callable, with U resolved as a type name
in the surrounding scope. Ordinary members take precedence. For example,
`where T.String is func(imm T) String` checks a declared text converter without
executing it. Use `T is String or T.String is func(imm T) String` to accept identity
too. Lookup preserves actual converter signatures; it does not synthesize
identity or variant adapters. Generic library bodies validate composed conversions
at their ordinary uses.

The CLI uses two query workers by default on machines with at least two CPUs;
`--workers=N` selects 0 through 64 workers, where 0 runs every query on the
calling thread. `--disk-cache` caches successful
builds in `.chi-cache/` beside the entry source. Without it, the CLI does not
read or write the disk cache. A whole-program cache hit skips analysis
and linking; on a changed program, unchanged functions can reuse typed bodies
and machine code.
In-memory queries and worker scheduling operate normally in either mode.
The key includes the complete contents and paths of every loaded source, the
module directory list, and the linked compiler build ID (or the running binary
digest when no build ID is available). The
compiler validates cached bytes and query dependencies before use and rebuilds
on damage or relevant input changes. AST, SSA, and assembly debug views always
run the normal queries.
Concurrent compiler processes can share the cache and working directory; each
runs its own executable while `./prog` is replaced atomically.

Top-level code is the implicitly fallible entry point; a function named `main` is ordinary.
Successful fallthrough cleans up and exits the generated program with status 0;
unhandled ordinary failure cleans up and exits it with status 1. Local handlers
retain precedence, and ordinary functions retain their declared fallibility.
For example, top-level code can use `var items = List(int).new?(4)`,
`items.append?(42)`, and `print(items[0])` without an enclosing function or guards.
Compile-time consumers still require successful evaluation.
The CLI itself exits with 0 after a normal program exit, or 1 on invalid arguments, source-read failure, source rejection, compiler failure, or abnormal program termination. It reports the program's exit status or termination signal separately from compiler failures. A compile-time `exit(code)` is compiler control instead: it produces no executable and becomes the CLI's own process status.

`panic` and `panic "message"` terminate with status 134 after reporting the
message and source call trace to stderr. Bare panic prints just `panic`.
The message accepts StringView and
ordinary string conversions. Panic bypasses fallible handlers and does not
unwind live owners. Compile-time panic reports a source error and call trace
instead of exiting the compiler with status 134. Native traces retain read-only
metadata and add no instructions to successful calls; traces stop at entry or
an unknown call site, with a maximum of 1024 frames.

Function names include their static arguments, for example `foo(1)` or
`Item(int).stop(7)`. Native traces, compile-time call notes, function diagnostic
contexts, and SSA/assembly labels use the same names and render static types
and values rather than interner IDs.

Run the focused panic suite with
`zig build test --seed=0 -Dtest-source=tests/panic_test.zig`.

## Documentation

| Document | Owns |
| --- | --- |
| [syntax&semantics.txt](../syntax&semantics.txt) | Language rules and examples; authoritative but incomplete |
| [ROADMAP.md](../ROADMAP.md) | Upcoming work, gaps, and priorities |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Compiler boundaries, ownership, representation contracts, and storage design |
| [PROGRAM_FLOW.md](../PROGRAM_FLOW.md) | Current query flow, invalidation, and result lifetimes |
| [AGENTS.md](../AGENTS.md) | Contribution and review rules |

Specification examples describe the target, not a promise of compiler support. Parser support alone does not establish semantics. Resolve missing language decisions in `syntax&semantics.txt` before implementing them; neither legacy behavior nor an old test overrides it.

## Layout

`src/frontend/` owns parsing, semantic analysis, typing, compile-time interpretation, and lifetime planning. `src/backend/` owns code generation and disassembly. `src/query/` contains the compiler-independent query engine and its codec. Shared types, compiler query definitions, module registration, caching, diagnostics, and the CLI remain directly under `src/`; `std/` contains the embedded standard library.

Standalone integration and backend suites live in `tests/`. Local tests that need private declarations remain beside their implementations. The project-root `test_sources.zig` collects inline stage tests and exposes one shared source module to the out-of-tree suites; Zig cannot import outside a module's root directory.

Reuse `test_sources.SourceFixture` for source registration, exit checks,
diagnostics, and native/interpreter parity, and `renderTemplate` for parameterized
fixtures. Keep cache restoration and memory-limited process setup suite-local.

Compile-time interpreter tests live in the standalone suite
`tests/comptime_interpreter_test.zig`, using the shared `test_sources` module;
`src/frontend/comptime_interpreter.zig` has no top-level tests.

## Verify

Routine suite (exhaustive allocation-failure sweeps are disabled):

```sh
zig build test --seed=0 -Doptimize=safe -j1
```

Full backup verification, including exhaustive allocation-failure sweeps:

```sh
zig build test --seed=0 -Doptimize=safe -Dallocation-failures=true -j1
```

Allocation-failure sweeps are opt-in backup checks, not routine agent checks.
Sweep-only tests report as skipped by default. Tests that combine ordinary
behavior assertions with a sweep still run their non-failing case once.
Ordinary OOM behavior tests and leak detection remain enabled in routine runs.
Use `-Dallocation-failures=true` only when explicitly requesting backup verification;
it also works with the focused source and name filters below.

Focused checks:

```sh
zig build test --seed=0 -Dtest-source=test_sources.zig -Dtest-filter=tokenizer
zig build test --seed=0 -Dtest-source=tests/modules_test.zig -Dtest-filter="name fragment"
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/query_disk_cache_test.zig -Dtest-filter="field visibility" --summary all
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/array_test.zig --summary all
zig build test --seed=0 -Dtest-source=tests/iteration_test.zig --summary all
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/converter_test.zig --summary all
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/comptime_interpreter_test.zig --summary all
```

Run the focused collection-construction suite with
`zig build test --seed=0 -Dtest-source=tests/collection_test.zig`.

Run the structural tuple and destructuring suite with
`zig build test --seed=0 -Dtest-source=tests/tuple_test.zig`.

Run the List mutation and consuming traversal suite with
`zig build test --seed=0 -Dtest-source=tests/list_test.zig`.

Run the focused overload suite with
`zig build test --seed=0 -Dtest-source=tests/overload_test.zig`.

Run the match syntax, coverage, capture, ownership, and native/compile-time parity
suite with `zig build test --seed=0 -Dtest-source=tests/match_test.zig`.

These entrypoints supply required module imports. Both suite modes run inline
tests once through `test_sources.zig` and seventeen standalone suites (eighteen default
roots total): `tests/array_test.zig`, `tests/collection_test.zig`, `tests/converter_test.zig`, `tests/codegen_test.zig`,
`tests/comptime_interpreter_test.zig`, `tests/modules_test.zig`, `tests/overload_test.zig`,
`tests/query_disk_cache_test.zig`, `tests/query_artifact_test.zig`, `tests/query_test.zig`, `tests/reference_test.zig`,
`tests/text_test.zig`, `tests/panic_test.zig`, `tests/iteration_test.zig`,
`tests/list_test.zig`, `tests/tuple_test.zig`, and `tests/match_test.zig`.
Each runs in its own binary's directory.
Run portable artifact remapping and std reuse checks with
`zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/query_artifact_test.zig`.

Private disk-cache tests remain inline in
`src/query_disk_cache.zig`; its snapshot integration suite lives in
`tests/query_disk_cache_test.zig`.

Allocation failure suites share a `SafeAllocator` backing with in-place resize
and remap disabled. This keeps failure indices repeatable and checks allocation
failure cleanup for every growth operation.

A fixed seed enables caching successful runs; Zig 0.17 defaults to a random seed.
Keep caches and options stable; `--summary all` shows cache hits. Direct `zig test`
caches compilation but reruns tests. The `safe` mode speeds up allocation checks,
with a slower first compile.

For quick test iteration, omit `-Doptimize=safe` and select the affected
suite with `-Dtest-source`. The full suite builds eighteen separate test binaries;
its compilation cost is different from building the CLI once.

Use focused checks during edits; run the routine suite once for changes spanning
stages or shared representations. Run the exhaustive backup checks only when
explicitly requested. Documentation-only edits need no compiler tests.

Check modified Zig files with `zig fmt --check <files>` and run `git diff --check`.
Keep temporary verification files outside the repository.

## Benchmark

The cold-compilation performance gates build separately in `fast` and `debug`:

```sh
zig build test-prelude-performance --seed=0
zig build test-prelude-debug-performance --seed=0
```

Debug budgets are consistently five times the Fast budgets. Prelude loading has
a 1 ms median budget in `fast` and a 5 ms median budget in `debug`. Every measured
compilation sample must finish within 8 ms in `fast` or 40 ms in `debug` for
scalar print and the mixed-array example. These are acceptance targets;
the gates report all cases before failing when a target is exceeded. Debug keeps
allocator diagnostics and runtime safety checks. Each case uses one unmeasured
warm-up and nine fresh one-worker databases, with no disk cache or query-result
reuse between samples. The compiled workloads are `const i = 10` followed by
`print(i)`, and the four-line mixed-array example embedded in the benchmark.
CSV output includes median, minimum, maximum, and budget in nanoseconds.
The gate checks at compile time that its driver and imported compiler use the
same optimization mode. The `fast` gate therefore uses LLVM and the `debug` gate
the self-hosted backend. Backend and build mode changes are separate measurements,
not replacements for the Debug target.
The timer covers database creation, source registration, analysis, native compilation,
and linking. Database teardown, CLI file discovery and output writes, and execution
of the generated program are excluded, so the actual CLI requires separate timing
verification. The prelude case alone does not exercise reachable function analysis.

The std precompilation comparison uses the same compiler and source fixtures
with bundle loading disabled (`source`) and enabled (`bundled`):

```sh
zig build std-benchmark --seed=0 -Doptimize=fast -j1
zig build std-benchmark --seed=0 -j1
```

Each case warms up both paths, then measures 21 alternating pairs of fresh
zero-worker databases without disk caching. `compile` includes database creation,
source registration, bundle loading where enabled, analysis, code generation, and
linking; `lifecycle` also includes teardown. `load` isolates bundle loading.
File discovery, output writes, and execution are excluded. Body-typing and codegen
counts come from separate instrumented warm-ups, outside the timed samples.

The recorded Zig 0.17 measurements use an AMD Ryzen 7 5800H, pinned to CPU 4
with `taskset -c 4`, without concurrent compiler builds or tests. The
[Fast results](../benchmarks/std_precompile.csv) use LLVM; the
[Debug results](../benchmarks/std_precompile_debug.csv) use the self-hosted backend.
Median compilation times, including bundle loading, are:

| Program | Fast source | Fast bundled | Debug source | Debug bundled |
| --- | ---: | ---: | ---: | ---: |
| Exit | 0.644 ms | 1.575 ms | 3.505 ms | 9.123 ms |
| Math clamp | 0.888 ms | 1.875 ms | 4.279 ms | 9.352 ms |
| Scalar print | 3.047 ms | 1.884 ms | 19.582 ms | 13.245 ms |
| List, text, range, and math | 5.419 ms | 3.728 ms | 35.768 ms | 24.660 ms |

Printing and the collection workload improve by 38% and 31% in Fast, and 32%
and 31% in Debug. Eager bundle loading costs roughly 0.8–1.1 ms in Fast and
5.8–5.9 ms in Debug, making the tiny exit/math cases slower. Native compilation
counts fall from 41 to 2 for printing and from 75 to 21 for the collection
workload; new generic specializations still compile normally.

Converter discovery and matching have a separate benchmark:

```sh
zig build conversion-benchmark --seed=0 -Doptimize=fast
```

It reports median/minimum/maximum nanoseconds over nine fresh one-worker
in-memory databases after one unmeasured warm-up. Cases cover 1,024 unrelated
declarations, 128/512 unrelated converters, and 128 distinct source/target pairs.
`first` includes cold index construction and the first match. `consumers` measures
256 additional distinct consuming queries, so enclosing-query memoization cannot
hide repeated resolution. `total` includes database creation, source registration,
type discovery, and those lookups; it excludes teardown and does not compile a
program. The prelude gates above measure full compilation separately. Run timed
benchmarks without concurrent builds or other benchmarks. The checked-in
`benchmarks/conversion_comparison.csv` records the before/after measurements.
`--debug=timing` includes a conversion-matching query count and elapsed-time row.

The recorded comparison uses Zig 0.17, the native compiler backend, and an AMD
Ryzen 9 3900X. With 512 unrelated converters, the first lookup improves from
13.233 ms to 4.565 ms and the 256 additional consumers from 159.265 ms to
0.809 ms. Across 128 distinct type pairs, those consumers improve from
41.290 ms to 5.646 ms. A tiny first lookup grows from 30 to 56 microseconds;
its 256 additional consumers improve from 2.660 ms to 0.777 ms.

The small full-compilation cases remain similar in `fast`: scalar print changes
from 17.718 ms to 18.098 ms and the mixed-array example from 36.281 ms to
36.616 ms. In `debug`, they improve from 22.907/45.544 ms to 20.836/40.812 ms.
Those measurements exceeded the original 8 ms compilation budget in both modes
before and after that change.

With its LLVM backend on the same machine, `zig build test-prelude-performance --seed=0`
meets every budget: prelude loading takes 0.631 ms median, scalar print 3.176 ms,
and the mixed-array example 5.574 ms median with a 7.407 ms maximum. Before the
query-storage, scratch-recycling, and StaticString changes an LLVM build of the
same gate measured 4.066 ms and 8.077 ms (8.490 ms maximum). Before `fast` switched
to LLVM, its self-hosted build measured 35.416 ms for the example; the corresponding
`debug` example measured 39.662 ms median, while its budget is checked against
the maximum.

The compile-time execution benchmark reports analysis, execution, publication,
cached lookup, and incremental recomputation times in CSV form:

```sh
zig build benchmark --seed=0 -Doptimize=fast
```

The flow benchmark reports typing time, retained snapshot bytes, and
lifetime-table bytes for scalar and owning functions with 8, 32, 128, 256,
and 512 branches:

```sh
zig build flow-benchmark --seed=0 -Doptimize=fast
```

Each row is the median of five fresh one-worker databases. Signature resolution
and unresolved semantic-body construction happen before the timed typing call;
published-body teardown and code generation are excluded. Typing includes
workspace compaction and release. Allocation statistics come from
a separate sixth database, so footprint-accounting work is excluded from the
timing samples. Typing includes ownership lowering and lifetime planning.
Owning fixtures keep all generations live to exercise branch and generation scaling.

Snapshot measurements count saved state handles, pointer-table roots and their
page pointers for values, local and field availability, initializer state, and
definite consumption completion. Each unique root and 16-slot page is counted
once, including its writable flag and padding. Default pages allocate nothing;
all components retain their independent logical lengths. Lifetime measurements
count the availability/demand bitsets and populated sparse cleanup-operand entries,
not hash-table capacity, dirty-block flags, or other scratch. Neither
measurement is process RSS or an allocation-traffic counter. Persistent page
sharing lets joins skip unchanged pages; all versions are reclaimed with the
body workspace. Cleanup operands are resolved on demand rather than stored in
dense block-by-generation matrices.

The body-workspace refactor's [ablation data](../benchmarks/flow_ablation.csv)
was measured on an AMD Ryzen 9 3900X with Zig 0.17's native backend,
one worker, and three alternating process trials per variant. Each trial uses the sample counts above; the CSV records the median
of trial medians and their range. `baseline` is the pending source state before
the refactor; `persistent_flat` measures flow with replaced snapshot storage;
`workspace` adds the
shared analysis workspace and is the retained implementation. `unified_calls`
also removes scalar call preparation; that experiment was rejected because its
flow workloads regressed against `workspace`. These are compiler timings and
retained snapshot footprints, with unchanged benchmark sources and lifetime
tables. Existing cold-compilation budgets remain unmet on this machine in both
the baseline and the retained implementation.

The [scalar-flow regression comparison](../benchmarks/flow_regression.csv)
uses Zig 0.17 with LLVM (`-Doptimize=fast`) on an AMD Ryzen 7 5800H, pinned to
CPU 4. Each variant has fifteen alternating process trials with the unchanged
five-sample flow fixtures. `baseline` is commit `4556095`, `prior` is commit
`7cb3afd`, and `flow_reads` adds const flow-value reads and shared-availability
page skipping to `prior`. Rows record the median and range of trial medians;
all graph and retained-memory counters are unchanged.

That comparison left the roadmap's performance gate open: scalar/128 was
11.8% slower than `baseline`, despite scalar/256 improving 6.3% and scalar/512
improving 16.0%. Absolute times and percentages vary between measurement rounds;
use matched trials rather than comparing absolute times from different rounds.

### Scalar/128 allocation-order diagnosis

The causal change is in parser preparation, not a larger typed graph.
`4556095` initializes the tokenizer before allocating its token buffer;
`7cb3afd` moves token-buffer allocation first. The intervening tokenizer
allocation changes arena growth and reuse. Parsing is outside the typing
timer, but it determines which scratch pages have already been touched when
typing starts. Equal retained footprints do not imply equal demand-page costs.

[Matched instrumentation](../benchmarks/scalar_allocation_order.csv) records
fifteen rotating process trials per variant on the same CPU and backend as
above. Each trial retains the original scalar/8 and scalar/32 prefix, five
timed databases, and a separate sixth footprint database. Per-sample phase
timings and Linux thread minor faults are aggregated as trial medians, then
medians across trials.

All four variants have 1,667 nullable value slots of 172 bytes each
(286,724 bytes), 1,666 unresolved expressions of 112 bytes each, and the same
4,043 recorded query-scratch allocation requests totaling 4,866,315 bytes
during typing. Their scratch capacity and used-byte totals before typing
also match. However, the resident-page counts summed over scratch chunks are
348 with tokenizer-first allocation and 189 with tokens-first allocation.
Clearing the value buffer incurs zero minor faults in the former and 70 in
the latter. Restoring only the allocation order in `7cb3afd` restores the
baseline residency and timing; reversing it in `4556095` reproduces the
residency change and slowdown.

The [uninstrumented full-matrix confirmation](../benchmarks/flow_parser_order.csv)
uses fifteen rotating process trials per variant with the unchanged benchmark,
including all scalar and owning sizes. Scalar/128 medians in that matched round:

| Variant | Typing time | Versus `4556095` |
| --- | ---: | ---: |
| `baseline` (`4556095`) | 3.023 ms | baseline |
| `prior` (`7cb3afd`) | 3.391 ms | +12.2% |
| `parser_order` (only allocation order restored) | 3.058 ms | +1.2% |
| `flow_reads` (flow-value read optimization) | 3.250 ms | +7.5% |
| `flow_reads_parser_order` (both changes) | 2.846 ms | -5.8% |

All graph and retained-memory counters match across every run.

The runtime parser now preserves tokenizer-first allocation, releasing
tokenizer scratch before parsing the resulting tokens. Ordinary OOM tests
cover cleanup when either initial allocation fails.

The [production-source verification](../benchmarks/flow_parser_application.csv)
repeats the unchanged full matrix with fifteen rotating trials per variant,
LLVM fast mode, and CPU 4 affinity. `baseline` is `4556095`; `before` and `after`
both include `924a474` and the same pending workspace changes, with `after`
adding the parser correction. The measurements and safe-suite run describe
that application snapshot, not subsequent unrelated workspace edits. Each row
summarizes five-sample trial medians:

| Scalar branches | Baseline | Before correction | After correction | Versus baseline |
| --- | ---: | ---: | ---: | ---: |
| 128 | 3.071 ms | 3.185 ms | 2.825 ms | -8.0% |
| 256 | 6.484 ms | 5.682 ms | 5.767 ms | -11.1% |
| 512 | 12.737 ms | 10.296 ms | 10.427 ms | -18.1% |

Graph and retained-memory counters match across every variant and trial.
The smaller scalar cases and owning cases show no repeatable adjacent
regression from the correction; owning medians range from 2.2% faster to
2.2% slower than baseline. Parser tests, the routine safe suite, formatting,
and whitespace checks pass. These typing-only results do not establish an
end-to-end compilation speedup.

For cold multi-file worker scaling and warm and edited disk cache reuse against
uncached runs, build an optimized compiler and run the generated benchmark fixture.
The `fast` mode strips debug symbols; the linker build ID keeps compiler identity
checks cheap:

```sh
zig build -Doptimize=fast
python3 benchmarks/parallel.py zig-out/bin/chi
python3 benchmarks/parallel.py zig-out/bin/chi --temp-dir .
```
