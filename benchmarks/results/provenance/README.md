# Result-Correlated Provenance

## Protocol

`zig build provenance-benchmark --seed=0 -j1` measures independent output
slots, repeated writes to one slot, selection of saved write history, and
forwarding depth at sizes 8, 32, and 128.
The inputs are accepted by both the baseline and the implementation: both
referents are writable and contain 40. Independent calls select their results
immediately; `serial_selected` selects every saved result after all calls.
The generated program runs 100,000 iterations and must exit 42.

Opt-in reference-contract cases use the same sampler and timers:

```sh
zig build provenance-benchmark --seed=0 -j1 -- --shape=cleanup --size=32
zig build provenance-benchmark --seed=0 -j1 -- --shape=callable --size=32
```

`cleanup` installs handles at automatic-drop boundaries; its helper edit switches
between two writable captured sources. `callable` repeatedly obtains returned
callbacks; its helper edit changes the known target. Both source states return
42 on the baseline and candidate. These cases do not alter the default workload set.

Cold time includes a fresh database, source registration, the snapshot's own
standard bundle, and executable construction. Contract-edit time changes only
the helper module's alternative/effect mapping in the same database. Generation,
database teardown, executable writing, and correctness checks are outside these
compilation timers. Runtime includes process creation and exit validation.

Executable SHA-256 fingerprints are emitted to stderr as
`image,case,phase,source-state,sample,sha256`, outside the compilation timers.
Compare matching normal/inverted source states, not sample indices: adaptive
sampling can finish cold and edit phases at different times. Preserve this
metadata alongside the timing CSV to compare emitted bytes as well as latency.
Runtime always restores the normal source and builds its executable before the
discarded runtime warm-up; restoration and rebuilding are outside all timers.

Sampling reuses the history policy: one discarded warm-up, at least two samples,
a 2% range/median stability threshold, and caps of three compilation or five
runtime samples. Capped noisy measurements are retained and marked unstable.
Baseline and candidate must use the same driver, machine, affinity, Zig build
mode, zero query workers, and backend/optimizer snapshot.

## Typing Reuse Boundary

`ConstructFunctionBody` retains source-body equality across helper edits.
`InferReferenceEffects` derives merged effects from cached validated typing when
available, with precise-contract fallback. `TypeFunctionInstance` retains bodies
proven valid for the entire capture union, including incoming no-write captures.
Exactness flags distinguish genuinely merged effects from unchanged precise facts,
avoiding a second typing pass for exact effect-exporting attempts. Conservative
forwarders derive precise exported contracts from their callees. Layered references,
aggregate slots, captured-variable effects, generations, and initializer regions
retain precise analysis. Publication owns the deep copy of body/construction views.

**Incremental improvement verified; overall performance not accepted.** Saved-history
edits at 128 and 512 calls are now approximately baseline cost rather than the
original 2.80/4.52-times regression. Forwarding edits improve, but cold forwarding
128 remains 9-10% slower in the final contended, unstable matrix/control. An earlier
same-source control was near baseline (18.707/18.877 ms, both unstable). These do not
establish an uncontended cold result; the roadmap performance gate remains open.

Final `exact-final-*` runs use the protocol above and CPU 4. Other workspace work
was explicitly permitted; another LLVM compiler was active at the final resource
sample. Timings increased substantially in both lanes, so absolute values and small
differences must not be treated as stable qualification. `*` below means unstable.
Values are milliseconds, baseline / final candidate.

| Case | Cold B / C | Contract Edit B / C | Runtime B / C |
| --- | ---: | ---: | ---: |
| independent-8 | 7.067* / 7.220* | 1.030* / 0.849* | 3.531* / 3.466* |
| independent-32 | 13.912* / 14.808* | 3.767* / 3.227* | 13.348 / 13.393* |
| independent-128 | 58.033* / 51.514* | 12.324* / 7.353* | 72.906 / 73.224* |
| serial-8 | 6.624 / 6.247* | 0.953* / 0.907* | 2.656* / 2.124* |
| serial-32 | 7.296* / 7.232* | 1.018* / 0.813* | 6.331* / 6.574 |
| serial-128 | 15.747* / 11.479* | 3.763* / 3.694* | 30.366* / 29.364* |
| serial_selected-8 | 6.750* / 6.385* | 0.943* / 0.759* | 3.842* / 3.730* |
| serial_selected-32 | 14.470* / 10.891* | 3.608* / 1.453* | 19.761* / 18.246* |
| serial_selected-128 | 34.550 / 32.497* | 9.923* / 9.936* | 89.694 / 89.007 |
| forwarding-8 | 6.928* / 6.317* | 1.190* / 0.794* | 1.979* / 2.012* |
| forwarding-32 | 14.230* / 13.367* | 5.009* / 1.501* | 2.660* / 2.718* |
| forwarding-128 | 33.272* / 36.332* | 17.732* / 8.706* | 3.114* / 3.057 |
| serial_selected-512 | 178.425* / 175.338* | 45.925* / 46.417* | 411.770 / 401.231 |
| serial-512 | 32.260* / 28.462* | 11.029* / 7.835* | 157.537 / 157.975 |

