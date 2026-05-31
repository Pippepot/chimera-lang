# TODO

**Local variables** (`var` mutation) — add assignment and mutable locals. `const` locals + multi-statement sequencing are implemented.

**`if const x = <expr> then ...`** — bind condition result in then-branch scope. Parsing + AST + typecheck infrastructure prepared in `.agents/fail-semantics.md`.

ASM debug view to compare with C code