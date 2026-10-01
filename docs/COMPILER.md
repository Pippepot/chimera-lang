# Chimera Compiler

An experimental language compiler written in Zig 0.16, targeting Linux x86-64. The root pipeline uses incremental queries to analyze functions, emit relocatable machine code, and link an ELF executable.

For an introduction to the language, start with the [Chimera README](../README.md).
All commands below run from the repository root.

## Run

```sh
zig build run -- --help
zig build run -- program.chi
zig build run -- --debug=ast,ssa,asm,timing program.chi
zig build run -- --workers=2 program.chi
zig build run -- --disk-cache program.chi
```

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
| [ROADMAP.md](../ROADMAP.md) | Verified implementation status, gaps, and ordered next steps |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Compiler boundaries, ownership, and representation contracts |
| [PROGRAM_FLOW.md](../PROGRAM_FLOW.md) | Current query flow, invalidation, and result lifetimes |
| [STORAGE_AND_REFERENCES.md](../STORAGE_AND_REFERENCES.md) | Implemented host API and accepted future storage design |
| [AGENTS.md](../AGENTS.md) | Contribution and review rules |

Specification examples describe the target, not a promise of compiler support. Parser support alone does not establish semantics. Resolve missing language decisions in `syntax&semantics.txt` before implementing them; neither legacy behavior nor an old test overrides it.

## Layout

`src/frontend/` owns parsing, semantic analysis, typing, compile-time interpretation, and lifetime planning. `src/backend/` owns code generation and disassembly. `src/query/` contains the compiler-independent query engine and its codec. Shared types, compiler query definitions, module registration, caching, diagnostics, and the CLI remain directly under `src/`; `std/` contains the embedded standard library.

Standalone integration and backend suites live in `tests/`. Local tests that need private declarations remain beside their implementations. The project-root `test_sources.zig` collects inline stage tests and exposes one shared source module to the out-of-tree suites; Zig cannot import outside a module's root directory.

## Verify

Run the complete suite with:

```sh
zig build test
git diff --check
```

The default runner uses four roots: one for all inline tests and three standalone suites. Each inline test runs once. Test binaries have separate working directories so they can write `./prog` in parallel. Use `zig build test -Dtest-source=tests/modules_test.zig` for one suite, or another source path for local tests and their imports. Add `-Dtest-filter="test name fragment"` to narrow the run. Use these build entrypoints for the required module imports. Check modified Zig files with `zig fmt --check <files>`. Keep temporary verification files outside the repository.

## Benchmark

The compile-time execution benchmark reports analysis, execution, publication,
cached lookup, and incremental recomputation times in CSV form:

```sh
zig build benchmark -Doptimize=ReleaseFast
```

The flow benchmark reports typing time, retained snapshot bytes, and dense
lifetime-table bytes for functions with 8, 32, 128, and 256 branches:

```sh
zig build flow-benchmark -Doptimize=ReleaseFast
```

The 256-branch fixture retains 23,667,201 bytes of snapshots and 3,248,256 bytes
of lifetime tables. Omitting trailing unbound value slots reduced snapshot
storage by 49% from 46,540,901 bytes without changing the graph or lifetime
tables. These are logical allocated slice sizes, not process RSS.

For cold multi-file worker scaling and warm and edited disk cache reuse against
uncached runs, build an optimized compiler and run the generated benchmark fixture.
ReleaseFast strips debug symbols; the linker build ID keeps compiler identity
checks cheap:

```sh
zig build -Doptimize=ReleaseFast
python3 benchmarks/parallel.py zig-out/bin/chi
python3 benchmarks/parallel.py zig-out/bin/chi --temp-dir .
```