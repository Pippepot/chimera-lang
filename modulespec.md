# Module system

## 1. Folders are modules

* A folder is a module. Every `.chi` file directly inside it contributes
  declarations to that module.
* Files create no namespace. Subfolders create child modules.
* Filenames and the `.chi` extension never participate in module or
  declaration identity.

Module paths derive from the entry file's directory. There is no
folder-root flag. That directory is `$entry`; subfolders append dotted
segments. Parent and sibling folders are invisible. Directory segments must
be spellable identifiers; other directories and their subtrees are invisible
to module discovery, so `physics/collision` and a literal `physics.collision`
folder never merge.

```text
main.chi
helpers.chi
physics/body.chi
physics/world.chi
physics/collision/raycast.chi
```

with the entry file in the top directory:

```text
.                      -> $entry
./physics/             -> physics
./physics/collision/   -> physics.collision
```

## 2. Same-module visibility

Static, function, and struct declarations are shared across every file of
one module. No import is needed between them. Top-level `const` and `var`
bindings are entry-body locals, not shared declarations. File and
declaration order have no meaning.

```text
// physics/body.chi
struct Body {}

// physics/world.chi
func simulate(body: Body) {}
```

## 3. Imports

Imports are file-scoped, top level only, and order-independent. Each file
states its own external dependencies; sharing a module does not share
imports.

```text
// a.chi
import physics

// b.chi
// physics is NOT imported here
```

Forms:

```text
import physics
import physics.collision
import physics.{Body, World}
import physics as phys
import physics.{Body as PhysicsBody}
```

* `import physics` introduces the qualified namespace: `physics.Body`,
  `physics.simulate()`. It never implicitly imports children, so
  `import physics` does not provide `physics.collision`.
* An unaliased import exposes its full path: `import physics.collision`
  provides `physics.collision.X` but not `collision.X`. Shared leading
  segments navigate parent namespaces without importing them, so combining
  imports that share a prefix is harmless.
* `import physics as phys` replaces the qualification: `phys.Body`.
* `import physics.{Body}` introduces `Body` directly into file scope.
  An empty selective list is the empty import.

## 4. Qualified lookup

`.` dispatches on what its left-hand side resolves to. Module-qualified
lookup is valid wherever the target declaration is valid:

```text
physics.Body
physics.make_body()
physics.Body{...}
```

Struct namespaces use the same syntax (`S.func()`). The first identifier
resolves normally, so a local shadows an imported module name with no
fallback:

```text
import physics

func foo()
    var physics = ...
    physics.x // the local, not the module
```

## 5. Name lookup and conflicts

Unqualified lookup order:

1. Local lexical declarations.
2. Function/static parameters.
3. Declarations of the current module.
4. Selective imports and import aliases of the current file.

Conflicts:

* A selective import or alias must not collide with another visible
  non-import declaration at the same file scope (`struct Body {}` plus
  `import physics.{Body}` is an error).
* Locals inside functions may shadow imports.
* The same import in different files of one module is fine.
* An exact duplicate import within one file is harmless; one name bound
  to different declarations is an error.

## 6. Visibility

Declarations are module-private by default and visible from every file of
the same module, but inaccessible elsewhere.

```text
struct Internal {}
func helper() {}
static state = ...
```

`pub` opens a top-level static, function, struct, or import to importing
modules. It is rejected on runtime `const`/`var` bindings and anywhere
inside a body:

```text
pub struct Body {}
pub func simulate() {}
pub static gravity = ...
pub import math.{Vec3}
```

Struct-field visibility is out of scope for this spec.

## 7. Re-exports

Imports are private by default and never create new declarations. `pub
import` re-exports under the importing module's namespace:

```text
pub import math.{Vec3} // consumers use physics.Vec3
```

* Re-export chains share one identity: `A.X`, `B.X`, `C.X` are the same
  declaration, including nominal type identity.
* A re-export never enters the unqualified scope of sibling files: each
  file sees its module's declarations plus its own imports only.
* Module-alias re-exports (`pub import physics.collision [as collision]`)
  follow the normal conflict rules.

## 8. Cycles

