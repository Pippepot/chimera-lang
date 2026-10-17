# Borrowed Aggregates and Pull Iteration: Design Record

Status: implemented foundations and next/End protocol, plus an unapproved,
deferred extension proposal in section 6. The language specification describes current behavior.
This record does not authorize additional syntax or semantic changes.

Implemented foundations: reference fields and alternatives,
tight ref precedence, logical-type matching, unambiguous expected-type capture,
and explicitly typed multi-element tuples preserve captured authority and
projection-specific origins through const carriers and copies. The scoped generic
borrowed Zip example executes in native and compile-time tests. Owned storage
views retain their readonly guarantees. Loop lowering and standard range/span
cursors use next and the shared std.iteration.End marker exclusively. There is
no protocol flag or advance/current fallback. The approved protocol migration
is separate from the general adapter redesign: automatic callable discovery,
computed member builders, and new conditional binding remain deferred proposals,
not prerequisites for the protocol.

## 1. Approval Boundary

New syntax and semantics require explicit user approval before implementation.
An implementation difficulty is not permission to extend the language, change
ownership, weaken verification, or introduce an iterator-specific exception.

The previous draft's public reflection API, conditional function-declaration
syntax, explicit variant-constructor syntax, qualified matching syntax, and
generic Zip body have been removed. They were not established language features
or evidence that the design was implementable as written. Do not substitute
another unapproved API for them.

## 2. Agreed Direction

### Aggregate Members and Reference Scope

Extend the existing reference-field relationship to tuple members and variant
alternatives. Keep a member's logical type separate from its owned/reference
storage kind. MemberSpec names that compile-time distinction; its concrete
source interface remains an open decision, not an approved meta library.

Use tighter ref precedence, with parentheses extending its scope:

```chi
func get(ref source: T) ref T
func next(mut self: Cursor) ref T | End
func get_variant(ref source: T | End) ref (T | End)
func zip_next(mut self: Cursor) (ref A, ref B) | End
```

These signatures use the implemented aggregate/result syntax.
They distinguish a borrowed result, an owned variant with a reference
alternative, a borrow of an existing complete variant, and an owned variant
containing a tuple of reference members.

Migrate existing unparenthesized borrowed-variant signatures deliberately,
including callable annotations. Do not silently reinterpret existing programs.
Parameter access modes remain separate from aggregate-member storage kinds.

Variant alternative identity includes logical type and storage kind, permitting
T | ref T. Owned nested variants flatten according to structural variant rules;
a reference to an existing complete variant does not distribute over its
alternatives. In particular, ref (A | B) differs from ref A | ref B.

Keep Ref(T) an ordinary nominal struct with a reference field. It is not an
implicitly unwrapped loop item. No independently owned raw-reference value,
address expression, or explicit dereference operator is part of this direction.

### Carrier Constness and Captured Authority

Readonly access to owned fields restricts those fields. Following a reference
member preserves its captured referent authority independently of whether its
carrier is const. Replacing the carrier or retargeting its stored reference
requires mutable carrier storage; ordinary assignment to a reference projection
writes the referent, not the stored address.

The following examples use the implemented typed tuple and reference-field rules:

```chi
var x = 10
const handle = Ref.from(x)
handle.value = 20
const pair: (ref int, int) = (x, 5)
pair.0 = 30
```

Capturing a readonly place records readonly authority. Copying or moving that
capture into mutable storage cannot upgrade it. Apply the same rule to reference
struct fields, tuple members, and variant alternatives, without a Ref-specific
or iterator-temporary exception.

This replaces the former specification's const-handle attenuation rule.
Audit APIs relying on carrier constness to provide readonly backing; their
contracts must be preserved explicitly or any API change brought for approval.
Do not treat approval of this general rule as approval of arbitrary API changes.

### Projection-Specific Contracts and Lifetimes

Infer origins and access requirements independently through fields, tuple
positions, variant alternatives, and reference edges. A function writing only
the first referent requires writable authority only there, not on every member
or on the carrier itself. Returning the first referent retains its origins and
permission, not those of unrelated members.

