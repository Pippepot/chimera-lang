# Benchmarks

Run commands from the repository root with Zig 0.17. Keep source snapshots,
optimization modes, workloads, worker counts, and machines matched. Do not run
timed benchmarks concurrently with builds, tests, or other benchmarks. Pinning
helps repeatability but does not remove frequency, thermal, or system-load noise.
Compiler timings, generated-program runtime, retained memory, and code size are
different measurements; none substitutes for another.

All measured C references use `clang` explicitly at `-O0` and `-O3`; install
Clang on `PATH`. Compiler path/version are part of reference-cache identity.

## Five-Face Key Search

The standalone [five-face key search](key-gen-face-five/README.md) compares
matching Chimera and C workloads:

```sh
python3 benchmarks/key-gen-face-five/run.py --cpu 4
```

## Array Sorting

The standalone [array-sort comparison](array-sort/README.md) benchmarks Chimera's
`Array.sort()` against Clang C++ `std::sort` and `std::stable_sort` at `-O3`:

```sh
python3 benchmarks/array-sort/run.py --cpu 4
```

It checks matching signed 32-bit inputs across five distributions and reports
whole-process timings for repeated fill/sort/verification batches, including
medians, ranges, and raw samples. See the benchmark guide for timing boundaries.

## Recording Results

The focused [provenance benchmark](results/provenance/README.md) measures cold
compilation, incremental alternative/effect contract edits, and generated runtime:

```sh
zig build provenance-benchmark --seed=0 -j1
zig build provenance-benchmark --seed=0 -j1 -- --shape=serial --size=32
```

