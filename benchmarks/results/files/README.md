# Filesystem implementation qualification

The complete [std.files API](../../../docs/FILES.md) uses ordinary library types,
converters, ownership, and error alternatives. Compiler changes provide typed
Linux x86-64 externs, shared parameter representation for native and ordinary functions,
and independent instance-field and type-declaration name scopes.

The final implementation includes EOF probing at the result size limit, so an
exactly full result succeeds at EOF and an oversized stream returns size_limit.
The boundary is tested with an injected small limit rather than gigabytes of data.

## Existing-workload performance

Baseline compiler/library source: `c52b963684a8a25b375bcf42ffea8ee3db15bdbc`. The candidate is
the working tree identified in [identity.json](identity.json), including exact
source and binary hashes. The benchmark driver and generated workloads are
unchanged. Both compilers use Zig 0.17 fast mode with LLVM and their own ordinary
precompiled standard-library bundle. C comparisons are skipped because these
measurements compare existing Chimera behavior before and after the feature.

The [benchmark protocol](../../README.md#measurement-protocol) supplies the timer
boundaries and result checks. Compilation uses the complete million-line workload
with zero and eight workers. Serial compilation and runtime use CPU 0; the eight
workers use CPUs 0 through 7. No builds, tests, or other benchmarks ran concurrently.
Cold includes registration, analysis, native code generation, and linking. Leaf edit
changes one source in the same database and relinks. Runtime checks the actual
5,107,832-prime output for the 88-million sieve and its smaller correctness probes.

Each compiler/worker pair has two runs, each with one discarded warm-up and three
measured cold/edit samples. Runtime has one warm-up and five measured samples.
The table pools every recorded sample within each measurement. Negative changes
mean a lower median elapsed time; they do not establish a feature-caused speedup.

| Measurement | Baseline ms | Candidate ms | Change |
| --- | ---: | ---: | ---: |
| cold, 0 workers | 21865.044 | 21431.146 | -1.98% |
| leaf-edit, 0 workers | 138.501 | 115.624 | -16.52% |
| cold, 8 workers | 4902.138 | 4802.157 | -2.04% |
| leaf-edit, 8 workers | 204.265 | 181.276 | -11.25% |
| sieve runtime | 589.597 | 581.569 | -1.36% |

No measured regression appears on these workloads. Cold runs satisfy the existing
2% repeatability rule; incremental and runtime samples include runs outside that
rule. All raw samples and their original stability flags are retained. These are
descriptive measurements on this machine, not a confidence interval or a proof
that every workload has unchanged performance.

The core executable remains 174,665,126 bytes. The runtime executable grows from
44,089 to 44,473 bytes. Every cold and edited executable passes its result check.

Raw samples:

- Serial: [baseline](baseline-0.csv), [confirmation](baseline-0-confirm.csv),
  [candidate](candidate-0.csv), [confirmation](candidate-0-confirm.csv).
- Eight workers: [baseline](baseline-8.csv), [confirmation](baseline-8-confirm.csv),
  [candidate](candidate-8.csv), [confirmation](candidate-8-confirm.csv).
- Runtime: [baseline](baseline-runtime.csv), [candidate](candidate-runtime.csv).

Reproduce with each retained snapshot's history benchmark executable:

```sh
# Build the driver with the snapshot's own compiler and bundled std.
zig build history-benchmark --seed=0 -j1 -Doptimize=fast -- --case=core-1000000 --lines=10000 --samples=3

# Run the built executable directly; repeat each compilation command twice.
taskset -c 0 <history-benchmark> --case=core-1000000 --samples=3
taskset -c 0-7 <history-benchmark> --case=core-1000000 --workers=8 --samples=3
taskset -c 0 <history-benchmark> --case=sieve-88000000 --skip-c --samples=5
```

## Verification

The routine safe suite passes: 2,691 tests passed and 24 optional checks skipped.
The focused 21-test filesystem suite also passes. The final explicit x86-64
syscall type produces a byte-identical benchmark binary to the measured one. Coverage
includes native/evaluator path parity, non-UTF-8 names, conversions and view
lifetimes, file moves and consuming close, collection and directory descriptor
cleanup, injected close errors, operation/close error precedence, storage limits,
allocation refusal, opening modes and competing exclusive creation, short/EOF
reads and failed reads, offsets, resizing, synchronization, metadata, symlinks,
namespace changes, evaluator I/O rejection, bundled source edits, native signature
validation, and persistent query restoration/recomputation.

```sh
zig build test --seed=0 -Doptimize=safe
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/files_test.zig
zig build test --seed=0 -Doptimize=safe -Dtest-source=tests/query_disk_cache_test.zig -Dtest-filter="filesystem snapshots"
zig fmt --check <modified-zig-files>
git diff --check
```

Exhaustive allocation-failure sweeps were not enabled.
