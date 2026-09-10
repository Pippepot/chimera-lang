# Architecture

Durable compiler contracts live here. [syntax&semantics.txt](syntax&semantics.txt) owns language rules; [ROADMAP.md](ROADMAP.md) distinguishes implemented behavior from the target. The current execution path is in [PROGRAM_FLOW.md](PROGRAM_FLOW.md).

## Stage boundaries

- Compiler stages depend in data-flow order. Shared types in `structures.zig` do not import stages. Parser, semantic analysis, and codegen do not import query orchestration; the query engine remains compiler-independent.
- Query definitions supply dependencies and small protocols such as `TypeInterner`. Semantic analysis owns source traversal and issues; the interner owns canonical type identity.
- Module and item queries own declarations, scopes, and shared semantic data. Body analysis operates per declaration; compilation operates per instance. Calls demand callee signatures, not bodies.
- Source and lexical validation build a query-local expression graph before callable resolution. Typing constructs the sole control-flow graph; codegen consumes it directly. Add a separate lowering representation only when a transformation requires it.
- `AnalyzeFunctionBody` is the typed publication boundary. It validates names, annotations, operations, calls, joins, and returns before publishing type-specific IR. Codegen trusts semantic facts and checks its own capabilities and resource limits.
- Expected source errors produce `structures.Diagnostic` values. Missing or stale query state remains distinct from rejection; infrastructure failures use errors. Broken compiler invariants use assertions or `unreachable`, never user diagnostics. `diagnostics.zig` alone translates kinds into messages; presentation resolves paths and source lines.

## Identity and ownership

- Query keys are small, pointer-free identities. Cached results own allocations or retain stable identities; they never borrow from replaceable inputs. Signatures own ordered parameter types and retain no AST nodes. Parameter names belong to body scope, not callable type identity; fallibility belongs in signatures when implemented.
- `ItemId` identifies a declaration; `InstanceId` identifies a callable instance. Declaration identity must survive body edits and relocation. Generic substitutions extend instance identity only when needed.
- `TypeId` is a pointer-free, session-local identity. Primitives have reserved IDs; other types use an `InternedTypeId` index. The index does not encode the type's semantic kind. Replace the variant-only store with one discriminated type-data store when a second interned shape arrives.
- Inputs and dependencies are recorded through the query context. Observable equality includes payload contents and diagnostics. Optional results inherit payload equality; use query-specific `eqlOutput` only when its semantics differ.
- Recomputations commit or discard fresh allocations, dependencies, and diagnostics together. Equal results retain allocations and `changed_at`; infrastructure failure preserves the last completed memo and permits retry. Input changes require an idle database.

## Typed values and control flow

- Expressions produce values; return and discard are uses, not operation kinds. Known operand types select operations such as `addi`, without redundant generic opcodes and type metadata.
- Preserve exactly-once, left-to-right evaluation, including struct initializer source order. Reordering must be unobservable.
- Fallibility is success/failure control flow, separate from `bool` and `never`. Use one predicate-branch structure with type-specific operations. Logical composition connects edges; extraction carries a value on the success edge. Do not materialize boolean SSA values for fallible outcomes.
- Every block has one terminator. Typed block parameters and instruction results share a value-ID namespace; function parameters are entry-block arguments. Calls and branches use separate flat operand arrays. Edges may be forward or backward and carry any number of arguments; edge copies are parallel.
- Semantic analysis owns variant canonicalization, joins, and widening legality. Canonicalization flattens and orders members, rejecting source duplicates after alias expansion. Publish coercions explicitly through `FunctionValueUse` or `variant_coerce`; consumers do not rediscover legality. Branch-local extraction and pattern bindings must not refine existing bindings.
- As control flow expands, represent divergence with `never` in joins and return-path analysis. Ownership analysis must preserve the language's move/copy/drop defaults, infallible custom hooks, stable storage for immovable values, and transfer-or-`deinit` obligations on every path.

## Representation and linking

- `TypeLayout(TypeId)` exposes only byte size and alignment. `VariantLayout(TypeId)` owns the variant payload offset and common layout; other type-specific results will own field offsets. Variants use an aligned `u32` tag followed by storage aligned for the largest payload, with tail padding. A future `sizeof` consumes the common layout boundary.
- Arguments, spills, and copies use the full layout. The current internal convention returns exactly four-byte values in `eax`, other nonzero-sized values in caller-provided stack storage, and zero-sized values without a machine result. Callers reserve a fixed outgoing area. This is not an external platform ABI.
- Per-function compilation emits owned code, relocations, alignment, and symbolic references. Whole-program construction resolves addresses and emits ELF. Cached reachability provides one deterministic breadth-first order for linking and debug output.
- Current startup calls the file's synthetic, unit-returning top-level entry, then exits with zero. Top-level statement values are discarded; `main` has no special status.
- Inline, unit-typed `exit` is temporary. Its language result is `never`; correct that with divergence analysis without requiring external linking. Migrate runtime services to compiler-seeded declarations and ordinary symbolic calls when another service, target, or foreign call justifies runtime-symbol linking. Remove dedicated `exit` machinery then; do not grow it into general intrinsic dispatch. Any bridging `noreturn` property disappears once `never` owns divergence.
