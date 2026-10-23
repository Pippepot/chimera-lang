# Compiler Guide

Chimera targets Linux x86-64 and builds with Zig 0.17. All commands below run
from the repository root. Start with the [README](../README.md) for the language;
[syntax&semantics.txt](../syntax&semantics.txt) owns detailed language rules.
Specification examples can describe planned features, not current support.

## Build and Run

```sh
zig build
zig build run -- program.chi
zig build run -- --help
zig build run -- --workers=2 --disk-cache program.chi
zig build run --watch -- program.chi
```

The default `debug` build uses Zig's self-hosted backend, runtime safety, and
incremental compiler builds. Editing only `.chi` sources does not rebuild the
compiler. `safe` is optimized with safety checks; `fast` disables them and uses
LLVM. These modes build the compiler, not an optimization mode for generated
Chimera code. There is no independent backend option.

```sh
zig build run -Doptimize=fast -- --debug=timing example.chi
```

Use `--summary all` before `--` to inspect Zig build-cache hits. `-fllvm` and
`-fno-llvm` belong to direct Zig compilation, not this project's build interface.

The CLI loads the entry's directory tree, reserving its root `std/` for embedded
standard-library sources. It compiles the designated file's top-level statements,
writes `./prog` atomically, runs a private link or copy, and reports the program's
status. Options precede the source path; later arguments go to the program.
`--workers=N` accepts 0 through 64; 0 is synchronous. The default is two workers
on machines with at least two CPUs.

Top-level success and unhandled ordinary failure clean up and exit the generated
program with status 0 and 1 respectively. The CLI itself exits 0 after a normal
program exit, reporting its status separately; invalid arguments, source or
compiler failures, and abnormal program termination make the CLI exit 1.
A compile-time `exit(code)` instead produces no executable and becomes the CLI
status. Panic prints a message and source trace, exits 134, and does not unwind
owners; compile-time panic is a source diagnostic rather than a compiler exit.

## Debugging and Reuse

```sh
zig build run -- --debug=ast,ssa,optimized,asm,timing program.chi
```

AST, SSA, optimized SSA, and assembly views demand ordinary analysis and bypass bundled std
results. Labels and diagnostics use source-style names with static arguments.
Native panic traces retain read-only call-site metadata, walk at most 1024 known
frames, and add no tracing instructions to successful calls.

The build embeds parsed std syntax and precompiled concrete std functions.
Ordinary runs load bodies and native functions lazily; absent specializations
compile normally. No adjacent std files or disk-cache flag are required.

`--disk-cache` enables `.chi-cache/` beside the entry. A whole-program hit skips
analysis and linking; a changed program may reuse validated body and code
snapshots. Keys include all loaded sources, module directories, and compiler
identity. Damage and relevant edits fall back to compilation. Without the flag,
the CLI does not read or write this cache. See [query flow](../PROGRAM_FLOW.md)
for invalidation and restoration details.

### Timing

`--debug=timing` reports milliseconds and computation counts:

- Stage `wall ms` measures dependency-inclusive elapsed intervals, not exclusive
  compiler passes. Work demanded during a stage is charged there.
- `thread ms` sums exclusive worker elapsed time after subtracting nested work.
  It is not CPU time and can exceed wall time with parallel workers.
- Query/function counts exclude memo hits; phase counts are invocations.
  Dependency waits count requests for incomplete work and are reported separately.
- Body work separates semantic construction, typing/SSA, reference/lifetime and
  cleanup, IR finalization, and setup/publication. Cache stages appear only when
  used. Percentages use the containing stage or work total, not total CLI time.

Profiling is disabled normally and adds overhead when enabled. Use uninstrumented
benchmarks for acceptance measurements.

## Verify

Routine checks:

```sh
zig build test --seed=0 -Doptimize=safe -j1
zig fmt --check <modified-zig-files>
git diff --check
```

Use focused tests while editing; run the routine suite once for changes spanning
stages or shared representations. Documentation-only changes need no compiler
tests. Keep default caches and fixed `--seed=0`; add `--summary all` to distinguish
executed checks from cached successful runs.

```sh
zig build test --seed=0 -Dtest-source=tests/operation_test.zig
zig build test --seed=0 -Dtest-source=tests/query_engine_test.zig
zig build test --seed=0 -Dtest-source=test_sources.zig -Dtest-filter=tokenizer
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/query_test.zig -Dtest-filter="name fragment"
```

`-Dtest-source` selects one root; `-Dtest-filter` selects names within it. Use
these build entrypoints rather than bare `zig test`, which can lack required
imports. The default suite list is maintained in [build.zig](../build.zig).
Standalone suites run in separate binary directories. The full suite builds
many binaries; its compile cost is not the CLI's compile cost. Omit
`-Doptimize=safe` for a narrow Debug iteration when appropriate.

Exhaustive allocation-failure sweeps are opt-in backup checks:

```sh
zig build test --seed=0 -Doptimize=safe -Dallocation-failures=true -j1
```

Run these only when explicitly requested. Ordinary OOM tests and leak detection
remain enabled without the flag; sweep-only tests report skips, and mixed tests
run their ordinary case. The shared failure allocator disables in-place growth
to make allocation indices repeatable. Do not run builds or measurements
concurrently in the shared workspace.

## Test Ownership

- [tests/query_engine_test.zig](../tests/query_engine_test.zig): generic scheduling,
  memoization, dependencies, accumulators, publication, and failure recovery;
  fixtures initialize plain databases without a language prelude.
- [tests/query_test.zig](../tests/query_test.zig): compiler query contracts,
  canonical compiler identities, diagnostics, and incremental behavior.
- [tests/language_test.zig](../tests/language_test.zig): cross-feature execution,
  ownership, modules, and native/interpreter parity.
- [tests/operation_test.zig](../tests/operation_test.zig): operator dispatch,
  signature validation, evaluation order, and incremental edits.
- Other [tests/](../tests/) suites own their named features; private implementation
  tests stay beside code. Large cross-module tests belong in standalone suites.

[test_sources.zig](../test_sources.zig) is both the inline-test root and the
shared import surface for integration tests. Its root location is intentional:
Zig imports cannot escape their module root. Reuse `SourceFixture` for source
registration, diagnostics, process checks, and native/interpreter parity, and
`renderTemplate` for parameterized programs. Keep cache restoration and
memory-limited process setup suite-local.

## Further Reading

- [Architecture](../ARCHITECTURE.md): code map, boundaries, and invariants.
- [Query flow](../PROGRAM_FLOW.md): demand, revisions, persistence, and lifetimes.
- [Benchmark guide](../benchmarks/README.md): commands, measurement boundaries,
  history recording, and saved experiment provenance.
- [Roadmap](../ROADMAP.md): priorities and deferred decisions.
- [Working rules](../AGENTS.md): contribution and review requirements.
