# Roadmap

Implementation audit: 2026-09-10, Zig 0.16.0.

The incremental pipeline works end to end. The next goal is to generalize bodies and control flow. Continue making the language in [syntax&semantics.txt](syntax&semantics.txt) usable through small, complete feature slices. That document is authoritative but incomplete: missing rules need a language decision, while missing implementation needs code. Legacy parity is not the goal.

## Current baseline

| Area | Implemented | Main gap |
| --- | --- | --- |
| Pipeline | Owned AST, stable item IDs, concurrent incremental queries, diagnostics, per-function SSA/code, reachable linking, Linux ELF CLI | Single-file callable scope; no generic instances or cross-run cache |
| Functions | Named and static-bound declarations, typed parameters, direct calls, general statement bodies, unit fallthrough, early returns | Fallible functions, parameter modifiers, callable values |
| Values | Decimal `int`, `unit`/`()`, `none`, `never`, immutable and mutable locals, assignments, calls, integer negation and `+ - * /` | `bool`, `float`, general type values |
| Variants | Canonical sets over `int`, `unit`, `none`; structural branch unions; layout, member injection, locals, calls, returns; subset widening at bindings, arguments, and returns | Named aliases, inspection/extraction |
| Control flow | Value-producing `if` over integer comparisons, implicit-unit no-else joins, general lexical branch blocks, divergence-aware joins and returns | Short-circuit logic, loops, match |
| Backend | Full-layout values, symbolic calls, recursion, arbitrary CFG edges, parallel edge copies | Frontend cannot yet produce all supported graphs; no external ABI |

Named function declarations canonicalize to static-bound function values during parsing. Inline bodies acquire an implicit return, and an omitted return annotation means `unit`. Block bodies accept general supported statements; unit functions may fall through, while every reachable path of other functions must return or diverge. Annotations on the static function binding itself remain unsupported and are rejected when the function signature is demanded. Direct `unit` and `none` values work at binding, call, and return boundaries as well as inside variants.

`exit(int)` remains an inline syscall implementation but is typed as `never` and terminates its control-flow path.

Top-level analysis accepts supported expressions, immutable and mutable locals, assignments, and general conditionals, skips static initializers, and synthesizes a unit return on reachable fallthrough. Successfully parsing a static initializer does not mean it was validated or evaluated. Discovery recognizes only static function initializers; uncalled bodies remain demand-driven. The parser also recognizes some future syntax—structs, parameter modifiers, `comptime`, `is`/`as`, `?`, and `sizeof`—without runtime semantics. `fallible`, `match`, and `loop` still need parser work.

## Priorities

Implement the remaining milestones in order, splitting each milestone into reviewable changes. Extend parsing, semantics, IR, codegen, diagnostics, and incremental tests only where the feature needs them. Architecture and query mechanics are documented separately.

### 1. Make the existing value and function subset consistent — done

Completed before adding new type families:

- Support the specified ordinary function forms: named declaration sugar, omitted return type meaning `unit`, and implicit return from an inline expression. Omission does not request return-type inference.
- Complete zero-sized values at ordinary binding/call/return boundaries: unit spellings, direct `none`, and direct `unit` parameters. Build on existing layout support.

Equivalent source forms retain equal typed and compiled results. Widening works at every currently supported expected-type boundary; narrowing and duplicate source members remain rejected. Tests cover tag remapping and equal-result retention after syntax and annotation edits.

### 2. Generalize bodies and control flow

General bodies and return control flow are complete. Finish the milestone with mutable loop-carried state:

1. **Done:** lexical block scopes, general statements in function and top-level bodies, multi-statement branch bodies, and `if` without `else`, joining its body value with an implicit unit failure branch. Ordinary unit fallthrough and reachable early returns are supported in functions.
2. **Done:** `never`, divergence-aware joins, return-path completeness, and correctly typed inline `exit`; runtime-symbol linking remains unnecessary.
3. **Done:** mutable locals and plain/arithmetic compound assignments, including SSA state joins across conditionals.
4. Add `loop`, `break` values, and `continue`. Use existing block arguments, backedges, and parallel copies for loop-carried state.

**Done:** branch-local names stay local; mixed returning/diverging paths type correctly; missing returns are diagnosed; loop break values join correctly. Tests cover evaluation order, skipped effects, mutation across backedges, and edits that change reachability.

### 3. Make variants inspectable and fallibility composable

Build on the control-flow model, without boolean condition values:

- Add unit-success `and`, `or`, and `not`, preserving precedence and left-to-right short-circuiting.
- Add `is`, fallible `as`, and immutable success-region condition bindings. Existing bindings keep their original types. Test both successful extraction and failure, including subset types.
- Add fallible function declarations, signatures, calls, and failure propagation. Preserve success payloads across calls and represent fallibility in callable type identity. Add ordinary-to-compatible-fallible widening with function values when that representation is available.

**Done:** conditions consume success/failure edges; extracted values exist only on success; a failed expression propagates from a fallible function without executing later effects. Calls, signatures, and diagnostics recompute correctly when fallibility changes.

Do not bundle postfix `?` into this milestone: its semantics are absent from the language reference. Specify it before implementation if it is retained.

### 4. Resolve declarations and compile-time values

Start with named type aliases and simple static values, then extend to `comptime` expressions and `static` parameters. Add module/item queries for demanded declarations and values; do not build a universal compile-time evaluator before its first use.

Define missing declaration lookup, cycle, and compile-time evaluation rules in the language reference first. Preserve structural variant identity through aliases. Resolve function annotations and callable values through the same type system. Generalize the variant-only interner when another interned type shape actually arrives. Extend `InstanceId` with compile-time arguments when specialization needs them.

**Done:** static values are validated and evaluated when demanded, source type names resolve, cycles have defined diagnostics, and changes invalidate their actual consumers. Preserve body-independent signatures and owned query results.

### 5. Complete scalar values and matching

Add `bool` and `float` as separate end-to-end slices after their missing numeric rules are specified. Keep bool values separate from fallible comparisons. Extend layouts, type-specific operations, calls, and variants as each scalar arrives.

Implement `match` using existing tag tests, narrowed arm bindings, and branch joins. Cover literal, wildcard, identifier, alias, and type patterns. Enforce exhaustiveness and reject fully covered arms; use the same join rules as `if` and loop breaks.

**Done:** scalar values survive calls and variants; match covers all specified patterns with correct scope, result types, and coverage diagnostics. Do not assume every type supports equality merely because literal patterns exist.

### 6. Add structs with ownership

Named types, general scopes/control flow, and stable layouts provide the foundation. Resolve missing struct identity and custom-hook signatures before implementing them.

Introduce field layout, named initialization, field access/mutation, and the specified parameter access modes in coherent slices. Design storage and ownership together: default copy is unavailable, immovable values require final storage, and explicit drop obligations must survive every branch and transfer. Add custom operations only with their concrete signatures and infallibility checks.

**Done:** field evaluation follows initializer order; access modes govern fields; move/copy/drop and `deinit` obligations are checked on all paths, including early returns and fallible exits. Allocation and incremental tests cover owned type metadata as well as runtime behavior.

## Work that waits for a concrete need

- **Runtime declarations and external linking:** begin when another runtime service, target, or foreign call needs symbols. Then seed declarations, link runtime artifacts, and remove dedicated `exit` handling.
- **Parser recovery and diagnostic breadth:** extend after supported semantics have clear diagnostic boundaries. Do not inspect isolated constructs inside otherwise opaque static initializers.
- **Finer query dependencies and parallel CLI work:** measure whole-file invalidation and useful independent roots first. Per-function queries currently retain equal downstream results but may rerun analysis after unrelated same-file edits.
- **Imports, visibility, overloading, extra targets/ABIs, and persistent caching:** require an explicit language or workload need. The old `arg` builtin and unspecified legacy features are not implied requirements.
- **Legacy removal:** delete modules once selected behaviors have root-pipeline regressions and no active tooling depends on them. Debug views already exist; they are not pending migration work.

## Decisions the reference still needs

Resolve each when its milestone reaches it; do not turn this list into a prerequisite for all work:

- Numeric details: float representation/operations, division and exceptional arithmetic, literal ranges, and comparison spelling/domains.
- Type details: declaration cycles, struct identity, callable compatibility with parameter modes, and recursive types.
- Ownership details: custom hook signatures, access/aliasing lifetimes, and transfers into final storage.
- Proposed syntax: postfix `?`, `sizeof`, and return-type inference have appeared in old plans or the parser but are not specified language commitments.

## Verification baseline

All seven active suites in [README.md](README.md) passed during this audit. They cover current behavior, including temporary restrictions; update those expectations with each conformance change. Parser tests and hand-built backend tests do not imply end-to-end language support. Keep live commands in README and behavioral evidence in tests, rather than duplicating test counts here.
