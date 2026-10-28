# Historical Results

These CSVs describe past experiments, not current acceptance results. No active
benchmark driver or history report reads them. Current measurements and cached
C baselines live in `.history/records/`; see the [benchmark guide](../README.md).

| Records | Provenance |
| --- | --- |
| [std_precompile.csv](std_precompile.csv), [std_precompile_debug.csv](std_precompile_debug.csv) | Zig 0.17, Ryzen 7 5800H, CPU 4; Fast/LLVM and Debug/self-hosted source-versus-bundle comparisons |
| [std_loading_comparison.csv](std_loading_comparison.csv) | Legacy std-loading comparison; the CSV does not record source snapshots or runner identity |
| [conversion_comparison.csv](conversion_comparison.csv) | Zig 0.17, Ryzen 9 3900X; converter lookup/consumer comparisons, separate from full compilation |
| [flow_ablation.csv](flow_ablation.csv) | Ryzen 9 3900X, self-hosted, three alternating trials; `baseline`, `persistent_flat`, retained `workspace`, and rejected `unified_calls` |
| [flow_regression.csv](flow_regression.csv) | Ryzen 7 5800H, CPU 4, LLVM, fifteen trials; `4556095`, `7cb3afd`, and `flow_reads` |
| [scalar_allocation_order.csv](scalar_allocation_order.csv), [flow_parser_order.csv](flow_parser_order.csv) | Same CPU/backend, fifteen rotating trials; allocation/residency instrumentation and uninstrumented full-matrix confirmation |
| [flow_parser_application.csv](flow_parser_application.csv) | `4556095` versus matched pending workspace snapshots containing `924a474`, before/after parser-order correction |
| [compiler_simplification.csv](compiler_simplification.csv) | 2026-10-28, Zig 0.17, Fast/LLVM, CPU 2, zero workers; matched pending-workspace baseline and reverted candidate |

Flow rows summarize five-sample trial medians; compare matched rounds rather
than absolute times across experiments. The parser-order diagnosis found that
tokenizer-first allocation touched scratch pages later used by typing; reversing
the order increased demand faults despite identical graphs, retained footprints,
and typing allocation requests. Restoring that order recovered the regression.
Parsing is outside the flow timer but influences its memory residency. These
typing-only results do not establish an end-to-end speedup. Historical eager std
loading and older compilation budgets are likewise not claims about the current
lazy loader or a supported performance-gate target.

## Compiler Simplification Findings

The candidate reduced production LOC from 35,599 to 35,349, not below the requested
34,000. Its production edits were reverted because performance qualification was
incomplete. Existing and concurrent work was preserved. Both measured lanes
included the same allocation-read hoisting and conditional-increment fixes.

Useful leads for a future, independently measured change:

- In the inspected typing implementation, `pending_consumption_owners` had no
	nonempty producer and `completed_consumptions` was written, copied, and merged
	without affecting diagnostics or IR. Executable consumption-completion cells
	and capture-transfer checks remain necessary.
- `Generation.start_order` duplicated its allocation index. Lifetime ordering
	can derive that index from the generation ID, but must preserve the independent
	`lifetime_origin` used by refinements. Some test fixtures supplied arbitrary
	orders that the production constructor never creates.
- Reference inference and optimization duplicate forward-reachability/reverse-
	caller SCC discovery. Missing reference bodies invalidate inference; missing
	optimization bodies are skipped. Preserve reference traversal order, sorted
	optimization output, the acyclic fast path, and query dependencies.
- Generation-only forwarding is attached only to unconditional join branches.
	Block-owned mappings can eliminate global hint sorting and lookup, but increase
	block storage. Consume that metadata before cleanup splitting or move it with
	its terminator; measure the representation tradeoff.
- Replacing the explicit optimizer instruction-read switch with `operands()`
	caused an approximately 2% repeatable cold-compilation regression. Forced
	inlining did not recover it. That probe was removed.

The final batch passed focused flow (22), lifetime (11), reference (83), and
recursive-query (2) checks. The full routine suite passed only for an earlier
candidate, not the final batch. These checks do not qualify performance.

The recorded pair used one warm-up and the adaptive sampling protocol. Cold
medians were 29.498 s before and 29.839 s after (+1.16%); both lanes stopped at
two locally stable samples. Candidate incremental samples and both runtime lanes
were unstable at their caps. Equal executable sizes do not prove equal bytes or
runtime performance. No speedup or no-regression claim was established.