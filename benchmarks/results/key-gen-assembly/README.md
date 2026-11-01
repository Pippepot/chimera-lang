# Key-search assembly investigation

Investigation on 2026-11-01 at revision
`e11253e28acb40f60845f0226007e011d576e7a8`. No compiler or workload source was
changed by this investigation. Temporary binary
patches isolate two scan changes: collision-edge placement and direct indexing.

The dominant avoidable cost is **taking a branch over collision-edge copies on
every noncollision**, rather than falling through to the loop test. Moving that
edge code reduces user cycles by 42.4%, accounting for 79.1% of the measured cycle
gap with Clang. Removing the index sign extension alone does not materially
improve cycles on this machine. After the branch change, sum generation explains
most of the remaining gap.

## Matched experiment

AMD Ryzen 9 3900X, runtime pinned to CPU 4, Zig 0.17.0 Fast compiler, Clang
22.1.8 C11 `-O3`, default target options. The uninstrumented Chimera executable
matches the `--debug=optimized,asm` executable byte for byte. The workload is the
unchanged index-10 search. Builds, runtime sampling, counter collection, and cycle
sampling ran separately. The investigation did not run builds or other benchmarks
during sampling.

| Executable | Median wall time (s) | User cycles (billions) | Instructions (billions) | Runtime stable? |
| --- | ---: | ---: | ---: | --- |
| Current Chimera | 2.989364 | 12.626391 | 44.368743 | Yes, 2 samples |
| Collision edge out of fallthrough (`branch`) | 1.756313 | 7.266613 | 44.371228 | No, 5-sample cap |
| Direct array index only (`address`) | 3.029103 | 12.613371 | 38.953063 | No, 5-sample cap |
| Both changes (`both`) | 1.728671 | 7.293987 | 38.955548 | No, 5-sample cap |
| Clang `-O3` | 1.450991 | 5.850009 | 33.368700 | No, 5-sample cap |

All lanes passed reference-prefix checks at indices 3 through 7, invalid-input
checks, and a discarded warm-up at index 10. Every measured and profiled run also
checked the complete index-10 output and exit status. Clang `-O0` passed the small
correctness checks but was not timed. Sampling alternated forward and reverse
lane order; each lane stopped independently at the existing 2% full-range
criterion or five samples. Except for current Chimera, the wall-time batch hit
the noise cap: **these medians are diagnostic, not stable acceptance results**.
The branch variant's observed median is 41.2% lower; the cycle result supplies
separate evidence for the large effect.

Linux `perf_event_open` counted user-space cycles, instructions, branches, and
branch misses for one complete run of each lane. All events ran for their full
enabled duration, with no multiplex scaling. A separate baseline/control pair
is retained too. The current and branch variants retire about 12.14 billion
branches each, with approximately 6.5 million misses (0.053%). Clang retires
11.00 billion branches with 3.0 million misses (0.027%). The improvement is not
explained by fewer retired branches or fewer mispredictions: the layout changes
which branches are taken on the common path. The likely mechanism is predictable
taken-branch throughput; frontend stall events were not measured.

## Owning code and assembly

The current common scan path is seven instructions:

```asm
movsxd rcx, r8d
mov    r9d, DWORD PTR [rsp+rcx*4+0x30f2c]
add    r8d, 1
cmp    ebx, r9d
jne    bound_test                  # taken for almost every pair
# collision edge: set carried valid=false, then jump to outer continuation
bound_test:
cmp    r8d, r10d
jl     scan                        # taken for almost every pair
```

