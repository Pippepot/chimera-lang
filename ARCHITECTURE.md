# Architecture

This document records durable design boundaries, not current implementation status. Update it when those boundaries change.

- Compiler stages depend in the direction of data flow. Parser, semantic, SSA, and codegen modules do not depend on query orchestration.
- The query engine remains compiler-independent. Query definitions use its context protocol without coupling stage implementations to the engine.
- Query keys are small stable identities, never owned ASTs or other large results.
- Cached values own their allocations or contain stable identities; they do not borrow from replaceable inputs.
- Observable optional query results derive equality from their payload type; query-specific `eqlOutput` is reserved for equality that differs from the output type's semantics.
- Inputs and query dependencies are recorded through the query context rather than hidden in globals.
- Function-body semantic analysis, lowering, and machine-code generation operate per function or instantiated function. Module and item queries own cross-function declarations, scopes, and other shared semantic data.
- `AnalyzeFunctionBody` is the typed publication boundary: lexical names, explicit annotations, and called signatures are validated before it returns type-specific instructions. SSA and codegen trust that result rather than repeating semantic type checks.
- Expressions produce typed values. Once operand types are known, semantic IR uses type-specific operations such as `addi`; consumers do not repeatedly recover an operation's type from a generic opcode plus metadata. Value IDs describe data flow, while terminators and statement position describe how values are used.
- Fallible expressions describe success or failure control flow; they are not boolean values, error unions, or `Never`. An `if` consumes that outcome through a predicate terminator. Predicate branches have one datatype-independent structure; the operation is type-specific after typing. Logical composition and future variant operations must lower by connecting success and failure edges rather than materializing a boolean SSA value.
- Calls produce values. Discarding a call result and returning it are uses of that value, not distinct call kinds.
- Runtime services ultimately enter semantic scope as compiler-seeded declarations and lower as ordinary symbolic calls to runtime linker symbols; this does not require source-level `extern` syntax. The current unit-valued, inline `exit(value: int)` operation is temporary until runtime-symbol linking is justified, and must not grow into general intrinsic dispatch machinery.
- Add a `Never` type when control-flow joins or return-path completeness first need to represent divergence. If runtime declarations arrive earlier, a temporary `noreturn` property may bridge that gap, but it should disappear once `Never` owns the rule.
- Function signatures own ordered parameter types; parameter names belong to the function body's lexical scope and do not affect callable type identity.
- Parameters are entry-block arguments, not synthetic instructions. All block arguments and instruction results share the value-ID namespace, while call and branch operands use separate flat per-function arrays.
- Control flow is block-structured: every basic block has exactly one terminator, branches carry zero or more arguments to typed target-block parameters, and the graph may contain forward edges or backedges.
- Function compilation produces relocatable function artifacts; whole-program construction resolves references and emits the executable format.
- Every file uses its synthetic top-level item as the program entry. A declaration named `main` is an ordinary function, and values produced by top-level statements are discarded because the entry result is `unit`.
- The language `int` type is a signed 32-bit value, returned through the current internal x86-64 calling convention in `eax`. Functions returning `unit` manufacture no machine value. Integer arguments use the caller's fixed outgoing stack area; this internal convention does not imply compatibility with an external platform ABI.
- Expected source errors are diagnostics, while query failures are reserved for infrastructure failures.
- Refactored compiler stages emit `structures.Diagnostic` values; resolving source paths and rendering source lines belongs to the presentation layer.
