# TODO

**Local variables** (`var` mutation) — add assignment and mutable locals. `const` locals + multi-statement sequencing are implemented.

**64-bit operations** — move AST from `i32` to `i64`, use `reg64` instead of `reg32` for arithmetic. `idiv` needs `cqo` instead of `cdq`.

**Real source input** — replace `demoSource(...)` path with CLI input modes (`--expr`, `--file`) so `main.zig` compiles user-provided source text.

**Parser error locations** — include line/column/span in parser diagnostics and surface them cleanly from `main.zig`.
