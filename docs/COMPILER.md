# Chimera Compiler

An experimental language compiler written in Zig 0.17, targeting Linux x86-64. The root pipeline uses incremental queries to analyze functions, emit relocatable machine code, and link an ELF executable.

For an introduction to the language, start with the [Chimera README](../README.md).
All commands below run from the repository root.

Install Zig 0.17 and make `zig` available on `PATH`.

## Run

```sh
zig build run -- --help
zig build run -- program.chi
zig build run -- --debug=ast,ssa,asm,timing program.chi
zig build run -- --workers=2 program.chi
zig build run -- --disk-cache program.chi
```

`zig build run` defaults to `debug`, which favors fast compiler builds and keeps
runtime safety checks, and enables incremental compilation of the compiler.
Use it for everyday edits. Zig caches the compiler binary,
so changing only `.chi` files does not rebuild the Zig compiler sources. Add
`--summary all` before `--` to see compilation time and cache hits.

To rebuild and rerun when Zig sources change, use
`zig build run --watch -- program.chi`. Stop watching with Ctrl+C.

`-Doptimize=safe` takes longer to build but runs compiler code and
allocation checks faster; it is useful for broad test runs.
`-Doptimize=fast` is for performance measurements. Keep the same mode
between runs to reuse its cache. These modes control the Zig-built compiler,
not optimization of the generated Chimera program.

`-h` and `--help` print usage and exit successfully when given before the source
path. Options after the source path are passed to the generated program instead.

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

Collection literals default to inline `Array(T, N)` or construct a known expected
target through its consuming converter. `List(T)` is a prelude export; implicit
List allocation failure terminates with status 134. `List(T).from([elements])`
is the explicitly fallible alternative. Ordinary element failure cleans partial
construction and releases List storage. Box, List, Buffer, and views execute at
compile time through their ordinary declarations. Evaluation-local storage can
be passed between nested calls but cannot escape into published values, static
arguments, or runtime storage; copied or extracted ordinary data can leave evaluation.

UTF-8 literals default to the prelude `String`. Literal-backed strings allocate
nothing; mutation grows unique owned storage, and `clone` is explicitly fallible.
`StringView` and `BytesView` are read-only views with byte counts. `byte_int` is the
named widening operation. `BytesView.validate_utf8` validates arbitrary byte
input, and text slices check codepoint boundaries. String-to-view converters
borrow their source; literal-to-view converters refer to permanent static bytes.

```chi
fallible output()
    var text = "hello"
    text.append?(" 🌍")
    print?(text)
if output() -> exit(0)
exit(1)
```

`std.io` exports `stdin`, `stdout`, `stderr`, `read_bytes`, `write_once`,
`write_all`, and `write_text`; `print` is also a prelude export. Reads append to
`Buffer(byte)` and expose only the initialized prefix through `bytes()`. Short
counts are successful progress; a nonempty read returning zero indicates EOF.
Failures keep existing initialized contents and earlier I/O effects. Programs
using output ignore SIGPIPE so a broken pipe becomes ordinary write failure.
Pure literal/view operations execute at compile time, while reached I/O is
rejected. Heap-backed text mutation and cloning also execute at compile time,
subject to the same storage publication boundary.

The CLI uses two query workers by default on machines with at least two CPUs;
`--workers=N` selects 1 through 64 workers. `--disk-cache` caches successful
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

Top-level code is the entry point; a function named `main` is ordinary. The CLI itself exits with 0 after a normal program exit, or 1 on invalid arguments, source-read failure, source rejection, compiler failure, or abnormal program termination. It reports the program's exit status or termination signal separately from compiler failures. A compile-time `exit(code)` is compiler control instead: it produces no executable and becomes the CLI's own process status.

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
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/converter_test.zig --summary all
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/comptime_interpreter_test.zig --summary all
```

These entrypoints supply required module imports. Both suite modes run inline
tests once through `test_sources.zig` and eight standalone suites (nine default
roots total): `tests/array_test.zig`, `tests/converter_test.zig`, `tests/codegen_test.zig`,
`tests/comptime_interpreter_test.zig`, `tests/modules_test.zig`,
`tests/query_disk_cache_test.zig`, `tests/query_test.zig`, and `tests/text_test.zig`.
Each runs in its own binary's directory.
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
suite with `-Dtest-source`. The full suite builds nine separate test binaries;
its compilation cost is different from building the CLI once.

Use focused checks during edits; run the routine suite once for changes spanning
stages or shared representations. Run the exhaustive backup checks only when
explicitly requested. Documentation-only edits need no compiler tests.

Check modified Zig files with `zig fmt --check <files>` and run `git diff --check`.
Keep temporary verification files outside the repository.

## Benchmark

The compile-time execution benchmark reports analysis, execution, publication,
cached lookup, and incremental recomputation times in CSV form:

```sh
zig build benchmark --seed=0 -Doptimize=fast
```

The flow benchmark reports typing time, retained snapshot bytes, and dense
lifetime-table bytes for scalar and owning functions with 8, 32, 128, 256,
and 512 branches:

```sh
zig build flow-benchmark --seed=0 -Doptimize=fast
```

Each row is the median of five fresh one-worker databases. Signature resolution
and unresolved semantic-body construction happen before the timed typing call;
body teardown and code generation are excluded. Allocation statistics come from
a separate sixth database, so footprint-accounting work is excluded from the
timing samples. Typing includes ownership lowering and lifetime planning.
Owning fixtures keep all generations live, so their dense tables deliberately
represent a demanding case rather than a promise that sparse storage would help.

Snapshot measurements count retained contiguous value slots or page-pointer
arrays, each unique shared value page once (including its reference-count
header), local and field availability, initializer state, and definite
consumption completion. Trailing unbound value slots are omitted. Lifetime
measurements count dense solver tables, not dirty-block flags or other scratch.
Neither measurement is process RSS or an allocation-traffic counter. Value-page
sharing reduces copying but does not remove the remaining snapshot-by-slot
arrays or block-by-generation tables.

For cold multi-file worker scaling and warm and edited disk cache reuse against
uncached runs, build an optimized compiler and run the generated benchmark fixture.
The `fast` mode strips debug symbols; the linker build ID keeps compiler identity
checks cheap:

```sh
zig build -Doptimize=fast
python3 benchmarks/parallel.py zig-out/bin/chi
python3 benchmarks/parallel.py zig-out/bin/chi --temp-dir .
```
