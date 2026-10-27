# Benchmarks

Run commands from the repository root with Zig 0.17. Keep source snapshots,
optimization modes, workloads, worker counts, and machines matched. Do not run
timed benchmarks concurrently with builds, tests, or other benchmarks. Pinning
helps repeatability but does not remove frequency, thermal, or system-load noise.
Compiler timings, generated-program runtime, retained memory, and code size are
different measurements; none substitutes for another.

## Commit History

[history.py](history.py) records exact snapshots and updates the static report at
`.history/index.html`. It requires Linux, Python 3.12+, Git, Zig, and Matplotlib:

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

LOC backfill is resumable and needs no historical compiler builds. It applies
the current [loc.sh](../loc.sh) policy to past sources, including older root-level
layouts, excluding build/benchmark drivers, comments, blank lines, and std.
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
Driver, generator, or sampling-protocol edits do not hide
history or add duplicate workload curves. Sampling details remain in tooltips
and raw records. Keep the benchmark input fixed for
comparable timings; raw records retain the original suite hashes for auditing.
Debug and obsolete protocols remain in raw records without adding duplicate
graphs. Runtime still uses its latest compatible workload.
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
runtime. Thus noisy cold compilation never exceeds the previous three-run
budget. All measured samples are retained.
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
exit status is checked. The compilation protocol versions this changed edit
sequence separately from the earlier fixed cold/edit pairs.

This is a broad synthetic throughput/reuse workload, not a claim to represent
every application or every language feature. Repeated shapes and shared generic
specializations are intentional; pathological generic expansion, large individual
functions, error reporting, and varied dependency graphs need separate workloads.
The old four-line collection/text and 128-function measurements remain in raw
records, not on the new compilation curves. Their timings are not comparable.

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
are rejected. Workload semantics and timer boundaries have separate versioned
identities from the recorded sampling policy. Older raw records are preserved;
compatible fixed-count C references remain reusable. Changed compilation
sampling sequences retain their protocol identities in raw records without
splitting the compilation graphs.

For worker-scaling measurements, the compilation driver accepts
`--workers=N` from 0 through 64 (default 0):

```sh
zig build history-benchmark --seed=0 -j1 -Doptimize=fast -- --case=core-1000000 --workers=4
```

Nonzero-worker samples use a `workers-N` lane. The history recorder runs the
zero-worker and eight-worker lanes independently and plots both; other counts
remain standalone probes. Both recorded lanes use the same adaptive policy.
Compare worker counts on the same CPU affinity set, using physical
cores where possible; do not pin a multiworker run to one CPU. `--cpu` restricts
every lane to that one CPU. The recorder warns when the worker count exceeds
the allowed CPU count: those samples measure oversubscription, not multicore
scaling. It preserves the requested affinity and all samples. To record both
lanes on an eight-core CPU set, omit `--cpu`:

```sh
taskset -c 4-11 .venv/bin/python benchmarks/history.py --worktree
```

Affinity remains part of the recorded environment for auditing and C-reference
reuse, but these results overlay the existing graphs for the same machine and
toolchain. Consult the raw records when comparing runs with different affinities.
Keep the normal warm-up and cold/edit validation. The worker option does not
change runtime sampling.

Only cold-compilation legends show rounded C++20 comparison estimates, without
reference lines or changes to the graph scale. The 2026-10-25 comparison uses
Clang 22.1.8, serial CPU 6 builds, no debug info, PCH, LTO, or compiler cache:
1,000,000 generated lines, 128 feature modules, and 19,584 mixed-feature units.
Cold estimates (160 s at `-O0`, 268 s at `-O2`) use mean projections from three
four-module resamples, checked against one full build per setting. The combined
observed/projected ranges were 158-162 s and 266-270 s, not confidence intervals.
C++ leaf-edit comparisons are omitted: reusing object files and invoking a
disk-based linker differs from Chimera's query-level reuse and in-memory linking.
C++ timing includes object/executable writes. Both exit statuses, 42 and 43,
were checked. C++ library and ownership
semantics differ from Chimera's; these labels are context, not matched history
samples or a claim about every C++ project.

Historical measurements use the current fixed driver and standalone
[build harness](history_build.zig) in temporary snapshots, not the historical
build target. A small import bridge exposes the revision's compiler. Compiler and
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
Backfill attempts older revisions too, rather than assuming
one failure proves every ancestor incompatible. Normal single-commit recording
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
Older snapshots without runtime coverage still contribute compiler measurements.
JSON retains all samples and executable sizes; graphs show separate workload
medians, not one aggregate score. Code size is not a runtime benchmark.
Compilation and runtime graphs use seconds.

