# Chimera Numeric Specification

## Types

- Signed integers: `i8`, `i16`, `i32`, `i64`.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`.
- Pointer-sized integers: `isize`, `usize`.
- Floating-point: IEEE 754 `f32`, `f64`.
- Aliases: `int = i32`, `byte = u8`, `float = f64`.
- Signed integers use two's-complement representation.

## Literals

- Integer literals support decimal, `0x` hexadecimal, `0b` binary, and `0o` octal notation.
- `_` may separate digits.
- Integer magnitudes are parsed with arbitrary precision.
- Literals adopt their expected type when representable, otherwise default to `int`.
- Negation is applied before literal range checking.
- Floating-point literals support decimal fractions and scientific notation.
- Floating-point literals default to `float` and round directly to their destination format using nearest-even.
- Floating-point literals outside the finite range, or nonzero literals rounding to zero, produce errors.
- Integer literals adopt floating-point types when exactly representable.

## Conversions

Lossless numeric conversions use implicit converters:

```python
pub extern converter(imm value: i32) i64
```

Both implicit and explicit invocation are supported:

```python
const a: i32 = 42
const b: i64 = a
const c = i64(a)
```

A conversion is lossless when every source value is exactly representable in the destination type.

Other numeric conversions use explicit policies:

| Operation | Semantics |
|---|---|
| `checked(T, x)` | Exact conversion, returning `T \| none` |
| `wrap(T, x)` | Integer conversion modulo \(2^N\) |
| `saturate(T, x)` | Clamp to destination integer range |
| `round(T, x)` | Nearest-even rounding |
| `truncate(T, x)` | Float-to-integer truncation toward zero |

Float-to-integer saturation truncates toward zero after clamping.

Float-to-integer `round` and `truncate` return `T | none` on invalid or out-of-range results. Float-to-integer `saturate` also returns `T | none` for NaN. Float-to-float `round` returns `T`, including infinity on overflow.

## Operator resolution

- Operators resolve through Chimera's existing function-based operator resolution.
- Implicit converters may satisfy parameter types after operator resolution.
- Numeric operations use the selected operator's return type.
- Generic inference follows existing rules.
- Literals use contextual typing.

## Integer arithmetic

- `+`, `-`, `*` use checked overflow, panicking in every build.
- `/` truncates toward zero; `%` has the dividend's sign.
- Division by zero and signed `MIN / -1` panic.
- Unary negation of signed `MIN` panics.
- Bitwise operations `&`, `|`, `^`, `~`, `<<`, `>>` operate at the integer's fixed width.
- Left shifts discard shifted-out bits.
- Right shifts are arithmetic for signed integers and logical for unsigned integers.
- Shift counts outside `[0, width)` panic.
- Comparisons produce `bool`.

### Overflow contexts

```python
wrapping(a + b)
saturating(a * b + c)
```

- `wrapping` performs modular arithmetic at the result width.
- `saturating` clamps each operation independently.
- Contexts affect compiler-recognized integer arithmetic within the expression.
- Nested contexts override enclosing contexts.
- Ordinary function and user-defined operator bodies retain their own arithmetic semantics.
- Primitive operator declarations and signatures remain unchanged.
- Under wrapping, signed `MIN / -1` produces `MIN`; under saturation, `MAX`. The corresponding remainder is zero.
- Division by zero always panics.

## Floating-point arithmetic

- `+`, `-`, `*`, `/` use IEEE 754 semantics with nearest-even rounding.
- Overflow produces signed infinity.
- Underflow supports subnormals.
- Invalid operations produce NaN.
- Division of a nonzero finite value by zero produces signed infinity.
- Signed zero is preserved.
- Comparisons involving NaN are false except `<>`, which is true.
- `f32.inf`, `f32.nan`, `f64.inf`, and `f64.nan` are provided.
- Arithmetic preserves specified rounding and exceptional-value behavior.

## Compile-time evaluation

- Constant evaluation follows the same concrete numeric semantics as runtime execution.
- Provable checked integer overflow produces a compilation error.
- Floating-point overflow produces infinity.
- Numeric operations retain their concrete widths during constant evaluation.

## Backend

- Numeric operators and converters are compiler-recognized intrinsics exposed through existing declarations.
- Arithmetic instructions record their numeric type and overflow mode.
- Conversion instructions record their destination type and conversion policy.
- Backend lowering and optimization preserve the specified numeric semantics.
