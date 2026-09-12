# Roadmap

Implementation audit: 2026-09-11, Zig 0.16.0.

[syntax&semantics.txt](syntax&semantics.txt) is authoritative but incomplete. Implement small end-to-end slices from it; make missing language decisions before coding behavior that depends on them. Legacy parity is not a goal.

Preserve body-independent signatures, owned query results, stable declaration identities, and equal-result retention as the language grows.

## Next: struct ownership

Structs are nominal; aliases preserve the original identity. Reject direct and
indirect recursive by-value containment, including cycles through variants.
Callable parameter modes participate in type identity. Custom ownership hooks
are ordinary infallible function expressions with signatures equivalent to
`func(read self: S) S` for copy, `func(var self: S) S` for move, and
`func(deinit self: S) unit` for drop.

Named struct declarations and aliases now have stable nominal type identity.
`StructDefinition` owns ordered field metadata, and `StructLayout` computes field
offsets while rejecting direct and variant-mediated containment cycles. Callable
signatures terminate containment traversal. `OwnershipCapabilities` computes
trivial primitive and callable behavior, fieldwise variant behavior, and default
struct move/copy/drop behavior. Invalid recursive structs publish no capabilities.
Named initialization now resolves fields nominally, requires every field exactly
once, preserves source evaluation order, and supports field coercions. Read-only
field access works through construction, bindings, parameters, calls, and returns.
Field assignment works through mutable local roots, including nested paths,
compound integer operations, field coercions, and control-flow joins. Updating a
field rebuilds the enclosing aggregate values without making fields independently
mutable.

Continue in dependency order:

1. Enforce copy-versus-transfer behavior for struct values and fields, including
   invalidation after explicit transfer.
2. Expand assignment, joins, extraction, and custom hooks only
   as their ownership behavior is implemented.

Reject nested declarations and unsupported ownership or transfer forms at their
owning boundaries. Cover diagnostics, execution, ownership paths, and
incremental recomputation in each slice.

## Later language slices

### Match

Build on existing variant tag tests, success-scoped extraction, lexical arm
scopes, and branch joins.

- Parse literal, wildcard, identifier-binding, `pattern as name`, and `is Type` patterns.
- Evaluate the subject once and test arms in source order.
- Keep pattern bindings immutable and arm-local without refining the original binding.
- Reject non-exhaustive matches and arms that are already fully covered.
- Join arm values using the same rules as conditionals and loop breaks.
- Cover literals, aliases, type patterns, bindings, variants, divergence, diagnostics, execution, and incremental recomputation.

Do not assume every future type supports equality merely because literal patterns exist. Add pattern capabilities with each type family.

### Captureless function literals

After `match`, make `func` expressions produce callable values through stable
nested declaration identities and the existing signature, body, reachability,
and relocation queries. Reject references to enclosing local bindings. Keep
closures and captures with the ownership work below.

### Float

Specify representation, literal range, arithmetic, comparison domains, conversions, division behavior, and exceptional values before implementation. Then add float as a separate end-to-end scalar slice, including variants and calls.

### Advanced struct ownership and parameter access

After the ownership foundation, decide callable compatibility across different
parameter modes, their source spelling in callable types, aliasing lifetimes,
partial-field transfers, and final-storage rules. Then complete read/mut/var/deinit
parameter behavior, custom hooks, final storage for immovable values, and
`deinit` obligations in coherent slices. Keep closures and captures coupled to
the ownership rules they require.

### Compile-time execution and specialization

Defer general `comptime`, `static` parameters, and generic specialization until runtime values and callable types provide a stronger base and a concrete use requires them. Extend `InstanceId` with compile-time arguments only when specialization is implemented; do not build a universal evaluator in advance.

## Deferred infrastructure

- Cross-file declarations, imports, visibility, overloading, persistent caching, extra targets, and external ABI support need an explicit use case.
- Runtime declarations and external linking begin when another runtime service replaces dedicated `exit` handling.
- Finer query dependencies and parallel CLI work require measurements showing that whole-file invalidation or current scheduling is a problem.
- Parser recovery and broader diagnostics should follow supported semantics rather than validate isolated constructs inside otherwise unsupported subtrees.
- Remove legacy modules only after active tooling no longer depends on them and selected behavior has root-pipeline regressions.

## Open language decisions

- Float representation and operations, numeric conversions, division, exceptional arithmetic, and literal ranges.
- Callable syntax and compatibility across different parameter modes, aliasing lifetimes, partial-field transfers, ownership-property override constraints, and final-storage transfers.
- Semantics for postfix `?`, `sizeof`, and return-type inference before treating their parser support as a language commitment.
