# TODO

**Local variables** (`var` mutation) — add assignment and mutable locals. `const` locals + multi-statement sequencing are implemented.

**64-bit operations** — move AST from `i32` to `i64`, use `reg64` instead of `reg32` for arithmetic. `idiv` needs `cqo` instead of `cdq`.

**`if const x = <expr> then ...`** — bind condition result in then-branch scope. Parsing + AST + typecheck infrastructure prepared in `.agents/fail-semantics.md`.