For example, the requested modify function accepts a writable first capture and
a readonly second capture. Swapping those permissions must reject the call.
The requested first function returns the first referent without borrowing the
second. These are inferred contracts, not new caller-written effect syntax.

Preserve these path-specific facts through generic and indirect calls, nested
aggregates, branches, and incremental recomputation. Keep authority separate
from logical type identity; do not introduce permission type arguments.

Distinguish carrier storage from captured referents. Borrowing an owned variant
payload depends on that carrier and its active tag. Extracting an existing
reference member follows its referent's origins; it does not additionally require
the pointer-carrying field or variant to stay alive. Replacing a carrier does
not retarget aliases previously extracted from it. A referent actually inside
the carrier still has the ordinary dependency on that storage.

Retain Chimera's nonexclusive mutable-alias model and existing call-overlap
checks. Cursor polling invalidates an old item only when its actual operations
invalidate storage or contents on which the item depends.

### Ownership and Binding Intent

Reference members own no destruction of their referents. Consuming a carrier
does not authorize consuming a referenced object. Owned members retain their
normal copy, move, and drop obligations.

Preserve existing loop-binding intent: a bare binding preserves the delivered
ownership category while providing readonly use; const/var own their logical
value and copy when necessary; ref aliases a place with its available authority.
Mixed patterns apply modes independently without upgrading a readonly referent.
Their complete construction and destructuring rules still need specification.

### Logical-Type Matching

Approved: existing as T matches alternatives by logical type, regardless of
owned/reference storage kind. No qualified matching syntax is needed for the
ordinary consumer. Binding mode controls whether the selected logical value is
aliased or copied under the existing ownership rules.

```chi
const result = cursor.next()
if ref item = result as A
   use(item)
```

For an owned A alternative, item aliases the carrier's payload and depends on
that storage and its active tag. For a reference-to-A alternative, item aliases
the referent with its captured authority and origins. A const carrier restricts
its owned payload but does not strip authority captured in a reference member.
Matching never upgrades permission or extends a referent's lifetime.

For A | ref A, as A can match either alternative. This does not merge their
storage identities, choose how to construct the variant, or permit consuming a
referenced object. Storage-kind inspection, if needed, remains a separate open
decision. These matching rules are implemented and covered by native/comptime
tests, including extraction from temporary reference-bearing carriers.

### Expected-Type Construction

Approved: when a return expects ref A | End, returning an existing A place
captures that place for the unique reference alternative without copying A.
Returning End constructs exhaustion normally. No reference-valued expression,
new constructor syntax, or temporary lifetime extension is introduced.

If both owned and reference alternatives are viable, report ambiguity rather
than choosing from copy availability. This does not supply an explicit way to
select storage kind in the ambiguous case.

Immovable values cannot be relocated to satisfy adapter composition. Fresh
destination construction may avoid relocation where actually supported; an
adapter cannot silently allocate or change an owned traversal into a borrow.
Explicit-drop items cannot disappear on rejected-filter or unmatched-zip paths.

### Polling and Filtering

End is the distinct ordinary exhaustion type. It is separate from ordinary
fallible failure. Exclude End as an item or direct flattened item alternative;
containing End inside an ordinary struct or tuple is not ambiguous.

Use existing func and fallible declarations. Compiler analysis of a callable's
declared result and failure behavior does not require a public reflection API.

Preserve single source/factory evaluation, named cursor state, ordinary cleanup,
and loop exit behavior. Each step polls next once. Producer failure propagates
before item matching; it must not become End or accidentally become a none item.
There is no for-else syntax or implicit reference-handle unwrapping.

Zip polls left before right. If left ends, do not poll right. Retain an acquired
left item while polling right, without reacquiring it. If right ends or fails,
discharge the unmatched item's ownership obligations. Reject actual invalidation
of the retained item, not merely the coexistence of mutable aliases.

