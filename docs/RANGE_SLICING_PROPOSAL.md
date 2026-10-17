# Range Slicing Contract

Status: range-based named slicing is implemented. Bracket dispatch, from-end
indices, and strided views remain deferred decisions. Language rules live in
[syntax&semantics.txt](../syntax&semantics.txt).

## Verified Starting Point

- Array, List, Span, BytesView, and StringView use one fallible `slice(bounds)`
  API. There is no separate public start/size slicing alternative. A Span result
  owns its view handle, not the selected elements or backing storage.
- `Range(A, B)` preserves independently typed original endpoints and inclusivity.
  Omitted endpoints use none; `..b`, `a..`, and `..` are reusable ordinary values.
- Resolution checks initialized bounds before offset or inclusive-end arithmetic.
  Empty exclusive slices at the endpoint are valid; reversed bounds fail rather
  than becoming empty slices. StringView additionally checks UTF-8 boundaries.
- Array and List expose `span()`. List spans cover initialized elements, not
  reserved capacity. Safe slicing must not expose uninitialized storage.
- Standard integer indexing returns `ref T`; binding intent selects borrowing
  or copying. Slicing returns an owned Span handle, not ownership of elements.
- Index operation declarations currently require an integer index. Operation
  identity uses spelling and runtime operand count, not argument types.
  Adding another same-arity index declaration is not an available overload.
- Fully bounded integer ranges create normalized traversal state only when
  iterated, reversed, or stepped. Reversal and stepping return RangeSequence,
  not raw Range bounds; these sequence values are not contiguous slice arguments.

The implementation anchors are [range.chi](../std/range.chi),
[allocation.chi](../std/memory/allocation.chi),
[array.chi](../std/array.chi), and the demanded-operation signature checks in
[queries.zig](../src/queries.zig).

## Bounds Versus Sequence

`2..2` and `2..1` retain different bounds even though both iterate an empty
sequence. The former can produce an empty slice; the latter fails slicing.
This distinction is established by raw bounds, not recovered from iteration.
Endpoints are evaluated once, left to right. No expected-context syntax rule
or separate Slice bounds type is needed.

Partial ranges require a collection extent for slicing and do not implicitly
introduce infinite iteration. A contiguous Span cannot represent a reversed or
strided sequence; keeping RangeSequence separate prevents silent reinterpretation.

## Decisions Still Requiring Approval

### Index Dispatch And Result Ownership

Decide how integer and range indexing coexist without inventing implicit
argument-type overloading. A generic index declaration would also need to
express the difference between `ref T` element results and owned Span results.
Returning a union of both shapes would change existing integer-index consumers;
returning a reference to a temporary Span is not an equivalent solution.

The implemented named slicing method does not change operator semantics or
implement `span[a..b]`. From-end spelling and strided-view representation also
remain open; independently typed bounds leave room for a future FromEnd type.

## Checked Bounded Slice Cases

For a source of length 5, these are named slicing outcomes, not bracket behavior:

| Bounds | Outcome |
| --- | --- |
| `0..5` or `..` | All five elements |
| `1..4` | Three elements |
| `..3` | First three elements |
| `2..` | Last three elements |
| `2..2` | Empty at index 2 |
| `5..5` | Empty at the endpoint |
| `0..0` or `..` on an empty source | Empty |
| `2..1` or `2..^1` | Failure, not an empty sequence |
| `-1..2` | Failure |
| `0..6` | Failure |
| `6..6` | Failure |
| `1..^3` | Three elements |
| `5..^5` or `1..^none` | Failure |

Bounds checks must precede size arithmetic. In particular, inclusive upper-bound
conversion must not compute `limit + 1` before proving that it is representable
and within the initialized source. Stepped and reversed sequence values are
rejected rather than treated as contiguous slices.

## Ownership And Verification Requirements

Preserve the existing Span contract rather than adding a slicing-specific
reference model:

- A mutable view of writable backing can modify selected elements without
  copying them. Readonly inputs and `as_imm()` cannot become writable through
  copying, nesting, a mutable carrier, or a helper return.
- Subviews may outlive intermediate view handles, but not the backing owner or
  an invalidating storage change. They do not acquire ownership of elements.
- Replacing or destroying List backing invalidates dependent views. Constructing
  a slice does not freeze its owner; actual conflicting use still matters.
- Empty endpoint slices and zero-sized elements retain checked bounds and
  ordinary lifetime rules. Empty views must not expose a spare element.
- Native and compile-time execution must agree on successful and failed bounds,
  permissions, and lifetimes. Incremental tests must cover changed bounds and
  source lengths without reusing a stale view result.

These guarantees use the existing reference model; slicing adds no new lifetime
or exclusivity rule.

## Existing API Characterization

The `span slicing` groups in [text_test.zig](../tests/text_test.zig) now cover:

- An independent endpoint matrix for a five-element source, including all
  21 exclusive and 15 inclusive valid slices and rejected bounds in the tested range.
- Extreme integer bounds rejected before offset arithmetic, endpoint-empty
  slices, empty sources, and zero-sized elements without phantom elements.
- Nested subviews returned past intermediate handles while retaining backing
  lifetime and permission; escaping a local backing owner remains invalid.
- The distinction between owned Span fields and captured reference fields in
  const carriers. Const owned views attenuate writes; reference fields retain
  their captured authority, but cannot upgrade readonly backing.

Range slicing tests also cover reusable bounds, omitted endpoints, direct
Array/List permissions, initialized extents, and rejection of sequence operands.
These tests run both native and compile-time execution. Range snapshots restore
each endpoint shape and recompute edits to its type and value. The nested-span
snapshot test in [query_disk_cache_test.zig](../tests/query_disk_cache_test.zig) checks
restoration and recomputation after edits to slice bounds, source length,
intermediate constness, and backing permission.

## Recommended Next Step

Approve an index-dispatch contract that preserves both borrowed integer results
and owned slice handles before extending bracket syntax. Keep generic reflection,
type builders, and new conditional-binding semantics outside that change.