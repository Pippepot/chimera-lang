# x86 Source -> Query -> Machine Code Compiler

**Location:** `x86/`

## Files

| File | Description |
|------|-------------|
| `main.zig` | CLI entrypoint (`main`) and query pipeline orchestration |
| `ast.zig` | AST node types (`AstNode`, `IfNode`, `VarNode`, `ConstNode`, `BlockNode`) |
| `runtime.zig` | Runtime helpers (`writeProgram`, `runProg`) |
| `parser.zig` | Lexer + recursive descent parser (`parseOwned`) from source text to AST |
| `typecheck.zig` | Type inference/checking over AST (`unit`, `bool`, `int`, `float`) |
| `query.zig` | Revisioned incremental query database (`QueryDb`) with memoized parse/lower/compile stages |
| `ir.zig` | Block-based SSA IR definitions and AST -> IR lowering |
| `codegen.zig` | x86 binary backend: IR -> x86 machine code + ELF executable |
| `scope.zig` | Shared lexical scope stack utility used by typecheck/lowering |
| `debug.zig` | Debug helpers: AST dump, SSA dump, debug flag parsing |
| `helpers_bin.zig` | Pre-assembled helper routines (`print_int`, `print_bool`, `print_float32`, `atoi`) as byte blobs |
| `test.zig` | End-to-end language tests plus incremental query behavior tests |
| `demo.x86` | Small demo source file for quick manual compile/run checks |

## Public API

| Symbol | File | Description |
|--------|------|-------------|
| `AstNode`, `IfNode`, `VarNode`, `ConstNode`, `BlockNode` | `ast.zig` | AST node types |
| `parseOwned(source, gpa)` | `parser.zig` | Parse source string into arena-owned AST |
| `Program`, `Block`, `Inst`, `Predicate`, `Terminator`, `Branch` | `ir.zig` | SSA/block IR model |
| `lower(node, typed, gpa)` | `ir.zig` | Typed AST -> `Program` |
| `compileProgram(prog, gpa)` | `codegen.zig` | IR -> ELF file bytes |
| `QueryDb` (+ `SourceId`, `Revision`, `QueryStats`) | `query.zig` | Incremental query engine over parse/lower/compile |
| `writeProgram(io, bytes)` | `runtime.zig` | Writes ELF bytes to `./prog` |
| `runProg(io, gpa, args)` | `runtime.zig` | Runs `./prog`, returns process exit code |
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
6. `compileResult(source_id)`
7. `writeProgram` + `runProg`

## Debug flags

Use `--debug=ast,ssa,timing,query`:

- `ast`: tree-form AST dump.
- `ssa`: block/terminator SSA listing.
- `timing`: stage timings.
- `query`: query diagnostics (revision, source set counts, hits/recomputes, dependency checks/invalidations) via `query.appendQueryDiagnostics`.

## Current behavior

- `zig run main.zig -- demo.x86` compiles and runs `demo.x86` (current demo prints `645` and `42`).
- `zig run main.zig --` prints usage and exits with code `1`.
- First non-debug CLI arg is source file path; remaining args are passed to the generated program.
- `if`/`else` uses indentation-based blocks (no `then` keyword). Use `->` for inline body, or newline + indent for block body.
- `else` does not require `->` for inline body; just `else <expr>`.
- Statements are newline-separated; `;` is not supported as a statement separator.
- `const` locals are non-mutable, `var` locals are mutable, and duplicate names are rejected for both.
- Reassignment (`name = expr`) produces unit and validates mutability and type match.
- Multi-statement programs are represented as explicit `AstNode.block`.
- Parentheses are expression grouping only and do not create scope boundaries.
- **Fail semantics:** `if` conditions must be fallible expressions (comparisons). Fallible expressions can only appear inside `if` conditions. Comparisons produce `unit` on success (not `bool`).
- Block/branch lexical scope is isolated: branch-local `const` and `var` names do not leak into sibling branches or following statements.
- Implementation plan at `.agents/fail-semantics.md`.

## Tests

`zig test test.zig` currently includes:

1. ELF bytes sanity test.
2. Arithmetic language behavior.
3. CLI arg behavior (`arg(n)`).
4. Comparisons (via `if` conditions — fallible in fallible context).
5. If branch side effects.
6. If expression value propagation.
7. Float arithmetic/printing.
8. Float comparison NaN semantics.
9. Const locals + multi-statement programs.
10. Bool literal printing and equality comparisons.
 11. Else-less `if` unit behavior.
 12. Indentation-based `if`/`else` blocks.
 13. `else if` chaining with mixed inline/block bodies.
14. Nested `if` with proper indentation-based binding.
15. Statement after indented `if` block parsing.
16. Branch-local `const` visibility/isolation behavior.
17. Same-name `const` declarations across opposite `if` branches.
18. Type error coverage (including fallible outside fallible context, non-fallible condition).
19. Fallible expression outside fallible context error.
20. Non-fallible expression in if condition error.
21. Query cache hits within same revision.
22. Source-change invalidation across parse/typecheck/lower/compile.
23. Source-specific invalidation isolation.
24. Unchanged source revision stability.
25. Compile `changed_at` backdating when output bytes are identical.
26. Query diagnostics formatting.
27. Program exit code follows top-level expression value.
28. Helper enum/index mapping.
29. `var` declaration and read.
30. `var` reassignment.
31. `var` type mismatch error, assign-to-const error, unknown variable error, duplicate var error, branch-local `var` scope isolation.
