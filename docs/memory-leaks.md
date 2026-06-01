# Memory leaks

There are ~14 pre-existing memory leaks in the compiler, all from the persistent
cache deserialization path in `query.zig:tryLoadPersistentCache`. They are not
introduced by recent changes — they exist in the original code at the same count.

## Root cause

`tryLoadPersistentCache` deserializes cached stage data (parse AST, resolved AST,
typed AST, lowered IR, compiled bytes) into local variables, then stores them into
the query system's memo maps via `fetchPut`. If any step between deserialization
and `fetchPut` fails (`catch return`), the deserialized stage values are abandoned:

```zig
// query.zig:299-341 (abbreviated)
const parse_value = deserializeParsed(...) catch return;  // may allocate
var parse_memo = loadMemo(parse_value, ...) catch return; // parse_value transferred to memo
parse_memo.deps = depForSource(...) catch return;          // allocates deps list
...
cache_backings.append(loaded.backing) catch return;        // backing transferred
...
fetchPut(source_id, parse_memo) catch return;               // memo stored in query
```

Every `catch return` bails out without freeing allocations from earlier steps.
The `errdefer loaded.deinit(self.gpa)` only cleans up the cache file backing,
not the deserialized stage values, dep lists, or intermediate data.

## Specific leaks per stage

| Stage | Allocation | Freed by |
|-------|-----------|----------|
| parse | `ParsedAst.ast.backing` (from `deserializeParsed`) | `ParsedAst.deinit()` → never called on `catch return` |
| resolve | `ResolvedAst.functions`, `key_arena`, hash maps | `ResolvedAst.deinit()` → never called on `catch return` |
| typecheck | `AnalyzedAst.functions`, func types, node types | `AnalyzedAst.deinit()` → never called on `catch return` |
| lower | `Program.functions`, symbols, func types | `Program.deinit()` → never called on `catch return` |
| compile | `compile_bytes` (duped from cache) | `gpa.free()` → never called on `catch return` |
| deps | `ArrayList(Dependency)` from `depForSource/Stage` | `memo.deps.deinit()` → memo never stored |
| backing | cache file bytes from `readFileAlloc` | `loaded.deinit()` → handled by `errdefer` ✅ |

## The `exit(1)` problem

Three call sites in `main.zig` use `std.process.exit(1)` which skips Zig's
`defer`/`errdefer` cleanup, including `defer qdb.deinit()`:

- `main.zig:88` — `cli_args.len == 0` (fixed)
- `main.zig:107` — source file read error (fixed)
- `main.zig:175` — compile diagnostics present (fixed)

All three were changed to `return error.xxx` so that `defer qdb.deinit()` runs
on error paths too.

## Remaining leaks (14)

After the `exit(1)` fix, 14 leaks remain on the **success** path. They come from
allocations during deserialization that are stored in memo values but not properly
freed by `qdb.deinit()`. These are pre-existing and were not introduced by recent
changes.

To fully fix them, `tryLoadPersistentCache` needs a `defer` block that frees all
intermediate allocations on any failure path, similar to:

```zig
var success = false;
defer if (!success) {
    if (parse_value) |*v| v.deinit(gpa);
    if (resolve_value) |*v| v.deinit(gpa);
    if (type_value) |*v| v.deinit();
    if (lower_value) |*v| v.deinit(gpa);
    if (compile_bytes) |b| gpa.free(b);
};
// ... process stages, setting each value to null after transferring to memo ...
success = true;
```

The challenge is that each type has a different `deinit` signature (some take `gpa`,
some don't), and `loaded.deinit()` must also be called to free stage diagnostics
that were emptied by `loadMemo` (which transfers ownership).
