# Fail Semantics Implementation Plan

Status: Approved. Ready for implementation.

## Core Model

| Concept | Meaning |
|---------|---------|
| **Fallible expressions** | Comparisons on all types: `<` `>` `<=` `>=` `==` `!=` |
| **Fallible context** | Only `if` conditions |
| **Success** | Condition is true → produces `unit` |
| **Failure** | Condition is false → fallible expression produces nothing |
| **`if` without else** | No-op on failure, body must be `unit` |
| **`if` with else** | Works as normal conditional |
| **`bool` type** | Exists for `true`/`false` literals & `printb` — separate from fallibility |

## Rules

1. `if` condition **must** be a fallible expression. Non-fallible (literals, arithmetic, etc.) → error.
2. Fallible expressions outside `if` condition → error.
3. Comparisons produce `unit` type (not `bool`) in the type system.
4. All `==`/`!=` on int, float, AND bool are fallible — no exceptions.

## Typechecker (`typecheck.zig`)

### Remove
- `IfConditionMustBeBool` — no longer needed
- `IfBranchTypeMismatch` — keep (still applies)
- `IfWithoutElseRequiresUnit` — keep (still applies)

### Add
- `IfConditionNotFallible` — for non-fallible expr in `if` condition
- `FallibleOutsideFallibleContext` — for fallible expr outside `if` condition

### Add to error messages
```zig
error.IfConditionNotFallible => "If condition must be a fallible expression",
error.FallibleOutsideFallibleContext => "Fallible expression is not allowed outside fallible context",
```

### Checker changes
- Add `in_fallible_scope: bool` field (default false)

### `inferIf` changes
```zig
fn inferIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) InferError!Type {
    // condition is in fallible scope
    self.in_fallible_scope = true;
    const cond_ty = try self.inferNode(if_node.cond);
    self.in_fallible_scope = false;

    // condition must be a fallible expression
    if (!isFallible(if_node.cond)) {
        return self.fail(if_node.cond, error.IfConditionNotFallible);
    }

    // then/else inference unchanged
    const then_ty = try self.inferNode(if_node.then_);
    if (if_node.else_) |else_node| {
        const else_ty = try self.inferNode(else_node);
        if (then_ty != else_ty) return self.fail(node, error.IfBranchTypeMismatch);
        return self.remember(node, then_ty);
    }
    if (then_ty != .unit) return self.fail(if_node.then_, error.IfWithoutElseRequiresUnit);
    return self.remember(node, .unit);
}
```

### `inferComparison` changes
Return `.unit` instead of `.bool`:
```zig
fn inferComparison(...) InferError!Type {
    // ... same operand checks ...
    return self.remember(node, .unit);  // was .bool
}
```

### `inferEquality` changes
Return `.unit` instead of `.bool`. Bool operands still accepted (comparison between bools is also fallible):
```zig
fn inferEquality(...) InferError!Type {
    // ... same operand checks ...
    return self.remember(node, .unit);  // was .bool
}
```

### `inferNode` dispatch changes
For comparison nodes, add fallible-scope check:
```zig
.lt, .gt, .le, .ge => {
    const result = try self.inferComparison(node, kids);
    if (!self.in_fallible_scope) {
        return self.fail(node, error.FallibleOutsideFallibleContext);
    }
    return result;
},
.eq, .ne => {
    const result = try self.inferEquality(node, kids);
    if (!self.in_fallible_scope) {
        return self.fail(node, error.FallibleOutsideFallibleContext);
    }
    return result;
},
```

### `isFallible` helper
```zig
fn isFallible(node: *const AstNode) bool {
    return switch (node.*) {
        .lt, .gt, .le, .ge, .eq, .ne => true,
        else => false,
    };
}
```

## IR (`ir.zig`)

Change comparison result types from `.bool` to `.unit`:

```zig
.lt => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    if (operand_ty == .int) return self.addPairInst(.lti, kids, .unit);
    return self.addPairInst(.ltf, kids, .unit);
},
.gt => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    if (operand_ty == .int) return self.addPairInst(.gti, kids, .unit);
    return self.addPairInst(.gtf, kids, .unit);
},
.le => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    if (operand_ty == .int) return self.addPairInst(.lei, kids, .unit);
    return self.addPairInst(.lef, kids, .unit);
},
.ge => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    if (operand_ty == .int) return self.addPairInst(.gei, kids, .unit);
    return self.addPairInst(.gef, kids, .unit);
},
.eq => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    return switch (operand_ty) {
        .int => self.addPairInst(.eqi, kids, .unit),
        .float => self.addPairInst(.eqf, kids, .unit),
        .bool => self.addPairInst(.eqb, kids, .unit),
        .unit => unreachable,
    };
},
.ne => |kids| {
    const operand_ty = try self.nodeType(&kids[0]);
    return switch (operand_ty) {
        .int => self.addPairInst(.nei, kids, .unit),
        .float => self.addPairInst(.nef, kids, .unit),
        .bool => self.addPairInst(.neb, kids, .unit),
        .unit => unreachable,
    };
},
```

