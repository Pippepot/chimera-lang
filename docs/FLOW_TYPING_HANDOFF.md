# Flow typing: implementation status and remaining acceptance

The compiler and source migration are implemented. **Final acceptance remains
unfinished.** Routine Safe verification is complete. The historical pre-flow
performance comparison below still needs a matched follow-up; the separate
[frontend compilation experiment](FRONTEND_PERFORMANCE.md) compares the current
engineering change against its immediate baseline.

## Implemented

Flow facts refine reads of existing places while declared storage types,
physical layouts, and ownership permissions remain fixed. Logical payload types
are separate from stored owned/reference alternatives. Reads, references,
assignments, transfers, and cleanup all project the original representation;
subset variant values use explicit repacking destinations in native code and
the interpreter.

Facts track aliases, mutation versions, saved bool implications, and proof
ancestry through joins. Bound references retain proof identity for dynamic
selections; independent selections receive no inherited proof. Loop backedges
must preserve entry proofs actually used by the body. Independent retests start
new proofs. Type discovery captures immutable flow snapshots and reads metadata
without executing argument effects early.

Cleanup generations retain sparse stored-member restrictions and missing paths
through field and variant projections. Owning field transfers preserve remaining
obligations. Immutable owners also carry generations through loops because their
cleanup shape can change. Nominal hooks remain authoritative. Reference lifetime
validation distinguishes allocation contents from an enclosing slot or variant
carrier. No lifetime assertions were suppressed.

Lost-proof diagnostics identify the establishing guard and invalidating write or
backedge. Diagnostic notes have content equality across query recomputations.
An initializer-inlining fix keeps a selected region header stable when the region
table grows. Source fixtures were repaired for removed bindings, generated layout,
stale edit needles, ownership intent, and static-value materialization.

Colon is an ordinary annotation. Annotation-based conditional/checked bindings
and typed match captures are removed. Checked structural List/Span length
patterns remain. The [specification](../syntax&semantics.txt) and
[architecture](../ARCHITECTURE.md) describe the current rules and boundaries.

## Verification evidence

The routine command
`zig build test --seed=0 -Doptimize=safe -j1 --summary all` passes on the frontend
follow-up source: **52/52 steps successful: 2,158 tests passed, 24 skipped**. This includes the
final identity traversal, native/interpreter flow regressions, ownership,
diagnostics, incremental recomputation, and cache restoration. The previous
annotation fixture failure is resolved. The traversal visits each shared join
once and avoids allocating traversal storage for simple identity chains.

The focused concrete-origin/loop-summary storage regression also passes.
Modified Zig files pass formatting checks and `git diff --check` passes.
Exhaustive allocation-failure sweeps were not requested or run.

This completes Safe verification; it does not replace the pre-flow performance
acceptance comparison described below.

## Completed typing measurements

The old handoff's baseline object `a3c235c76e6e00fe2fe3b1d8ec6f8f621e65f872`
is unavailable in this repository. These measurements instead use the accessible
pre-flow parent **b3d46674a72b63d29a1a823521fb3ca1b9b79bb7**. The scalar and
owning generated sources are unchanged between those revisions.

Zig 0.17.0, Fast/LLVM, CPU 2 affinity, one database worker, seed 0, serialized
runs. Each trial reports the median of five fresh databases per row, followed by
one separate instrumented database. The table below takes the median of three
trials. These are typing timings, not whole-program compilation or runtime.

| 512-branch workload | Parent | Current | Change |
| --- | ---: | ---: | ---: |
| Scalar, no narrowing | 4.677 ms | 5.305 ms | +13.4% |
| Owning, no narrowing | 19.201 ms | 20.727 ms | +7.9% |
| Narrowing, aliases, loops | unavailable | 354.513 ms | new workload |

Scalar/owning snapshot payloads grew from **3,454,981 to 3,774,741 bytes** (+9.3%).
The 512-branch narrowing workload retains **122,526,909 snapshot bytes**, plus
122,880 fact bytes, 49,184 place/path/key bytes, 16,384 predicate bytes, and 14,336
inference-key bytes. Its snapshot growth deserves review before acceptance.
Counts exclude map capacity, arena overhead, and allocation traffic; see the
[measurement boundaries](../benchmarks/README.md#focused-drivers).

Raw trials: [parent](flow-typing/typing-parent.csv),
[current](flow-typing/typing-final.csv).
[Environment and source fingerprint](flow-typing/measurement-environment.json)
record the measured source state and driver hashes. The interrupted profiling
attempt was discarded; none of its timings appear in these files.

The common `loc.sh --json` policy reports code lines **35,085 → 36,013** and test
lines **46,908 → 51,268**. Raw counts:
[parent](flow-typing/loc-parent.json), [current](flow-typing/loc-final.json).

## Remaining work, in order

1. **Review performance acceptance.** Investigate the measured scalar/owning
   regressions and refinement-heavy snapshot growth. The exponential shared-join
   traversal was fixed. The frontend experiment compares against the immediate
   baseline, not the historical pre-flow parent. Recheck that parent under matched
   settings before accepting the original regressions or snapshot growth.
2. **Complete matched compilation and runtime measurements.** Use temporary source
   copies of the parent and current tree. Copy the current
   `benchmarks/history_workload.zig` into both, then apply
   [the common-workload patch](flow-typing/common-workload.patch) in both copies.
   This keeps generated compilation inputs byte-identical and valid for both
   syntax versions. Run serially with the same affinity and settings:
   ```sh
   taskset -c 2 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --lines=10000 --samples=3 --workers=0
   taskset -c 2 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=sieve-88000000 --samples=3 --skip-c
   ```
   Runtime drivers retain the same sieve algorithm and output validation, with
   syntax migration between revisions. Preserve that distinction in the report.
   Reproduce typing with three serial runs of
   `taskset -c 2 zig build flow-benchmark --seed=0 -Doptimize=fast -j1` per tree.
3. **Close the status documents only after acceptance.** Replace this pending
   acceptance status in README and ROADMAP after checks and measurements pass.

Optional local copies remain at `/tmp/chimera-flow-baseline` and
`/tmp/chimera-flow-final-measure`; they are conveniences, not repository
dependencies. The latter contains the common compilation generator. The recorded
code fingerprint hashes sorted paths and bytes under `src/` and `std/`, plus
`build.zig` and `build.zig.zon`, with NUL separators. Do not run measurements
concurrently with builds or tests. Allocation-failure sweeps remain opt-in.