Ordinary filter accepts Chimera's fallible-condition predicate convention:
predicate success accepts and predicate failure rejects. Handle only the
predicate invocation as rejection; producer failure still propagates. A separate
filtering operation may use bool results with ordinary operational failure;
its name and concrete API have not been selected. Release rejected borrows
before polling again and discharge rejected owned items' obligations.

## 3. Decisions Still Needed

### Explicit Storage-Kind Selection

Logical-type matching and unambiguous expected-type construction are approved.
How code explicitly selects storage kind for ambiguous construction or inspects
storage kind, if required, remains open. No explicit constructor or
storage-qualified matching extension has been approved. Agree on any additional
operation and spelling before implementing it.

### Generic Composition Interface

Generic code must preserve logical type and storage kind independently and be
able to express computed result specifications, including borrowed results.
The concrete way to construct, combine, and use MemberSpec in ordinary source
signatures is not settled. No particular builders, descriptor-valued annotation
mechanism, or type-inspection interface is approved by the conceptual agreement.

First distinguish what can be expressed with explicit static type arguments
from what requires a computed storage-qualified specification. Do not require
item metadata declarations on every cursor or expose general callable reflection
merely to make an adapter example shorter.

Verified ordinary-source cases use explicit cursor/item types: map over owned
and borrowed inputs, borrowed and owned filters, a filter with caller-supplied
explicit disposal, mixed owned/reference zip, and nested reference-bearing
tuples. Infallible and fallible definitions spell their effects separately.
Tests cover predicate rejection versus producer failure, poll order, unmatched
and delivered cleanup, independent permissions, first-only returned lifetime,
and actual shared-buffer invalidation versus unrelated mutation. These are
working specialized shapes, not a computed MemberSpec interface or an approved
standard-library adapter API.

The subsequent feasibility audit in section 6 demonstrates that existing
type-valued factories can select owned/reference delivery and exact declared
fallibility. The unresolved part is automatic callable discovery and arbitrary
storage-qualified structural composition, not conditional declaration syntax.

### Tuple Construction and Patterns

Explicitly typed tuples with at least two elements, reference-member capture,
and positional element access are implemented. Independently applied pattern
modes remain part of the direction. Unannotated tuple inference, general
destructuring, and singleton syntax are still open; implemented tuple types do
not settle those additional rules.

### Exact Generic Fallibility

Preserve the requirement that adapters handle producer and callback outcomes
correctly. An ordinary type-valued factory can select an anonymous struct with
an ordinary func or fallible next declaration. Native/comptime tests now cover
all four producer/callback effect combinations, using an explicit combined
effect argument. Fallible specializations reject an unmarked call; the fully
infallible specialization needs no failure handler. Actual producer and callback
failures propagate, while successful End takes a distinct successful path.

When only the callback can fail, ordinary callable widening supplies a fallible
poll function without applying ? to an infallible source call. This proves
selection, not automatic effect discovery: supplying the combined effect bit
is still the caller's responsibility. Section 6 proposes a narrow callable
query instead of conditional declaration syntax or general effect inference.
Do not silently make all adapters fallible, erase an effect, catch producer
failure as rejection, or weaken ownership and effect checks.

Existing condition failure scopes require staging a fallible poll before its
item-matching condition. A call made inside that condition can be handled as
condition failure, even with ordinary propagation syntax. The verified fallible
filter binds the producer result first and handles only the predicate invocation
as rejection; no new propagation operator or iterator exception is introduced.

### Remaining Library Policy

Empty End-only producers, permanently exhausted zip state, and the disposal API
for explicit-drop items need explicit decisions if implementation depends on
them. The previous draft's chosen defaults are not requirements here. Cleanup
must still be correct; unresolved disposal policy never permits silent discard.

## 4. Minimal Borrowed Zip: Local Feasibility Audit

Start with two infallible cursors and two unrelated, noncopyable struct item
types A and B. The left cursor yields a writable reference to A; the right yields
a readonly reference to B. Both return owned reference-bearing variant carriers.
The desired pair is an owned tuple containing those two references.