The candidate-first forwarding-128 control produced cold 35.410*/38.893* ms,
edit 18.521/10.113* ms, runtime 3.157*/3.082* ms. All benchmark executions returned
42. All 42 shared phase/source-state image groups match byte-for-byte; two additional
groups occur in only one lane because sampling stops adaptively.

[Baseline](exact-final-baseline.sources.json),
[pre-boundary](exact-final-before.sources.json), and
[final](exact-final-after.sources.json) manifests verify 69 inputs each. Historical
snapshots are unchanged; only `src/queries.zig` and `src/frontend/typing.zig` differ
between the pre-boundary and final candidate. Backend, optimizer, std, driver,
sampler, and build registration match. The final source digest is
`9f7ba20ac0a2c8ec618099fb5d897bdb69b8f02c8633dd581cc888077464dd9f`.
Raw timing/image CSVs share the `exact-final-` prefix; `-selected`, `-serial`, and
`-forward` identify scaling and the reversed control.

Saved-history edits grow by 6.84 then 4.67 for 32 -> 128 -> 512 calls, versus
2.75 then 4.63 on the baseline. These noisy finite samples do not prove an
asymptotic exponent. Eligible edits reuse validated typing; full selected-history
analysis still has the quadratic worst case described below.

Final focused checks pass three query reuse/precision/lifetime regressions, 14
provenance tests, and two correlated disk-restoration tests. Final full Safe query
and 68-test disk-cache suites pass. The earlier routine Safe run passed
2346/2371 tests, with 24 skips and one captured-slot automatic-drop failure.
A removed diagnostic probe established `TypeFunctionInstance` rejects that body
while direct precise analysis accepts its invalid write. That cleanup failure is
unresolved; the full routine result is not represented as green for final source.

Local construction inside reusable typing was rejected after forwarding edit cost
rose to 10.248*/8.528* ms (candidate/baseline). It is not the final implementation.
Earlier probe prefixes describe intermediate versions, not this final state;
`qualified-*` also overlapped another build. Original `final-*` and
`confirm-selected-*` artifacts below remain unchanged.

## Reference Contract Fixes

The separate reference-contract investigation fixes opaque handle authority,
immutable callable recovery, and scheduled automatic-drop writeback. Captured-slot
reads use cleanup-time contents; mutable parameter outputs include cleanup writes.
The final affected checks pass 112 reference tests and 366 query tests, with six
query skips. The close-out reused those successful cached checks; the CLI build,
formatting, whitespace, and editor diagnostics also pass. The earlier shared full
run's captured-slot failure passes in the subsequent reference suite. A new full
routine run was not performed for this final source.

**Performance is not qualified.** The matched cleanup-128 cold median grows from
21.426 to 27.039 ms (+26.2%), and its edit median from 14.814 to 20.011 ms (+35.1%);
both pairs are stable. This agrees with earlier cleanup regressions. Further
optimization is deferred at the user's request to finish the close-out quickly.

The [qualification artifact](reference-contract-scheduled-state.json) retains
source hashes, every sample and stability flag, raw CSVs, and image fingerprints.
The isolated lanes share backend, optimizer, std, build, driver, and sampler;
only the task's typing and query changes differ. Runs use fast LLVM, CPU 4,
zero query workers, `--seed=0`, and `-j1`, alternating lane order by case.
All executions return 42, and all 37 shared image groups match. Image equality
establishes emitted-byte parity, not runtime latency acceptance.

Size-128 medians below are milliseconds, baseline / candidate. `*` means capped
as unstable. The artifact also retains all size-32 results. These measurements
do not replace or qualify the concurrent typing-boundary investigation.

