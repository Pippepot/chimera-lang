# Nominal Variant Alternatives

## Declaration

```chi
static Color = .Red | .Blue | .Green
static Result = .Success: int | .Failure: int
static Mixed = .Red | int | .ErrorCode: int
```

- `.Name: T` declares a nominal type wrapping an anonymous payload of type `T`.
- `.Name` abbreviates `.Name: unit`. It remains distinct from bare `unit` and `none`.
- Nominal types belong to the enclosing named declaration's namespace.
- Nominal identity is determined by declaration and generic specialization.
- Duplicate case declarations within the same namespace are invalid.
- `|` retains its existing structural union semantics.
- Payload types must support copying; a non-copyable payload is rejected when
  the declaration or generic specialization is analyzed. Ordinary non-copyable
  type alternatives in structural unions are unchanged.
- A payload annotation binds one primary type. Group a union payload, as in
  `.Choice: (int | bool)`, or a tuple payload, as in `.Pair: (int, int)`.

```chi
func Optional(static T: type) type -> .Some: T | .Empty
static Integers = Optional(int)
```

## Visibility

- Cases and their generated converters inherit the enclosing declaration's
  visibility. A public variant exposes its cases without separate `pub` markers.
- A public variant cannot contain private type alternatives or payload types,
  including private types supplied to a generic specialization.
- Aliases and re-exports preserve the cases' original identities and visibility.

## Construction

```chi
const red = Color.Red
const explicit_red = Color.Red{}
const success = Result.Success{42}
const failure = Result.Failure{7}
```

- Extend brace initialization to support a single positional initializer for anonymous payloads.
- `Name{value}` initializes a nominal wrapper containing `value`.
- `Name{}` initializes a wrapper with a `unit` or `none` payload.
- Ordinary struct field initialization continues to use `Foo{name = value}`.
- Construction preserves nominal identity.

When an expected type is available, `.Name{payload}` or `.Name{}` selects its
unique nominal case with that name:

```chi
func color(c: Color) int
    match c
        .Red -> return 1
        .Blue | .Green -> return 2

const red: Color = .Red
const success: Result = .Success{42}
color(.Red)
```

Annotations, parameters, returns, assignments, and aggregate members supply the
expected type. Match arms use the subject type; tuple subpatterns use their
element types. Aliases, composed variants, specialized generic variants, and
singleton case types all retain their original case identities. Missing context,
missing names, and distinct cases sharing a name are errors. Payload types do not
break name ties. Visibility and constructor validation match qualified lookup.
For cases with a `unit` or `none` payload, bare `.Name` in an expression is a
value, equivalent to `.Name{}`. Other payloads require braces and an initializer.
Type declarations and match patterns retain their type meanings; runtime
shorthand never declares a new case.

Qualified references to cases with `unit` or `none` payloads also construct
values in value contexts. An unannotated `const` or `var` infers the narrow case
type; annotations, arguments, returns, assignments, and aggregate elements can
widen that value as usual. Static aliases of the case type follow the same rule.
Type annotations, static type arguments, type-returning functions, patterns,
constructor targets, compile-time type comparisons, and union type composition
continue to select the type.
Unannotated static initializers select values too, matching `unit` and `none`.
A static type alias supplies a `type` annotation:

```chi
static Red: type = Color.Red
static red = Color.Red
static saved: Color = Color.Red
const narrow = Red
const wide: Color = Color.Red
```

Cases with other payloads still require braces and an initializer. This rule
does not implicitly construct ordinary structs.

This currently applies to nominal cases. The same expected-type principle could
support struct namespace members or omitted-type struct initializers, but those
extensions need their own eligibility and ambiguity rules.

## Conversion

- The compiler synthesizes a converter from `.Name: T` to `T` when `T` is
  neither `unit` nor `none`.
- **Neither `unit` nor `none` payloads have a generated converter.**
- Generated converters participate in existing implicit and explicit converter resolution.
- Conversion copies the payload and follows existing ownership rules. It does
  not consume or mutate the original wrapper. Compile-time-only payloads use
  ordinary static converter specialization.
- No reverse converter is generated.
- No implicit payload field is introduced.

## Flow Typing

```chi
func process(result: Result) int
    if result is Result.Success
        return result

    return 0
```

- Type tests use nominal identity.
- Existing flow-sensitive narrowing applies.
- Converters resolve against the narrowed type.
- Conversion does not modify the original value.

## Composition

```chi
static Extended = Result | .Cancelled
```

- Existing alternatives retain their nominal identities and namespaces.
- Newly declared alternatives belong to the enclosing namespace.
- Union composition does not generate new nominal types.
- Existing structural union and converter-resolution rules remain unchanged.
- Qualified lookup through aliases and composed variants resolves the original
  case type: `Extended.Success` is `Result.Success`. If distinct cases share a
  name, the composition remains valid but lookup of that name is ambiguous;
  use their original variant qualifiers.

## Storage

- A case stores only its anonymous payload; `unit` and `none` payloads occupy no
  bytes. A singleton structural union has no discriminator.
- A multi-alternative variant uses the smallest byte-width discriminator that
  can represent all its alternatives: one byte through 256 alternatives, two
  through 65,536, and four beyond that.
- Payload storage uses the maximum member size and alignment. Variants containing
  only `unit`/`none` alternatives and cases with `unit`/`none` payloads store only
  the discriminator.