Supply L, R, A, and B as explicit static type parameters for this first case.
The following body uses the agreed aggregate notation and logical-type matching,
existing calls, and expected reference-member capture from the typed-tuple
example. The complete scoped example is compiled and executed in the reference
suite; it does not approve any additional operation. Input cursor results use
the approved expected-type construction rule.

```chi
struct Zip(L: type, R: type, A: type, B: type)
   left: L
   right: R

   func next(mut self: Zip(L, R, A, B)) (ref A, ref B) | End
      const left_result = self.left.next()
      if ref left_item = left_result as A
         const right_result = self.right.next()
         if ref right_item = right_result as B
            var pair: (ref A, ref B) = (left_item, right_item)
            return pair^
      return End{}
```

This scoped case needs neither callable reflection nor computed fallibility.
Its result shape is spelled directly with the agreed aggregate notation, so it
also does not establish a general computed-MemberSpec interface. L and R must
provide infallible next operations with the stated result shapes; this is not a
claim that the body handles arbitrary cursor signatures.

The explicit tuple annotation determines reference-member capture without
copying A or B. Returning pair transfers the tuple representation into the
unique owned tuple alternative using existing variant-widening intent. Const
poll-result carriers do not strip captured authority. Right End releases only
the unmatched left borrow in this scoped case. No permanently-exhausted state
or disposal policy is added by this example.

| Operation | Assessment |
| --- | --- |
| Name the cursor and item types | Existing explicit static type arguments suffice; no discovery API is needed. |
| Poll left and store its carrier once | Existing call/binding forms plus the agreed borrowed-alternative result direction. |
| Detect left End | Existing is End form selects the unambiguous exhaustion alternative. |
| Extract left's reference to A | Approved: if ref item = result as A aliases the referent, preserving its origins and authority. |
| Poll right while retaining left | Requires ordinary path-specific origins and actual-effect invalidation checks, not a new iterator operation. |
| Detect right End and extract B | Same approved matching rule; unmatched left is only a borrow in this scoped case. |
| Construct and return the reference pair | Known reference members capture the two places, as in the approved typed-tuple example; transfer the tuple, not A or B. |
| Preserve writable-left/readonly-right | Requires independent inferred result paths, not a permission on the whole pair. |

Matching, known reference-tuple capture, and unambiguous expected-type result
construction are approved for this scoped example. The walkthrough does not
claim general computed-MemberSpec or fallibility interfaces. The complete scoped
example and input cursors execute in native/comptime tests; it does not establish
a general adapter interface. No extra mechanism is approved by this walkthrough.

Required observations for this first case: the left referent can be modified,
the right cannot, neither logical item is copied, poll-result carriers can end
without invalidating external referents, and the returned first reference does
not retain the second referent's owner. Reverse the permissions as a second
instance. Reject a real shared-buffer invalidation case.

Then separately validate mixed owned/borrowed items, multiple item alternatives,
borrowed complete carriers, nested zip, lending, and fallible producers. A
borrowed-only example must not stand in for those broader requirements.

## 5. Approved Scope and Verification

1. Preserve the approved matching, construction, typed reference-tuple, and
   authority rules. Obtain explicit approval for any additional language change.
2. Compiler lowering, standard cursors, and legacy fixtures use next/End
   together; the verification flag and old cursor methods are removed. There is
   no automatic fallback, hidden item copy, or implicit Ref unwrapping.
3. Verify supported specialized composition, lending, producer/predicate failure,
   unmatched cleanup, explicit-drop obligations, and immovable construction.
   Preserve scoped aliases of owned poll payloads and reject escaping aliases.
4. Verify native/comptime parity and incremental invalidation of member-kind,
   permission-contract, effect, factory, and protocol-method changes. Run required
   formatting and routine test gates for compiler changes.
5. Keep general adapter limitations explicit. Existing type factories select
   exact effects and storage kinds from explicit static arguments, but do not
   supply automatic discovery or arbitrary storage-preserving composition.

The broader extension proposal is deferred, not an additional migration gate.
Report any unresolved conflict rather than changing semantics or weakening
ownership checks. Layout niche optimization, standalone runtime reference values,
and arbitrary generators are not prerequisites.