| Case | Cold B / C | Contract Edit B / C | Runtime B / C |
| --- | ---: | ---: | ---: |
| independent | 25.267* / 26.324* | 4.605* / 4.980* | 35.361 / 34.943 |
| serial | 7.767* / 7.436* | 2.756* / 2.463* | 14.914 / 15.285 |
| serial_selected | 13.853* / 16.242* | 4.448* / 5.252* | 43.493 / 43.212 |
| forwarding | 19.116 / 17.029 | 4.825* / 4.911* | 1.459* / 1.458* |
| cleanup | 21.426 / 27.039 | 14.814 / 20.011 | 0.933* / 0.900* |
| callable | 5.309* / 5.176* | 1.290* / 1.289* | 0.924* / 0.963* |

## Original Results

**Not acceptable.** The corrected saved-history contract edit at size 128 grew
from 4.396 to 12.299 ms (2.80 times), with both phases stable. A candidate-first
confirmation produced 4.764 versus 13.756 ms (2.89 times), with both phases capped
as unstable. Size 512 grew from 23.870 to 107.839 ms (4.52 times); the candidate
was unstable. The repeated incremental regression prevents closing the roadmap
item. Cold and runtime measurements do not establish a separate repeatable
regression: most cold samples are noisy, and emitted images are identical.

Final runs used Zig 0.17.0, the fast LLVM benchmark driver, zero query workers,
`--seed=0`, `-j1`, and CPU 4 on an AMD Ryzen 9 3900X, Linux 7.2.5-3-omarchy.
Resource checks before and after found no competing compiler or benchmark jobs.
The matrix ran baseline then candidate; selected size 512 ran candidate first,
and the size-128 confirmation reversed the matrix order. The snapshot standard
bundles were built independently; their production sources are identical.

The generated [baseline manifest](final-baseline.sources.json) and
[candidate manifest](final-candidate.sources.json) record all 69 production/build
inputs, modes, hashes, environment, and corrected protocol identity. Backend,
optimizer, std, build registration, driver, and sampler hashes match. Only
`typing.zig`, `reference_origins.zig`, `structures.zig`, and the three contract
serialization modules differ. Main's concurrent frontend changes are not part
of this isolated attribution.

Medians below are milliseconds, baseline / candidate. `*` means capped as
unstable, not a qualified stable measurement. Stable phases stopped at two
samples; unstable compilation/runtime phases hit three/five samples respectively.
The [baseline CSV](final-baseline.csv) and [candidate CSV](final-candidate.csv)
retain every sample and stability flag.

| Case | Cold B / C | Contract Edit B / C | Runtime B / C |
| --- | ---: | ---: | ---: |
| independent-8 | 3.523* / 3.444* | 0.955* / 1.044* | 2.109* / 1.725* |
| independent-32 | 6.637* / 7.062* | 1.844* / 4.315* | 6.710* / 6.284* |
| independent-128 | 29.839* / 31.494* | 5.058* / 25.230* | 35.923 / 36.601* |
| serial-8 | 3.177* / 2.778* | 0.855 / 1.171* | 1.041* / 0.905 |
| serial-32 | 3.797* / 3.807 | 0.981* / 1.447* | 3.447* / 3.107* |
| serial-128 | 7.718* / 6.871* | 2.034* / 3.856* | 14.457* / 14.039 |
| serial_selected-8 | 3.440* / 3.287* | 0.863* / 1.027 | 2.036 / 2.012* |
| serial_selected-32 | 6.376* / 5.915 | 1.591* / 3.017* | 9.180* / 9.163* |
| serial_selected-128 | 15.105* / 13.917* | 4.396 / 12.299 | 43.204 / 44.371 |
| forwarding-8 | 2.755* / 2.786 | 0.880* / 0.931* | 0.952 / 0.940 |
| forwarding-32 | 5.430* / 5.912* | 2.354* / 2.708 | 1.146* / 1.147* |
| forwarding-128 | 17.329* / 17.362* | 8.593* / 10.339* | 1.443* / 1.429* |
| serial_selected-512 | 91.230 / 105.281* | 23.870 / 107.839* | 203.555 / 212.672 |
| serial-512 | 17.262* / 16.249* | 5.277* / 11.739* | 76.069 / 76.582 |

The 512-call samples are in `final-{selected,serial}-{baseline,candidate}.csv`;
the reverse-order control is in `confirm-selected-{baseline,candidate}.csv`.
All 42 shared phase/source-state image groups in the final matrix and scaling
runs have a single identical SHA-256 across baseline and candidate, including
normal and inverted sources. Every benchmark execution returned 42; focused
native/interpreter provenance controls passed. Runtime differences with identical
images are timing variation, not different generated instructions.

