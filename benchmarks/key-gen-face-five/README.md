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
Zig 0.17, and Clang (`clang` on `PATH`):

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

The runner builds the current Fast compiler and Clang C11 `-O0`/`-O3` executables in a
temporary directory without replacing the repository's `prog` or installed
compiler. All compilation is outside runtime timing. Before sampling, each
executable passes reference-prefix and invalid-input probes, then one discarded
warm-up at the selected endpoint. It takes at least two measured runs, stopping
when the full range is within 2% of the median, with a five-run cap. All samples,
medians, repeatability status, toolchains, and CPU affinity are printed. Capped
noisy results are marked unstable. The timer measures complete process wall time,
including stdin/stdout, stack initialization, computation, and startup/cleanup;
output validation is outside the timer. `--cpu` pins only runtime checks and
samples, not builds. Chimera retains checked bounds and overflow semantics;
C does not provide equivalent checks.
This standalone workload does not modify the history suite or its graphs.

## Runtime Findings

The runner now uses Clang explicitly. The GCC measurements below retain their
original toolchain labels and describe the earlier comparison.

A matched comparison on 2026-10-31 used CPU 4 of an AMD Ryzen 9 3900X,
Zig 0.17.0 Fast compilers, and GCC 16.2.1. The frozen baseline already includes
the earlier arithmetic, syscall-register, flag-exit, cold-trap, bounds-inference,
and address/load-fusion improvements. Only `src/backend/codegen.zig` and
`src/backend/registers.zig` differ between these compiler sources; frontend,
optimizer, standard-library sources, and workloads are matched.

Each executable passed reference-prefix and invalid-input checks, followed by
one discarded warm-up at the default endpoint. Before/after/C sampling order
alternated with its reverse. Each executable stopped after meeting the full-range
2% stability criterion, with a five-sample cap. The final batch qualified with
two measured samples per executable:

| Executable | Median (s) | Measured Samples (s) |
| --- | ---: | --- |
| Chimera before | 4.435842 | 4.454945105, 4.416738794 |
| Chimera after | 3.120420 | 3.095781381, 3.145058502 |
| GCC 16.2.1 `-O3` | 3.497764 | 3.502278340, 3.493250156 |

This change provides **29.7% less runtime (1.42x speedup)**.
Chimera takes 0.892x the GCC 16.2.1 `-O3` wall time, or 10.8% less. These are local
measurements, not portable performance guarantees. An earlier batch on the same
final native code hit the noise cap for before/after; all of its samples remain
explicitly marked unstable in [runtime-noise-cap.json](../results/key-gen-loops/runtime-noise-cap.json).

A subsequent independent recheck rebuilt both compilers' outputs and added
GCC `-O2` and Clang `-O3` controls. All four executables passed the same correctness
checks, then ran one warm-up and five measured samples each on CPU 4, alternating
forward/reverse sampling order. The fresh Chimera and GCC `-O3` executables match
the earlier measured binaries byte for byte. This batch did not meet the 2%
full-range criterion for any executable; these medians are explicitly noisy:

| Executable | Median (s) | Full Sample Range (s) |
| --- | ---: | ---: |
| Chimera | 3.074831 | 3.007545–3.201863 |
| GCC 16.2.1 `-O3` | 3.516294 | 3.458085–3.642684 |
| GCC 16.2.1 `-O2` | 6.566942 | 3.640715–6.634789 |
| Clang 22.1.8 `-O3` | 1.432032 | 1.408787–1.511207 |

The result is specific to GCC's output: **Chimera beats GCC `-O3` here, while
Clang `-O3` is substantially faster than Chimera**. GCC's nine-instruction scan
materializes two condition flags through stack slots on every comparison.
Chimera uses eight instructions with a register counter and direct branches.
Clang uses six instructions, addresses the array directly with its index register,
and lets noncollision execution fall through the equality test. It executes one
taken branch on the common path, compared with Chimera's two. These assembly
observations explain remaining opportunities; they are not a measured attribution
of each instruction's cost. [All recheck samples and executable hashes](../results/key-gen-loops/c-compiler-recheck.json),
[the GCC scan](../results/key-gen-loops/scan-gcc-o3.asm), and
[the Clang scan](../results/key-gen-loops/scan-clang-o3.asm) are retained.

Loop-weighted register preferences coalesce scalar copies and arithmetic results
only when expanded machine live ranges permit it. Native block layout starts in
reverse postorder and places empty two-block loop tests after their bodies.
The collision scan's noncollision path shrinks from 12 instructions and three
branches to **8 instructions and two branches**. The counter increments directly
in its loop register, and the conditional backedge replaces the unconditional
jump to a separate bound test. Initial entry still tests the bound before running
the body. Shared exits retain their flag and counter values, including the final
increment on collision. Existing bounds and overflow semantics are unchanged.

A matched, alternating 88-million sieve comparison found essentially unchanged
runtime: 1.222287 s before and 1.216067 s after. Both pairs met the
2% stability criterion with two samples after small probes and one discarded
warm-up. Each full run produced `5107832` and status 0. This does not establish
a sieve speedup.

The routine Safe suite passed **2,261 tests with 24 skips**. New coverage checks
counter reuse with retained inputs, physical block permutations, skipped loop
bodies, and state on bound/collision exits. The Fast build, formatting checks,
and `git diff --check` passed.

[Raw runtime samples](../results/key-gen-loops/runtime.json),
[sieve samples](../results/key-gen-loops/sieve.json),
[environment and executable hashes](../results/key-gen-loops/environment.json),
[source hashes](../results/key-gen-loops/source-files.json),
[isolated compiler patch](../results/key-gen-loops/compiler-change.patch),
[before scan](../results/key-gen-loops/scan-before.asm),
[after scan](../results/key-gen-loops/scan-after.asm), and
[Safe test output](../results/key-gen-loops/safe-tests.txt) are retained in the repository.
Frozen sources, compiler binaries, executables, complete disassembly, and sampling
drivers are retained locally in `/tmp/chimera-key-analysis.x932d6`.
