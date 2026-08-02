# Prompt: Implement the next minimal step

Use `ROADMAP.md`, `ARCHITECTURE.md`, and the code to identify and implement the smallest complete next step. Keep me updated. Optimize for correctness and minimum total machinery.

## 1. Establish the contract before editing

Trace the relevant ownership, identities, state transitions, query dependencies, equality, failures, callers, and downstream consumers. State the intended behavior and remaining assumptions concisely.

Try to falsify the proposed design with concrete cases. Consider the following where they are relevant rather than treating each as a mandatory test category:

- Positive and meaningful negative behavior.
- Empty, missing, malformed, duplicate, and reordered inputs.
- Edits that must preserve identity versus change it.
- Borrowed data escaping replaceable inputs.
- Partial construction and cleanup.
- Diagnostics or side effects changing while values remain equal.
- Dynamic dependencies, stale edges, retries, and concurrency.
- Synthetic values: both creation and non-creation.

For changes involving ownership, stable identity, incremental dependencies, concurrency, diagnostics, or an architecture boundary, write a concise invariant/behavior matrix and map its nontrivial rows to production locations and tests. For smaller local changes, a short written contract is enough.

Perform a fresh adversarial review of the proposed design. Use a sub-agent when the change crosses several boundaries, has subtle lifecycle behavior, or would materially benefit from an independent review; otherwise do the review yourself. Classify findings as required by the stated contract, necessary consequences of the architecture, or broader semantic policy. Do not implement broader policy without user approval.

## 2. Decide whether an exploratory pass is warranted

Use a disposable exploratory implementation when there is substantial uncertainty about ownership, cleanup, query invalidation, concurrency, state transitions, architecture placement, or when competing designs need to be tested.

When an exploratory pass is warranted:

- Mark or otherwise record the expected change points.
- Snapshot only the affected state well enough to restore it without disturbing unrelated work. Use hashes when the dirty worktree or untracked files make exact restoration difficult.
- Implement the risky parts and their nontrivial tests.
- Review what the exploration revealed, then restore the snapshot before writing the final version.

For a well-understood, narrow change, implement once and refine it in place. Do not require TODO-only edits, hashes, reversal, or duplicate implementation merely as ceremony.

## 3. Implement and verify

Implement the smallest complete production solution and its relevant tests. Preserve architecture boundaries and unrelated changes. Do not add abstractions or semantic rules for hypothetical future needs.

Before presenting the result, perform two explicit passes:

1. Correctness: check ownership, partial cleanup, pointer lifetimes, identity, equality, diagnostics, incremental behavior, failures, state transitions, and concurrency where applicable.
2. Cleanup: reread the complete flow and simplify redundant state, wrappers, helpers, conditions, locks, mixed stable/revision-local data, and excess scope.

Add important tests discovered during either pass. Run focused and relevant regression suites, stress allocation failures and concurrency/state transitions where applicable, format, and run `git diff --check`.

## 4. Update the handoff

Update `ROADMAP.md`: record completed behavior and verification, remove obsolete details, update limitations, and promote the next minimal step.

In the final response report:

- What was implemented and verified.
- Any important requirement or failure mode discovered during review.
- If an exploratory pass was used, what changed in the final version and why.
- The next minimal step without implementing it.
