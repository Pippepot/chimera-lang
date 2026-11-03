# Static and runtime sort comparators

The [benchmark runner](../../array-sort/README.md) compares matching static and
runtime callback interfaces in Chimera and C++. All timings below are whole-process
wall time, including generation, sorting, scratch allocation, verification,
startup, and cleanup. They do not isolate sorting-kernel time.

```sh
python3 benchmarks/array-sort/run.py --cpu 4 --output benchmarks/results/array-sort/static-samples.json
```

Machine: AMD Ryzen 9 3900X, Linux x86-64, Zig 0.17.0; Clang 22.1.8 with
GNU libstdc++ 16. C++ flags are `-std=c++17 -O3 -DNDEBUG -fno-lto`.
Each process sorts 65,536 signed 32-bit integers eight times. Measurements use
one discarded full warm-up per lane/distribution, then nine samples with
rotating lane order, pinned to CPU 4. Each distribution also passes independent
correctness probes with seeds 0, 42, and 65,535.

Chimera static calls `values.sort(int, before)`; runtime calls
`values.sort(before)`. C++ static lanes use the default comparator; runtime lanes
pass a function pointer into a separately compiled translation unit without LTO.
Both C++ interfaces support ordinary runtime functions. Chimera is stable in
both modes; C++ `std::stable_sort` matches that ordering guarantee.

Median milliseconds per batch of eight sorts (lower is faster):

| Input | Chimera static | C++ sort | C++ stable_sort | Chimera runtime | C++ sort runtime | C++ stable_sort runtime |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| random | 140.624 | 27.677 | 21.859 | 153.799 | 34.736 | 28.064 |
| sorted | 6.727 | 7.207 | 12.051 | 7.117 | 17.556 | 15.780 |
| reversed | 7.515 | 6.376 | 12.976 | 7.864 | 13.730 | 15.486 |
| duplicates | 41.042 | 11.898 | 18.764 | 44.325 | 18.627 | 25.790 |
| runs | 43.941 | 8.398 | 12.325 | 48.239 | 16.965 | 16.152 |

On random input, specializing the comparator reduces Chimera's process time by
8.6% (1.09× speedup). The static lane still takes
5.08× the C++ default `std::sort` time; the runtime lane takes
4.43× the C++ runtime `std::sort` time. Eliminating indirect comparisons therefore
explains only part of the difference. The languages still use different sorting
implementations, bounds checks, and generated machine code.

The duplicate-heavy measurements include visible outliers; consult minima,
maxima, and all nine samples in the [raw record](static-samples.json). The raw
record also retains source and compiler binary hashes, versions, affinity, and
executable sizes. The [earlier runtime-only comparison](samples.json) is retained
as a separate snapshot and was not overwritten.

## Code generation and size

Named assembly was inspected with the measured compiler, using `--debug=asm`
on the same source with the runtime mode selected or discarded at compile time.
Both the explicit static overload and default `sort()` have zero indirect call
sites in their sort helpers, and the comparison/adaptor functions are inlined.
The runtime overload retains 14 indirect comparison call sites. There are 12
emitted sort-helper bodies in each mode; specialization preserves the shared
algorithm rather than forcing recursive helper inlining.

- Chimera static executable: 93,452 bytes.
- Chimera runtime executable: 95,621 bytes.

These are separate programs using one comparator each. They do not measure code
growth in a program that retains multiple static comparator specializations.
The C++ executable contains all four C++ lanes and is not a per-lane size baseline.

## Verification

Every measured output passed ascending-order and order-sensitive checksum checks
against Python's independently sorted input. Additional smoke runs at 20 and 257
elements passed all five distributions and all six lanes, covering the insertion
threshold and a partial natural run; their one-sample timings are not included
as performance measurements.

The routine safe suite passed 2,418 tests with 24 skipped; its only failure was a
source-edit cache fixture still matching the old callback-call syntax. After
updating that fixture, all 71 disk-cache tests passed. The two affected static-sort
tests also passed on the final exact-element-type constraint. The checks together
cover 2,419 passing tests and 24 skipped, including incremental comparator edits,
cache restoration, ownership, stability, and native/interpreter parity. Formatting
checks and `git diff --check` passed.
