# Key-search compiler fixes

Implemented after the [assembly investigation](../key-gen-assembly/README.md).
The workload and checked language semantics are unchanged.

- Non-fallthrough conditional edge copies are outlined before register allocation.
  The common collision-scan path falls through instead of jumping over copies.
  Final relocation bypasses stubs whose copies coalesce away.
- Machine loop weights follow CFG cycles instead of physical backward spans, so
  cold edge stubs do not inflate register-allocation priorities.
- Valid array/allocation positions use zero extension. Loads can address directly
  with an allocated index when every definition clears its upper bits. Signed
  cursor offsets, wide definitions, spills, labels, and retained scratch values
  keep their required lowering.
- Inlining resumes after simplification frees capacity, retaining the original
  caller growth budget. This removes the two per-sum array accessor calls.
- Boolean joins, known edge arguments, shared exits, and conditional backedges
  simplify without speculating effects or inventing exit state. Loop rewrites
  resume after simplification exposes their containing loops.
- Inclusive unit-stride range proofs follow terminal joins and dominating order
  guards. Key-array bounds and counter-overflow checks disappear only where
  proved; unconditional terminal overflow and edited invalid bounds still panic.

The final common scan is six instructions, with one taken branch on the usual
noncollision path:

```asm
mov r9d, [rsp+r8*4+0x30e5c]
add r8d, 1
cmp r10d, r9d
je collision
cmp r8d, ebx
jl scan
```

The matched baseline has seven instructions and two taken branches on that path.
The generated executable shrinks from 30,152 to 22,979 bytes (23.8%). This is
assembly and size evidence, **not a fresh measured runtime speedup or a claim
that Chimera now beats Clang**. Runtime sampling was queued behind concurrent
builds/tests, then omitted when the user requested a prompt wrap-up. The earlier
binary-probe timing results remain historical evidence only.

Both Fast compilers and history drivers built successfully with Zig 0.17.0.
Fresh before/after/Clang executables pass prefix checks at indices 3–7 and 10,
plus missing and invalid input checks; see [correctness.json](correctness.json).
These correctness runs were not used for timing.

The source comparison uses revision
`e11253e28acb40f60845f0226007e011d576e7a8` plus only the nine compiler files and
two test files in [compiler-change.patch](compiler-change.patch). This isolates
unrelated frontend work in the shared checkout. Both snapshots share the
[build-only patch](build-only.patch), which adds a step to install tools without
running benchmarks; its unused provenance benchmark registration is common too.
Full source hashes are retained for [before](before-source-final-files.json) and
[after](after-source-final-files.json), with toolchains and executable hashes in
[environment.json](environment.json).

Regression coverage includes edge-copy fallthrough and coalescing, all allocated
index registers and fallbacks, reversed/empty ranges, conditional exits, guarded
bounds with incremental invalidation, final overflow, and fixed inlining growth.
The focused Safe [codegen](codegen-tests.txt), [optimizer](optimizer-tests.txt),
and [iteration](iteration-tests.txt) suites pass for the final source state.
Formatting and diff checks pass. The full Safe run was stopped during the List
suite for the requested quick wrap-up; a complete full-suite pass is not claimed.
The separate initializer-capture buffer fix in the current frontend passed
[29 focused tests](frontend-init-capture.txt).

Frozen source trees, release tools, complete disassembly, and measurement scripts
remain in `/tmp/chimera-key-fix-e3281m6h`. After project builds/tests are idle,
`python3 /tmp/chimera-key-fix-e3281m6h/measure_runtime.py` performs the existing
adaptive index-10 protocol on CPU 4. The follow-up script collects hardware
counters, sieve runtime, and cold/leaf-edit compilation measurements separately.
