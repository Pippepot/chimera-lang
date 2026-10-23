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

Flow rows summarize five-sample trial medians; compare matched rounds rather
than absolute times across experiments. The parser-order diagnosis found that
tokenizer-first allocation touched scratch pages later used by typing; reversing
the order increased demand faults despite identical graphs, retained footprints,
and typing allocation requests. Restoring that order recovered the regression.
Parsing is outside the flow timer but influences its memory residency. These
typing-only results do not establish an end-to-end speedup. Historical eager std
loading and older compilation budgets are likewise not claims about the current
lazy loader or a supported performance-gate target.