[Codegen's `emitPredicateBranch`](../../../src/backend/codegen.zig) chooses the
physical fallthrough, but when the other edge carries arguments it emits that
edge's copies inline and branches over them. Here the collision edge passes
`false` to the shared exit. Even though the loop test follows the body, its
noncollision edge must jump over the collision copies. Merely changing the
order of source blocks or reversing the comparison will not remove this inline
edge stub.

The `branch` experiment preserves the sign extension, load, increment, both
comparisons, and near-branch encodings. It moves collision argument setup after
the bound-exit setup, using `je collision` and letting noncollision execution
fall through to the bound test. The extra jump on bound exit is outside the hot
scan path. It also retargets initial entry to the relocated bound test, preserving
empty scans. Carried flags, collision-exit state, and the increment before the
comparison remain intact.

Clang's scan has six instructions, direct index addressing, and one taken branch
on the common path. [Machine encoding](../../../src/backend/machine.zig) already
combines the old accumulator copy and sign extension into `movsxd rcx,r8d`.
[Element-address lowering](../../../src/backend/codegen.zig) and the indexed-load
encoder still use `rcx` as the index. Replacing that extension/load pair with a
load indexed by `r8` removes approximately **5.416 billion instructions**, but
leaves the two taken branches and essentially the same cycle count. The direct
index experiment is valid for this scan's nonnegative counter and its 32-bit
writes; it is not justification to discard signed extension for arbitrary indices.

## Remaining gap

Separate user-cycle sampling used a 2,000,000-cycle period, with no lost records:

| Executable | Samples in inner scan / total | Share |
| --- | ---: | ---: |
| Current Chimera | 5,486 / 6,313 | 86.9% |
| `branch` | 2,792 / 3,629 | 76.9% |
| `both` | 2,823 / 3,644 | 77.5% |
| Clang `-O3` | 2,775 / 2,921 | 95.0% |

These are region-level samples, not precise per-instruction stall attribution;
sampling skid can place a sample after its triggering event. The samples imply
roughly 1.67 billion cycles outside the scan for `branch`, versus 0.29 billion for
Clang. That difference closely matches the remaining total-cycle gap of 1.42
billion cycles. In `branch`, 573 samples fall in the nested sum-generation body
and 237 in its two array accessors, out of 837 samples outside the scan.

The generation assembly still contains:

- Out-of-line `Array(int, 13).at` at `0x402cc8` and
  `Array(int, 50000).[]=/3(int)` at `0x402d96`, called once per generated sum.
  Arguments/results pass through stack homes, with additional copies around the
  returned element address.
- Bounds checks on the other four key loads and checked sum arithmetic.
- Expanded range-iterator control state, repeated boolean/finished tests, and
  substantial stack traffic for the nested loop state.

Clang's generation inner body uses direct array loads/adds and one direct sum
store. Chimera's checks preserve stronger semantics than this C reference;
elimination requires proofs. The reason these particular accessor calls remain
uninlined has not been isolated; the inliner's selection and caller-growth policy
are follow-up investigation points, not confirmed causes.

The first implementation target should therefore be **edge-copy placement that
allows loop-continuation fallthrough**, preserving parallel-copy and exit-state
invariants. Then investigate generation accessor inlining, nested counter/range
proofs, and the resulting spills. Direct indexing is a secondary code-size and
instruction-count opportunity, not the leading measured runtime opportunity.
These binary probes are not a compiler implementation or regression verification.

## Evidence and reproduction

- [Runtime samples, order, stability, toolchains, and binary hashes](runtime.json)
- [Hardware counters, including the independent baseline/control](counters.json)
- [Cycle sample IP counts and region boundaries](sampling.json)
- [Exact binary changes and expected hashes](binary-patches.json)
- [Compiler, std, build, and workload source hashes](source-files.json)
- Scans: [current](scan-chimera.asm), [branch](scan-branch.asm),
  [address](scan-address.asm), [both](scan-both.asm), [Clang](scan-clang.asm)

The full compiler output, executables, disassembly, and collection scripts remain
locally in `/tmp/chimera-key-investigation-m9kmn2v3`. Build the recorded revision
with the existing runner's commands to reproduce the baseline. For binary probes,
keep the compiler invocation in a temporary working directory; patches are
deliberately specific to the recorded executable hash. Given that executable as
`/tmp/key-study/chimera`, apply the recorded changes with:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
study = Path('/tmp/key-study')
manifest = json.loads(Path('benchmarks/results/key-gen-assembly/binary-patches.json').read_text())
original = (study / 'chimera').read_bytes()
assert hashlib.sha256(original).hexdigest() == manifest['base_sha256']
for name, variant in manifest['variants'].items():
    binary = bytearray(original)
    for patch in variant['patches']:
        offset = patch['file_offset']
        expected = bytes.fromhex(patch['expected'])
        assert binary[offset:offset + len(expected)] == expected
        binary[offset:offset + len(expected)] = bytes.fromhex(patch['replacement'])
    assert hashlib.sha256(binary).hexdigest() == variant['sha256']
    path = study / name
    path.write_bytes(binary)
    path.chmod(0o755)
PY
```

Use the existing runner's `validate` and `checked_run` helpers with CPU affinity
set to `{4}`, one discarded endpoint-10 warm-up, and alternating lane order as
recorded in `runtime.json`. Measure binaries directly; compiler startup is outside
the timer. No tests or compiler builds are required for these result/documentation
additions. The Fast baseline build and all executable probes passed.
