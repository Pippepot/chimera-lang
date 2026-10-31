# Shared integer algebra

The current structural revision combines both binary simplifiers and constant
folding, removes the `Algebra` metadata type and rule table, and reuses the IR's
operand API. `./loc.sh --json` counts 589 production lines in the original
canonicalizer, 605 in the first accepted implementation, and 581 in this revision.
Behavioral regression coverage is retained. Its raw measurements are in
`structural-candidate.csv`; the measurements below describe the preceding version.
The structural revision's medians are 31.324 seconds cold, 213 ms for a fresh leaf
edit, and 1.181 seconds for the sieve. All sample sets met the stability threshold;
the comparison shows no material regression against the preceding implementation.

The baseline includes the existing uncommitted optimizer/backend work. The
compiler change is confined to `src/optimizer/canonicalize.zig`; source hashes,
commands, toolchain, and sampling details are in `environment.json`. Raw samples
are retained beside `summary.json`.

Both versions use Zig 0.17.0, ReleaseFast, the ordinary std bundle, zero workers,
CPU 4, default caches, and seed 0. Each measurement has one discarded warm-up and
uses the benchmark guide's adaptive sampling limits and stability threshold.
Builds and tests were excluded from timed runs.

The initial implementation repeatedly increased cold compilation time by about
2.3–2.5%. The final implementation substitutes immutable identity inputs during
the same sweep and bypasses arithmetic algebra rules for comparisons. Its cold
median is 31.383 seconds, within 0.2% of both baseline medians (31.342 and 31.322
seconds). The final leaf-edit median is 211 ms versus 215 ms initially, but those
sample sets reached the noise cap.

The first final sieve sample set was slightly slower. An isolated comparison
produced medians of 1.189 seconds for the baseline and 1.183 seconds for the
candidate; the candidate reached the noise cap. This does not show a repeatable
runtime regression or establish a speedup. Executable sizes were unchanged for
both workloads. The sieve measures broad regressions, not the new identities in
isolation.

Verification passed: 46 optimizer tests, 16 numeric tests, formatting checks, and
`git diff --check`. Coverage includes integer widths and overflow modes, writable
snapshots, retained operand traps and panic provenance, and incremental edits.
