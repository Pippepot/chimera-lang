# Nominal Variant Alternatives

## Declaration

```chi
static Color = .Red | .Blue | .Green
static Result = .Success: int | .Failure: string
static Mixed = .Red | int | .ErrorCode: int
```

- `.Name: T` declares a nominal type wrapping an anonymous payload of type `T`.
- `.Name` abbreviates `.Name: none`.
- Nominal types belong to the enclosing named declaration's namespace.
- Nominal identity is determined by declaration and generic specialization.
- Duplicate case declarations within the same namespace are invalid.
- `|` retains its existing structural union semantics.

## Construction

```chi
const red = Color.Red{}
const success = Result.Success{42}
const failure = Result.Failure{"error"}
```

- Extend brace initialization to support a single positional initializer for anonymous payloads.
- `Name{value}` initializes a nominal wrapper containing `value`.
- `Name{}` initializes a payloadless nominal wrapper.
- Ordinary struct field initialization continues to use `Foo{name = value}`.
- Construction preserves nominal identity.

## Conversion

- The compiler synthesizes a converter from `.Name: T` to `T` when `T` is not `none`.
- **No converter is generated for payloadless (`none`) cases.**
- Generated converters participate in existing implicit and explicit converter resolution.
- Conversion extracts the payload and follows existing ownership rules.
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