# Compiler

An experimental language compiler written in Zig 0.16, targeting Linux x86-64. The root pipeline uses incremental queries to analyze functions, emit relocatable machine code, and link an ELF executable. `legacy/` is a reference implementation, not the active compiler.

## Run

```sh
zig run main.zig -- example.chi
zig run main.zig -- --debug=ast,ssa,asm,timing example.chi
```

The CLI compiles one source file, writes `./prog`, runs it, and reports its exit code. Extra arguments after the source path are passed to the generated program.

Top-level code is the entry point; a function named `main` is ordinary. The CLI itself exits with 0 after a normal program exit, or 1 on invalid arguments, source-read failure, source rejection, or compiler failure. It reports the program's status separately. A compile-time `exit(code)` is compiler control instead: it produces no executable and becomes the CLI's own process status.

## Documentation

| Document | Owns |
| --- | --- |
| [syntax&semantics.txt](syntax&semantics.txt) | Language rules and examples; authoritative but incomplete |
| [ROADMAP.md](ROADMAP.md) | Verified implementation status, gaps, and ordered next steps |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler boundaries, ownership, and representation contracts |
| [PROGRAM_FLOW.md](PROGRAM_FLOW.md) | Current query flow, invalidation, and result lifetimes |
| [COMPTIME_EXECUTION.md](COMPTIME_EXECUTION.md) | Planned compile-time execution architecture and delivery slices |
| [STORAGE_AND_REFERENCES.md](STORAGE_AND_REFERENCES.md) | Allocation/reference research and API design proposal |
| [AGENTS.md](AGENTS.md) | Contribution and review rules |

Language examples describe the target, not a promise of compiler support. Parser support alone does not establish semantics. Resolve missing language decisions in `syntax&semantics.txt` before implementing them; neither legacy behavior nor an old test overrides it.

## Verify

Use the suites relevant to the change. Query tests cover execution and incremental recomputation; backend tests also exercise graphs the frontend cannot yet produce.

```sh
zig test tokenizer.zig
zig test ast_new.zig
zig test semantic.zig
zig test diagnostics.zig
zig test lifetime.zig
zig test typing.zig
zig test query_new_test.zig
zig test codegen_new_test.zig
zig test main.zig
git diff --check
```

Run suites that write `./prog` sequentially. Check modified Zig files with `zig fmt --check <files>`. Keep temporary verification files outside the repository.

## Benchmark

The compile-time execution benchmark reports analysis, execution, publication,
cached lookup, and incremental recomputation times in CSV form:

```sh
zig run -O ReleaseFast comptime_benchmark.zig
```
