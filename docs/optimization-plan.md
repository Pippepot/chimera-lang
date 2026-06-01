# Chimera optimization plan

## Benchmark: recursive fib(40)

Run `zig run main.zig -- bench.chi` compiles recursive Fibonacci with exit-code return.
Comparison against `gcc -O0` and `gcc -O2` (100 runs each, user time):

| Compiler | Time (100x) | Per call | vs -O0 | vs -O2 |
|----------|------------|----------|--------|--------|
| gcc -O0  | 69.6s      | 696ms    | 1.0x   | 4.9x   |
| Chimera  | 87.2s      | 872ms    | 1.25x  | 6.2x   |
| gcc -O2  | 14.1s      | 141ms    | 0.20x  | 1.0x   |

Binary sizes: Chimera 4917 bytes (ELF static), gcc -O0 16000 bytes (PIE dynamic).

*Note: Chimera `read`-mode parameter passes by pointer (default), `var`-mode by value.
The `var` mode adds more call overhead in the original code. After Phase 1
optimizations, `var` mode improved ~7% and `read` mode ~6%.*

## Assembly analysis (fib function)

**C -O0 fib** (73 bytes): compares against memory directly (`cmp [rbp-0x14], 1`), falls through
on failure with `jne`, keeps `n` in memory but avoids spills for return values, 24-byte frame.

**Chimera fib** (~100+ bytes): 256-byte frame (next_value × 8), loads constants through
stack slots, redundant store-load pairs around returns, dead block param copies,
indirect calls through `call rax`, pointer-dereference on every `read`-mode parameter use.

## Phase 1 — Low-hanging fruit (codegen-only)

### 1. Immediate operand fusion in comparisons

`emitCompareIntToEax` loads both operands from stack slots. When one operand is `iconst`,
emit `cmp reg, imm` directly instead of loading through the stack.

Adds `const_map` pre-pass in `emitFunction` that records which `ValueRef`s are `iconst`.
`emitCompareIntToEax` checks the map: if an operand is constant, uses `cmp eax, imm32`
instead of `mov ebx, [slot]; cmp eax, ebx`.

**Status:** ✅ Done
**Impact:** Minor (saves 1 load per comparison, ~6 bytes)

### 2. Remove redundant load on return for constants

`emitFunctionReturn` loads return value from a stack slot. When the value is a known `iconst`,
emits the constant directly. Saves 1 load per constant return (7 bytes).

**Status:** ✅ Done
**Impact:** Minor (saves 1 load per return)

### 3. Direct call via fn_map + skip fn_addr store for call-only uses

Every function call goes through a `fn_addr` instruction that stores the function address to a
stack slot, then loads it for an indirect `call rax`. Two optimizations:

a) Build `fn_map` in `emitFunction` recording which `ValueRef`s are `fn_addr`. In `.call`,
   if the callee is in the map, emit `call rel32` directly instead of loading from slot.

b) Track `fn_use_count` — if a `fn_addr` value is only referenced by `.call` instructions,
   skip emitting the `lea rax, [fn]; mov [slot], rax` entirely (the address is never stored).

**Status:** ✅ Done
**Impact:** ~5% on `var` mode fib (removes 2 instructions + 1 store + 1 load per call)

### 4. Binary arithmetic immediate fusion (not implemented)

`emitBinaryArithmeticInt` loads both operands from stack slots. Same `const_map` approach
could emit `add/sub/imul reg, imm` directly. More impactful for tight loops.

**Status:** 🔲 Todo

## Phase 2 — IR-level improvements

### 6. Unused block parameter elimination

If-else without else creates merge block params carrying unit values that are never read.
A `removeUnusedBlockParams` pass scans blocks post-lowering, detects unused params,
removes them (`param = null`, `param_width = 0`), and clears branch args in all
incoming terminators.

The codegen's `branchCopy` naturally skips null-param blocks (no slot copies emitted).

**Status:** ✅ Done
**Impact:** ~8% on `var` mode fib (eliminates dead `mov [slot]; mov [slot]; mov [slot]`
copy chains in pass-through blocks), zero on `read` mode (overhead is dominated by
pointer-dereference pattern).

### 7. Dead block folding

Pass-through blocks (L2→L3 that only contain a `br` to the next block) are folded:
incoming edges are redirected to the target, and the block is marked `dead` for
the codegen to skip. Currently only folds blocks with **zero instructions**
(empty block). Blocks with a dead `iconst 0` (from if-without-else lowering)
are not yet folded — requires `removeUnusedBlockParams` to work first.

**Status:** ✅ Done (empty blocks only)

### 8. Precise frame sizing

`frameSize` now uses `func.maxUsedValue()` instead of `func.next_value`.
`maxUsedValue()` scans instructions, block params, and param values for the max
`ValueRef` actually referenced. This catches small functions where `next_value` is
inflated by block params that were removed.

**Status:** ✅ Done
**Impact:** Fixes zero-frame allocation for trivial functions (monomorphized wrappers
with only a `ret`). General case has same frame as before since value_ref space is
sequential.

### 9. Block reordering for fall-through branches

Emit then-block immediately after its condition block so the fall-through path avoids an
unconditional jump. Requires a depth-first block order.

**Status:** 🔲 Todo

## Phase 3 — Advanced optimizations

### 10. Simple register allocation

Keep frequently used variables in registers instead of stack slots. Use a simple linear-scan
approach for hot values (function parameters, long-lived locals).

### 11. Constant folding at lowering

Fold `iconst 1 + iconst 2` → `iconst 3` in the IR lowerer before codegen.

### 12. Dead store elimination

Remove stores to slots that are overwritten before their next read.