## 6. Feasibility Audit and Extension Proposal

This section is a proposal for approval. No std.meta module, descriptor-valued
type builder, callable query, or inferred conditional binding below has been
implemented or approved. Its feasibility audit adds tests only; the approved
next/End protocol does not depend on these proposed language extensions.

### Verified Existing Facilities

The four `adapter feasibility` groups in tests/iteration_test.zig establish:

| Question | Observed result |
| --- | --- |
| Can one public type factory select exact next fallibility? | Yes. All four producer/callback combinations execute natively and at compile time; fallible results require the existing call marker. Actual producer/callback failures remain distinct from successful End. |
| Can an infallible source participate in a fallible adapter? | Yes. Widen its method reference to a fallible callable, then invoke that callable with ?. The source itself remains infallible. |
| Can a factory select owned or borrowed delivery? | Yes. Select ordinary anonymous definitions returning T or ref T inside the result variant. A noncopyable borrowed item remains writable through a ref consumer. |
| Can ordinary code obtain a callable's type? | Yes. `func TypeOf(static T: type, value: T) type -> T` works for a method reference. No typeof intrinsic is needed. |
| Can a factory return a computed tuple type using `(A, B)`? | No. That expression is a tuple value and reports tuple_requires_expected_type, even when the function returns type. |
| Can a callable parameter pattern infer its result type? | No. `func NextType(static S: type, static R: type, operation: func(mut S) R) type -> R` works with explicit S and R, but inference from Source.next reports static_argument_cannot_be_inferred. |
| Can const/ref matching retain Item and ref Item inside a narrowed carrier? | Not in the tested Zip-slot construction. Const matching reports type_not_copyable for the noncopyable reference alternative; reconstructing from a ref binding reports ambiguous_variant_member. Direct reference aliasing of the original mixed carrier succeeds. |

The successful cases do not establish automatic metadata discovery, arbitrary
mixed alternatives, or a complete generic Zip interface. In particular, a single
borrowed flag cannot describe int | ref int, nor distinguish ref (A | B) from
ref A | ref B.

### Recommended Compile-Time Surface

Introduce a compile-time-only MemberSpec with two independent facts:
logical_type, a type value, and reference, a bool. It owns no referent and carries
no authority; authority and lifetime remain inferred from actual source places.
It is not a standalone runtime reference type or an address value.

Proposed names and contracts, not current declarations:

```text
meta.result(callable_type)           -> MemberSpec for the whole result
meta.can_fail(callable_type)         -> bool for declared operational failure
meta.variant_members(variant_type)   -> immutable list of physical MemberSpecs
meta.tuple_type(member_specs)        -> canonical structural tuple type
meta.variant_type(member_specs)      -> canonical variant type
```

result preserves the outer result kind. A result ref (A | End) is one reference
to that complete variant, not an owned variant with reference alternatives.
variant_members preserves each alternative's logical type and storage kind.
It does not erase the difference between A and ref A or merge their identities.
The builders use current arity, canonicalization, ownership, and flattening rules;
reference alternatives never distribute over their logical variant type.

These operations accept type information, never execute a producer or callback,
and return successful compile-time data for an eligible input. Ineligible inputs
are source diagnostics, not operational failure. They do not inspect bodies to
change declared fallibility. Broad parameter reflection, cursor-specific
metadata, return-type inference, and inferred function effects are not proposed.

For example, the following is proposed source, not currently runnable code:

```chi
func pair_next_type(static A: type, static B: type, static ar: bool, static br: bool) type
   const pair = meta.tuple_type([
      meta.MemberSpec{logical_type = A, reference = ar},
      meta.MemberSpec{logical_type = B, reference = br},
   ])
   return meta.variant_type([
      meta.MemberSpec{logical_type = pair, reference = false},
      meta.MemberSpec{logical_type = End, reference = false},
   ])
```

This computes the four owned/reference tuple shapes without four separate
signature spellings. Returned types remain ordinary type values, so type-valued
calls in annotations need no descriptor-valued annotation rule. A bare borrowed
result still uses an ordinary ref annotation in a selected factory definition;
the MemberSpec itself is not usable as an independently owned raw reference.

