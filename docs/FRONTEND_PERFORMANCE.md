# Frontend compilation measurements

This experiment addresses the immediate frontend priority in ROADMAP.md against
`b6c86c322bf6d23c53f6ecf37a29f2cb43347e3c`. It changes body construction scratch
storage, reference resolution, and flow snapshot comparisons, with no language,
workload, optimizer, or machine-stage changes.

## Attribution and choice

The existing phase collector separates exclusive worker elapsed time from nested
queries and dependency waits. Cold builds and fresh leaf edits use the same
million-line workload as acceptance. Serial attribution precedes eight-worker
attribution on the same CPU set. These measurements include profiler overhead
and are diagnostic evidence only.

A separate [10,000-line typing probe](frontend-performance/typing-probe.txt) adds
temporary nested scopes to the baseline's typing helpers. It measures general
call preparation at 7.896 ms exclusive, reference processing at 10.585 ms, and
operation target lookup at 6.192 ms. The reference group covers resolution,
transformation, reads, root advancement, and call effects. Nested inference,
flow, ownership, and type-fact scopes are charged separately. Probe clocks and
collection affect small helpers, so these figures rank work for investigation;
they are not acceptance timings or additive projections of uninstrumented time.
The temporary scopes are absent from the production compiler.

Inspection of these paths and their consumers found repeated work in four places:

- General call preparation separately allocated argument places, reference
  origins, contract sources, and IR operands. They have identical lifetimes and
  fixed counts. One exact-capacity `MultiArrayList` now supplies their separate
  field slices, preserving contiguous operand publication and argument order.
- Flow buffer equality and merge already establish matching lengths. An
  identical persistent root proves that every page is shared, so those operations
  now skip repeated page walks. Length remains an independent property, including
  when a snapshot grows without allocating new pages.
- Origin expansion uses the input set's uniqueness before a loop can introduce
  overlap. It appends that concrete prefix without redundant duplicate searches,
  reuses a concrete leaf when it is the entire result, and retains ordinary set
  insertion after a loop. Recursive expansion returns its result directly.
  Multi-origin traversal order, cycle detection, current loop summaries, and
  incomplete-state reporting remain unchanged.
- An access that preserves its binding identity reuses the already resolved
  identity, including conflicting and incomplete facts. Other accesses retain
  the original pair of resolutions and avoid an additional equality check.
  No new cache or cached loop-completeness fact was added.

An initial attempt to share every concrete origin list was rejected after
single-core trials reproduced a slowdown in refinement-heavy functions. The
accepted approach keeps the original traversal order and removes redundant work
inside expansion instead of adding a separate traversal. Its regression checks
include overlapping concrete and loop inputs.

The phase profile also exposes body finalization and setup/publication costs.
Those costs, parsing, and initial type-fact computations do not warrant a new
cache or invalidation scheme ahead of typing. A leaf edit demands only one typed
body. Its remaining query orchestration, dependency validation, and executable
linking cost should not be represented as frontend reanalysis.

## Measurement boundaries

Both snapshots use the identical current history driver, generator, sampler, Zig
0.17.0 ReleaseFast/LLVM settings, embedded std configuration, and whole-program
CPU affinity `0-7` on an Intel Core Ultra 7 265K. These are eight physical performance cores;
serial and eight-worker lanes use the same allowed set. Each snapshot uses its
own precompiled std artifact. Builds, tests, profiling, and timed runs execute
serially, with default Zig caches. The snapshots differ only in compiler source;
the benchmark driver changes enable optional profiling and leave the ordinary
workload and timers intact. Separate backend, optimizer, and test edits appeared in
the shared checkout during the work. Performance snapshots exclude those edits:
the baseline archive receives only the frontend files and common driver. Their
results therefore attribute the frontend change independently of machine-stage
work.

