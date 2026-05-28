# x86 AST -> Machine Code Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `main.zig` | AST types, binary pipeline (`writeProgram`, `runProg`, `eval`, `main`) |
|------|-------------|
| `ir.zig` | Block-based SSA IR definitions and AST -> IR lowering |
| `codegen.zig` | x86 binary backend: IR -> x86 machine code + ELF executable |
| `debug.zig` | Debug helpers: AST tree dump, SSA dump, asm dump, timing, debug flag parsing |
| `helpers_bin.zig` | Pre-assembled helper routines (`print_int`, `atoi`) as byte blobs |
| `test.zig` | Full-pipeline tests: compile -> assemble -> link -> run -> assert stdout |

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `AstNode`, `IfNode` | `main.zig` | AST node types |
| `Program`, `Block`, `Inst`, `Terminator`, `Branch` | `ir.zig` | SSA/block IR model |
| `lower(node, gpa)` | `ir.zig` | AST -> `Program` |
| `compileProgram(prog, gpa)` | `codegen.zig` | IR -> ELF file bytes |
| `compile(node, gpa)` | `codegen.zig` | AST -> ELF file bytes (lower + compileProgram) |
| `writeProgram(io, bytes)` | `main.zig` | writes ELF bytes to `./prog` |
| `runProg(io, gpa, args)` | `main.zig` | runs `./prog`, returns process exit code |
| `eval(io, node, gpa, args)` | `main.zig` | compile + write + run |
| `HelperId`, `HelperDef`, `HelperBlob`, `all_helpers`, `indexOf` | `helpers_bin.zig` | Runtime helper registry |

## IR Model

`ir.zig` uses a basic-block SSA design:

- `Program`: `{ entry, blocks, next_value }`
- `Block`: `{ id, param, insts, term }`
- `ValueInst`: `{ id, op }`
- `Terminator`: `br`, `cbr`, `ret`
- `Branch`: `{ target, arg? }`

### Branch-argument style (MLIR-like)

`if` merges use block parameters instead of phi nodes:

1. Lowering creates `then`, `else`, and `merge` blocks.
2. `then` and `else` end with `br` to `merge`, passing a value (`arg`).
3. `merge` declares one `param`, and that param is the `if` expression result.

## Internal Pipeline

1. **Lowering** (`ir.lower`) — AST to block-based SSA IR.
2. **Binary codegen** (`codegen.compileProgram`) — IR to x86 machine code in-memory, then wraps it in a minimal ELF executable (no external assembler or linker).
3. **Write & run** (`writeProgram` + `runProg`) — write ELF bytes to disk, execute, capture exit code.

## Backend Notes

### Emitter structure (`BinaryEmitter` in `codegen.zig`)

- **Slot model** — every SSA value gets a stack slot at `[rsp + value_id * 8]`. Frame size is `next_value * 8`. No register allocation.
- **ALU ops** — load both operands into `eax`/`ebx`, compute, store result to slot. Shared via composite helpers: `emitBinaryArithmetic` (add/sub/imul with internal enum), `emitBinaryDiv`, `emitCompare` (with `SetccCond` typed enum instead of raw opcode bytes).
- **Control flow** — `br` copies branch arg to target block param slot then jumps. `cbr` uses prep labels for edge-specific copies. Jumps use near encoding with symbol fixups.
- **Fixup system** — `emitCall`/`emitJmp`/`emitJe`/`emitJne` emit opcode bytes and a placeholder `i32` displacement, recording a `RelFixup`. `resolveFixups` (called by `finish`) walks all fixups, computing RIP-relative offsets from symbol positions bound during emission.
- **Helper registry** — `print_int` and `atoi` are pre-assembled binary blobs compiled at comptime in `helpers_bin.zig`. Accessed via `helperSymbol(id)` which indexes a `helper_symbols` parallel array. `emitCallAndStore` factors the emitCall + emitStoreRaxToSlot pattern used by both.
- **Low-level emit** — all appends route through `appendBytes`, including `appendByte` (wraps as `&.{byte}`) and `appendLeI32`/`appendLeU32` (write LE then forward to `appendBytes`).

### ELF construction (`buildElfExecutable`)

Produces a minimal 64-bit ELF binary with one `PT_LOAD` segment. Layout constants: `elf_header_size=64`, `program_header_size=56`, `code_file_offset=0x1000`, `image_base=0x400000`. Little-endian write helpers are scoped as `le.write16/32/64` inside the function body.

### `helpers_bin.zig`

Pre-assembled helper routines generated at comptime via `HelperBuffer`, patched with internal rel32 fixups. Registered via:
- `HelperId` enum (`print_int`, `atoi`)
- `all_helpers` array of `HelperDef` (`{ id, blob }`)
- `indexOf(id)` for stable-index lookup
- Comptime assertions: blob size limits, coverage of all `HelperId` variants

## Debug Flags

Use `--debug=ast,ssa,asm,timing` (comma-separated) with `zig run`:

- `ast`: tree-form AST dump using box characters (`├─`, `└─`, `│ `).
- `ssa`: block/terminator SSA listing.
- `asm`: emitted assembly body dump.
- `timing`: per-stage timing diagnostics (lower, compile, write, run).

## Main Example Behavior

`main.zig` demo program uses conditionals:

- `zig run main.zig` prints `10` from `if (3 < 4) ...`.
- `zig run main.zig -- 5` prints `111` from `if (arg1 > 0) ...`.

## Tests

`zig test test.zig` currently runs 5 end-to-end tests:

1. Arithmetic group (`int`, `add`, `sub`, `mul`, `div`, nested)
2. Argument read (`arg`)
3. Comparisons
4. Branch side effects (`if` branches with print in each arm)
5. `if` expression value propagation (including use inside arithmetic)
