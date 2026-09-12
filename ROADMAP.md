# Roadmap

Implementation audit: 2026-09-12, Zig 0.16.0.

[syntax&semantics.txt](syntax&semantics.txt) is authoritative but incomplete. Make missing language decisions before implementing dependent behavior; legacy parity is not a goal.

## Current foundation

- Incremental queries preserve stable declaration and type identities, owned results, diagnostics, and equal-result retention.
- Typing publishes one SSA control-flow graph with fallible edges, joins, loops, calls, callable values, variants, and divergence.
- Structs have nominal identity, cycle-checked layout, default ownership capabilities, source-ordered initialization, field access, and field updates through mutable local roots.
- Callable declarations and types share ordered mode/type parameter records. Omitted and explicit `read` are supported; other modes are rejected before body analysis.

## Next: ownership uses

First specify the remaining ownership matrix: which bindings, assignments,
arguments, returns, and field paths borrow, copy, or transfer; when reassignment
restores an invalidated place; and how callable modes compare. Then implement in
small end-to-end slices:

1. Represent local and field places once, and track available versus transferred
   state through branches and loops.
2. Enforce `OwnershipCapabilities` at copies and explicit `^` transfers, with
   precise use-after-transfer, non-copyable, and non-movable diagnostics.
3. Enable owned `var` and `deinit` parameters, custom copy/move/drop hooks, and
   path-complete drop obligations.
4. Add `mut` aliasing, partial-field transfer, and final storage for immovable
   values only after their lifetime and call-convention rules are specified.

Each slice must cover diagnostics, execution, ownership paths, and incremental
recomputation. Keep unsupported forms rejected at their owning boundary.

## Then

1. **Match:** evaluate the subject once; support literal, wildcard, binding,
   `pattern as name`, and `is Type` patterns; diagnose redundancy and
   non-exhaustiveness; reuse existing branch joins and variant mappings.
2. **Captureless function literals:** assign stable nested declaration identities,
   reuse signature/body/reachability queries, and reject captures. Defer closures.
3. **Numeric semantics:** specify integer division and the full float model
   (representation, literals, conversions, arithmetic, comparison, and exceptional
   values), then implement float as one scalar slice.
4. **Compile-time specialization:** add general `comptime`, static parameters, and
   `InstanceId` arguments only when a concrete generic use requires them.

## Deferred

- Cross-file declarations, imports, visibility, overloading, persistent caching,
  extra targets, and external ABI support need an explicit use case.
- Replace dedicated `exit` handling with runtime declarations only when another
  runtime service or external symbol requires that machinery.
- Finer-grained source invalidation and parallel CLI compilation require measured
  evidence that current whole-file dependencies or scheduling are limiting.
- Decide whether the CLI should validate unreachable declarations; current
   compilation intentionally diagnoses only demanded signatures, bodies, and values.
- Specify postfix `?`, `sizeof`, and return-type inference before implementation.
- Remove `legacy/` only after active tooling has replacement regressions.