Module import cycles are allowed and are not errors by themselves. Only a
real semantic dependency cycle fails, via the existing
`declaration_cycle` mechanism.

## 9. Entry and execution

`$entry` is the entry file's directory module and may span several files.
Any file may contain executable top-level statements, but only the file
passed to the compiler executes them. An imported file's statements never
run. Imports are compile-time dependencies with no runtime side effects.

## 10. Moves

* Renaming a file within its folder has no semantic effect.
* Moving a declaration across folders changes its module and its identity,
  including nominal type identity (`physics.Body` to
  `physics.types.Body`).
* `pub import` can preserve the old access path but never the old nominal
  identity.

## 11. Invariants

* Folder = module; file = organizational subdivision.
* Same-module declarations are shared across files.
* Cross-module access is explicit via imports.
* Private means module-private; public API uses `pub`.
* Children are never implicitly imported.
* Order of files, declarations, and imports has no meaning.
* Re-exports add names, never declarations or identities.
* Imports never execute code.

Non-goals: package distribution, struct-field visibility, standard-library
contents and prelude names.

## 12. Implementation plan

Baseline: slices 0–2 are done. `main.zig` loads every `.chi` file under the
entry directory (`SourceText` + `FileModule` inputs, entry fixed at `FileId`
0); `Token.Tag`/`Node.Tag` have `import`/`pub` forms with `pub` as a
transparent wrapper; imports are skipped by `$entry`, misplaced imports and
`pub` are rejected, and qualified types parse with resolution deferred.
Each slice below is one coherent diff and covers diagnostics, ownership
paths, and incremental recomputation; unsupported forms are rejected at
their owning boundary.

Note on §5: the plan adopts module-declarations-before-file-imports, with
collisions as errors, so the order is rarely observable.

### Slice 0 — Record semantics in `syntax&semantics.txt`

Port settled §§1–11 decisions there before coding (working-rules
requirement); `ROADMAP.md` module item tracks status. No compiler change.

### Slice 1 — Module identity and file loading (done)

* Add `ModuleId` (entry-dir-relative folder path; pointer-free query key).
  `FileModule(FileId) → ModuleId` input/query; `$entry` = entry file's
  directory.
* CLI walks the entry directory and subfolders for `.chi` files, assigns
  one `FileId` each, loads each `SourceText`. Parents/siblings stay
  invisible. No root flag.
* Tests (`*_test.zig` helpers): folder grouping, child paths
  (`physics`, `physics.collision`), outside-tree invisibility.

### Slice 2 — Syntax: `import`, `pub`, qualified paths (done)

* Tokenizer: `keyword_import`, `keyword_pub` (`as` exists).
* AST: one `import` node (`[path, selective…]`, struct-init-style) reusing
  `field_access`/`.as` shapes, plus a `pub` wrapper on top-level
  declarations. Imports allowed anywhere among top-level declarations,
  order-independent.
* `.` needs no new expression form: the first identifier resolves normally
  (locals shadow modules, §4); module-qualified use parses in type, value,
  callee, and initializer-head positions, with resolution deferred. An
  empty selective list parses as the empty import.
* Misplaced imports and `pub` are rejected (`import_outside_top_level`,
  `misplaced_pub`); hook source offsets are computed from the unwrapped
  declaration.

### Slice 3 — Cross-file discovery, identity, and membership (done)

* Split declaration identity from source location. Identity is
  `{module, owner, kind, name}`; the current file and AST position move
  into a replaceable index result that `ResolveItem` consults, trying the
  discovery hint first and scanning member indexes on relocation. Missing
  membership is an infrastructure failure, never a silent fallback:
  `addSource` isolates legacy test files in per-file modules and the
  driver always registers complete membership. Relocating a declaration
  between files of one module preserves identity while updating its
  location and file-scoped imports; same-folder renames are no-ops;
  cross-folder moves change the module and the identity, including
  nominal type identity. Replacing `ItemLoc.file_id` with `module_id`
  alone is insufficient.
* Keep synthetic `$entry` identities file-specific: one per file, never
  merged by module.
