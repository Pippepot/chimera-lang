# x86 AST → Assembly Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `x86.zig` | AST definition, IR lowering, register allocator, codegen, binary pipeline, main |
| `debug.zig` | Debug helpers: AST dump, IR dump, assembly dump, debug flag parsing |
| `print.asm` | NASM `print_int` routine (converts int to decimal, writes to stdout via `sys_write`) |
| `test.zig` | Full-pipeline tests: compile AST → assemble → link → run → capture stdout and verify |

## Public API (`x86.zig`)

- **`AstNode`** — tagged union: `.int(i32)`, `.print(*const AstNode)`, `.add/sub/mul/div(*const [2]AstNode)`, `.arg(u32)`
- **`Inst`** / **`InstPair`** / **`InstRef`** — SSA IR types (all `pub` for downstream use)
- **`compile(node, gpa)`** — AST → NASM assembly string (``[]const u8``)
- **`emitIr(ir, buf, gpa)`** — IR → NASM instructions (3-pass register allocator)
- **`assembleAndLink(io, asm_source)`** — writes `x86.asm`, runs `nasm`, runs `ld`, produces `prog`
- **`runProg(io, gpa, args)`** — runs `./prog` with args, returns exit code (``u8``)
- **`eval(io, node, gpa, args)`** — all-in-one: compile + assemble/link + run, returns exit code

## Internal pipeline

1. **`lower`** — AST → SSA IR (``std.ArrayList(Inst)``), appends implicit `ret`. Binary ops use shared `lowerBinop` helper.
2. **`emitIr`** — three-pass: use-count, peak-live stack-frame, register allocation + emission
3. **`compile`** = `lower` → `compileIr` (adds prologue, `lea rbp, [rsp+8]`, embeds `print.asm`)

### IR (`Inst`)

| Variant | Meaning |
|---------|---------|
| `iconst i32` | Load immediate |
| `iadd/isub/imul/idiv { l, r }` | Binary op on IR refs |
| `print ref` | Call `print_int` with value |
| `ret ref` | Exit with value as code |
| `iarg u32` | Read argv[index] via `atoi` |

## Debug flags

Pass `--debug=ast,ssa,asm` (comma-separated) on `zig run` to dump intermediate representations:
- `ast` — S-expression AST dump
- `ssa` — SSA IR listing (numbered `%0`… refs)
- `asm` — emitted NASM instructions (before embedding `print.asm`)

## Usage

- `zig run x86.zig` — compiles and runs the example (`(print (+ (* 2 5) 3))`, prints `13`, exits with `13`)
- `zig run x86.zig -- 42` — passes `42` as argv to `prog`, which prints and exits with it
- `zig run x86.zig -- --debug=ast,ssa` — runs with debug dumps to stderr-inherited output
- `zig test test.zig` — runs 7 tests (int, add, sub, mul, div, nested, arg)

## Register allocator

- 10 allocatable registers: `rax`, `rbx`, `r8`–`r15` (``eax``/``rXXd`` for 32-bit ops); `reg64`/`reg32` are comptime arrays
- Three-pass design:
  1. **Use counts** — count consumers per IR ref
  2. **Peak liveness** — forward simulation using `rem_uses` + `live` + `consumeUse` helper, computes stack frame size
  3. **Register allocation + emission** — linear-scan with spilling
- Data structures: `val_to_reg: []?u8` (value → register), `reg_to_val: [NUM_REGS]?u32` (register → value), `spill_slots: []?u32`
- `eax` is preferred for instruction results (``imul r, m``, ``idiv``, etc.)
- Frame is allocated with `sub rsp, N` when peak live > `NUM_REGS`
- Spill slots are lazily created with `mov [rsp+offset], reg`; tracking variables use tight types (``u8`` for register indices)

## Notes

- `div` uses `cdq` (sign-extend eax→edx) then `idiv reg32`
- `print` leaves the printed value in `eax` (doesn't push/pop)
- `iarg` calls `atoi` (no libc — implemented via `syscall` in `print.asm`)
- No libc, no sysdeps — the emitted binary is statically linked by `ld`
