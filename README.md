# Compiler

An experimental language compiler written in Zig 0.16, targeting Linux x86-64. The root pipeline uses incremental queries to analyze functions, emit relocatable machine code, and link an ELF executable.

## Run

```sh
zig build run -- program.chi
zig build run -- --debug=ast,ssa,asm,timing program.chi
```

The CLI loads the entry directory tree, shares declarations within each module,
compiles the designated entry file, writes `./prog`, runs it, and reports its exit
code. Imports are file-scoped; qualified and selective names work in types,
values, calls, and compile-time expressions. The embedded `std/prelude.chi`
exports are in every user file's unqualified scope by default; compiler-owned
standard-library files do not implicitly import the prelude. An explicit
`import std.prelude.{}` disables the defaults for a user file. Only the
designated file's top-level statements execute. Extra arguments after the
source path are passed to the generated program.

Top-level code is the entry point; a function named `main` is ordinary. The CLI itself exits with 0 after a normal program exit, or 1 on invalid arguments, source-read failure, source rejection, or compiler failure. It reports the program's status separately. A compile-time `exit(code)` is compiler control instead: it produces no executable and becomes the CLI's own process status.

## Documentation

| Document | Owns |
| --- | --- |
| [syntax&semantics.txt](syntax&semantics.txt) | Language rules and examples; authoritative but incomplete |
| [ROADMAP.md](ROADMAP.md) | Verified implementation status, gaps, and ordered next steps |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler boundaries, ownership, and representation contracts |
| [PROGRAM_FLOW.md](PROGRAM_FLOW.md) | Current query flow, invalidation, and result lifetimes |
| [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md) | Allocation/reference research and API design proposal |
| [AGENTS.md](AGENTS.md) | Contribution and review rules |

Language examples describe the target, not a promise of compiler support. Parser support alone does not establish semantics. Resolve missing language decisions in `syntax&semantics.txt` before implementing them; neither legacy behavior nor an old test overrides it.

## Verify

Use the suites relevant to the change. Query tests cover execution and incremental recomputation; backend tests also exercise graphs the frontend cannot yet produce.

```sh
zig test src/tokenizer.zig
zig test src/parser.zig
zig test src/semantic.zig
zig test src/diagnostics.zig
zig test src/lifetime.zig
zig test src/typing.zig
zig test src/query_test.zig
zig test src/codegen_test.zig
zig test src/disasm.zig
zig test --dep standard_library -Mroot=src/main.zig -Mstandard_library=std/library.zig
zig test --dep standard_library -Mroot=src/modules.zig -Mstandard_library=std/library.zig
zig test --dep standard_library -Mroot=src/modules_test.zig -Mstandard_library=std/library.zig
git diff --check
```

Run suites that write `./prog` sequentially. Check modified Zig files with `zig fmt --check <files>`. Keep temporary verification files outside the repository.

## Benchmark

The compile-time execution benchmark reports analysis, execution, publication,
cached lookup, and incremental recomputation times in CSV form:

```sh
zig run -O ReleaseFast src/comptime_benchmark.zig
```