There is a real additional foundation here: descriptors and their lists contain
type values and therefore have no runtime layout. Permit such immutable
compile-time aggregate values and builder inputs, while rejecting runtime
storage, runtime ABI use, or allocation of those values. This must be implemented
as a general compile-time eligibility boundary, not as an iterator exception.
No arbitrary static descriptor-argument feature is required: adapters can
specialize on ordinary cursor/callback types and compute descriptors during
type-factory execution. Generated definitions continue to capture enclosing
static parameters only; their annotations call global type helpers rather than
capturing factory-local bindings.

### Recommended Storage-Preserving Binding

Keep existing as T logical matching and const/var/ref binding semantics intact.
An owning const binding must not silently change from copying a referenced
logical item to transferring its carrier merely because an adapter needs it.

Propose a bare conditional binding with the existing bare-loop binding intent:

```chi
if item = result^ as Item
   const pair: (Item | ref Item, int) = (item^, 0)
   return pair^
```

The syntax is new and requires approval. It matches by logical type but preserves
the selected physical owned/reference alternatives, just as bare for delivery
does. It does not consume a referent when consuming a pointer-carrying variant.
Single borrowed results remain readonly uses, following existing bare-loop rules;
code that needs available writable authority still uses an explicit ref binding.
Multiple retained alternatives stay an ordinary reference-bearing variant, not
a fabricated reference to their logical union. Failure follows current consuming
match cleanup. No storage-qualified as syntax or runtime member-index API is
proposed.

The concrete need is narrowing int | ref int | End to an owned carrier containing
int | ref int for a Zip tuple slot. const matching currently owns the logical int
and copies the reference alternative; ref matching exposes an int place but
cannot preserve whether it was an owned item or an external capture. Merely
adding metadata cannot resolve that distinction. The proposed binding provides
the already implemented inferred extraction intent outside compiler-owned for
lowering, without changing either existing binding mode.

The source regression confirms those two diagnostics alongside a native/comptime
aliasing control. This does not settle the new spelling or prove the proposed
inferred binding's permission behavior; implementation tests must preserve bare
loop rules and independently captured authority rather than upgrade a readonly
origin. Existing const/ref semantics are not candidates for silent reinterpretation.

### Effects and Remaining Policy

Use the existing type-factory technique for exact declared effects. A general
map computes the disjunction of producer and callback operational failure; Zip
computes the disjunction of its producers. Ordinary condition-filter predicate
failure remains rejection, so it is excluded from that filter's operational
failure. Stage the producer poll outside the predicate's failure scope.

A complete adapter must derive delivery from both the outer carrier kind and
the alternatives' independent kinds. A whole-carrier borrow, separate captured
references, and a mixed owned/reference variant are not interchangeable. Test
their combinations, same-logical-type alternatives, nested tuples, actual
invalidation, and immovable destination restrictions before adopting a general
standard-library adapter contract.
The simple pair_next_type example does not discharge that obligation.

Keep the existing open library policies separate: End-only producers, sticky
Zip exhaustion, and explicit-drop disposal. Do not silently select defaults or
discard an unmatched explicit-drop item. No additional tuple inference,
destructuring, singleton, generator, or allocation policy is part of this proposal.

### Approval and Implementation Order

1. Approve or revise the compile-time MemberSpec/container model and the five
   narrow query/builder contracts. Do not add callable-pattern inference merely
   to work around missing inspection; no parameter-reflection API is needed here.
2. Approve or revise inferred conditional binding against the mixed-carrier
   source regression, including readonly uses and captured reference authority,
   before implementing it.
3. Implement the approved general facilities with behavior and incremental
   tests, then demonstrate one ordinary map/filter/Zip entrypoint for all
   supported shapes and exact effects. Keep explicit-drop disposal explicit.
4. Run native/comptime, incremental, ownership, formatting, and routine
   verification gates for those extensions. These future adapter proofs do not
   gate the separate, approved next/End protocol migration.