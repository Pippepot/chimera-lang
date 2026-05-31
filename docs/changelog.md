# Changelog

## 2026-05-31 — Variant `as` casts and `if` condition bindings

### Language surface

- Added **`as`** as a fallible variant cast: `value as Type`.
  - Succeeds when the variant tag matches `Type`.
  - Fails otherwise (usable only in fallible contexts, like `if` conditions).
- Added `if` condition binding form:
  - `if const x = value as Type`
  - `if var x = value as Type`
- Condition bindings are scoped to the **success branch only** (do not leak to `else` or outer scope).

### Compiler implementation

- Parser/AST:
  - Added `kw_as` token and `.as` AST node.
  - `parseIf` now accepts binding conditions (`if const/var ... = ...`).
- Resolver:
  - Resolves `as` LHS expressions.
  - Resolves bound name only within the `then` branch for condition bindings.
- Type analysis:
  - Added `inferAs` with diagnostics for non-variant LHS and non-member RHS.
  - Added condition-binding analysis that records binding type and enforces fallible RHS.
- Lowering:
  - Added runtime tag-check lowering for `as`.
  - For `if const/var name = v as T`, emits payload copy into a branch-local binding slot on success.

### Cache + tests

- Persistent cache compiler ABI version bumped to **6**.
- Added regression tests for:
  - `if const i = b as int` / `if const f = b as float` execution
  - success-branch-only scope of condition-bound names

## 2026-05-31 — Remove astgen stage, fold diagnostics into db.zig

### Pipeline simplification

- **Removed `astgen` stage entirely** from the query pipeline. The `astgen.zig` module (AstgenIr, computeAstgen, serializeAstgen/deserializeAstgen) is deleted. Type analysis (`computeAnalyze`) now depends directly on `resolve` instead of `astgen`.
- **Reduced pipeline from 6 to 5 stages:** `parse → resolve → typecheck → lower → compile`. All stage enums, memos, stats, diagnostics printing, timing, and persistent cache serialization updated accordingly.
- **Removed legacy `typecheck.zig`** (retained but unused) and `diagnostics.zig`. Diagnostics types (`Stage`, `Diagnostic`) and formatting (`appendDiagnostic`, `appendDiagnostics`, `lineInfoForOffset`, `highlightLen`) moved into `db.zig`.
- **Persistent cache schema version bumped** from 5 to 6 (astgen stage data removed from serialization format).

### Code quality

- **AST serialization:** `Ast.serialize` and `AstBuilder.seal` now use `Ast.computedSize` layout struct instead of manual offset arithmetic. `computedSize` made `pub`.
- **Codegen:** `emitLoadRegFromSlot`/`emitStoreRegToSlot` replaced switch-on-register with prefix lookup tables.
- **Debug:** `writeAstLabel` groups multi-tag cases into single pattern arms.
- **Parser:** `parseStructFields` extracted as shared helper used by both `parseComptimeStruct` and `parseStructExpr`. Local `alignForward` removed in favor of `computedSize`.
- **QueryDb:** Inlined memo/dep setup in `tryLoadPersistentCache` replaced with `loadMemo`, `depForSource`, `depForStage` helpers. `snapshotStage` refactored with `serializeStageValue` dispatch. Comments removed per convention.

## 2026-05-30 — String-language removal and naming cleanup

### Language surface

- Removed language-level string support:
  - string literals are rejected by the lexer/parser.
  - `string` type annotations are rejected as unknown type.
- Added regression tests to lock this behavior.

### Naming clarity

- Renamed AST identifier intern storage terminology:
  - `StringIdx` -> `IdentIdx`
  - `stringOf` -> `identOf`
  - `internString` -> `internIdent`
  - `string_bytes`/`string_offsets`/`string_map` -> `ident_bytes`/`ident_offsets`/`ident_map`
- Renamed IR symbol table terminology:
  - `StringId` -> `SymbolId`
  - `Program.strings` -> `Program.symbols`
  - `Program.stringFor` -> `Program.symbolFor`

## 2026-05-30 — Query pipeline adds explicit astgen stage

- Added `astgen` stage metrics and diagnostics output.
- `QueryDb` now stores/verifies/persists an `astgen` memo between resolve and type analysis.
- Active type analysis in the query pipeline is wired through `analyze.zig`.
- CLI timing output now includes `astgen`.
- Demo source (`demo.chi`) updated to Fibonacci example.

## 2026-05-30 — Error reporting & grammar fixes

### Error reporting (parser.zig)

- **Before:** `parseReport` called `parseSource`, which created the parser internally.
  When `parseProgram` failed, the original error token position was lost and the span
  was hardcoded to `(0,0)-(0,1)` — every parse error pointed to line 1, col 1.

- **After:** The parser is now created directly in `parseReport`. On failure, the
  current token's span is captured and reported, giving accurate line/column info
  and a caret pointing to the offending token. `parseSource` was removed.

### Grammar — comptime declarations anywhere (parser.zig, typecheck.zig, ir.zig)

- **Before:** `comptime` declarations were only accepted at the very top of a module,
  before any runtime statements. Mid-program `comptime` would hit
  `error.ExpectedExpression` with no hint about the real problem. If they somehow
  made it past parsing, `inferNode` and `lowerAst` would hit `unreachable`.

- **After:** `parseStatement` now dispatches `kw_comptime` to `parseDeclaration`
  and registers the result in `builder.decls`. `comptime_fn`/`comptime_struct`
  nodes in block items are handled by both the typechecker (return `.unit`) and
  the IR lowerer (emit unit value). Comptime declarations are now valid at any
  position in a module.