The IR instructions still produce 0/1 values internally — the type annotation changes to `.unit`. Codegen for `cbr` just loads the value and compares to 0 regardless of type.

## Codegen (`codegen.zig`)

No changes needed. `cbr` does `cmp eax, 0; je/jne` — type metadata is irrelevant.

## Parser (`parser.zig`)

No changes needed now.

## Future: scope infrastructure for `if const x = <expr>`

For future use, the condition of `if` can bind a variable visible in the then-branch:

```
if const a = 3 < 6 then ...
```

- `a` would be `unit` (the result of the comparison succeeding)
- Not visible in else-branch or outer scope
- Parsing: new syntax variant `if const ident = <expr> then <expr> [else <expr>]`
- AST: new node or add `const_binding` field to `IfNode` (e.g. `const_name: ?[]const u8`)
- Typecheck: push binding with the fallible expr's result type only in then-branch scope
- Not implemented now — mechanism ready when needed

## Test Changes (`test.zig`)

### Remove / change (comparisons as values now invalid)

- Line 100-108: `print(3 < 4)`, `print(4 < 3)`, etc. → remove (fallible outside fallible context)
- Line 127-130: `print((0.0 / 0.0) == 1.0)`, `print((0.0 / 0.0) != 1.0)` → remove
- Line 149-155: `print(true == false)`, `print(true != false)`, `print(true == true)` → remove
- Line 167-170: `if true then print(99)`, `if false then print(98) else print(97)` → remove or change to use fallible conditions

### Keep (valid)

- Line 110-113: `if 3 < 4 then print(11)`, `if 3 > 4 then print(33) else print(44)` → valid
- Line 114-118: `print(if 8 > 2 then 55 else 66)` → valid (inner if has else, returns int)
- Line 117: `print((if 2 == 2 then 5 else 6) + 7)` → valid (inner if has else)
- Line 149-151: `print(true)`, `print(false)` → valid (bool literals, not fallible)
- Line 167: `if 3 < 4 then print(11)` → already valid form
- Line 172-174: `if 3 < 4 then print(11)` → keep

### Update type error tests

- Line 180: `"if 1 then 2 else 3"` → error changes from "if condition must be bool" to "If condition must be a fallible expression"
- Line 183-185: `"if 1 < 2 then 1 else 2.0"` → same error (IfBranchTypeMismatch)
- Line 186-188: `"if 1 < 2 then 1"` → same error (IfWithoutElseRequiresUnit)
- Line 189-191: `"print(if 1 < 2 then print(1) else print(2))"` → same error (PrintUnitValue)

### Add new tests

- `if true then print(11)` → error: "If condition must be a fallible expression"
- `print(3 < 4)` → error: "Fallible expression is not allowed outside fallible context"
- `const x = 3 < 4` → error: "Fallible expression is not allowed outside fallible context"
- `if 3 < 4 == 5 > 2 then print(11)` → valid (nested fallible in fallible context)

## Example Translations

| Source | Status | Reason |
|--------|--------|--------|
| `if 3 < 4 then print(11)` | ✅ Valid | `3 < 4` is fallible in fallible context |
| `if 3 < 4 then print(11) else print(22)` | ✅ Valid | Same, with else |
| `if true then print(11)` | ❌ Error | `true` is not fallible |
| `print(3 < 4)` | ❌ Error | Fallible outside fallible context |
| `const x = 3 < 4` | ❌ Error | Fallible outside fallible context |
| `print(true)` | ✅ Valid | Bool literal, not fallible |
| `print(true == false)` | ❌ Error | `==` is fallible outside fallible context |
| `3 < 4` (top-level) | ❌ Error | Fallible outside fallible context |
| `if 3 < 4 then 42` | ❌ Error | No-else requires unit then-branch |
| `if (3 < 4) == (5 > 2) then print(11)` | ✅ Valid | Nested fallible in fallible context |
| `if 0 then print(11)` | ❌ Error | `0` is not fallible |

## Lowering Flow (unchanged in practice)

```
Source: if 3 < 4 then print(11)

Typecheck:
  fallible_scope = true
  3 < 4 → lti → type=unit → ok (fallible in fallible scope)
  fallible_scope = false
  print(11) → type=unit
  if type = unit

Lower:
  lti(3, 4) → slot[5], type=unit
  cbr(slot[5]): 0→else, 1→then
  then: printi(11) → br merge(0)
  else: iconst(0)  → br merge(0)
  merge: param=unit

Codegen:
  cmp [rsp+40], 0  (load slot[5])
  je   .else
  jmp  .then
  ... (identical to current)
```
