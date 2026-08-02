# Architecture

This document records durable design boundaries, not current implementation status. Update it when those boundaries change.

- Compiler stages depend in the direction of data flow. Parser, semantic, SSA, and codegen modules do not depend on query orchestration.
- The query engine remains compiler-independent. Query definitions use its context protocol without coupling stage implementations to the engine.
- Query keys are small stable identities, never owned ASTs or other large results.
- Cached values own their allocations or contain stable identities; they do not borrow from replaceable inputs.
- Observable optional query results derive equality from their payload type; query-specific `eqlOutput` is reserved for equality that differs from the output type's semantics.
- Inputs and query dependencies are recorded through the query context rather than hidden in globals.
- Function-body semantic analysis, lowering, and machine-code generation operate per function or instantiated function. Module and item queries own cross-function declarations, scopes, and other shared semantic data.
- Function compilation produces relocatable function artifacts; whole-program construction resolves references and emits the executable format.
- Every file uses its synthetic top-level item as the program entry. A declaration named `main` is an ordinary function, and values produced by top-level statements are discarded because the entry result is `unit`.
- The language `int` type is a signed 32-bit value, returned through the x86-64 callable ABI in `eax`.
- Expected source errors are diagnostics, while query failures are reserved for infrastructure failures.
- Refactored compiler stages emit `structures.Diagnostic` values; resolving source paths and rendering source lines belongs to the presentation layer.
