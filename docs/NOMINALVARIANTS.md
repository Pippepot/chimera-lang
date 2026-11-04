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
const red = Color.Red{}
const success = Result.Success{42}
const failure = Result.Failure{7}
```

- Extend brace initialization to support a single positional initializer for anonymous payloads.
- `Name{value}` initializes a nominal wrapper containing `value`.
- `Name{}` initializes a wrapper with a `unit` or `none` payload.
- Ordinary struct field initialization continues to use `Foo{name = value}`.
- Construction preserves nominal identity.

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