# Working rules

Build clear, correct code with the least total machinery.

## Design

- [syntax&semantics.txt](syntax&semantics.txt) is the incomplete language source of truth; [ARCHITECTURE.md](ARCHITECTURE.md) owns compiler/query boundaries and [ROADMAP.md](ROADMAP.md) owns priorities. State broader semantic interpretations before implementing them.
- Solve the whole problem, not just the symptom. When a clean implementation needs stronger foundations, consider a focused change that also supports future work.
- Model all required shapes and independent semantic dimensions, not just the first syntax case. Keep expression structure separate from operation typing; avoid one-variant unions and redundant type fields.
- Use Zig 0.16 APIs, verified with the local compiler. Prefer fully qualified names except familiar shorthand such as AST.
- Keep switch arms at statement level; extract substantial arms into named functions.

## Boundaries and invariants

- Distinguish source errors, missing/stale query state, and compiler invariant violations. Use assertions or `unreachable` for invariants, one invariant per assertion.
- Validate facts at their owning boundary. Downstream stages trust IR and check only capabilities and resource limits.
- Do not selectively validate constructs inside otherwise unanalyzed subtrees.
- Discard query results only for validation or dependency tracking; make the purpose explicit.

## Verification

- Test behavior, ownership, and incremental recomputation, not type-system guarantees. Keep large cross-module suites in `*_test.zig`.
- Use [docs/COMPILER.md](docs/COMPILER.md) for test commands; run relevant tests, formatting checks, and `git diff --check`.
- Update the document that owns a changed fact; replace obsolete roadmap details rather than accumulating history.
