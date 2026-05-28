# x86 Source -> Query -> Machine Code Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `main.zig` | AST types, runtime entrypoints (`writeProgram`, `runProg`, `eval`, `main`), and query diagnostics formatting |
| `parser.zig` | Lexer + recursive descent parser (`parseOwned`) from source text to AST |
| `typecheck.zig` | Type inference/checking over AST (`unit`, `bool`, `int`, `float`) |
| `query.zig` | Revisioned incremental query database (`QueryDb`) with memoized parse/lower/compile stages |
| `ir.zig` | Block-based SSA IR definitions and AST -> IR lowering |
| `codegen.zig` | x86 binary backend: IR -> x86 machine code + ELF executable |
| `debug.zig` | Debug helpers: AST dump, SSA dump, debug flag parsing |
| `helpers_bin.zig` | Pre-assembled helper routines (`print_int`, `print_bool`, `print_float32`, `atoi`) as byte blobs |
| `test.zig` | End-to-end language tests plus incremental query behavior tests |
| `demo.x86` | Small demo source file for quick manual compile/run checks |

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `AstNode`, `IfNode` | `main.zig` | AST node types |
| `parseOwned(source, gpa)` | `parser.zig` | Parse source string into arena-owned AST |
| `Program`, `Block`, `Inst`, `Terminator`, `Branch` | `ir.zig` | SSA/block IR model |
| `lower(node, typed, gpa)` | `ir.zig` | Typed AST -> `Program` |
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
2. `typecheck(source_id)` -> typed AST metadata
3. `lower(source_id)` -> `Program`
4. `compile(source_id)` -> `[]const u8` ELF bytes

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

1. Read source text from CLI-provided file path
2. `setSource(source_id, source_text)`
3. `parsedAst(source_id)` (for AST debug)
4. `typedAst(source_id)`
5. `loweredProgram(source_id)` (for SSA debug)
6. `compileBytes(source_id)`
7. `writeProgram` + `runProg`

## Debug flags

Use `--debug=ast,ssa,timing,query`:

- `ast`: tree-form AST dump.
- `ssa`: block/terminator SSA listing.
- `timing`: stage timings.
- `query`: query diagnostics (revision, source set counts, hits/recomputes, dependency checks/invalidations).

## Current behavior

- `zig run main.zig -- demo.x86` compiles and runs `demo.x86` (prints `42` with current demo file).
- `zig run main.zig --` prints usage and exits with code `1`.
- First non-debug CLI arg is source file path; remaining args are passed to the generated program.
- Statements are newline-separated; `;` is not supported as a statement separator.
- `const` locals are supported, non-mutable, and duplicate names are rejected.
- Parentheses are expression grouping only and do not create scope boundaries.

## Tests

`zig test test.zig` currently includes:

1. ELF bytes sanity test.
2. Arithmetic language behavior.
3. CLI arg behavior (`arg(n)`).
4. Comparisons.
5. If branch side effects.
6. If expression value propagation.
7. Float arithmetic/printing.
8. Float comparison NaN semantics.
9. Const locals + multi-statement programs.
10. Else-less `if` unit behavior.
11. Type error coverage.
12. Query cache hits within same revision.
13. Source-change invalidation across parse/typecheck/lower/compile.
14. Source-specific invalidation isolation.
15. Unchanged source revision stability.
16. Compile `changed_at` backdating when output bytes are identical.
17. Query diagnostics formatting.
18. Helper enum/index mapping.
