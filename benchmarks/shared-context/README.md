# Shared context runtime qualification

[run.py](run.py) builds the current Fast compiler, then compiles and qualifies
27 optimized Chimera binaries from [main.chi](main.chi). Each workload runs
through zero, one, and four checked forwarding providers or logging backends.
A binary loop count arrives through stdin; every sample validates the exact
checksum, service count where applicable, and empty stderr. Binaries are warmed
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
logging timings and is qualified by compiler integration tests.

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
not charged to the service-handle measurements.
