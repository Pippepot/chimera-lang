# Five-Face Key Search

[main.chi](main.chi) and its matching [C version](main.c) follow
[oscar6echo's key-gen-face-five.c](https://github.com/oscar6echo/rust-c-go-speed/blob/main/c/key-gen-face-five.c).
Starting with `0, 1, 5`, each candidate key enumerates nondecreasing five-rank
combinations, excluding five equal ranks, then scans pairs of sums in enumeration
order, stopping at the first collision. Both versions retain the brute-force
algorithm, signed 32-bit keys/sums, and 50,000-element stack buffer. The upstream
outer `c5` loop redundantly wraps another loop over the same variable and executes
only once; both versions omit that wrapper without changing enumeration.

Run the standalone comparison from the repository root with Linux, Python 3.12+,
Zig 0.17, and `cc`:

```sh
python3 benchmarks/key-gen-face-five/run.py
python3 benchmarks/key-gen-face-five/run.py --cpu 4
python3 benchmarks/key-gen-face-five/run.py --check-only --last 7
python3 benchmarks/key-gen-face-five/run.py --last 12 --cpu 4
```

The default searches through index 10, matching upstream's active loop bound:
`0, 1, 5, 22, 94, 312, 992, 2422, 5624, 12522, 19998`.
Indices 11 and 12 yield `43258, 79415` and take substantially longer.
Each executable reads one stdin byte specifying the final index (3 through 12)
and prints one key per line. Missing/out-of-range input exits 1. Runtime input
and the complete output keep the search observable; timing is external rather
than printed inside the program.

The runner builds the current Fast compiler and C11 `-O0`/`-O3` executables in a
temporary directory without replacing the repository's `prog` or installed
compiler. All compilation is outside runtime timing. Before sampling, each
executable passes reference-prefix and invalid-input probes, then one discarded
warm-up at the selected endpoint. It takes at least two measured runs, stopping
when the full range is within 2% of the median, with a five-run cap. All samples,
medians, repeatability status, toolchains, and CPU affinity are printed. Capped
noisy results are marked unstable. The timer measures complete process wall time,
including stdin/stdout, stack initialization, computation, and startup/cleanup;
output validation is outside the timer. `--cpu` pins only runtime checks and
samples, not builds. Chimera retains its normal dynamic bounds checks; C does not.
This standalone workload does not modify the history suite or its graphs.

## Runtime Findings

On 2026-10-31, a frozen before/after comparison on CPU 4 with Zig 0.17.0 and
GCC 16.2.1 measured the unchanged default endpoint. Unrelated concurrent compiler
edits were excluded from the after snapshot. Each executable passed the complete
output and invalid-input checks, followed by one discarded warm-up. Measured
before/after/C order alternated; all three reached the 2% stability criterion
with two samples:

| Executable | Median (s) | Measured Samples (s) |
| --- | ---: | --- |
| Chimera before | 13.739612 | 13.755552182, 13.723672687 |
| Chimera after | 8.491792 | 8.474561237, 8.509023415 |
| C `-O3` | 3.517350 | 3.506475711, 3.528224174 |

This is **38.2% less runtime (1.62x speedup)**. Chimera remains 2.41x the C
`-O3` wall time. A preceding batch reached the after-version noise cap
(8.657 s median); it was not classified as stable. These are local measurements,
not portable performance guarantees.

The compiler now uses compact 32-bit arithmetic operands, rotates carried
collision flags of either polarity into direct exits, and removes overflow
checks from recurrences only when the final update is proved safe. Linux syscall
register reservations no longer unnecessarily exclude `r8`-`r10`; the emitted
scan retains its right index and left-hand sum in registers. Normal and
assembly-debug executable images were byte-identical. No benchmark algorithm or
language safety policy changed. Repeated bounds checks and sum-generation
iterator/array-access overhead remain; Fast optimizes the compiler itself,
not the safety policy of generated programs.

Matched zero-worker, profiling-off million-line compilation measured 33.294 s
before and 33.380 s after (0.3% difference). Leaf edits measured 326.735 ms
before and 321.273 ms after; the before samples reached the three-run noise cap,
so that comparison is not a stable speedup claim. Reversed-order checks of the
88-million sieve did not reproduce an initial 1.4% slowdown: three batch medians
ranged from 1.300-1.343 s before and 1.283-1.319 s after. All native output and
exit-status checks passed.