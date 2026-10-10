# Working rules

Build clear, correct code with the least total machinery.

## Design

- [syntax&semantics.txt](syntax&semantics.txt) is the incomplete language source of truth; [ARCHITECTURE.md](ARCHITECTURE.md) owns compiler/query boundaries and [ROADMAP.md](ROADMAP.md) owns priorities. State broader semantic interpretations before implementing them.
- Solve the whole problem, not just the symptom. When a clean implementation needs stronger foundations, consider a focused change that also supports future work.
- For simplification work, inspect the complete lifecycle and its consumers before choosing an abstraction. Look for stronger invariants that eliminate repair passes and repeated special cases.
- Model all required shapes and independent semantic dimensions, not just the first syntax case. Keep expression structure separate from operation typing; avoid one-variant unions and redundant type fields.
- Use Zig 0.17 APIs, verified with the local compiler. Prefer fully qualified names except familiar shorthand such as AST.
- Keep switch arms at statement level; extract substantial arms into named functions.

## Boundaries and invariants

- Distinguish source errors, missing/stale query state, and compiler invariant violations. Use assertions or `unreachable` for invariants, one invariant per assertion.
- Validate facts at their owning boundary. Downstream stages trust IR and check only capabilities and resource limits.
- Do not selectively validate constructs inside otherwise unanalyzed subtrees.
- Discard query results only for validation or dependency tracking; make the purpose explicit.

## Verification

- Test behavior, ownership, and incremental recomputation, not type-system guarantees. Keep large cross-module suites in `*_test.zig`.
- Use [docs/COMPILER.md](docs/COMPILER.md) for test commands; run relevant tests, formatting checks, and `git diff --check`.
- Batch related edits before focused checks. Verify isolated changes with affected suites; run the routine suite once for changes spanning stages or shared representations. Documentation-only edits need no compiler tests.
- Exhaustive allocation-failure sweeps are opt-in backup checks. Do not enable `-Dallocation-failures=true` unless explicitly requested; ordinary failure-path tests remain part of routine verification.
- Use default caches and fixed `--seed=0`. Repeat passing checks only for relevant changes or unresolved concerns. Collaborating agents share results for the same source state; one agent owns the final full-suite run.
- Update the document that owns a changed fact; replace obsolete roadmap details rather than accumulating history.