* Add explicit module membership: a per-module membership input enumerating
  member files, fed by the directory catalog. The catalog represents empty
  modules and parents containing only child modules; interning a path
  never establishes existence. `FileModule` answers which module owns a
  file; it cannot enumerate a module's files.
* `DiscoverItems` leaves import decls out of value scope without collecting
  them; slice 4 reads imports from the AST. Duplicate detection merges all
  files of one module: a repeated name rejects the module; equal names in
  different modules are independent.
* `BuildModuleScope` stays `FileId`-keyed and becomes module-aware: it
  serves the merged `ModuleDeclarations` set (union of member files, still
  sorted) through the file's module. Hook items stay excluded as today.
  File keys are kept because slice 4 adds file-scoped imports to the
  effective file scope.
* Cross-file declaration errors render with correct files immediately.
  Membership changes and declaration relocation get recomputation tests
  here, not in slice 7.
* Tests: identity/location split (move preserves, cross-folder changes),
  file-specific entries, membership incl. empty modules, cross-file
  duplicates, relocation recomputation.

### Slice 4 — Import resolution, visibility, re-exports

* New query `ResolveFileImports(FileId)`: resolves the file's imports
  against module paths, filters by `pub`, binds whole-module namespaces,
  aliases, and selective names; follows `pub import` chains without
  creating identities. Whole-module imports bind namespace identities
  without resolving imported contents, so cyclic module graphs never
  deadlock: exported names resolve on demand through declarations and
  re-exports, independently of body and type evaluation. A binding
  distinguishes a module namespace from a declaration; no new runtime
  value type. Import-graph cycles are allowed; only semantic cycles fail
  via `declaration_cycle`.
* Effective file scope = current-module declarations + file imports (§5
  order). Enforce `pub` at the use site; private stays module-local.
  Diagnostics spanning files render with correct paths in this slice.
* New `Diagnostic.Kind`s: `unknown_module`, `unknown_imported_name`,
  `private_access`, `import_conflict`. Duplicate exact imports harmless;
  one name to different declarations errors. `pub` on struct fields
  rejected at its owning boundary.
* Effective file scope = current-module declarations + file imports (§5
  order). Enforce `pub` at the use site; private stays module-local.
* New `Diagnostic.Kind`s: `unknown_module`, `unknown_imported_name`,
  `private_access`, `import_conflict`. Duplicate exact imports harmless;
  one name to different declarations errors. `pub` on struct fields
  rejected at its owning boundary.
* Tests: whole/selective/alias imports, child-not-implicit, shadowing,
  conflicts, private rejection, re-export chains sharing identity,
  import-cycle-without-semantic-cycle.

### Slice 5 — Semantic/typing integration

* `TypeInterner` (`resolveStatic`/`resolveFunction`/`resolveItem`) and
  `typing.zig` `BodyBuilder` consume the effective file scope instead of
  the raw per-file table. Qualified paths resolve LHS module-alias vs
  value, then member/type-namespace lookup; comptime thunks use the same
  scope. No ownership/lifetime representation changes.
* Tests: cross-module types/calls/initializers, alias qualification,
  struct-namespace vs module-namespace disambiguation.

### Slice 6 — Entry, reachability, execution

* Top-level statements allowed in any file, but only the CLI-designated
  entry file's statements execute; imported files' statements never
  compile or run. `CollectReachableInstances` seeds from the entry file's
  `$entry`; per-function compile/codegen unchanged.
* Tests: imported-module side-effect freedom, entry-only execution with
  multi-file `$entry`, `exit` behavior preserved.

### Slice 7 — Incremental, CLI, docs

* Slice-3-level recomputation is covered at introduction; here: remaining
  dependency edges file→module and module→module, equal results retaining
  allocations/`changed_at`, and driver-level file add/remove invalidation.
* CLI debug (`ast,ssa,asm`) and diagnostics render multi-file paths;
  `git diff --check`, `zig fmt --check`, README suites
  (`query_new_test`, `codegen_new_test`, `main`, tokenizer/AST/semantic).
* Update owning docs only: `ARCHITECTURE.md` (new queries, `ModuleId`
  ownership), `PROGRAM_FLOW.md` (diagram), `ROADMAP.md` (module status).
