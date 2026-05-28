# TODO

**Local variables** (`let`) — stack-allocated slots with `mov [rsp+offset], reg` / `mov reg, [rsp+offset]`. Reuses existing spill infrastructure. Unlocks multi-statement programs.

**64-bit operations** — move AST from `i32` to `i64`, use `reg64` instead of `reg32` for arithmetic. `idiv` needs `cqo` instead of `cdq`.

codegen Emitter.emitProgram and Emitter.finish can be combined into a single function as they are used only once the same place

