# Numeric implementation benchmarks

Baseline: `cf30f8d65e6eeab1b1da7b58b9e23dc0edc5c485` (`git archive` snapshot).
Candidate: the implementation in this working tree; the final source fingerprint
is recorded with the results. Environment details are in `environment.json`.

Both snapshots use Zig 0.17, ReleaseFast with LLVM, their ordinary bundled std,
and CPU affinity 0–7. Runs are sequential, with no concurrent builds or tests.
Compiler builds and source generation are outside the measured intervals.

The unchanged history driver measures fresh compilation and one-leaf incremental
edits of the same million-line mixed-feature program, with zero and eight workers.
Every executable's expected result is verified. Sieve runtime uses the unchanged
88,000,000-element workload and verifies its output. Each measurement discards
one warm-up and uses the repository's adaptive sampling protocol (2% full range,
up to three compilation samples or five runtime samples). Raw CSVs preserve all
samples and stability flags.

The compile-time evaluator benchmark separately measures analysis, execution,
publication, cached reads, and incremental edits. Its raw CSVs retain one discarded
warm-up plus five measured runs for each snapshot. This driver uses embedded std
sources and one query worker, as defined by `benchmarks/comptime_benchmark.zig`.

Commands (run in each snapshot, with output files named for that snapshot):

```sh
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --skip-c --workers=0
taskset -c 0-7 zig build history-benchmark --seed=0 -Doptimize=fast -j1 -- --case=core-1000000 --workers=8
taskset -c 0-7 zig build benchmark --seed=0 -Doptimize=fast -j1
```

## Observed results

Times below are medians. Positive changes mean slower execution. `*` marks a
measurement that did not reach the 2% stability threshold at its sampling cap;
its full sample range is retained in [summary.json](summary.json). These are
observed differences on this machine, not confidence intervals.

| Measurement | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fresh compilation, serial | 26.873 s | 30.330 s | +12.9% |
| Leaf edit, serial | 242.684 ms * | 274.233 ms | +13.0% |
| Fresh compilation, 8 workers | 7.221 s * | 7.725 s | +7.0% |
| Leaf edit, 8 workers | 294.749 ms | 335.380 ms * | +13.8% |
| Sieve runtime | 992.278 ms * | 1190.472 ms | +20.0% |

The million-line executable grew from 118,104,377 to 162,356,053 bytes (+37.5%).
The sieve executable grew from 18,524 to 24,689 bytes (+33.3%). The candidate
performs checked arithmetic and retains numeric panic traces; the baseline used
modular arithmetic. Thus this comparison includes the cost of the changed
semantics. These workloads do not measure every newly supported numeric type.

Compile-time evaluator timings (five measured runs per snapshot, milliseconds):

| Case | Analyze: baseline → candidate | Execute: baseline → candidate | Execute change |
| --- | ---: | ---: | ---: |
| constant | 0.0820 → 0.0942 | 0.0065 → 0.0061 | -6.5% |
| short-expression | 0.0953 → 0.1052 | 0.0032 → 0.0047 | +45.0% |
| loop-10000 | 0.1194 → 0.1392 | 3.8362 → 3.8509 | +0.4% |
| fibonacci-20 | 0.0264 → 0.0252 | 0.1372 → 0.1454 | +6.0% |
| unique-recursion-200 | 0.0187 → 0.0227 | 1.3982 → 1.4169 | +1.3% |
| memoized-call | 0.0363 → 0.0457 | 0.0163 → 0.0149 | -8.2% |
| aggregate-call | 0.1977 → 0.2010 | 0.0404 → 0.0601 | +48.7% |
| type-specialization | 0.0410 → 0.0447 | 0.0077 → 0.0076 | -1.8% |

Publication, 1,000 cached reads, incremental edits, minima/maxima, and individual
samples are also retained in [summary.json](summary.json) and the raw CSVs.
Microsecond-scale cases are particularly sensitive to noise; relative percentages
alone exaggerate small absolute changes. An unrelated terminal build overlapped
the initial candidate evaluator samples. Those samples were discarded, and the
retained evaluator set was collected after that build finished. The history
measurements completed before the unrelated build began.

## Verification and artifacts

- [Verification commands](verification.txt): full safe suite, 2,237 passed and 24 skipped;
  ReleaseFast numeric suite, 15/15 passed; formatting and diff checks passed.
- [Environment and driver hashes](environment.json).
- [All summaries and candidate source fingerprint](summary.json). The fingerprint
  covers `src/`, `std/`, the four recorded Zig benchmark sources,
  `benchmarks/history_runtime.c`, and `build.zig`.
- `baseline-serial.csv` / `candidate-serial.csv`: serial compilation, leaf edits,
  and runtime, with sampling counts and stability flags.
- `baseline-workers-8.csv` / `candidate-workers-8.csv`: parallel compilation and
  leaf edits.
- `baseline-comptime.csv` / `candidate-comptime.csv`: all five evaluator runs.
  The corresponding `*-comptime-warmup.csv` files contain discarded warm-ups.
