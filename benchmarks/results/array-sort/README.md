# Stable sorting with static and runtime comparators

The [benchmark runner](../../array-sort/README.md) compares matching static and
runtime callback interfaces in Chimera and C++. Timings are whole-process wall
time, including generation, sorting, scratch allocation, verification, startup,
and cleanup. They do not isolate sorting-kernel time.

## Matched before and after measurements

The [baseline](optimization-before.json) and [optimized run](optimization-after.json)
use the same checkout revision, workload, compiler source, machine, toolchain, and
CPU affinity. The standard-library sort source changes between runs; both raw
records retain source hashes and the compiler executable hash. The compiler was
already built and supplied with `--compiler` in each run.

```sh
python3 benchmarks/array-sort/run.py --cpu 4 --compiler /path/to/chimera --output /tmp/array-sort.json
```

Machine: AMD Ryzen 9 3900X, Linux x86-64, Zig 0.17.0; Clang 22.1.8 with
GNU libstdc++ 16. C++ flags are `-std=c++17 -O3 -DNDEBUG -fno-lto`.
Each process sorts 65,536 signed 32-bit integers eight times. Measurements use
one discarded full warm-up per lane/distribution, then nine samples with
rotating lane order, pinned to CPU 4. Each distribution also passes independent
correctness probes with seeds 0, 42, and 65,535.

Median milliseconds per batch of eight sorts (lower is faster):

| Input | Static before | Static after | Runtime before | Runtime after |
| --- | ---: | ---: | ---: | ---: |
| random | 58.316 | 50.013 | 96.973 | 66.919 |
| sorted | 4.904 | 5.066 | 5.689 | 5.630 |
| reversed | 5.493 | 5.761 | 6.272 | 6.404 |
| duplicates | 21.463 | 22.311 | 30.348 | 27.921 |
| runs | 20.011 | 14.819 | 27.199 | 15.518 |

Random input improves by 1.17x with a static comparator and 1.45x with a runtime
comparator. Reversed runs improve by 1.35x and 1.75x respectively. Ordered inputs
retain their scan/reverse fast paths; their small timing differences, and the
static duplicate-heavy result, do not demonstrate an improvement. C++ reference
medians also varied between sessions, so small differences need caution.

Chimera static calls `values.sort(int, before)`; runtime calls
`values.sort(before)`. C++ static lanes use the default comparator; runtime lanes
pass a function pointer into a separately compiled translation unit without LTO.
Chimera remains stable in both modes; C++ `std::stable_sort` matches that guarantee.
In the optimized run, static random input takes 2.20x C++ `std::stable_sort` time,
and static runs take 1.18x. The runtime runs lane takes 0.94x C++'s matching runtime
`std::stable_sort` time. The full six-lane samples and ranges are in the raw records.

## Nearly sorted inputs

A [runtime-history worktree run](nearly-sorted-runtime.json), with refreshed C/C++
references, compares two additional inputs with fully sorted data. These use
65,536 integers and eight sorts per process, with seven rotated samples pinned
to CPU 4. All medians below are milliseconds per process; every correctness probe
and measured output passed. The raw record includes the parent commit, source
hashes, all runtime-history results, and their C/C++ references.

| Input | Chimera static | Chimera runtime | C++ sort | C++ stable_sort | C++ sort runtime | C++ stable_sort runtime |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sorted | 4.653 | 5.539 | 7.219 | 12.079 | 16.992 | 15.890 |
| adjacent swap | 9.106 | 10.654 | 7.304 | 12.387 | 17.378 | 16.078 |
| minimum last | 10.571 | 12.227 | 28.541 | 12.003 | 48.998 | 15.913 |

The adjacent-swap input exchanges the middle pair of an otherwise ascending
array. It nearly doubles Chimera's time despite requiring only two elements to
move, exposing the cost of leaving the allocation-free ordered fast path.
The minimum-last input is `1, 2, ..., N - 1, 0`: one displaced minimum requires
the whole array to shift. Chimera takes a little longer than for the adjacent
swap, while C++ `std::sort` takes almost four times its fully sorted time.
C++ `std::stable_sort` changes little across these inputs. Both cases are retained
because they distinguish local disorder, long-distance displacement, and the
algorithms' different responses.

## Implementation

- Quicksort partitions equal keys only when an ancestor bound or an empty less-than
  partition establishes the need. It recurses into the smaller region and loops
  over the larger one; every iteration consumes depth, preserving the stable
  worst-case fallback even for inconsistent comparisons.
- Large partitions choose a pivot from three medians of three samples.
- Merging buffers the shorter run and writes into the index array in the safe
  direction. Ordered adjacent runs need no movement; strictly reversed disjoint
  ranges move as blocks after two boundary comparisons.
- Index storage is allocated without zero filling. The permutation and each
  scratch range are initialized before any read. Hot loops use private span
  descriptors and copies with offsets established before entering the loop.
- The final permutation trusts the index bounds established by the sorting
  algorithms. Source elements remain stationary during comparison and retain
  their ordinary ownership transfers when the permutation is applied.

The public API, stable ordering, custom copy/move/drop behavior, reference
permissions, and two-index-buffer allocation policy are preserved. The optimized
static executable is 51,722 bytes, compared with 48,790 bytes before; runtime is
60,411 bytes, compared with 51,751 bytes. C++'s 31,016-byte executable contains all
four C++ lanes, so its size is not a per-lane comparison.

## Verification

Every measured output passed ascending-order and order-sensitive checksum checks
against Python's independently sorted input. The sort suite also covers native
and interpreter execution, stability for noncopyable owners, comparator effects,
custom moves and drops, backing references, explicit drop duties, forced stable
fallback, allocation failures, asymmetric and overlapping merges, and changing
inconsistent comparisons. Distribution/length coverage crosses the insertion,
pivot-sampling, and natural-run thresholds.

`zig build test --seed=0 -Doptimize=safe --summary all` passed 2,516 tests with
24 skipped. Zig formatting checks and `git diff --check` passed.

Earlier comparator-specialization measurements remain available in
[static-samples.json](static-samples.json) and [samples.json](samples.json).
