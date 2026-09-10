# Roadmap

Implementation audit: 2026-09-08, Zig 0.16.0.

The incremental pipeline works end to end. The next goal is to make the language in [syntax&semantics.txt](syntax&semantics.txt) usable through small, complete feature slices. That document is authoritative but incomplete: missing rules need a language decision, while missing implementation needs code. Legacy parity is not the goal.

## Current baseline

| Area | Implemented | Main gap |
| --- | --- | --- |
| Pipeline | Owned AST, stable item IDs, concurrent incremental queries, diagnostics, per-function SSA/code, reachable linking, Linux ELF CLI | Single-file callable scope; no generic instances or cross-run cache |
| Functions | `static f = func(...) Type`, typed parameters, direct calls, explicit final returns | Named declaration sugar, omitted unit return type, inline implicit return, fallible functions, parameter modifiers, callable values |
| Values | Decimal `int`, `none`, immutable locals, calls, integer negation and `+ - * /` | Mutable locals, assignments, `bool`, `float`, `never`, general type values; direct unit/none support is uneven |
| Variants | Canonical sets over `int`, `unit`, `none`; structural branch unions; layout, member injection, locals, calls, returns; subset widening at bindings, arguments, and returns | Named aliases, inspection/extraction |
| Control flow | Value-producing `if/else` over integer comparisons; one expression per branch, including nested conditionals | No-else/statement `if`, general branch blocks, short-circuit logic, early returns, loops, match |
| Backend | Full-layout values, symbolic calls, recursion, arbitrary CFG edges, parallel edge copies | Frontend cannot yet produce all supported graphs; no external ABI |

The supported function form still requires an explicit return, even inline: `static f = func(a: int) int -> return a`. An omitted return annotation is rejected, despite the language's unit default. Annotations on the static function binding itself are also unsupported and rejected when the function signature is demanded. Direct `unit`/`none` parameters, returns or local annotations of exactly `none`, and unit literals remain unsupported; those types already work as variant members.

`exit(int)` emits a syscall but is still typed as `unit`, contrary to the specified `never` result.

Top-level analysis accepts immutable locals and calls, skips static initializers, and synthesizes a unit return. Successfully parsing a static initializer does not mean it was validated or evaluated. Discovery recognizes only static function initializers; uncalled bodies remain demand-driven. The parser also recognizes some future syntax—structs, parameter modifiers, `comptime`, `is`/`as`, `?`, and `sizeof`—without runtime semantics. `fallible`, `match`, and `loop` still need parser work.

## Priorities

Implement these in order, splitting each milestone into reviewable changes. Extend parsing, semantics, IR, codegen, diagnostics, and incremental tests only where the feature needs them. Architecture and query mechanics are documented separately.

### 1. Make the existing value and function subset consistent

Close known contradictions before adding new type families:

- Support the specified ordinary function forms: named declaration sugar, omitted return type meaning `unit`, and implicit return from an inline expression. Omission does not request return-type inference.
- Complete zero-sized values at ordinary binding/call/return boundaries: unit spellings, direct `none`, and direct `unit` parameters. Build on existing layout support.

**Done:** equivalent source forms have equivalent typed results; widening works at every currently supported expected-type boundary; narrowing and duplicate source members remain rejected. Exercise tag remapping and equal-result retention after annotation edits.

### 2. Generalize bodies and control flow

The current final-return and single-expression-branch restrictions block most of the language. Address them in dependent slices:

1. Add lexical block scopes, general statements in function and top-level bodies, multi-statement branch bodies, and `if` without `else`, discarding its body value and producing unit. Support ordinary unit fallthrough and reachable early returns in functions.
2. Add `never` with divergence-aware joins and return-path completeness. Type `exit` correctly while keeping its inline implementation; runtime-symbol linking is not a prerequisite. Implement this alongside the first slice wherever return paths require it.
3. Add mutable locals and assignments, then `loop`, `break` values, and `continue`. Use existing block arguments, backedges, and parallel copies for loop-carried state.

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
