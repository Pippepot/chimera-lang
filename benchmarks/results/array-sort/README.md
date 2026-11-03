# Array.sort versus C++ standard-library sorting

This comparison uses the working tree on 2026-11-03, including the standard-library
updates and optimizer fix for threaded range exits. The initial probe exposed
the cleanup hang; no timings from that broken executable were accepted.

Run the [benchmark](../../array-sort/README.md) from the repository root:

```sh
python3 benchmarks/array-sort/run.py --cpu 4 --output benchmarks/results/array-sort/samples.json
```

The [raw record](samples.json) contains the exact toolchains, compiler binary
hash, workload and sorting source hashes, machine, affinity, and every sample.
Measurements use 65,536 signed 32-bit integers, eight regenerated fill/sort/check
rounds per process, one discarded warm-up per algorithm and distribution, and
nine samples with rotating algorithm order, pinned to CPU 4.

Timings are whole-process wall time, including input generation, sorting,
scratch allocation, order/checksum verification, startup, and cleanup. They are
not isolated sorting-kernel times. Chimera guarantees stability; C++
`std::stable_sort` matches that guarantee, while `std::sort` may reorder equal
elements. The integer workload cannot observe the difference in stability.

Machine: AMD Ryzen 9 3900X, Linux x86-64, Zig 0.17.0; Clang 22.1.8
with GNU libstdc++ 16 (`__GLIBCXX__ = 20260810`), C++17 `-O3 -DNDEBUG`.

Median milliseconds per batch of eight sorts (lower is faster):

| Input | Chimera (ms) | std::sort (ms) | std::stable_sort (ms) | Chimera / sort | Chimera / stable_sort |
| --- | ---: | ---: | ---: | ---: | ---: |
| random | 156.537 | 29.057 | 23.060 | 5.39× | 6.79× |
| sorted | 7.334 | 7.505 | 12.706 | 0.98× | 0.58× |
| reversed | 8.632 | 7.543 | 14.450 | 1.14× | 0.60× |
| duplicates | 50.522 | 13.263 | 20.044 | 3.81× | 2.52× |
| runs | 49.139 | 8.670 | 12.743 | 5.67× | 3.86× |

Random input takes 5.39× the C++ `std::sort` wall time and 6.79× the
`std::stable_sort` wall time. The ordered-input fast path brings Chimera
close to `std::sort` on ascending input and below `std::stable_sort` on
ascending and descending input. Repeated keys and runs remain slower
than both C++ implementations. These ratios describe the complete
workload, rather than isolating algorithm or code-generation costs.

All measured executions and the three per-distribution seed probes
passed the runtime order and independent checksum checks. Additional smoke runs
at 20 and 257 elements passed all five distributions and all three algorithms,
covering the insertion-sort boundary and a partial natural run. Their one-sample
timings are not included as performance measurements.

The broader routine suite run by the standard-library session reported 295
passed, one skipped, and one failure in
[`inlining exposes callee bodies to scalar replacement selects and loop idioms`](../../../tests/optimizer_test.zig)
(expected 1, found 0). This benchmark's own execution checks independently verify
ascending order and an order-sensitive checksum against Python's sorted result.