The fixed limit was calibrated on CPU 4 for a C `-O3` baseline close to one second.
There are no sleeps, repeated subprocess padding, or optimization barriers.
Faster machines can produce subsecond samples; fresh and cached baselines accept
these timings with the same correctness checks. The workload stays fixed across
machines, and incompatible environments remain separate. The old one-million-element timings
remain in raw records and are not joined to the new runtime curve.

The equivalent [C sieve](history_runtime.c) uses the same algorithm, signed 32-bit
integer array, input, output, correctness probes, warm-up, and process timer.
This matches Chimera's `int`; the old C reference used a wider 64-bit array.
The system `cc` builds it at `-O0` and `-O3`, outside the timer;
these snapshots require a C11 compiler on `PATH`. Each level gets one warm-up
and its own adaptive measurement sequence.
The latest matching run's C medians appear as two labelled horizontal runtime
reference lines in the report and SVG/PNG exports. They share the runtime
curve's color, with dotted `-O0` and dashed `-O3` lines. Render-only never reruns C.
Older `-O1` and `-O2` samples remain in raw records but are neither plotted nor
remeasured; existing complete `-O0`/`-O3` samples remain reusable.
Normal recording reuses complete C samples from existing `.history/records/`
when the suite (C source and timing driver), protocol, Zig/C toolchains, and
runner (including CPU affinity) match. On a hit, C is neither compiled nor run;
Chimera is still measured normally. Reused samples retain their original
measurement timestamp and snapshot. New or incompatible configurations measure
C once. Use `--refresh-c` to deliberately replace that baseline, for example
after a machine or thermal-state change. There is no separate cache to maintain;
preserve the history records to preserve the C baseline.
Compiler identity and C source hashes remain internal and isolate incompatible
comparisons. Older records without C samples have no reference lines. C lacks
Chimera's dynamic bounds checks and List machinery, so this compares equivalent
algorithms and data layouts, not identical safety or library overhead.
Optimization levels are not guaranteed to improve monotonically.

Assembly inspection confirms that optimized C still executes the factor and
multiple-marking loops. GCC replaces elementwise zeroing with `memset` and
vectorizes the final count; it does not substitute a precomputed prime count.
The generated Chimera code inlines List indexing, fills with `rep stosd`, and keeps
unchanged List descriptors outside the marking and counting loops. Scalar
iterator results use separate tag and payload values, and eligible loop scalars
use preserved registers with in-place arithmetic at last-use operand reuse.
Scalar edge copies run without staging when forward or reverse order preserves
their sources; cycles and unsupported shapes retain scratch storage.
Constant incoming predicates can bypass independent terminal exits instead of
materializing exhausted iterator joins. Bounds checks and scalar counting remain
in the hot loops. These are concrete code-generation/library differences, not evidence
of C skipping the requested computation. ReleaseFast optimizes the Zig compiler
itself, not the generated Chimera program through LLVM.

The suite does not measure CLI file discovery/startup, multi-worker scaling,
peak RSS, or broad application runtime. Those need separate versioned workloads.

For CI, use a full-history checkout, the matching Zig toolchain and Python
requirements, restore prior records, then run
`python3 benchmarks/history.py "$GITHUB_SHA"`. Upload the records and generated
reports/graphs with `actions/upload-artifact`; no commits are needed. A durable
external store avoids artifact expiration. Dedicated runners are preferable for
performance; hosted runners are too variable for small timing differences.
No automatic hook or workflow is installed.

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

The flow driver covers scalar, owning, and narrowing functions with 8, 32, 128,
256, and 512 branches. Narrowing cases combine saved bool proofs, reference aliases,
and loop backedges. Each row is the median of five fresh one-worker databases.
Signatures and semantic construction precede the timer; typing includes workspace
compaction/release, ownership lowering, and lifetime planning, but not codegen or
published-body teardown. A separate sixth database measures retained storage.
Owning fixtures keep generations live to expose branch/generation scaling.

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

For CLI worker scaling and warm/edited disk reuse:

```sh
zig build -Doptimize=fast
python3 benchmarks/parallel.py zig-out/bin/chimera
python3 benchmarks/parallel.py zig-out/bin/chimera --temp-dir .
```

The linker build ID identifies stripped Fast compiler binaries cheaply. Measure
the explicitly built binary, not an installed binary left over from another
source state.

## Historical Results

The nine old CSVs and their provenance are archived under [results/](results/README.md).
They are experiment evidence, not inputs to the active drivers or history graphs.
Current measurements and cached C baselines live in `.history/records/`.
