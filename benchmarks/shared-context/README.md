# Shared context runtime qualification

[run.py](run.py) builds the current Fast compiler, then compiles and qualifies
36 optimized Chimera binaries from [main.chi](main.chi): 27 core service variants
and nine separate element-hook/I/O variants. Each workload runs
through zero, one, and four checked forwarding providers or logging backends.
A binary loop count arrives through stdin; every sample validates the exact
checksum, service/drop count where applicable, and exact stderr. Binaries are warmed
before timing, and sample order alternates.

```sh
python3 benchmarks/shared-context/run.py --rounds 200000 --samples 7 \
  --output benchmarks/results/shared-context/runtime.json
```

Use `--cpu N` only for a CPU allowed by the current affinity. `--compiler PATH`
uses an explicitly supplied compiler instead of building one. Do not run
measurements concurrently with tests or builds. See the repository
[measurement protocol](../README.md#measurement-protocol).

The explicit and contextual lifecycle cases construct a capacity-one `List(int)`,
append one integer, read it, and destroy the list on each iteration. Their
matched difference includes ambient selection and checked forwarding; both
release through the provider retained by the allocation. Spare append reserves
its entire capacity before the loop. Growing append starts empty. Neither
append case has element ownership hooks.

Logging cases compare disabled filtering, an enabled backend that increments a
counter, and an enabled pure no-op backend. Wrapper thresholds preserve disabled
filtering before dispatch. The counter backend reports delivered events;
its update cost is separate from the pure no-op case. Known pure backends may
benefit from ordinary compiler optimization. Actual stderr I/O is outside these
core logging timings and is measured separately below; compiler integration
tests also qualify output and failure behavior.

The lifecycle, append, and logging rows measure whole-process time, including
startup, input, checksum output, and final cleanup. Destruction rows allocate
and initialize all nested lists before emitting `ready`. The driver then starts
a separate interval, sends one byte, and measures removal from the outer list,
inner destruction, checksum output, and exit. This excludes startup and allocation
construction; it includes the pipe handshake and removal/loop overhead. Explicit
and contextual destruction use the same loop and list shape. Provider wrappers
remain alive through the destruction interval. These rows are not a timer for
an isolated machine `free` instruction.

The report records individual samples, medians/ranges, source and compiler
hashes, machine/affinity, generated binary sizes, and actual callable, Allocator,
Logger, Allocation(int), and List(int) layouts. Sizes are native x86-64 facts,
not target-independent ABI promises. Element-hook costs and actual I/O costs are
not charged to the core service-handle measurements. The two element lifecycle
rows use identical element fields, size, construction, provider selection, and
cleanup loops; only the second element type adds a destructor that increments
its borrowed counter. Both report the exact drop count, including zero for the
baseline. Their difference includes hook dispatch/bookkeeping and the counter
write, not arbitrary application destructors.

The root stderr rows deliver every event through the real root backend and
validate every `info: event\n` byte. Stderr is a pipe captured and drained by the
benchmark parent. Timing includes process startup, pipe writes, parent draining,
checksums, and cleanup, not terminal rendering or filesystem latency. These rows
are separate from no-op backend timings and do not estimate other I/O sinks.

The driver retains all seven fixed samples rather than selectively remeasuring
noisy rows. A full sample range above 2% of the median, or fewer than two samples,
marks a row `unstable`. This is the repository's observed-repeatability heuristic,
not a confidence interval. Submillisecond whole-process timings are particularly
sensitive to startup and scheduling; small element-hook differences within the
recorded ranges do not establish an isolated hook cost.

## Recorded qualification

The [raw report](../results/shared-context/runtime.json) records the 2026-11-09
dirty worktree based on `2c1c9d9`, using the rebuilt Fast compiler, Zig 0.17.0,
Linux x86-64, CPU 19, 200,000 rounds, and seven alternating-order samples.
All 36 variants passed compilation, count-19 qualification, count-42 warm-up,
and exact output checks for every measured run. Sixteen rows exceeded the 2%
range heuristic and are explicitly marked unstable; no samples were dropped.

Native sizes in bytes: callable 16, Allocator 32, Logger 24, Allocation(int) 56,
and List(int) 64. Both element-hook comparison types are 16 bytes.

Median milliseconds for the complete 200,000-round workload:

| Workload | 0 wrappers | 1 wrapper | 4 wrappers |
| --- | ---: | ---: | ---: |
| Explicit lifecycle | 362.368 | 363.855* | 362.239 |
| Contextual lifecycle | 364.612 | 436.800 | 633.591 |
| Spare append | 3.216* | 3.261* | 3.251* |
| Growing append | 3.653* | 3.646* | 3.725* |
| Disabled logging | 0.571* | 0.710* | 0.732* |
| Enabled counter backend | 32.355 | 64.609 | 162.794 |
| Enabled pure no-op backend | 32.252 | 64.161 | 161.818 |
| Explicit destruction | 236.671* | 234.272* | 234.269* |
| Contextual destruction | 234.123* | 269.953* | 364.794 |
| Element lifecycle without hook | 366.015 | 434.947 | 628.017 |
| Element lifecycle with counted drop | 364.508 | 436.871 | 631.575 |
| Enabled root stderr pipe | 202.709* | 273.449 | 478.962 |

`*` marks an unstable row. Full ranges and individual samples are in the report.
Zero-wrapper contextual lifecycle was 1.006 times the explicit baseline; deeper
rows additionally pay checked forwarding. Enabled logging likewise scales with
checked backend nesting. The element-hook ranges overlap: these measurements do
not resolve a standalone hook cost or imply that hooks are free. Real pipe I/O
is substantially different from a no-op backend and must not be attributed to
context selection alone.
