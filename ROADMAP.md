# Roadmap

Implementation audit: 2026-09-12, Zig 0.16.0.

[syntax&semantics.txt](syntax&semantics.txt) is authoritative but incomplete. Make missing language decisions before implementing dependent behavior; legacy parity is not a goal.

## Current foundation

- Incremental queries preserve stable declaration and type identities, owned results, diagnostics, and equal-result retention.
- Typing publishes one SSA control-flow graph with fallible edges, joins, loops, calls, callable values, variants, and divergence.
- Structs have nominal identity, cycle-checked layout, source-ordered initialization, field access, field updates through mutable local roots, and validated move/copy/drop strategy overrides.
- Function-valued struct properties receive stable owner-qualified item identities, reuse ordinary signature and body queries without entering module scope, and are validated against exact copy/move/drop signatures. Typing lowers custom hooks to ordinary direct calls, recursively composes fieldwise struct and active-variant operations, and suppresses redispatch only for compiler-generated plumbing inside the active hook.
- Callable declarations and types share ordered mode/type parameter records. Function declarations support omitted or explicit `read`, borrowed `mut`, owned `var`, and cleanup-authorized `deinit`; inferred callable values retain exact modes. Mutable arguments require exact-typed mutable places and reject overlapping read or mutable argument paths.
- Lexical const and var bindings have stable root-place identities. Typing tracks available, transferred, and possibly transferred states through branches and loops; whole assignment restores a mutable root.
- Bare place values borrow in observation and `read` calls. Bindings, replacement assignments, struct fields, returns, and owned calls require copy support; `^` explicitly transfers movable local roots. Owned temporaries pass directly. `var` and `deinit` parameters are mutable owned roots, with only `deinit` authorized to satisfy explicit drop. Partial-field transfer remains rejected.
- Lexical exits end owned roots in reverse order. Explicit-drop trees must transfer or reach a `deinit` parameter on every path; borrowed temporaries and replaced values obey the same obligation. Automatic custom drop runs for locals, replaced values, discarded temporaries, read-call temporaries, and temporary aggregate projections. Trivial and hook-free fieldwise cleanup require no runtime instruction.

## Next: ownership storage

The root-place use matrix, non-escaping `mut` borrows, owned `var` parameters,
cleanup scheduling, explicit drop obligations, and `deinit` parameters are
specified and implemented. Continue with:

1. Add partial-field transfer and final storage for immovable values only after
   their lifetime and call-convention rules are specified.

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