[history.py](history.py) records exact snapshots and updates the static report at
`.history/index.html`. It requires Linux, Python 3.12+, Git, Zig, Clang, and Matplotlib:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r benchmarks/requirements.txt
source .venv/bin/activate
python3 benchmarks/history.py --worktree
python3 benchmarks/history.py HEAD
python3 benchmarks/history.py <commit> --cpu 4
```

`--worktree` copies tracked and nonignored untracked files into a temporary
snapshot and fingerprints paths, modes, and contents. Commit arguments use
`git archive`. Neither mode changes the checkout or creates commits. Results
and reports are ignored by Git. Use `--data-dir PATH` for a durable or shared
store; reports otherwise use `.history/`.

```sh
python3 benchmarks/history.py --backfill-loc
python3 benchmarks/history.py --backfill-benchmarks --cpu 4
python3 benchmarks/history.py <commit> --loc-only
python3 benchmarks/history.py --render-only
python3 benchmarks/history.py --worktree --cpu 4 --refresh-c
python3 -m unittest discover -s benchmarks -p history_test.py -v
zig build history-benchmark --seed=0 -j1
```

LOC backfill is resumable and needs no compiler builds. It applies
the current [loc.sh](../loc.sh) policy to each revision, excluding
build/benchmark drivers, comments, blank lines, and std.
The graph plots production LOC; raw records retain test and total counts.

Reports follow the selected revision's first-parent ancestry. The horizontal
axis is commit order, not elapsed time, with at most six date labels. They use
the latest committed run per revision and a single temporary worktree entry.
Only the newest recording can contribute a worktree point: another worktree run
replaces it, even with a different parent, and a committed run clears it. Raw
records retain all runs and snapshot status; replacement affects the graphs,
not the saved measurements. The temporary point follows its parent without a
status label. Incompatible environments remain separate. The dashboard plots
separate zero-worker and eight-worker compilation curves per phase and matched
environment, using the latest result per commit regardless of suite hash.
Driver, generator, or sampling-protocol edits do not add duplicate workload curves.
Sampling details and suite hashes remain in tooltips and raw records. Keep the
benchmark input fixed for comparable timings.
Compilation and runtime have separate identities: replacing compilation
workloads does not discard unchanged runtime history or its cached C references.
Zig, machine, and kernel keep incompatible timing environments
separate. Affinity is retained in raw records but does not split the graphs;
worker-count curves share the existing history axes.

The report also writes `.history/benchmarks.html`, `benchmarks.png`, and standalone
SVG/PNG graphs under `.history/graphs/`. Matplotlib uses its `xkcd` style and the
bundled openly licensed Comic Neue font; SVGs embed the font for offline use.
Graphs are monochrome: serial compilation is solid, while eight workers uses a
thicker dotted line and hollow point markers.
Benchmark tooltips retain dates, medians, minima, and maxima. Graphs omit runner,
suite hashes, and status labels; raw records preserve that metadata. `--render-only`
rebuilds reports without measuring. One snapshot gives points, not a trend.

### Measurement Protocol

The history driver uses ReleaseFast with LLVM and each revision's ordinary std
configuration: its own precompiled bundle where supported, otherwise its own
embedded std sources. Compilation is measured separately with zero and eight
workers, using fresh databases without disk caching or profiling. Each worker
count has one discarded warm-up per measurement, then adaptive sampling. Two
measured runs suffice when their full range is at most 2% of their median;
otherwise sampling continues up to three runs for compilation and five for
runtime. All measured samples are retained.
Results still outside that range at the cap are explicitly marked unstable in
raw records and graph tooltips, not silently accepted as stable. This is an
observed-repeatability heuristic, not a confidence interval or proof of no
regression. Runtime keeps its zero-worker compilation setup. The cold timer
includes database creation, module/source registration, analysis, native
code generation, and linking. It excludes source generation, compiler builds,
database teardown, file writes, and generated-program execution. Cold means
cold query state, not flushed filesystem or CPU caches. Every program's expected
status is checked outside the timer; a failing workload contributes no samples.

The dashboard keeps three measurements: `core-1000000 / cold`,
`core-1000000 / leaf-edit`, and generated sieve runtime. The compilation program
has exactly 1,000,000 nonblank, noncomment generated code lines, excluding std.
Source generation is outside both timers. It is partitioned into 128 bounded-size
feature modules plus shared support and a one-line leaf module. The entry checks
every module's result, so the feature functions must be analyzed, emitted, and run.

Each repeated feature unit combines arithmetic, predicates, branches, loops,
ranges, arrays, List construction/indexing, slices and reference mutation, text
conversion/comparison, structs and methods, generic types/functions, tuples and
destructuring, variants/match, overload selection, custom converters, indirect
calls, explicit optional result handling, explicit ownership transfer, and
compile-time evaluation. The full executable must exit 42; changing the leaf's
returned value first produces 43 while preserving all feature checks.

Cold means a fresh database for the whole million-line program. Leaf edit changes
only the one-line leaf source input in that existing database, then measures
incremental recomputation, code generation, and relinking. The module catalog and
other source inputs are unchanged. Cold and edit sampling stop independently.
An edit normally follows a measured cold build; if more edit samples are needed,
they use the last database and a new leaf value each time. They never toggle
between already-cached leaf bodies or force extra cold builds. Every resulting
exit status is checked. The compilation protocol records the sampling sequence
independently of the workload.

This is a broad synthetic throughput/reuse workload, not a claim to represent
every application or every language feature. Repeated shapes and shared generic
specializations are intentional; pathological generic expansion, large individual
functions, error reporting, and varied dependency graphs need separate workloads.
Small generator/semantic checks, without recording misleading million-line points:

```sh
zig test benchmarks/history_workload.zig --test-no-exec -femit-bin=/tmp/chimera-history-workload-test
/tmp/chimera-history-workload-test --seed=0
zig test benchmarks/history_sampling.zig --test-no-exec -femit-bin=/tmp/chimera-history-sampling-test
/tmp/chimera-history-sampling-test --seed=0
zig build history-benchmark --seed=0 -j1 -Doptimize=fast -- --case=core-1000000 --lines=1000 --samples=1
```

Nondefault line counts are labelled `probe-core-N` and rejected by the recorder.
`--samples=N` overrides adaptive stopping for standalone probes in either case;
one-sample probes are not accepted as history measurements. The CSV declares each
measurement's total sample count and stability, so truncated or duplicate samples
are rejected. Workload semantics, timer boundaries, and sampling policy have
separate versioned identities in raw records without splitting the compilation
graphs. C references are reused only when their protocols are compatible.

For worker-scaling measurements, the compilation driver accepts
`--workers=N` from 0 through 64 (default 0):

```sh
zig build history-benchmark --seed=0 -j1 -Doptimize=fast -- --case=core-1000000 --workers=4
```

Nonzero-worker samples use a `workers-N` lane. The history recorder runs the
zero-worker and eight-worker lanes independently and plots both; other counts
remain standalone probes. Both recorded lanes use the same adaptive policy.
`--cpu` pins zero-worker compilation and generated runtime (including C) to
that CPU. The eight-worker lane uses the invocation's original CPU set, before
`--cpu` pinning, while respecting any outer `taskset` restriction. The recorder
warns if that set has fewer than eight CPUs. Such samples remain in the raw
records but are excluded from worker-count graphs; the latest eligible result
for each lane is retained. Use physical cores where possible. To record both
lanes on the same eight-core CPU set, omit `--cpu`:

```sh
taskset -c 4-11 .venv/bin/python benchmarks/history.py --worktree
```

Serial/runtime affinity remains in `runner.affinity`; the worker CPU set is
recorded separately as `worker_affinity`. C-reference reuse depends only on the
serial/runtime affinity, not the worker set. These results overlay the existing
graphs for the same machine and toolchain. Consult the raw records when comparing
runs with different affinities.
Keep the normal warm-up and cold/edit validation. The worker option does not
change runtime sampling.

Compilation plots contain measured Chimera results only. The former hard-coded
C++ timing estimates had no compiler provenance and are no longer displayed;
there is no measured Clang C++ compilation or leaf-edit baseline.

Commit measurements use the fixed driver and standalone
[build harness](history_build.zig) in temporary snapshots rather than each
revision's build target. An import bridge exposes the compiler. Compiler and
standard-library sources are never replaced or patched to accept a workload.
LOC and source identity are captured before harness insertion; the suite hash
separately includes the driver, sampler, workload generator, C reference, build harness,
and import bridge.

`--backfill-benchmarks` attempts first-parent commits newest first and saves each
revision immediately. It skips matching prior attempts, including recorded
failures, when resumed. Each workload runs separately: an unsupported runtime
case does not erase valid compilation results. Source, host-toolchain, build,
and correctness failures produce no timing; details live in raw records and
`.history/failures/`. Single-snapshot recording exits nonzero if a requested
workload fails, after saving its record and rendering the report. Backfill
continues through unavailable revisions. Revisions predating the harness's module/query API are
marked unavailable; this does not prove their compiler cannot compile the source.
Backfill attempts each revision independently; one failure does not establish
incompatibility of its ancestors. Normal single-commit recording
can retry a revision; changing the suite or environment also triggers new attempts.

Generated runtime has a separate `sieve-88000000` workload: a heap-backed List
counts exactly 5,107,832 primes through 88 million. `List(int).filled` allocates
its `limit + 1` zeroed elements once, as C's `malloc` and zeroing loop do. The
bound arrives as four little-endian stdin bytes, not as a source constant. The program prints the actual count; only the
driver knows the expected answer and checks the full output after timing.
The same executable first passes checks for bounds 2, 10, 100, and 1,000.
Runtime input and observable output prevent constant-result substitution or
dead-code elimination, while permitting legitimate algorithm optimizations;
there are no volatile operations or inner-loop barriers.

The executable builds and writes once outside the timer, then runs once
unmeasured and then adaptively sampled under the rule above. Process wall time includes stdin/stdout,
startup, allocation, computation, and cleanup, not just a kernel.
Snapshots without runtime coverage still contribute compiler measurements.
JSON retains all samples and executable sizes; graphs show separate workload
medians, not one aggregate score. Code size is not a runtime benchmark.
Compilation and runtime graphs use seconds.

The fixed limit remains 88 million across C toolchains. There are no sleeps,
repeated subprocess padding, or optimization barriers.
Faster machines can produce subsecond samples; fresh and cached baselines accept
these timings with the same correctness checks. The workload stays fixed across
machines, and incompatible environments remain separate.

The equivalent [C sieve](history_runtime.c) uses the same algorithm, signed 32-bit
integer array, input, output, correctness probes, warm-up, and process timer.
This matches Chimera's `int`.
`clang` builds it as C11 at `-O0` and `-O3`, outside the timer;
there is no fallback to the system `cc`. Each level gets one warm-up
and its own adaptive measurement sequence.
The latest matching run's C medians appear as two labelled horizontal runtime
reference lines named `Clang -O0` and `Clang -O3` in the report and SVG/PNG
exports. They share the runtime curve's color, with dotted `-O0` and dashed `-O3` lines. Render-only never reruns C.
Normal recording reuses complete C samples from existing `.history/records/`
when the suite (C source and timing driver), protocol, Zig/C toolchains, and
runner (including CPU affinity) match. On a hit, C is neither compiled nor run;
Chimera is still measured normally. Reused samples retain their original
measurement timestamp and snapshot. New or incompatible configurations measure
C once. Use `--refresh-c` to deliberately replace that baseline, for example
after a machine or thermal-state change. There is no separate cache to maintain;
preserve the history records to preserve the C baseline. Switching from an old
GCC reference automatically misses the cache and measures Clang. Existing GCC
records retain their compiler identity and render as `GCC` references; unknown
legacy compilers retain generic `C` labels. Historical samples are not relabelled
as Clang.
The [Clang baseline qualification](results/clang-baselines/README.md) records
matched sieve timings and verification for this switch.
Compiler identity and C source hashes remain internal and isolate incompatible
comparisons. Records without C samples have no reference lines. C lacks
Chimera's dynamic bounds checks and List machinery, so this compares equivalent
algorithms and data layouts, not identical safety or library overhead.
Optimization levels are not guaranteed to improve monotonically.

ReleaseFast optimizes the Zig compiler itself, not the generated Chimera program
through LLVM. Assembly and code-size differences are not runtime measurements.

The suite does not measure CLI file discovery/startup, general worker scaling,
peak RSS, or broad application runtime. Those need separate versioned workloads.

For CI, use a full-history checkout, the matching Zig toolchain and Python
requirements, restore prior records, then run
`python3 benchmarks/history.py "$GITHUB_SHA"`. Upload the records and generated
reports/graphs with `actions/upload-artifact`; no commits are needed. A durable
external store avoids artifact expiration. Dedicated runners are preferable for
performance; hosted runners are too variable for small timing differences.
No automatic hook or workflow is installed.

## Runtime History

[runtime_history.py](runtime_history.py) records every runtime benchmark (the 88M sieve,
the five-face key search, and the array sort across its input distributions with static and
runtime comparators) across commits, in `.history/runtime/`, and renders a standalone
report to `.history/runtime.html`. It shares nothing with the compilation history's
records or report.

```sh
python3 benchmarks/runtime_history.py --cpu 4
python3 benchmarks/runtime_history.py --cpu 4 --worktree
python3 benchmarks/runtime_history.py --cpu 4 --sort-pattern 'adjacent swap' --sort-pattern 'minimum last'
python3 -m unittest discover -s benchmarks -p runtime_history_test.py -v
```

Each commit's compiler builds from `git archive` in Debug mode, which cannot change the
generated machine code, then compiles the current benchmark programs unchanged, so a
point differs from its neighbours only by the compiler. Recording starts at HEAD and
walks first-parent commits newest to oldest until it reaches an existing entry or a
compiler build, benchmark compilation, or execution/correctness failure. It saves
each commit immediately, retaining completed benchmarks from a failed commit, and
renders the report when it stops. A new failure exits nonzero after rendering.
Existing entries stop the default walk regardless of their suite hash or status.
To add inputs to older records, repeat `--sort-pattern` for the desired inputs.
This measures only missing case/comparator entries, preserving all prior samples
and their provenance. Each backfill records its own suite hash, timestamp, environment,
and result keys. The walk stops when all requested entries at a commit already
exist (successful or failed), or at the first new failure. It does not rerun the
sieve, key search, or other sort inputs. The optional
`--since` sets an inclusive oldest commit. The sieve program is read from
[history_benchmark.zig](history_benchmark.zig) rather than copied. Only generated programs are timed,
pinned to `--cpu`, with the same correctness checks and adaptive sampling as the
standalone drivers (sort: seven rotated samples). Clang C and C++ references are
cached in `.history/runtime/references.json`; delete it to measure them again.
References are measured only when a new entry is needed, and ratios apply to the
machine and session that produced those references. Adding a workload refreshes an
incomplete reference cache. Records carry a suite hash for provenance. Do not run
it alongside other timed work.

Each chart's x-axis includes only commits with a successful measurement in one of
its displayed Chimera lanes. Ticks show dates; commit hashes remain in point hover
details. Each chart reports its measured commit count and date range, plus a
recorded failure boundary for that input when available.

## Frontend attribution

The compilation driver can profile one cold build and one fresh leaf edit with
its ordinary workload and the compiler's phase collector:

```sh
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --profile
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --workers=8 --profile
```

Use an affinity set available on the measurement host. Run serial first, then
eight workers on the same eight physical cores. Each phase reports wall time; counters report exclusive
worker elapsed milliseconds and invocations, separating dependency coordination
(blocking and scheduler/query bookkeeping) from
body construction, typing, lifetime work, publication overhead, optimization, and
code generation. Parallel totals are summed worker time, not wall time.
`--profile` requires the compilation case and excludes `--samples`; it prints
attribution to stderr without timing CSV, so the recorder cannot accept
instrumented samples. Both resulting programs still pass the ordinary correctness
checks. Use the uninstrumented measurement protocol above for acceptance.

Body counters further separate scalar/general call preparation, type-only
inference, call effects, origin expansion, reaching contents, pending reference
uses, service mutations, ownership metadata, lifetime planning, cleanup
stabilization/materialization, flow/effect validation, and contract publication.
Origin expansion, reaching contents, and type-only inference count uncached work;
the remaining typing and lifetime counters exclude these nested phases. A smaller
`--lines=100000` probe uses the same generator, but does not replace the unchanged
million-line acceptance workload.

### Recorded typing and lifetime attribution

**2026-11-10 status: investigation only, not a performance fix.** This pass added
profiling counters, CLI timing rows, and tests. The cold-compilation regression
remains open; no optimization was implemented or qualified by this investigation.

Measurements used Zig 0.17, fast/LLVM, bundled std, no disk cache, and the unchanged
100,000-line and million-line workloads on an AMD Ryzen 9 3900X. Serial runs were
pinned to CPU 4; eight-worker runs could use CPUs 0-23. The source state was based
on `f828761` plus the uncommitted compiler/std changes, not a clean commit.
The [saved pre-instrumentation candidate](results/compiletime-regression/measurements.json)
is the comparison below; it was not rebuilt and measured as a fresh paired baseline.

Uninstrumented cold-compilation medians:

| Lines | Workers | Recorded candidate (s) | With counters disabled (s) | New samples stable |
| --- | --- | --- | --- | --- |
| 100,000 | 0 | 4.869 | 4.903 | Yes |
| 100,000 | 8 | 1.178 | 1.172 | Yes |
| 1,000,000 | 0 | 48.239 | 49.135 | No |
| 1,000,000 | 8 | 10.783 | 11.006 | Yes |

Leaf-edit medians were 22.872/35.570 ms for 100,000 lines and
224.158/342.369 ms for a million lines, with zero/eight workers respectively.
Only the million-line serial leaf-edit samples met the repeatability criterion.
The roughly 2% higher million-line cold medians do not establish instrumentation
overhead or a regression: the comparison was not freshly paired, and serial
samples were unstable. No speedup is demonstrated.

The million-line serial profile took 50.177 s and attributed the following
exclusive elapsed time:

| Work | Seconds |
| --- | --- |
| Optimization passes, combined | 15.303 |
| Remaining typing/SSA | 7.883 |
| Reference-origin expansion | 7.819 |
| General call preparation | 3.141 |
| Type-only inference | 1.433 |
| Effect validation | 1.411 |
| Cleanup materialization | 1.363 |
| Lifetime planning | 0.537 |
| Cleanup stabilization | 0.253 |

Origin expansion ran 1,824,257 uncached times. These rows exclude nested work;
the small lifetime-planning and cleanup-stabilization self times do not include
the separately attributed origin/contents work they demand. Remaining typing/SSA
is residual work, not an identified individual algorithm.

Eight workers increased body-typing invocations from 38,600 to 57,983 and doubled
type-only inference from 172,811 to 345,622. Parallel phase times are summed worker
elapsed time, not wall time. The following section supersedes this pass's
direction: it attributes the regression by controlled intervention.

All profiled and timed programs passed the driver's expected-exit checks.
Uninstrumented executable sizes remained 17,220,583 bytes for 100,000 lines and
174,665,169 bytes for a million lines, matching the recorded candidate. Any future
fix still needs fresh matched cold/leaf-edit measurements at both sizes and worker
counts, while preserving context, provider ownership, and incremental reuse.

### Cold-compilation regression attribution (2026-11-11)

Method: paired snapshot builds of the old tree (`b153a16`, before shared context)
and `HEAD` (`ddac9af`) through `history_benchmark` (`git archive`, `history.prepare`,
`.history.build.zig`), plus the compiler's own `--debug=timing` rows, marginal cost
per generated unit from two workload sizes, and measurement-only builds that switch
one mechanism off. Those builds are unsound and were used only for attribution.
Serial runs were pinned to one CPU; Unity ran on the machine, so A/B runs were
interleaved. Earlier theories (optimizer/IR volume, leaf count, protocol envelope,
cache invalidation) were refuted by these measurements and are not repeated here.

Cold compilation, `core-1000000` workload:

| Lines | Workers | `b153a16` | `HEAD` | After kept fixes (`a24f955`) |
| --- | --- | --- | --- | --- |
| 100,000 | 0 | 1.66 s | 2.80 s | 2.46 s |
| 100,000 | 8 | 0.42 s | 0.71 s | 0.54 s |
| 1,000,000 | 0 | 16.9 s | 29.3 s | 24.7 s |

The ratio is the same at 100,000 and 1,000,000 lines, so the regression is linear
cost per function, not a scaling or cache failure. The README's 48 s figure for
`HEAD` was not reproduced on this machine. Executable size grew from 10.2 MB to
17.2 MB.

Phase split on a 4,000-unit generated CLI-style workload, serial (ms; the
workload is not checked in):

| Phase | `b153a16` | `HEAD` |
| --- | --- | --- |
| Analysis (typing, lifetimes, cleanup) | 1,353 | 3,681 |
| Optimization | 1,915 | 1,935 |
| Codegen | 180 | 267 |
| Other | 149 | 221 |

Analysis is 93% of the gap; the optimizer is unchanged. Marginal analysis cost
per unit was 349 us (old), 908 us (`HEAD`), and 716 us after the kept fixes.

**Cause.** `Allocation` used to hold no borrows. It now carries an `Allocator`
provider (a callable payload) and a `StorageCursor`, so `Allocation`, `List`,
`Box`, and `String` are borrow-bearing. The whole borrow pipeline therefore runs
for every owning container at every exit path: origin expansion, reaching
contents, cleanup candidates and scheduling, effect validation, and
service-mutation application. Per-unit analysis splits roughly as:

- About 63% (about 233 us): owning containers being borrow-bearing. Treating
  `Allocation` as non-borrow-bearing lowers analysis from 716 to 483 us per unit
  (17% of total wall time), origin expansions from 380k to 160k, and cleanup
  candidates from 68k to 8. Removing only the provider or only the cursor gains
  nothing; both must go.
- About 16% (about 57 us): applying provider-callback service mutations at calls.
- About 21%: general typing and call preparation of views, strings, lists, and
  arrays (a plain `Array` shows about +10 us).

Codegen grew about 26 us per unit (thread-state setup in context-using functions
and larger value copies); the two contributions are not isolated.

Interventions that gave 2.5% or less: trivial `Allocator` ownership, collapsing
contextual source paths, memoizing origin merges, and not inlining `deallocate`.

**Kept fixes (`a24f955`).** A fold hasher for reference-origin sets, a memo of
the pure origin transformations, a memo of nonowning callable origins, and
skipping the callee-discovery prefetch for bodies that conservative typing cannot
accept (it typed each of them an extra time with workers). They are sound and pass
the suite, and recover about 13% serial and 24% with eight workers.

**Remaining attribution.** The percentages above describe the earlier source
state and overlap with the scheduling work removed below; they are not additive
estimates for another optimization. Treating owning containers as non-borrow-bearing
remains unsound. A compact provenance representation must preserve result/source
paths, provider retention, physical aliases, captured authority, invocation
identity, and temporal snapshots; a whole-value ambient-context bit is not enough.
Further work must attribute the remaining typing and call-preparation costs
before selecting a rewrite. Later options include a single-handle `Allocator`
and removing thread-state setup. Qualify each with matched cold and leaf-edit
runs at both sizes and both worker counts.

### Demand-sensitive cleanup scheduling (2026-11-12)

The implementation adds two complementary refinements to `a24f955`:

- Ordinary service mutations expand immediately when their receivers are
  complete. The existing expansion path still defers incomplete receivers and
  preserves invocation-site context snapshots.
- Cleanup scheduling substitutes each actual receiver before making the body's
  reference contents provisional. Fully resolved abstract ambient receivers keep
  their published mutations without scheduling body-local contents writes.
  Concrete providers, local/parameter receivers, incomplete origins, initializers,
  direct contents writes, and context selected by the hook remain conservative.

Immediate service expansion alone did not demonstrate a meaningful improvement.
Both refinements are needed. Neither removes provider or storage borrows.

A qualified snapshot of this implementation used Zig 0.17, fast/LLVM, bundled std,
no disk cache, fixed seed 0, one warm-up, and five cold/leaf-edit samples per run.
Serial runs were pinned to CPU 4; eight-worker runs used CPUs 0-7. The unchanged
history driver executed and checked every generated program.

Representative uninstrumented cold medians:

| Lines | Workers | `a24f955` (s) | Demand-sensitive scheduling (s) | Both sample sets stable |
| --- | --- | --- | --- | --- |
| 100,000 | 0 | 2.460 | 2.158 | Yes |
| 100,000 | 8 | 0.550 | 0.512 | No |
| 1,000,000 | 0 | 24.887 | 21.876 | Yes |
| 1,000,000 | 8 | 5.184 | 4.827 | Yes |

Repeated rounds gave roughly 9-12% less serial cold time and 5-7% less with eight
workers; some additional rounds did not satisfy the 2% stability rule. Executable
sizes remained 17,220,583 and 174,665,169 bytes. The 100,000-line cold profile reduced
origin expansions from 180,377 to 79,821, contents queries from 96,801 to 41,
cleanup candidates from 32,304 to 35, and cleanup scheduling from 13,278 to 6.
The routine safe suite passed 2,682 tests with 24 skips. A profiling regression
test checks that allocator reads and service-mutation contracts survive without
speculative scheduling, including execution after a source edit.

This is a partial recovery, not restoration of the historical 16.9-second
million-line baseline. Incremental timings were variable and included slower
candidate rounds; neither incremental speedup nor absence of slowdown is
established. Remaining work includes finer attribution and a sound provenance/
call-preparation design, not bypassing borrow validation.

### Shared provenance-expression prototype (2026-11-12)

A follow-up prototype represented pure unions and transformations as shared
expressions, separated semantic origins from list links, cached materialization,
and added a lifetime-specific existence query. Known contracts avoided constructing
opaque fallback return provenance. Published contracts and argument evaluation
order were unchanged; most consumers still required concrete origin sets.

Fresh comparisons against the two-part scheduling fix used the same five-sample,
uninstrumented protocol above. All generated executables passed output checks and
had unchanged sizes.

| Lines | Workers | Scheduling fix (s) | Expression prototype (s) | Both sample sets stable |
| --- | --- | --- | --- | --- |
| 100,000 | 0 | 2.151 | 2.249 | Yes |
| 100,000 | 8 | 0.519 | 0.524 | No |
| 1,000,000 | 0 | 21.619 | 22.775 | Yes |
| 1,000,000 | 8 | 4.863 | 4.917 | Yes |

The million-line serial median regressed by 1.156 s (5.35%); the eight-worker
median increased by 0.054 s (1.11%). All paired leaf-edit samples were unstable,
so no incremental improvement is established. The prototype passed 2,683 tests
with 24 skips, plus formatting and whitespace checks.

Relative to the scheduling fix, the source patch added 268 lines and deleted 234:
net +34 physical lines, comprising +2 compiler lines and a 32-line behavioral
test. Excluding blank and comment-only lines, compiler code grew by 12 lines.

The prototype was not retained. Sharing expressions did not eliminate enough
consumer-side work to offset its overhead; this is not evidence that a larger
consumer rewrite would recover the remaining regression. Further designs must
demonstrate reduced end-to-end time, not just fewer origin-expansion invocations.

## Focused Drivers

| Command | Measures |
| --- | --- |
| `zig build benchmark --seed=0 -Doptimize=fast` | Compile-time analysis, execution, publication, cached lookup, and recomputation |
| `zig build conversion-benchmark --seed=0 -Doptimize=fast` | Converter index construction and repeated matching |
| `zig build flow-benchmark --seed=0 -Doptimize=fast` | Typing time and retained flow/lifetime storage |
| `zig build std-benchmark --seed=0 -Doptimize=fast -j1` | Source-only versus bundled std compilation |

The std driver also supports the default Debug build. It warms both paths and
measures 21 alternating pairs of fresh zero-worker databases. `compile` includes
creation, registration, optional bundle loading, analysis, codegen, and linking;
`lifecycle` adds teardown, and `load` isolates bundle loading. File discovery,
writes, and execution are excluded. Typing/codegen counts come from separate
instrumented warm-ups, not timed samples.

The conversion driver uses one warm-up and nine fresh one-worker databases.
Cases cover 1,024 unrelated declarations, 128/512 unrelated converters, and 128
source/target pairs. `first` includes index construction and first match;
`consumers` requests 256 distinct consuming queries; `total` adds database setup
and discovery, excluding teardown. It does not compile a complete program.

The flow driver covers scalar, owning, narrowing, and backedge functions with 8,
32, 128, 256, and 512 branches. Both refinement cases combine saved bool proofs
and reference aliases. `narrowing` uses loops that break after one pass;
`backedges` uses conditional breaks and retains real loop backedges. Each row is
the median of five fresh one-worker databases.
Signatures and semantic construction precede the timer; typing includes workspace
compaction/release, ownership lowering, and lifetime planning, but not codegen or
published-body teardown. A separate sixth database measures retained storage.
Owning fixtures keep generations live to expose branch/generation scaling.
Refinement fixtures keep all mutable carriers live across every loop, exposing
the cost of loop-carried values as both carrier and loop counts grow.

Snapshot bytes count saved handles and each unique pointer-table root and
16-slot page once, including flags and padding, across independent value,
availability, initializer, and completion buffers. Default pages allocate
nothing. Lifetime bytes count availability/demand bitsets and populated sparse
operand entries, not map capacity, scheduling flags, or other scratch. Neither
figure is process RSS or allocation traffic. Flow fact, place/path/key, predicate,
and inference-key columns separately count retained table payloads. Predicate and
inference environments count additional unique snapshot pages, sharing the same
visited-page set as ordinary snapshots. Table payload counts exclude hash bucket
metadata, spare capacity, and arena allocation overhead.
Binding identity graphs, reference-provenance tables, and other workspace scratch
are outside these columns. Snapshots and flow facts are body-local construction
state, released with the workspace; they do not become cached IR.

For CLI worker scaling and warm/edited disk reuse:

```sh
zig build -Doptimize=fast
python3 benchmarks/parallel.py zig-out/bin/chimera
python3 benchmarks/parallel.py zig-out/bin/chimera --temp-dir .
```

The linker build ID identifies stripped Fast compiler binaries cheaply. Measure
the explicitly built binary, not an installed binary left over from another
source state.
