# Program Flow

How the incremental compiler pipeline executes. Design rules live in `ARCHITECTURE.md`; milestone status lives in `ROADMAP.md`.

The pipeline is a Salsa-style query system: every compilation step is a memoized query that pulls its inputs on demand, records what it read, and survives source edits by re-verifying dependencies instead of recomputing. Queries are defined in `query_structures.zig`, run on the concurrent engine in `query_new.zig`, and exchange the shared value types in `structures.zig`. `query_new_test.zig` drives the full path, ending in `runtime.writeProgram`/`runProg`.

## Query graph

```mermaid
flowchart TD
    ST["SourceText(FileId)<br/>owned source bytes"]
    ST --> PF["ParseFile(FileId) → ?Ast"]
    PF --> DI["DiscoverItems(FileId) → ?ItemTree<br/>(incl. synthetic $entry)"]
    DI --> IX["IndexItems(FileId) → ?ItemIndex<br/>interns ItemLoc → stable ItemId"]
    IX --> SE["SelectEntry(FileId) → ?ItemId"]
    IX --> MS["BuildModuleScope(FileId)<br/>→ ?ModuleScope (name-sorted)"]
    IX --> RI["ResolveItem(ItemId)<br/>→ ?ResolvedItem (file + decl node)"]
    RI --> FS["FunctionSignature(ItemId)<br/>→ ?FunctionSignature"]
    RI --> AB["AnalyzeFunctionBody(ItemId)<br/>→ ?FunctionBodyAnalysis"]
    MS -->|"resolve call names"| AB
    FS -->|"validate calls / returns"| AB
    AB --> SSA["LowerToSSA(InstanceId)<br/>→ ?SsaFunction (ssa.zig)"]
    SSA --> CF["CompileFunction(InstanceId)<br/>→ ?CompiledFunction (codegen_new.zig,<br/>relocatable: code + relocations<br/>+ referenced_instances)"]
    SE --> BE["BuildExecutable(FileId) → ?Executable<br/>BFS over referenced_instances,<br/>layout + resolve relocations (codegen_new.zig)"]
    CF --> BE
```

- Per-function granularity: editing one body invalidates only `AnalyzeFunctionBody` for that item and downstream per-instance queries; equal signatures suppress callee-side recomputation.
- Semantic failures are values (`?Output` plus emitted diagnostics); errors are reserved for infrastructure failures.
- The executable's entry is each file's synthetic top-level `$entry`; a `main` declaration is ordinary.

## Engine execution cycle (`query_new.zig`)

```mermaid
flowchart TD
    CALL["db.get(Q, key) or ctx.get(Q, key)<br/>(spawn/wait; work-stealing worker pool)"] --> KEY{"entry exists?"}
    KEY -->|no| RUN["run Q.run(ctx, input)"]
    KEY -->|yes| VER{"output present and<br/>verified_at == revision?"}
    VER -->|yes| HIT["return cached output"]
    VER -->|no| DEPS{"re-verify recorded deps:<br/>input changed_at / dep changed_at"}
    DEPS -->|unchanged| MARK["verified_at = revision (hit)"]
    DEPS -->|changed| RUN
    RUN --> EMIT["ctx.input / ctx.get record deps;<br/>ctx.emit collects diagnostics"]
    EMIT --> COMMIT{"output + accumulators equal<br/>to previous?"}
    COMMIT -->|"equal"| KEEP["destroy fresh output;<br/>keep old allocation and changed_at"]
    COMMIT -->|"different"| SWAP["free old output; store fresh;<br/>changed_at = revision"]
    CYCLE["cycle detection via queued/running state"] -.-> RUN
```

Inputs (`addInput`/`setInput`) may change only while the database is idle; a real value change bumps the global revision. Every result type defines structural equality — equality gates replacement, so unchanged results keep their allocation and pointer identity across revisions.

## Data structures and lifetimes

Ownership follows one rule: **cached values own their allocations; identities are small stable keys.** Everything below lives until `Database.deinit` unless noted.

| Lifetime | Structure | Notes |
| --- | --- | --- |
| Session (owned by DB inputs) | `SourceText` value `[]const u8` | Cloned into `Database`; freed and replaced only by `setInput` |
| Session (interner) | `ItemId` → interned `ItemLoc` | Opaque `enum(u32)`; names owned by the interner; stable across edits, reused after remove/restore |
| Session (memoized outputs) | `Ast` | Flat `[]Token`, `[]Node`, `[]Node.Index`; owns its arrays, stores `FileId` instead of borrowing text |
| " | `ItemTree`, `ItemIndex`, `ModuleScope` | Owned slices/hash map of file items; scope maps names to `ItemId`s |
| " | `FunctionSignature` | Owned parameter-type slice |
| " | `FunctionBodyAnalysis` | `FunctionIr(ItemId)`: flat arrays of block args, call operands, typed instructions, blocks |
| " | `SsaFunction` | Same shape as above with symbolic `InstanceId` call targets |
| " | `CompiledFunction` | Relocatable machine code + relocation records + referenced-instance table; no addresses |
| " | `Executable` | Final linked bytes; consumer must copy before `Database.deinit` |
| Per-recompute metadata | `Entry.deps`, `Entry.input_deps` | Fresh dependency edge lists committed atomically or discarded |
| Query-transient (freed within one query run) | `UnresolvedBody` | Name-resolution scratch built by semantic.zig, consumed and freed before publishing `FunctionBodyAnalysis` |
| " | BFS sets, scratch lists | e.g. reachability set in `BuildExecutable` |
| Beyond the process | `Executable.bytes` | Copied into the `./prog` file by `runtime.writeProgram` |

Result pointers are stable across equal recomputations but must be treated as invalid once a changed recomputation replaces a memo.
