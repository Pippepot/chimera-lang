# x86 AST → Assembly Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `x86.zig` | AST definition, emitter, compiler, binary pipeline, main |
| `print.asm` | NASM `print_int` routine (converts int to decimal, writes to stdout via `sys_write`) |
| `test.zig` | Full-pipeline tests: compile AST → assemble → link → run → verify exit code |

## Public API (`x86.zig`)

- **`AstNode`** — tagged union: `.int(i32)`, `.print(child)`, `.add/`.sub/`.mul/`.div([left, right])`
- **`compile(node, gpa)`** — AST → NASM assembly string
- **`assembleAndLink(io, asm_source)`** — writes `x86.asm`, runs `nasm`, runs `ld`, produces `prog`
- **`runProg(io)`** — runs `./prog`, returns exit code
- **`eval(io, node, gpa)`** — all-in-one: compile + assemble/link + run, returns exit code

## Description

A self-contained AST-to-x86-64 compiler in Zig with no libc. Emits raw NASM assembly that uses `_start` as ELF entry point. The exit code of `prog` is the result of the arithmetic expression. Supports `print` via a `write` syscall in `print.asm` (no libc).

## Usage

- `zig run x86.zig` — compiles and runs the example (prints `4`, exits with `4`)
- `zig test test.zig` — runs 6 tests exercising int/add/sub/mul/div/nested

## Notes

- Register usage: `eax` holds current expression result; `ebx` holds rhs during binary ops; stack (`push`/`pop`) for intermediate values
- `div` uses `cdq` (sign-extend eax→edx) then `idiv ebx`
- `print` saves/restores the result (`push rax`/`pop rax` around `call print_int`)
- No libc, no sysdeps — the emitted binary is statically linked by `ld`
