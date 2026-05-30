# Chimera — Source -> Query -> Machine Code Compiler

**Location:** `chimera/`

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
| `ast.zig` | **Flat index-based AST** — `Node` (extern struct, 12 bytes), `Ast` container with single `backing: []u8`, buffer-copy `serialize`/`deserialize` |
| `parser.zig` | **Rewritten** — builds flat arrays via `AstBuilder`, returns `NodeIdx` not `*const AstNode`, `AstBuilder.seal()` packs contiguous backing buffer |
| `resolver.zig` | **Rewritten** — `NodeIdx` keys, flat AST accessors, no `*const AstNode`/`*const ast.Module` |
| `typecheck.zig` | **Rewritten** — `NodeIdx`/`TypeIdx` keys, flat AST accessors, `TypedAst.ast` reference |
| `ir.zig` | Flat AST dispatch via `ast.nodes[idx].tag` and accessors |
| `codegen.zig` | IR->x86 + ELF, backdate support |
| `query.zig` | Generic `ensureMemo`, 5-stage pipeline, persistent cache load/save |
| `query_cache.zig` | Buffer-copy ser/des for all 5 stages, persistent cache with schema v4 |
| `db.zig` | Shared query types/stats/deps/memo helpers |
| `debug.zig` | Flat AST dispatch |
| `runtime.zig` | Runtime helpers (`writeProgram`, `runProg`) — unchanged |
| `scope.zig` | Reusable lexical scope stack utility — unchanged |
| `helpers_bin.zig` | Embedded helper machine-code blobs — unchanged |
| `test.zig` | All 34 tests pass using flat API |

## Query architecture

`QueryDb` stages:

1. `parse(source_id)` -> `ParsedAst`
2. `resolve(source_id)` -> `ResolvedAst`
3. `typecheck(source_id)` -> `TypedAst`
4. `lower(source_id)` -> `Program`
5. `compile(source_id)` -> `[]const u8`

### Red/green behavior

- Memos track `deps`, `verified_at`, `changed_at`, `computing`.
- Unchanged dependencies yield cache hits without recomputation.
- Compile stage supports `changed_at` backdating when bytes/diagnostics are unchanged.
- Cross-run persistent cache stores compile outputs + per-stage diagnostics metadata keyed by strict fingerprints.

## Flat AST design (in progress)

The old pointer-based AST (`*const AstNode`, `*const ast.Module`, `*const ast.FuncDecl`) is being replaced with a flat index-based design:

- **`ast.Node`**: 12-byte `extern struct { tag: Tag, _pad: [3]u8, data0: u32, data1: u32 }`
- **`ast.Ast`**: Single `backing: []u8` containing all arrays (nodes, extra, ident_bytes, ident_offsets, spans, decls). Buffer-copy `serialize`/`deserialize`.
- **Node overflow**: Nodes needing >2 values use `data1` as extra index.
- **Accessor functions**: `ast.blockItems(idx)`, `ast.varDeclValue(idx)`, `ast.ifData(idx)`, `ast.callArgs(idx)`, `ast.fnParams(idx)`, `ast.fnBody(idx)`, `ast.structFields(idx)`, `ast.structInitFields(idx)`, `ast.identOf(idx)`, etc.
- **Identifier interning**: `AstBuilder.internIdent()` copies to `ident_bytes`, records offset, uses `std.StringHashMap` during building (freed after seal).
- **Replace map types**: `std.AutoHashMap(usize, T)` → `std.AutoHashMap(ast.NodeIdx, T)`. Full sorted-array serialization is deferred.

### Serialization plan

All 5 stages must be cached with `hits=1 recomputes=0` when cache is present. The flat AST makes parse output inherently serializable (memcpy of `backing`). Stages 2-5 use buffer-copy serialization in `query_cache.zig`.

## Current status (May 2026)

- **ast.zig** ✅ — Flat AST with `serialize`/`deserialize` (buffer-copy), `verifyAt`/`entry`
- **parser.zig** ✅ — `AstBuilder`, `NodeIdx` returns, `verifyAt`/`entry` support
- **resolver.zig** ✅ — Flat AST, `NodeIdx` keys, deps: parse
- **typecheck.zig** ✅ — Flat AST, `NodeIdx`/`TypeIdx` keys, deps: resolve, parse
- **ir.zig** ✅ — Flat AST dispatch via `ast.nodes[idx].tag` and accessors, deps: typecheck
- **codegen.zig** ✅ — IR->x86 + ELF, backdate support, deps: lower
- **query.zig** ✅ — Generic `ensureMemo`, 5-stage pipeline, persistent cache load/save
- **query_cache.zig** ✅ — Buffer-copy ser/des for all 5 stages, persistent cache with schema v4
- **main.zig** ✅ — Updated for `?*const ast.Ast`, persistent cache CLI
- **test.zig** ✅ — All 43 tests pass using flat API
- **runtime.zig** — Unchanged
- **scope.zig** — Unchanged
- **helpers_bin.zig** — Unchanged

## Language notes

- Statements are newline-separated.
- `if`/`else` uses indentation-based blocks with inline `->` form supported.
- Fallible comparisons (`<`, `>`, `<=`, `>=`, `==`, `!=`) are only legal in `if` conditions.
- `const` and `var` bindings support optional type annotations.
- **No language string values** — string literals and `string` type annotations are rejected.
- **Struct types** — `comptime Name = struct` with indented field lines.
- **Struct init** — `TypeName{field1 = val1, field2 = val2, ...}`.
- **Field access** — `expr.fieldName`, multi-field structs use consecutive stack slots + `field_load` IR.

## Current behavior

- `zig run main.zig -- demo.chi` compiles and runs the demo.
- First non-debug CLI argument is source file path.
- Remaining CLI args are passed to generated `./prog` and accessible via `arg(n)`.
- Debug flags: `--debug=ast,ssa,timing,query`.
- Query cache is enabled by default for CLI path-backed sources (`setSourceFile`); disable with `--no-query-cache`.

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
  - persistent cache reuse/disable/failure/corruption/stale cleanup behavior
- Zero-recompute test: `compileResult` twice with no source change → 0 recomputes, 1 compile hit (compile is the only stage accessed on the second call; all others are implicitly cached).
- Current suite: `zig test test.zig` (43 tests).
