# Chimera Core Foundation — Single-File Canonical Syntax Implementation Guide

Status: Approved. Ready for implementation.

## Goal

Implement the next compiler foundation as a single-file declaration-based language with canonical comptime declarations, first-class function values, and function-call execution end to end.

The first shippable vertical slice is:
1. top-level function declarations
2. first-class function values (named function symbols as values)
3. function calls (direct and via function values)
4. return statements
5. multi-function lowering/codegen

## Current Compiler Baseline (starting point)

The current compiler is expression-oriented and already has:
- parser + AST for expressions, `if`/`else`, `const`, `var`, assignment, and print/arg
- fallible comparison model in `if` conditions
- typechecker for primitive types (`unit`, `bool`, `int`, `float`)
- block-based IR with branches and return
- x86 ELF codegen for the current IR
- incremental query system with stages: parse -> typecheck -> lower -> compile

Key files in current repo:
- `ast.zig`
- `parser.zig`
- `typecheck.zig`
- `ir.zig`
- `codegen.zig`
- `query.zig`
- `db.zig`
- `main.zig`
- `debug.zig`
- `test.zig`

## Language Surface To Implement In This Phase

### Top-level declarations
Implement these canonical declaration forms:
```text
comptime Name = func(<params>) <ret_type>
    <body>

comptime Name = struct
    <fields>
```

### Function body forms
Support these in function bodies:
- `return <expr>`
- expression statements
- existing `if`/`else` forms
- `const` bindings
- `var` bindings
- assignment

### Calls
Support call expressions for declared functions and function values:
```text
foo(1, 2)
const f = foo
f(1, 2)
```

### First-class function values
Support named function symbols as ordinary values:
- bind to locals/consts
- pass as arguments
- return from functions
- call through value position

### Types in this phase
Support checker-visible types needed for the vertical slice:
- `unit`, `bool`, `int`, `float`
- function types/signatures
- function value types for named function symbols
- named struct types
- generic/comptime type parameters used in declarations

## Implementation Order (execute in sequence)

## 1) AST and Parser Refactor

### `ast.zig`
Add declaration and function-oriented nodes:
- program/module root with top-level declaration list
- declaration variants for comptime func and comptime struct
- parameter node and type annotation node forms
- return statement node
- call expression node
- function value/reference expression support tied to resolved symbols

Keep existing expression nodes for arithmetic, comparisons, if, var/const/assign, print, arg.

### `parser.zig`
Refactor parser entrypoint to declaration parsing:
- parse whole file as declaration list
- parse canonical comptime declarations
- parse function signatures and indented function bodies
- parse return statements in function body scope
- parse call expressions with argument list parsing and precedence integration
- parse function symbol references in value position

Preserve source spans/diagnostics style already used in parser.

## 2) Resolver Stage

### Add `resolver.zig`
Create a resolver stage that assigns symbol identity before typechecking.

Resolver responsibilities:
- top-level symbol table for declarations
- function-local symbol table for params/locals
- generic/comptime parameter symbol table
- duplicate symbol diagnostics
- unknown symbol diagnostics
- span-accurate diagnostics using parser spans

Produce a resolver memo value that typecheck can consume (symbol bindings + resolved refs).

## 3) Function-aware Typechecker

### `typecheck.zig`
Extend checker from expression-only to declaration + function model.

Required behavior:
- build/check function signatures
- validate call arity and argument types
- type function symbols as first-class values
- validate passing/returning/storing function values against function signatures
- support calling function-typed expressions in addition to direct symbol calls
- validate return expressions against declared function return type
- ensure function body typing works with locals and branches
- keep current fallible-context semantics intact for comparisons/if conditions

Update typed output shape so lowering can reference typed functions and typed call nodes.

## 4) Monomorphization Stage

### Add `monomorphize.zig`
Create stage after typecheck to instantiate concrete generic declarations.