For saved history, increasing 32 -> 128 -> 512 calls multiplies candidate edit
time by 4.08 then 8.77, versus 2.76 then 5.43 on the baseline. Plain serial edits
multiply by 2.66 then 3.04 on the candidate. These finite, partly noisy samples
expose growing selection cost; they do not prove a universal asymptotic exponent.
The baseline can retain callers because its merged contract is unchanged; the
new per-alternative mapping changes and demands caller reanalysis. Avoiding that
retyping requires a broader boundary change separating provenance validation
from reusable typed/codegen work, not another guard-evaluation micro-optimization.

Final main-source focused checks pass 14 result-correlated tests, 33 flow-typing
tests, contract mapping recomputation, direct/indirect cache clear/edit/restore,
and two private resolution checks. The isolated candidate also passes all 29 List
tests. The one routine Safe run had 2073/2092 tests pass, 17 skipped, two failures,
and a private-root compilation failure. The attributable explicit-drop iterator
failure was repaired by preserving explicit physical flow origins; its focused
test and the affected 81-test Safe iteration suite now pass. Concurrent main
updates supplied the missing private `ReferenceContentsAnalysis` type and repaired
factory-demand behavior. Their affected Safe checks now pass one query test and
two private tests. All originally failed checks now pass; the full routine suite
was not repeated after these repairs, so the original full-run result is not
rewritten as a green run for the final main source. Final formatting and
whitespace checks pass.

Earlier drivers reversed the condition without changing which result member
owned the write. Their edit phase did not measure result-effect invalidation and
is invalid for acceptance. The corrected driver keeps the write condition fixed
and swaps `unit`/`none`; only `final-*` and `confirm-selected-*` samples qualify
this final source state. Older probe samples remain exploratory.

## Complexity

Let `O` be distinct origin payloads, `D` reachable condition nodes, `A` reachable
alternative atoms, `V` variant members, and `G` the initialized guard-ID prefix.
One selected-result filter costs `O(G + O + D + A * V)`, assuming cached type
facts, with `O(G)` memo storage and `O(D)` worst-case recursion depth. Dense
memos evaluate each reachable node once across all origins of one incoming
refinement snapshot; different incoming edges never share evaluated entries.
Selections that retain every origin preserve the original head. Unrefined atoms
skip variant matching. Guard interning is expected constant time, except
full-variant coverage checks costing `O(V)`. Large origin merges use expected-
linear hashing; short sets use bounded scans.

Writability checks now evaluate guards only for readonly origins and do not
rebuild an origin set. Their bound is `O(G_r + O + D_r + A_r * V)`, where
`D_r` and `A_r` are reachable through readonly origins; all-writable sets need
only the origin scan and initialize no guard memo. Selection does not scan all
flow places. Eligible immutable whole-result copies reuse their existing proof
instead of adding physical tag places; explicit physical flow origins remain
authoritative for match captures. Write invalidation visits the existing
physical-place index, not synthetic result proofs.

Identical payloads merge their conditions with shared AND/OR nodes. Repeated
writes with a fixed payload count create `O(N)` condition metadata over `N`
calls, not an enumeration of alternative histories. Repeated selection of a
growing graph can still require quadratic total work. Increasing distinct
payloads, projections, or live owners adds corresponding work; this is not a
universal linear compiler bound. Loop expansion also depends on nesting and
backedges. Removing iteration-local conditions memoizes graph rewriting per
removal/limit pair, with the same variant-coverage caveat.

Contract equality uses unordered scans: output-group matching is quadratic in
group count, and each group's origin comparison is quadratic in origin count,
including path comparisons. Conservative-effect projection deduplicates the
union with unordered singleton comparisons: for `K` input origins and maximum
path length `L`, its bound is `O(K^2 * (1 + L))`, with `O(K)` origin storage. Publishing
construction and typed-body views deep-copies their output once, linear in the
published tables and nested payloads.

Transparent forwarding recognition scans instructions and positional argument
paths, plus signatures and the exact callee-contract dependency. Accepted
forwarders have disjoint parameter paths, making recognition linear in their
instruction and argument counts. Conservative typing reuse avoids rebuilding SSA
and provenance graphs when the merged proof remains valid; dependency validation
and executable construction still run. Changed result partitions update precise
forwarded exports without retyping that wrapper. Capture-sensitive, layered, and
cleanup-sensitive bodies retain full precise recomputation. This removes the
measured repeated-selection work from eligible contract edits, not its worst-case
quadratic bound when full analysis is required.