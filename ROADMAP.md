# Roadmap

Implementation audit: 2026-09-11, Zig 0.16.0.

[syntax&semantics.txt](syntax&semantics.txt) is authoritative but incomplete. Implement small end-to-end slices from it; make missing language decisions before coding behavior that depends on them. Legacy parity is not a goal.

The compiler currently has an incremental single-file pipeline through x86-64 ELF emission, with functions, integer expressions, lexical control flow, loops, structural variants, fallibility, and demand-driven simple static declarations. Preserve body-independent signatures, owned query results, stable declaration identities, and equal-result retention as the language grows.

## Next: bool values

Add `bool` as the next complete scalar slice. This is the smallest specified feature that exercises the existing value pipeline without requiring compile-time evaluation, a new storage model, or unresolved floating-point rules.

- Add distinct `bool` type identity and `true`/`false` values. Do not represent bool as an alias of `int`.
- Support bool in static declarations, locals, mutable assignment, parameters, calls, returns, branch joins, and structural variants.
- Support `==` and `!=` as fallible bool comparisons so the specified `if enabled == true` form works. Do not add truthiness or ordered bool comparisons.
- Extend layouts, typed IR, code generation, diagnostics, debug output, and incremental equality only where bool requires it.
- Test direct and variant values across static resolution, calls, returns, mutation, conditionals, execution, diagnostics, allocation failure, and equal-result recomputation.

The slice is complete when bool survives every boundary already supported for `int`, while conditions still consume success/failure control flow rather than materializing boolean branch results.

## Then: match

Implement `match` after bool. It builds on existing variant tag tests, success-scoped extraction, lexical arm scopes, and branch joins, but still needs parser and exhaustiveness work.

- Parse literal, wildcard, identifier-binding, `pattern as name`, and `is Type` patterns.
- Evaluate the subject once and test arms in source order.
- Keep pattern bindings immutable and arm-local without refining the original binding.
- Reject non-exhaustive matches and arms that are already fully covered.
- Join arm values using the same rules as conditionals and loop breaks.
- Cover literals, aliases, type patterns, bindings, variants, divergence, diagnostics, execution, and incremental recomputation.

Do not assume every future type supports equality merely because literal patterns exist. Add pattern capabilities with each type family.

## Callable values

Resolve callable annotations and function values through the ordinary type system.

- Intern ordinary and fallible callable types when they become the second interned type shape, replacing the variant-only type store with discriminated type data at that point.
- Type-check callable compatibility, including ordinary-to-fallible widening, without changing direct-call behavior prematurely.
- Support function values at bindings, parameters, calls, and returns before adding closures or captures.

Parameter modes other than the current read-only behavior wait for the ownership work unless a smaller independently specified subset emerges.

## Later language slices

### Float

Specify representation, literal range, arithmetic, comparison domains, conversions, division behavior, and exceptional values before implementation. Then add float as a separate end-to-end scalar slice, including variants and calls.

### Structs and ownership

Decide struct identity and custom ownership-hook signatures first. Then add field layout, named initialization, field access and mutation, parameter access modes, move/copy/drop behavior, final storage for immovable values, and `deinit` obligations in coherent slices.

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
- Struct identity, recursive types, callable compatibility with parameter modes, ownership hook signatures, aliasing lifetimes, and final-storage transfers.
- Semantics for postfix `?`, `sizeof`, and return-type inference before treating their parser support as a language commitment.
