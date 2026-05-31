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
| `analyze.zig` | Active semantic analysis/type inference/comptime stage (`AnalyzedAst`) |
| `db.zig` | Shared query types/stats/deps/memo helpers + diagnostics formatting (was `diagnostics.zig`) |
| `ir.zig` | Flat AST dispatch via `ast.nodes[idx].tag` and accessors |
| `codegen.zig` | IR->x86 + ELF, backdate support, records `program_code_len` in ELF padding |
| `disasm.zig` | Pattern-based x86 disassembler (75-entry table), two-pass label collection, used by `--debug=asm` |
| `query.zig` | Generic `ensureMemo`, 5-stage pipeline, persistent cache load/save |
| `query_cache.zig` | Buffer-copy ser/des for all active stages, persistent cache |
| `debug.zig` | Flat AST dispatch, debug flag parsing (ast/ssa/asm/timing/query) |
| `runtime.zig` | Runtime helpers (`writeProgram`, `runProg`) — unchanged |
| `scope.zig` | Reusable lexical scope stack utility — unchanged |
| `helpers_bin.zig` | Embedded helper machine-code blobs — unchanged |
| `test.zig` | All tests pass using flat API |

## Query architecture

`QueryDb` stages (5-stage pipeline):

1. `parse(source_id)` -> `ParsedAst`
2. `resolve(source_id)` -> `ResolvedAst`
3. `typecheck(source_id)` -> `AnalyzedAst`
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

## Current status (June 2026)

- **ast.zig** ✅ — Flat AST with `serialize`/`deserialize` (buffer-copy), `struct_expr` tag, comptime mask in fn extra data
- **parser.zig** ✅ — `AstBuilder`, `NodeIdx` returns, comptime params, struct expressions, inline call struct init
- **resolver.zig** ✅ — Flat AST, `NodeIdx` keys, builtin type name resolution, deps: parse
- **analyze.zig** ✅ — Flat AST, `Type.type_type`, `ComptimeValue.type_value`, monomorphized struct type creation/lookup, comptime evaluator supports type_name/struct_expr
- **ir.zig** ✅ — Flat AST dispatch, `Type.type_type`, deps: analyze
- **codegen.zig** ✅ — IR->x86 + ELF, backdate support, `program_code_len` in ELF padding, deps: lower
- **disasm.zig** ✅ — Pattern-based x86 disassembler, 75-entry table, two-pass label resolution
- **query.zig** ✅ — Generic `ensureMemo`, 5-stage pipeline, persistent cache load/save
- **query_cache.zig** ✅ — Buffer-copy ser/des for all active stages, `type_type` and `type_value` serialization
- **main.zig** ✅ — CLI, persistent cache
- **test.zig** ✅ — All 70 tests pass including monomorphization, variant `is`/`as`, and caching tests

## Language notes

- Statements are newline-separated.
- `if`/`else` uses indentation-based blocks with inline `->` form supported.
- Fallible comparisons (`<`, `>`, `<=`, `>=`, `==`, `!=`) are only legal in `if` conditions.
- **Variant types** — compiletime type unions use `|` (e.g. `comptime T = int | float | Foo`).
- **`is` predicate** — fallible runtime variant tag check (`if x is int`).
- **`as` cast** — fallible runtime variant cast (`if const i = x as int`).
- **Condition binding scope** — names introduced by `if const/var name = ... as Type` are visible only in the success (`then`) branch.
- `const` and `var` bindings support optional type annotations.
- **No language string values** — string literals and `string` type annotations are rejected.
- **Struct types** — `comptime Name = struct` with indented field lines.
- **Struct init** — `TypeName{field1 = val1, field2 = val2, ...}`. Supports inline call-based init: `Wrapper(float){x = 3.0}`.
- **Field access** — `expr.fieldName`, multi-field structs use consecutive stack slots + `field_load` IR.
- **Comptime functions with type params** — `comptime Name = func(comptime T: type) type` with indented body. Comptime params support `type`, `int`, `float`, `bool` types. Functions with comptime params returning `type` are monomorphized: each unique call is independently evaluated at comptime, producing a concrete struct type.
- **Comptime functions with runtime params referencing comptime types** — `comptime foo = func(comptime T: type, x: T) body` monomorphizes per unique call, generating separate runtime functions (e.g., `foo$int`, `foo$float`). The comptime type param is in scope for subsequent param type annotations. Monomorphized entries are added to `AnalyzedAst.functions` dynamically (ArrayList), typechecked independently, and the IR lowerer resolves `var_ref` types from local bindings to handle shared AST nodes. See `inferMonomorphizedCall`, `call_monomorph_targets`, `FunctionInfo.is_monomorphized`.
- **Struct expressions** — `struct` followed by indented field lines creates a struct type in expression position (e.g., `return struct\n  x: T` inside a comptime function).
- **`type` metatype** — usable as parameter and return type annotations for comptime functions. Builtin type names (`int`, `float`, `bool`, `unit`, `type`) can be passed as comptime arguments.

## Current behavior

- `zig run main.zig -- demo.chi` compiles and runs the demo.
- First non-debug CLI argument is source file path.
- Remaining CLI args are passed to generated `./prog` and accessible via `arg(n)`.
- Debug flags: `--debug=ast,ssa,timing,query,asm`.
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
- Current suite: `zig test test.zig` (70 tests).
