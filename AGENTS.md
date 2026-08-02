# AGENTS.md

## Goal

Build clear, correct code with the least total machinery.

## Working principles

- Change one coherent issue at a time and keep the diff narrowly scoped.
- Before editing, inspect the surrounding ownership, dependencies, state transitions, and failure paths.
- Preserve unrelated user changes and avoid cleanup outside the requested scope.
- Prefer the smallest complete solution. Do not add abstractions for hypothetical future needs.
- Avoid a helper used only once when it adds indirection without meaningful clarity.
- Follow the style of the file being edited. Prefer fully qualified names except for obvious shorthand such as AST.
- Look for nearby patterns and reusable functionality before creating a new implementation.
- Follow the Zig 0.16 APIs used by nearby code and verify assumptions with the local compiler.
- For changes to compiler or query boundaries, follow `ARCHITECTURE.md`.

## Scope and invariants

- Do not strengthen a semantic rule beyond the user's explicit wording without first stating the broader interpretation.
- Before adding special-case traversal, check whether the surrounding subtree is otherwise semantically analyzed. Do not validate one construct inside an otherwise opaque subtree.
- Classify every `null`, error, and diagnostic branch as an expected user error, stale or missing query state, or compiler invariant violation.
- Represent compiler invariant violations with assertions or `unreachable`, never user diagnostics.
- Put one invariant in each assertion so a failure identifies the violated condition.
- A discarded query result must have an explicit validation or dependency purpose. Express that purpose directly in code or a concise comment.
- During cleanup, identify machinery added for only one unsupported construct and attempt to delete it.

## Implementation review

Before presenting an implementation, perform two passes:

1. Correctness: check ownership, error cleanup, pointer lifetimes, concurrency, cache invalidation, and state transitions.
2. Cleanup: reread the complete flow and simplify names, conditions, duplication, helpers, and temporary state.

During cleanup:

- Prefer descriptive, positive boolean names and direct conditions.
- Represent each lifecycle transition in one clearly named place.
- Optimize for minimum total complexity, not minimum local line count.
- Comments explain why an invariant or instruction exists, not merely what the code says.
- Make ownership transfers explicit and invalidate deinitialized values when that prevents accidental reuse.
- Identify temporary architecture explicitly instead of presenting it as final.

## Testing

- Add tests for observable behavior, regressions, ownership, and incremental recomputation.
- Do not add tests for declarations or constraints already guaranteed by the type system.
- Prefer existing test infrastructure; temporary verification scaffolding must not remain in the repository.
- Keep large cross-module suites in dedicated `*_test.zig` files and hide repeated setup, counters, and cleanup behind test-focused helpers.
- Run the focused suite, relevant regressions, formatting, and `git diff --check`.
