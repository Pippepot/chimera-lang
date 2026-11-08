# Array sorting

Compare Chimera's static and runtime comparator overloads with C++17 `std::sort`
and `std::stable_sort`, compiled by Clang at `-O3` using its default C++ standard
library. Chimera's sort is stable, so `std::stable_sort` provides the comparison
with the same ordering guarantee. Integer elements do not expose stability;
the compiler's sort test suite separately covers that contract.

```sh
python3 benchmarks/array-sort/run.py --cpu 4
python3 benchmarks/array-sort/run.py --size 1024 --rounds 128 --samples 9 --cpu 4
python3 benchmarks/array-sort/run.py --cpu 4 --output /tmp/array-sort.json
```

Run from the repository root with Zig 0.17, Python 3, and `clang++` on `PATH`.
Choose a CPU in the process's allowed affinity set. Builds use the default caches
and `--seed=0`. The runner builds the current compiler with `-Doptimize=fast`,
compiles both programs outside the timers, and leaves the checkout's executable
outputs alone. ReleaseFast optimizes the compiler; Chimera's generated machine
code uses its ordinary native backend. `--compiler PATH` reuses an existing
compiler instead of building one; its binary hash is retained with the results.

The runner builds six lanes. Chimera static calls `values.sort(int, before)`;
Chimera runtime calls `values.sort(before)`. The C++ template lanes use their
default comparator. The two C++ runtime lanes pass the ascending comparison as
a function pointer to [runtime.cpp](runtime.cpp), compiled as a separate
translation unit without LTO. Its sorting helpers cannot see the concrete
callback from [main.cpp](main.cpp). The runtime lanes therefore compare function
pointer interfaces, and the static lanes compare specialized interfaces. The
algorithms and runtime bounds checks still differ between languages.

Each program fills the same stack-backed array of signed 32-bit integers and
sorts it eight times by default. Size, round count, distribution, and seed match
between languages. The round count, distribution, and seed arrive on stdin.
Distributions are a deterministic 16-bit pseudorandom sequence, ascending values,
descending values, 16 distinct keys, and ascending runs of 256 elements arranged
in reverse order. Two nearly sorted cases swap the middle adjacent pair, or move
the smallest element to the end. Each round regenerates the unsorted input.
Random rounds use successive seeds; the 16-bit generator repeats after 65,536 values.

Every round checks ascending order and folds every output value into an
order-sensitive checksum. Python independently sorts the input and verifies the
resulting checksum, outside the timer. Each distribution first passes correctness
probes with seeds 0, 42, and 65,535. Timed batches use seed 0, one discarded full
warm-up per algorithm, and nine samples with rotating algorithm order. Failures
abort the run. Output includes medians, minima, maxima, and wall-time ratios;
optional JSON preserves every sample, toolchain and machine details, affinity,
executable sizes, and workload/sort source hashes. The C++ size covers its combined
binary containing all four C++ lanes; the Chimera binaries are separate per mode.

The timer measures **whole-process wall time**, including startup, input, array
initialization, sorting and its scratch allocations, verification, output, and
cleanup. It excludes compiler builds, compilation, and oracle construction.
Reported milliseconds cover the entire batch, not one sort. This measures the
cost of using each sorting implementation in a matched workload; initialization,
verification, and process overhead can dominate especially for ordered inputs
and small arrays. It does not isolate sort-kernel time or attribute differences
between algorithm choice, bounds checks, callback calls, and machine-code quality.

The [recorded comparison](../results/array-sort/README.md) retains a run on the
development machine.
