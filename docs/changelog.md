# Changelog

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
