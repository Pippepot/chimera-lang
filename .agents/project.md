# x86 Source -> Query -> Machine Code Compiler

**Location:** `x86/`

## Overview

This compiler now supports a declaration-first language with optional top-level executable statements:

- Canonical declarations:
  - `comptime Name = func(<params>) <ret_type> ...`
  - `comptime Name = struct ...`
- Top-level statements are valid and act as the runtime entry point (Python-style).
- Function symbols are first-class values and can be bound/passed/returned/called.
- Existing expression language features remain available inside function bodies and top-level entry blocks.

## Files

| File | Description |
|------|-------------|
| `main.zig` | CLI entrypoint and query pipeline orchestration |
| `ast.zig` | AST/module/declaration/types and expression nodes |
| `parser.zig` | Lexer + parser (`parseOwned`) to module AST |
| `resolver.zig` | Symbol resolution stage (top-level + locals) |
| `typecheck.zig` | Type inference/checking including function types/calls/returns |
| `monomorphize.zig` | Monomorphization stage artifact (`MonoProgram`) |
| `ir.zig` | Multi-function IR and lowering |
| `codegen.zig` | x86/ELF backend for multi-function programs |
| `query.zig` | Incremental revisioned query DB |
| `db.zig` | Shared query types/stats/deps/memo helpers |
| `debug.zig` | AST/IR debug dump helpers + flags |
| `runtime.zig` | Runtime helpers (`writeProgram`, `runProg`) |
| `scope.zig` | Reusable lexical scope stack utility |
| `helpers_bin.zig` | Embedded helper machine-code blobs |
| `test.zig` | End-to-end behavioral + incremental tests |

## Query architecture

`QueryDb` stages:

1. `parse(source_id)` -> `ParsedAst`
2. `resolve(source_id)` -> `ResolvedAst`
3. `typecheck(source_id)` -> `TypedAst`
4. `monomorphize(source_id)` -> `MonoProgram`
5. `lower(source_id)` -> `Program`
6. `compile(source_id)` -> `[]const u8`

### Red/green behavior

- Memos track `deps`, `verified_at`, `changed_at`, `computing`.
- Unchanged dependencies yield cache hits without recomputation.
- Compile stage supports `changed_at` backdating when bytes/diagnostics are unchanged.

## Language notes

- Statements are newline-separated.
- `if`/`else` uses indentation-based blocks with inline `->` form supported.
- Fallible comparisons (`<`, `>`, `<=`, `>=`, `==`, `!=`) are only legal in `if` conditions.
- `const` and `var` bindings support optional type annotations:
  - `const x: int = 1`
  - `var y: float = 1.0`
  - Annotation is optional when RHS inference is sufficient.
- **`string` type** — primitive type supporting string literals with escape sequences (`\n`, `\t`, `\\`, `\"`, `\0`). `print` on strings calls `print_string` helper.
- **Struct types** declared with `comptime Name = struct` and indented field lines.
- **Struct init** uses `TypeName{field1 = val1, field2 = val2, ...}` syntax.
- **Field access** uses `expr.fieldName` syntax.
  - Multi-field structs allocate consecutive stack slots and use `field_load` IR for non-zero field indices.

## Current behavior

- `zig run main.zig -- demo.x86` compiles and runs the demo.
- First non-debug CLI argument is source file path.
- Remaining CLI args are passed to generated `./prog` and accessible via `arg(n)`.
- Debug flags: `--debug=ast,ssa,timing,query`.

## Tests

- Behavioral tests include:
  - declaration parsing
  - resolver duplicate/unknown symbol diagnostics
  - first-class function value flows
  - multi-function call execution
  - top-level entry execution
  - binding annotation success/mismatch
- Incremental tests include:
  - per-stage cache hits/recomputes
  - source invalidation behavior
  - compile `changed_at` backdating
- Current suite: `zig test test.zig` (38 tests).
