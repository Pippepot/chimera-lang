# x86 Source -> Query -> Machine Code Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `main.zig` | AST types, runtime entrypoints (`writeProgram`, `runProg`, `eval`, `main`), and query diagnostics formatting |
| `parser.zig` | Lexer + recursive descent parser (`parseOwned`) from source text to AST |
| `query.zig` | Revisioned incremental query database (`QueryDb`) with memoized parse/lower/compile stages |
| `ir.zig` | Block-based SSA IR definitions and AST -> IR lowering |
| `codegen.zig` | x86 binary backend: IR -> x86 machine code + ELF executable |
| `debug.zig` | Debug helpers: AST dump, SSA dump, asm note, debug flag parsing |
| `helpers_bin.zig` | Pre-assembled helper routines (`print_int`, `atoi`) as byte blobs |
| `test.zig` | End-to-end language tests plus incremental query behavior tests |

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `AstNode`, `IfNode` | `main.zig` | AST node types |
| `parseOwned(source, gpa)` | `parser.zig` | Parse source string into arena-owned AST |
| `Program`, `Block`, `Inst`, `Terminator`, `Branch` | `ir.zig` | SSA/block IR model |
| `lower(node, gpa)` | `ir.zig` | AST -> `Program` |
| `compileProgram(prog, gpa)` | `codegen.zig` | IR -> ELF file bytes |
| `QueryDb` (+ `SourceId`, `Revision`, `QueryStats`) | `query.zig` | Incremental query engine over parse/lower/compile |
| `writeProgram(io, bytes)` | `main.zig` | Writes ELF bytes to `./prog` |
| `runProg(io, gpa, args)` | `main.zig` | Runs `./prog`, returns process exit code |
| `HelperId`, `HelperDef`, `HelperBlob`, `all_helpers` | `helpers_bin.zig` | Runtime helper registry |

## Query architecture

`query.zig` uses a reusable DB with revisioned inputs and per-stage memo tables.

### Inputs

- `setSource(source_id, text)` stores source text keyed by `SourceId`.
- Revision increments only when text actually changes.
- Input metadata tracks `changed_at` revision.

### Stage queries

1. `parse(source_id)` -> `ParsedAst`
2. `lower(source_id)` -> `Program`
3. `compile(source_id)` -> `[]const u8` ELF bytes

### Memo metadata

Each stage memo stores:
- `value`
- `deps` (source deps and query deps)
- `verified_at`
- `changed_at`
- `computing` (cycle guard)

### Red/green verification

- If `verified_at == current_revision`: cache hit.
- Otherwise, recursively verify dependencies and reuse memo if unchanged.
- Recompute only on dependency invalidation.
- Compile memo supports backdating: if recomputed bytes equal old bytes, preserve old `changed_at`.

### Ownership/lifetime

- `QueryDb` owns all memoized values and source text.
- Replacing a memo deinitializes/frees the old value.
- Returned pointers/slices are borrowed and valid until that memo is invalidated or DB is deinitialized.

## Internal pipeline

Runtime flow in `main.zig`:

1. `setSource(source_id, demoSource(...))`
2. `parsedAst(source_id)` (for AST debug)
3. `loweredProgram(source_id)` (for SSA debug)
4. `compileBytes(source_id)`
5. `writeProgram` + `runProg`

## Debug flags

Use `--debug=ast,ssa,asm,timing,query`:

- `ast`: tree-form AST dump.
- `ssa`: block/terminator SSA listing.
- `asm`: binary backend note (text asm emitter removed).
- `timing`: stage timings.
- `query`: query diagnostics (revision, source set counts, hits/recomputes, dependency checks/invalidations).

## Current behavior

- `zig run main.zig` prints `10`.
- `zig run main.zig -- 5` prints `111`.

## Tests

`zig test test.zig` currently includes:

1. ELF bytes sanity test.
2. Arithmetic language behavior.
3. CLI arg behavior (`arg(n)`).
4. Comparisons.
5. If branch side effects.
6. If expression value propagation.
7. Query cache hits within same revision.
8. Source-change invalidation across parse/lower/compile.
9. Source-specific invalidation isolation.
10. Unchanged source revision stability.
11. Compile `changed_at` backdating when output bytes are identical.
12. Query diagnostics formatting.
13. Helper enum/index mapping.
