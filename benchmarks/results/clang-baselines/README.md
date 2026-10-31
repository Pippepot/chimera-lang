# Clang C References

Both maintained C benchmark drivers now select `clang` explicitly. The history
recorder stores its executable path and version; GCC cache entries do not match
Clang. Historical GCC records retain their identity and labels. Compiler-unspecified
C++ compilation estimates have been removed from the generated history graphs.

On 2026-10-31, the unchanged 88-million sieve ran on CPU 4 of an AMD Ryzen 9 3900X
with Zig 0.17.0 Fast and Clang 22.1.8. Builds were outside the runtime timers;
no other benchmark, test, or build ran during sampling. Each lane passed the
small correctness probes and one discarded warm-up. Every full run printed
`5107832` and exited 0. All three lanes met the 2% full-range criterion with two
samples in the qualification batch:

| Executable | Median (s) | Samples (s) |
| --- | ---: | --- |
| Chimera | 1.219518 | 1.216273322, 1.222763494 |
| Clang -O0 | 1.612984 | 1.609980849, 1.615986804 |
| Clang -O3 | 1.004722 | 1.008549491, 1.000895206 |

Chimera takes 1.214x the Clang `-O3` wall time locally. These results describe
this workload and machine. The first batch narrowly hit the Clang `-O3` noise cap;
[sieve-initial.json](sieve-initial.json) retains all samples and their original status.
[sieve.json](sieve.json) contains the qualified measurements, compiler identity,
protocol, and source hashes; [sieve.csv](sieve.csv) is the actual driver output.

The updated standalone key-search runner passed its reference-prefix and
invalid-input probes and the index-7 output for Chimera and Clang `-O0`/`-O3`.
See [key-check.txt](key-check.txt). These are correctness probes, not runtime
acceptance measurements. Frozen binaries, earlier key-search Clang timings, and
assembly remain in the [key-search results](../key-gen-loops/).

History tests cover the selected compiler, cache separation, graph labels, and
measured-only compilation legends. No compiler implementation or workload source
changed for this switch.
