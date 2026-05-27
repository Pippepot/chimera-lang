# x86 AST → Assembly Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `x86.zig` | AST types, binary pipeline (`assembleAndLink`, `runProg`, `eval`, `main`) |
| `codegen.zig` | IR types, AST→IR lowering, register allocator, emission, `compile` |
| `debug.zig` | Debug helpers: AST dump, IR dump, assembly dump, debug flag parsing |
| `print.asm` | NASM `print_int` routine (converts int to decimal, writes to stdout via `sys_write`) |
| `test.zig` | Full-pipeline tests: compile AST → assemble → link → run → capture stdout and verify |

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `AstNode` | `x86.zig` | Tagged union AST node |
| `Inst`, `InstPair`, `InstRef` | `codegen.zig` | SSA IR types |
| `compile(node, gpa)` | `codegen.zig` | AST → NASM assembly string |
| `emitIr(ir, buf, gpa)` | `codegen.zig` | IR → NASM instructions |
| `assembleAndLink(io, asm_source)` | `x86.zig` | writes `x86.asm`, runs `nasm`, runs `ld`, produces `prog` |
| `runProg(io, gpa, args)` | `x86.zig` | runs `./prog` with args, returns exit code |
| `eval(io, node, gpa, args)` | `x86.zig` | all-in-one: compile + assemble/link + run, returns exit code |

## Internal pipeline

1. **`lower`** (`codegen.zig`) — AST → SSA IR (``std.ArrayList(Inst)``), appends implicit `ret`. Binary ops use shared `lowerBinop` helper, each switch arm is a one-liner.
2. **`emitIr`** (`codegen.zig`) — three-pass codegen:
   - `computeUseCounts` — count consumers per IR ref
   - `computeFrameSize` — forward liveness simulation, computes stack frame (`sub rsp, N`)
   - `Emitter` struct — groups allocator state (val_to_reg, reg_to_val, spill_slots, spill_idx, use_count), with methods: `emitAddSub`, `emitImul`, `emitIdiv`, `loadIntoReg`, `ensureAnyReg`, `findFreeReg`, `freeOperands`, `assignResult`
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
  1. **Use counts** — `computeUseCounts`: count consumers per IR ref
  2. **Peak liveness** — `computeFrameSize`: forward simulation using `rem_uses` + `live`, computes stack frame size
  3. **Register allocation + emission** — `Emitter` struct: linear-scan with spilling
- Data structures: `val_to_reg: []?u8` (value → register), `reg_to_val: [NUM_REGS]?u32` (register → value), `spill_slots: []?u32`
- `eax` is preferred for instruction results (``imul r, m``, ``idiv``, etc.); `findFreeReg` returns the first free register without special-casing eax
- Frame is allocated with `sub rsp, N` when peak live > `NUM_REGS`
- Spill slots are lazily created with `mov [rsp+offset], reg`; tracking variables use tight types (``u8`` for register indices)
- `emitAddSub(mnemonic, p, i)` factors iadd/isub; `emitImul` uses three-operand `imul eax, reg/lhs, imm` optimization; `emitIdiv` handles `cdq` before `idiv`

## Notes

- `div` uses `cdq` (sign-extend eax→edx) then `idiv reg32`
- `print` leaves the printed value in `eax` (doesn't push/pop)
- `iarg` calls `atoi` (no libc — implemented via `syscall` in `print.asm`)
- No libc, no sysdeps — the emitted binary is statically linked by `ld`
