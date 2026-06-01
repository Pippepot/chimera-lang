# TODO

**Local variables** (`var` mutation) — add assignment and mutable locals. `const` locals + multi-statement sequencing are implemented.

**`if const x = <expr> then ...`** — bind condition result in then-branch scope. Parsing + AST + typecheck infrastructure prepared in `.agents/fail-semantics.md`.

## Optimization priorities (see docs/optimization-plan.md)

Phase 1 (codegen):
- [x] Immediate fusion in comparisons — `cmp reg, imm` instead of loading iconst to stack
- [x] Direct calls via fn_map — skip fn_addr store for call-only targets
- [ ] Binary arithmetic immediate fusion — `add/sub/mul reg, imm` for iconst operands

Phase 2 (IR):
- [x] Eliminate unused block parameters from if-without-else
- [x] Precise frame sizing via maxUsedValue
- [ ] Fold pass-through blocks
- [ ] Block reordering for fall-through branches

Phase 3 (advanced):
- [ ] Simple register allocation
- [ ] Constant folding at lowering
- [ ] Dead store elimination