Uninstrumented runs follow the [adaptive protocol](../benchmarks/README.md#measurement-protocol):
one discarded warmup, two or three cold/edit samples per lane, and up to five
runtime samples. Every cold program returns 42. Each edit advances to a fresh
leaf value and its expected exit status; it does not alternate cached values.
Runtime validates bounds 2, 10, 100, and 1,000 before warmup and the measured
88-million sieve. C comparisons are omitted because this experiment compares the
same generated runtime across compiler snapshots.

The focused flow driver is additional evidence, not a replacement for these
whole-program measurements. Its five fresh one-worker databases per row exclude
semantic construction, code generation, and body teardown. A separate database
collects retained flow storage. Six alternating before/after pairs pin this
focused comparison to CPU 2; the table uses the median of their row medians.

To reproduce, archive the baseline into a separate temporary directory and copy
only the current `benchmarks/history_benchmark.zig` driver into that snapshot.
Run the following in each tree, one command at a time, preserving both outputs:

```sh
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --workers=0
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --workers=8
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=sieve-88000000 --skip-c
taskset -c 2 zig build flow-benchmark --seed=0 -Doptimize=fast -j1
```

Run compilation attribution separately with `--profile` instead of a sample
count. Instrumented output is stderr-only and cannot become history timing CSV.
The [environment manifest](frontend-performance/environment.json) records source
and driver hashes, toolchain, affinity, and protocol identities. The source hash
covers sorted Zig files under `src/`, all files under `std/`, and the build files,
with paths and contents separated by NUL bytes. Untracked measurement outputs and
this report are excluded.

## Uninstrumented results

All times are milliseconds. Each cell is the median of its retained samples.
Positive changes are slower; stability flags and the complete ranges remain in
the linked CSV files.

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| Cold, zero workers | 19891.901 | 19583.082 | -1.55% |
| Fresh leaf edit, zero workers | 134.710 | 132.152 | -1.90% |
| Cold, eight workers | 11748.941 | 11664.930 | -0.72% |
| Fresh leaf edit, eight workers | 163.957 | 162.293 | -1.01% |
| Generated sieve runtime | 619.211 | 613.881 | -0.86% |

Raw compilation samples: [before/zero](frontend-performance/before-0.csv), [after/zero](frontend-performance/final-0.csv), [before/eight](frontend-performance/before-8.csv), [after/eight](frontend-performance/final-8.csv). Runtime: [before](frontend-performance/before-runtime.csv), [after](frontend-performance/final-runtime.csv).

The sieve executables are **byte-identical**, 19,059 bytes, SHA-256
`2c74a45e17aae3100d09d2f40579f7acd3015fcfd15d72208424218edf92ffff`. Runtime timing differences therefore describe
process and machine variation rather than different generated instructions.
Both snapshots also produce 121,178,993-byte executables for the million-line workload.

Sample ranges and repeatability:

| Lane / phase | Before range | After range | Before stable | After stable |
| --- | ---: | ---: | --- | --- |
| 0 / cold | 19878.944–19904.858 | 19554.192–19611.972 | true | true |
| 0 / leaf-edit | 134.579–134.842 | 131.515–135.461 | true | false |
| 8 / cold | 11701.714–11796.167 | 11597.861–11731.998 | true | true |
| 8 / leaf-edit | 163.267–167.850 | 161.551–165.256 | false | false |
| runtime / runtime | 616.454–621.968 | 613.477–614.285 | true | true |

### Focused flow checks

All sizes below use the median of six alternating trials, each row containing
five fresh databases. Three confirmation pairs followed the initial three to
investigate noisy small cases; all six are included without dropping outliers.
The ranges span row medians across trials.

before: [1](frontend-performance/flow-before-1.csv), [2](frontend-performance/flow-before-2.csv), [3](frontend-performance/flow-before-3.csv), [4](frontend-performance/flow-before-4.csv), [5](frontend-performance/flow-before-5.csv), [6](frontend-performance/flow-before-6.csv).

final: [1](frontend-performance/flow-final-1.csv), [2](frontend-performance/flow-final-2.csv), [3](frontend-performance/flow-final-3.csv), [4](frontend-performance/flow-final-4.csv), [5](frontend-performance/flow-final-5.csv), [6](frontend-performance/flow-final-6.csv).

| Case / branches | Before | After | Change | Before range | After range |
| --- | ---: | ---: | ---: | ---: | ---: |
| scalar / 8 | 0.114 | 0.116 | +2.25% | 0.111–0.263 | 0.103–0.198 |
| scalar / 32 | 0.399 | 0.384 | -3.91% | 0.392–0.425 | 0.371–0.389 |
| scalar / 128 | 1.595 | 1.456 | -8.70% | 1.397–1.659 | 1.380–1.542 |
| scalar / 256 | 2.944 | 2.867 | -2.64% | 2.706–3.240 | 2.650–3.080 |
| scalar / 512 | 5.660 | 5.652 | -0.15% | 5.472–6.355 | 5.518–5.753 |
| owning / 8 | 0.265 | 0.261 | -1.65% | 0.255–0.275 | 0.250–0.276 |
| owning / 32 | 0.718 | 0.714 | -0.57% | 0.696–0.783 | 0.690–0.728 |
| owning / 128 | 3.081 | 3.103 | +0.74% | 2.717–3.644 | 2.945–3.458 |
| owning / 256 | 7.143 | 7.406 | +3.68% | 6.729–7.796 | 7.074–7.825 |
| owning / 512 | 21.651 | 21.523 | -0.59% | 20.646–22.948 | 20.265–22.525 |
| narrowing / 8 | 0.441 | 0.423 | -4.09% | 0.378–0.480 | 0.389–0.437 |
| narrowing / 32 | 2.047 | 1.926 | -5.89% | 1.850–2.146 | 1.756–2.020 |
| narrowing / 128 | 14.910 | 14.556 | -2.37% | 14.058–15.328 | 13.822–14.798 |
| narrowing / 256 | 45.614 | 46.079 | +1.02% | 45.021–47.043 | 44.623–47.940 |
| narrowing / 512 | 163.939 | 164.528 | +0.36% | 159.947–167.644 | 161.344–165.439 |
| backedges / 8 | 0.570 | 0.534 | -6.38% | 0.517–0.580 | 0.430–0.570 |
| backedges / 32 | 3.601 | 3.486 | -3.19% | 3.447–3.780 | 3.164–3.780 |
| backedges / 128 | 34.464 | 31.846 | -7.60% | 32.939–35.336 | 30.592–33.107 |
| backedges / 256 | 125.908 | 119.024 | -5.47% | 123.918–130.232 | 117.042–123.078 |
| backedges / 512 | 594.755 | 561.290 | -5.63% | 584.887–600.637 | 553.242–564.063 |

The small positive rows above overlap the observed timing ranges. The initial
owning/eight and backedges/32 increases reversed in the additional pairs. The
remaining owning/256 increase prompted a separate confirmation: the identical
flow driver with only its main loop changed to repeat that case 32 times per
process. Six alternating before/after pairs use CPU 2 and fresh databases, with
all rows retained. The [driver patch](frontend-performance/owning-confirmation.patch)
and its hash in the environment manifest identify this diagnostic.

| Owning/256 confirmation pair | Before | After |
| --- | ---: | ---: |
| 1 | 7.035 | 7.149 |
| 2 | 7.069 | 7.094 |
| 3 | 7.228 | 7.591 |
| 4 | 7.222 | 7.229 |
| 5 | 7.203 | 7.223 |
| 6 | 7.217 | 7.049 |

The median of process medians is **7.210 → 7.186 ms (-0.33%)**.
This does not reproduce the broad driver's +3.68% owning/256 result; treat this
case as unchanged within observed variation.

before: [1](frontend-performance/owning-confirmation-before-1.csv), [2](frontend-performance/owning-confirmation-before-2.csv), [3](frontend-performance/owning-confirmation-before-3.csv), [4](frontend-performance/owning-confirmation-before-4.csv), [5](frontend-performance/owning-confirmation-before-5.csv), [6](frontend-performance/owning-confirmation-before-6.csv).

final: [1](frontend-performance/owning-confirmation-final-1.csv), [2](frontend-performance/owning-confirmation-final-2.csv), [3](frontend-performance/owning-confirmation-final-3.csv), [4](frontend-performance/owning-confirmation-final-4.csv), [5](frontend-performance/owning-confirmation-final-5.csv), [6](frontend-performance/owning-confirmation-final-6.csv).

All retained flow storage and graph counters are unchanged for every paired row.
This includes snapshot bytes, lifetime storage, flow facts, places, predicates,
and inference-key storage. These counters do not measure process RSS or total
allocation traffic.

## Phase attribution

Counters below are exclusive worker elapsed milliseconds from separate profiling
runs. Eight-worker totals are sums across workers, not wall time or CPU time.

| Phase | Before, zero | After, zero | Before, eight | After, eight |
| --- | ---: | ---: | ---: | ---: |
| Parsing | 186.833 | 191.577 | 205.771 | 203.981 |
| Body construction | 503.223 | 511.340 | 1057.822 | 1049.761 |
| Typing / SSA | 5105.464 | 4976.779 | 8617.765 | 8355.696 |
| Lifetime / cleanup | 666.263 | 646.653 | 1038.810 | 992.813 |
| IR finalization | 97.626 | 97.402 | 106.366 | 104.108 |
| Body setup / publication | 149.788 | 145.700 | 348.885 | 350.418 |
| Type-fact computations | 0.342 | 0.240 | 1.664 | 1.334 |
| Optimization (all parts) | 11747.136 | 12136.768 | 13377.033 | 13480.911 |
| Code generation | 956.760 | 1009.619 | 3998.450 | 4022.967 |
| Other query work | 241.170 | 270.360 | 343.143 | 353.207 |
| Dependency waits | 58.958 | 58.473 | 2948.060 | 2746.715 |

Full attribution: [before/zero](frontend-performance/profile-before-0.txt), [after/zero](frontend-performance/profile-final-0.txt), [before/eight](frontend-performance/profile-before-8.txt), [after/eight](frontend-performance/profile-final-8.txt). The leaf-edit sections show the unchanged one-body demand separately from dependency waits and linking/orchestration.

Typing accounts for about 5.1 seconds of serial baseline work and 8.6 summed
worker seconds with eight workers. The corresponding after counters are 2.5%
and 3.0% lower. Both snapshots demand 38,575 typed bodies on a cold build and
one on a fresh leaf edit. The small type-fact computation counters do not include
all accesses to already available facts. These single instrumented runs also
vary in unchanged phases; use the uninstrumented samples for acceptance.

The matched uninstrumented measurements show no regression in cold builds,
fresh leaf edits, or generated runtime. Leaf-edit samples remain noisy at their
protocol cap, and the eight-worker cold change is small. The focused evidence
supports the loop-heavy improvement; scalar, owning, and narrowing totals vary,
so their small differences should not be advertised as established speedups.

## Correctness and ownership

The shared routine Safe run used
`zig build test --seed=0 -Doptimize=safe -j1 --summary all` against the
combined checkout, including the separate backend and optimizer edits.
All **52/52 steps succeeded**:
**2,158 tests passed and 24 skipped**. The
[complete log](frontend-performance/safe-tests.txt) and
[source hashes](frontend-performance/safe-source.json) identify that verification.
The frozen frontend source remained unchanged through the run. The logged allocation
panics are expected negative-test output, not failing tests.

The focused origin regression covers storage reuse, traversal order, overlapping
concrete/loop dependencies, incomplete cycles, and changed loop summaries. The
flow-buffer regression checks distinct logical lengths sharing the same root.
Existing suites cover native/interpreter behavior, diagnostics, cleanup and
ownership, incremental recomputation, and cache restoration.

The benchmark recorder's **41 Python tests** and three invalid profiling-argument
cases pass. Modified Zig files pass `zig fmt --check`; `git diff --check` passes.
Exhaustive allocation-failure sweeps were not requested or run.