Requirements:
- collect reachable generic instantiations from calls/constructions
- collect reachable generic instantiations through function-value flows
- key instantiations by declaration + concrete type args
- generate one concrete instance per unique key
- reuse existing instance for repeated same key
- output monomorphized program model for lowering

## 5) Multi-function IR Lowering

### `ir.zig`
Upgrade IR model from single-entry expression program to function-oriented IR.

Add:
- function table
- per-function entry block
- call instruction
- representation for function-symbol values
- explicit return terminator per function

Lowering responsibilities:
- lower each resolved/typed/monomorphized function body independently
- preserve existing control-flow lowering style for `if`/branches
- map function params/locals into value slots consistently
- lower function-value calls to callable IR form

## 6) x86 Codegen for Calls and Returns

### `codegen.zig`
Extend backend to emit machine code for multiple functions and internal calls.

Implement a minimal internal calling convention for this compiler:
- argument passing placement
- return value register convention
- stack frame interaction with current slot model
- symbol/fixup handling for internal function targets
- callable dispatch for function-symbol values

Continue emitting a runnable ELF executable exactly as current runtime expects.

## 7) Query Pipeline Integration

### `db.zig`
Extend query stage enum and stats to include:
- resolve
- monomorphize

### `query.zig`
Add memo tables and ensure functions for:
- parse
- resolve
- typecheck
- monomorphize
- lower
- compile

Wire dependencies in this order:
1. resolve depends on parse
2. typecheck depends on resolve (and parse spans as needed)
3. monomorphize depends on typecheck
4. lower depends on monomorphize
5. compile depends on lower

Preserve existing red/green behavior, diagnostics accumulation, and compile backdating logic.

## 8) CLI, Debug, and Tests

### `main.zig`
Keep single input-file flow and run through the expanded stage chain.

### `debug.zig`
Add stage diagnostics support for resolve/monomorphize counters and optional textual dumps for their artifacts.

### `test.zig`
Migrate and expand tests to declaration/function pipeline.

Required test groups:
1. parser/AST declaration tests
2. resolver tests (duplicates, unknown refs, scoped bindings)
3. first-class function value tests (bind/pass/return/call)
4. function typecheck tests (calls, returns, branches)
5. monomorphization dedup/instantiation tests
6. IR/codegen multi-function behavior tests
7. incremental query invalidation tests for new stages

## Acceptance Criteria

Implementation is complete when all are true:
1. Canonical comptime function declarations parse and compile.
2. Function symbols behave as first-class values in bind/pass/return/call flows.
3. Multiple functions can call each other and return correct values.
4. Resolver emits correct duplicate/unknown symbol diagnostics with spans.
5. Typechecker enforces call arity/types and return typing.
6. Monomorphization produces deterministic unique concrete instantiations.
7. Query diagnostics show resolve/monomorphize stage hits/recomputes.
8. Existing language behavior (arithmetic, var/const/if/fallible conditions) remains working.
9. `zig test test.zig` passes with expanded coverage.

## Suggested Incremental Delivery Commits

1. `ast+parser: declaration root, comptime func/struct, return, call, function-value syntax`
2. `resolver: add symbol resolution stage and diagnostics`
3. `typecheck: function signatures, first-class function values, call/return checking`
4. `mono: add monomorphization stage with instantiation dedup`
5. `ir: move to multi-function IR with function values and call/ret`
6. `codegen: internal function call emission for direct/value calls`
7. `query/db/debug/main: integrate new stages`
8. `tests: migrate and expand for declaration/function pipeline`

## Notes For Implementer

- Follow existing Zig 0.16 conventions from `AGENTS.md` (allocator APIs, IO, process, etc).
- Reuse existing diagnostics style and span plumbing.
- Keep edits aligned with existing modular split:
  - parse in `parser.zig`
  - semantic checks in `typecheck.zig`
  - IR in `ir.zig`
  - backend in `codegen.zig`
  - orchestration in `query.zig`.
