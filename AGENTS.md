# Working rules

Build clear, correct code with the least total machinery.

## Scope and design

- [syntax&semantics.txt](syntax&semantics.txt) is the incomplete language source of truth. Follow [ARCHITECTURE.md](ARCHITECTURE.md) for compiler/query boundaries and [ROADMAP.md](ROADMAP.md) for priorities. State any broader semantic interpretation before implementing it.
- Inspect ownership, dependencies, state transitions, failure paths, and nearby patterns before editing. Keep each diff to one coherent issue and preserve unrelated user changes.
- Choose the smallest complete solution. Avoid hypothetical variants, no-op branches, dispatch scaffolding, and abstractions without a current use.
- Before choosing a representation, enumerate the milestone's required shapes and separate independent semantic dimensions. Do not turn the first syntax shape or test case into a semantic kind. Generalize expression structure separately from operation typing; use type-specific operations after typing, without one-variant value unions or repeated type fields.
- Follow surrounding style and Zig 0.16 APIs; verify assumptions with the local compiler. Prefer fully qualified names except obvious shorthand such as AST.
- Keep switch arms at statement level. Move an arm with more than a few statements into a named function that owns the steps. Otherwise avoid single-use helpers that add indirection without clarity.

## Boundaries and invariants

- Classify each `null`, error, and diagnostic path as source error, missing/stale query state, or compiler invariant violation. Use assertions or `unreachable` for invariants, with one invariant per assertion.
- Validate facts at their owning boundary. Downstream stages trust IR and check only their capabilities and resource limits.
- Before adding special-case traversal, check whether the surrounding subtree is analyzed. Do not validate one construct inside an otherwise opaque subtree.
- Discard query results only for explicit validation or dependency purposes; express the purpose in code or a concise comment.

## Review

Before presenting changes, make two passes:

1. **Correctness:** ownership, error cleanup, pointer lifetimes, concurrency, invalidation, and state transitions.
2. **Cleanup:** reread the complete flow; simplify names, conditions, duplication, helpers, and temporary state. Attempt to delete machinery that exists only for an unsupported construct.

Use descriptive, positive booleans and direct conditions. Give each lifecycle transition one clearly named home. Make ownership transfers explicit and invalidate deinitialized values when it prevents reuse. Comments explain why; identify temporary architecture as temporary. Minimize total complexity, not local line count.

## Verification

- Test observable behavior, regressions, ownership, and incremental recomputation, not facts guaranteed by the type system.
- Use existing infrastructure. Keep large cross-module suites in `*_test.zig`, with test helpers for repeated setup, counters, and cleanup. Remove temporary scaffolding.
- Run focused tests, relevant regressions, formatting checks, and `git diff --check`. Commands live in [README.md](README.md).
- Update the document that owns a changed fact. Remove obsolete roadmap details instead of accumulating history or repeating language rules.
