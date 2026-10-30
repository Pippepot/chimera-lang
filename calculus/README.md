# Chimera Core Calculus

Status: a descriptive language model with a mechanically checked refinement
subset, not a normative specification or a proof of full Chimera.
[The language specification](../syntax&semantics.txt) remains authoritative.
A disagreement requires an explicit language decision; neither this model nor
the compiler silently wins.

This document describes a small, monomorphic core after name resolution,
specialization, overload selection, and converter selection. Its purpose is to
make ownership, mutation, and flow refinement understandable independently of
the compiler's data structures. It does not propose a new compiler IR.

## 1. Scope

The first model includes records, structural tuples, owned/reference variants,
functions, mutable places, control flow, destination construction, and affine
deferred initializers. It distinguishes ordinary returns from divergence and
fatal execution errors. Absence and user errors remain ordinary data.

The account has three layers:

| Layer | Responsibility |
| --- | --- |
| Execution | Storage, values, operations, construction, and lifetime events |
| Static reasoning | Types, permissions, availability, origins, and refinements |
| Elaboration | Source evaluation order, explicit preparation, and cleanup |

Compile-time execution is an extension of execution, described in section 9.
It is not a second language with different ownership rules.

The model does not yet give complete rules for custom ownership-hook bodies,
storage primitives, collection relocation and mutation provenance, arbitrary
reference-effect inference, or static specialization and type-factory identity.
It states the contracts these features must satisfy. It also excludes planned
named variant cases, closures, shared ownership, numeric extensions, and the
publication of evaluation-local allocations. A safety claim about this core
must not be presented as a theorem about those excluded features.

## 2. Types, Places, and Values

Use the following mathematical syntax. It is not Chimera source syntax.

```text
T ::= int | byte | bool | unit | none | never
    | R | (k1 T1, ..., kn Tn) | Sum{k1 T1, ..., kn Tn}
    | Fun(m1 T1, ..., mn Tn; r T)

k ::= own | ref
m ::= imm | mut | var | deinit | init
r ::= own | ref

p ::= x | p.field | p.index(a)
v ::= integer | byte-value | true | false | () | none
    | record{...} | tuple(...) | inj(k T, payload) | function-id
b ::= place(p, authority, dependencies)
d ::= uninitialized destination
u ::= pending initializer
```

`R` is a resolved nominal record identity with a separately declared field
shape. A fixed-size array can be modeled as a homogeneous record of element
places; allocation-backed containers need the storage extension. `a` is an
already evaluated index, never an expression that is evaluated again.

`Sum` is a finite canonical set of alternatives. Flatten owned nested sums,
remove `never`, and identify a singleton owned sum with its member. Reference
alternatives remain distinct from owned alternatives. In particular:

```text
Sum{own T, ref T}       has two alternatives
ref Sum{own A, own B}   denotes one borrowed whole variant
Sum{ref A, ref B}       stores one of two reference alternatives
```

The last two forms are not interchangeable. `ref T` above describes member or
result storage, not a general source-level reference type constructor. A handle
such as `Ref(T)` is an ordinary record containing a reference field.

Keep these dimensions independent:

| Fact | Meaning |
| --- | --- |
| Declared type | What storage may contain and what assignment accepts |
| Read type | Which alternatives a valid control-flow proof permits reading |
| Member kind | Whether an aggregate owns a member or stores a reference |
| Authority | Whether access through this place permits writing |
| Capabilities | Copy, move, and destruction operations supported by a type |
| Representation | Whether the implementation passes bits or an address |

No capability follows from representation. Address-passed arrays need not be
immovable. Narrowing grants neither ownership nor writable authority.

## 3. Execution State

A machine configuration is:

```text
<H, O, E, K, c>
```

`H` is storage, `O` is ownership and construction state, `E` maps local names to
operands or places, `K` contains call and initializer continuations, and `c` is
the next command. Fresh identities never become equal through storage reuse.
These are semantic identities, not numeric addresses exposed to programs.

Each resolved storage path has independently relevant identities:

| Identity | Ends or changes when |
| --- | --- |
| Slot lifetime `s` | Its storage ceases to designate that place |
| Ownership generation `g` | Its current owned object is consumed or destroyed |
| Content version `h` | A write changes the contents relevant to an observation |
| Active-tag version `t` | A variant carrier may select a different alternative |

Identities are path-sensitive: replacing a field need not change its sibling's
identity. The model uses fresh versions for potentially relevant writes, even
when a concrete write happens to restore the previous bits. Runtime need not
store these versions; they also serve as ghost state for static reasoning.

`O` records which generation owns each initialized subobject and which final
destinations are reserved or under construction. A record may have a residual
set of initialized fields. Such a record is not a whole initialized value.

A borrow `b` records a resolved place, captured authority, and dependency tokens
such as `slot(s)`, `object(g)`, `contents(h)`, or `tag(t)`. The selected path and
kind of observation determine which tokens are needed; a borrow does not
automatically depend on every token of every enclosing value.

Examples of dependency selection:

- An inline payload alias depends on its owning storage and active tag.
- Following a stored reference alternative depends on the captured referent,
  not on the continued existence of the variant carrier that held the address.
- An alias to an ordinary stable slot can survive replacement of its contents.
- A view into an old allocation depends on that allocation, not just its owner's
  surviving inline slot. A validated text view also depends on byte contents.

Evaluating a projection may temporarily retain a carrier while capturing its
address or contents. This retention is not a captured referent dependency. A
completed reference binding or handle copy retains only its referent dependencies;
an assignment target retains its required carrier through preparation and
write-back, or through ordinary cleanup if preparation returns, breaks, or
continues instead.

A copy of a reference field preserves authority and dependencies. Readonly
access through an owned field restricts authority. Following a reference field
uses the captured authority independently of the carrier's constness. There is
no global rule requiring mutable references to be exclusive.

## 4. Core Operations and Reduction

Core operations make decisions already implicit in source syntax explicit:

```text
read p                         observe an initialized place
alias p                        capture a nonowning place
copy p into d                  construct using T.copy
move p into d                  construct using T.move; consume the source
construct T {...} into d       initialize members at their final addresses
inject k T operand into d      construct one selected sum alternative
replace p with producer        prepare or construct replacement as below
test p against A               produce bool and edge implications
invoke f(args) into d          call with prepared arguments and destination
defer expression captures      form one pending initializer
force u into d                 evaluate the initializer in its destination
end g                          complete one lifetime under its drop contract
branch b c1 c2 | loop c | return operand | break operand | continue
```

These are semantic operations, not proposed source spellings. Evaluation
contexts select the leftmost unevaluated eager subexpression. Branches select
only one successor. An initializer body is evaluated only by `force`.

Write `C -> C'` for one ordinary transition. Write `C ->* C'` for zero or more
transitions. The following schemas specify the important transitions; record
member traversal, call frames, and hook execution refine these schemas rather
than introducing a second ownership model.

### 4.1 Reading, Aliasing, and Testing

```text
H(p) is initialized with v; dependencies of p are live
-------------------------------------------------- READ
<H, O, E, K, read p> -> <H, O, E, K, v>

resolve(p) = l; dependencies(p) = D; authority(p) = q
-------------------------------------------------- ALIAS
<H, O, E, K, alias p> -> <H, O, E, K, place(l, q, D)>

H(p) = inj(a, payload)
-------------------------------------------------- TEST
<H, O, E, K, test p against A>
  -> <H, O, E, K, logical-type(a) in A>
```

`READ` is observation, not an implicit copy of an owned object. A value used to
initialize an owned destination still needs copying, movement, or construction.
A reference alternative projects its referent as a place. A test compares
logical types, so it can select owned and reference alternatives of the same
logical type without changing their stored kinds.

### 4.2 Copy, Transfer, and Construction

```text
p initialized; d uninitialized; T.copy supported
-------------------------------------------------- COPY
copy p into d executes T.copy(p, d), then owns fresh generation at d

p owned and initialized; d uninitialized; T.move supported
-------------------------------------------------- MOVE
move p into d executes T.move(p, d), consumes p, and owns fresh generation at d

d uninitialized; member initializers e1, ..., en in source order
-------------------------------------------------- CONSTRUCT
construct each ei into its member destination; publish complete object at d
```

Custom hooks may have observable effects and must satisfy their declared
contracts. Trivial and fieldwise operations are the direct instances of these
schemas. Copy and move are not generally pure heap updates. A fresh result
constructs in its consumer's destination without invoking a delivery copy or
move. An immovable object's address remains stable through destruction.

A field transfer removes that field from the source generation's residual
obligations. Parent capability restrictions still apply. Consuming the final
owned field leaves no parent drop obligation. Reinitialization creates a new
generation rather than reviving the old one.

If construction leaves by an ordinary permitted exit, clean completed
subobjects in reverse initialization order, constrained by reference
dependencies. Never call the incomplete object's whole-object drop hook.
Completed aggregates use their ordinary field destruction order instead.

### 4.3 Replacement

For directly movable `T`, replacement follows this sequence:

```text
retain target p and its old generation
prepare an independent owned replacement, preserving source evaluation order
end the old generation under its drop contract
install the prepared value in the existing slot; begin a new generation
release target retention
```

Installation is an ownership handoff, not an extra source-level copy or move
hook. An exit during preparation does not itself destroy the old target early;
ordinary exit cleanup applies. Completed writes and transfers are not undone.

For a type requiring construction at its final address:

```text
end the old generation; mark p uninitialized
construct the replacement directly at p
publish a new complete generation if construction completes
```

The second form cannot access the replaced place, an enclosing place, or a
borrow of either during construction. Independent siblings remain usable. An
ordinary exit may leave the destination missing, subject to the surrounding
initialization and parameter obligations. Neither form permits retaining a
borrow whose required old-object dependency has ended.

### 4.4 Calls and Parameter Modes

Calls prepare arguments once in source order. The parameter type is already
selected; conversion is an explicit ordinary call before final preparation.

| Mode | Preparation and callee contract |
| --- | --- |
| `imm` | Readonly access; aggregates borrow through the call; directly passed scalars snapshot during preparation |
| `mut` | Exact-typed writable caller storage; retain backing owners; restore required initialization on return |
| `var` | Owned argument initialized by copy, transfer, or fresh construction |
| `deinit` | Delegate consuming access; no binding copy or custom move hook |
| `init` | Pass a pending initializer without evaluating its expression |

`deinit` preserves source storage when direct movement is unavailable. A
directly movable source is snapshotted into independent owned storage before
later arguments execute. The caller loses ownership at preparation, not at
callee entry. References into parameter-owned storage cannot escape its
lifetime. References contained in the parameter retain independent origins.

An owned result constructs in the caller's result destination. A borrowed
result designates caller or permanent storage, never local or copied-parameter
frame storage. Function types retain parameter and result modes. Indirect calls
must preserve the same contracts; safety cannot depend on seeing a particular
callee body or on inlining.

Call contracts describe result origins, caller-visible writes, and transferred
obligations. For this initial model they are explicitly supplied assumptions
which each modeled function must satisfy. The derivation of arbitrary
interprocedural contracts is not formalized here. Unknown targets use a sound
conservative contract, not an assumption of no effects. Caller-visible output
dependencies merge all ordinary return paths; selecting an optional or error
alternative does not retroactively narrow those effects.

### 4.5 Deferred Initializers

A pending initializer contains an expression, lexical captures, and a fresh
affine token. Its expression is type-checked without performing its effects.
Each receiving parameter has one authority to force or forward that token.

```text
u pending; d uninitialized; captured accesses remain permitted
-------------------------------------------------- FORCE
force u into d consumes u's token and evaluates its body with destination d

u pending; forwarding to an init parameter
-------------------------------------------------- FORWARD
transfer u's token and captures, without evaluating the body
```

A continuation may discard an unused initializer. Each receiving authority can
be exercised at most once on an execution path. A chain may forward the same
token through several calls, but it can be forced at most once. Forwarding
transfers authority to force; it does not create another token. The initializer
cannot be inspected as a `T`, stored, copied, or returned as a handle.

Captured owners remain live until their required accesses end. Conflicting
mutations and consumption are rejected across all later argument preparation
and forwarding. Deferred transfer does not consume its source until executed;
an absent result after execution does not restore that source. Shared
continuations require availability on every incoming path.

An initializer has its own control region. It produces its declared value or
diverges; `return`, `break`, and `continue` cannot target outside that region.
Called functions and loops inside it retain their ordinary exits. Capture
retention ends at the consuming construction call's end, unless an ordinary
borrowed result carries a surviving dependency.

### 4.6 Cleanup and Terminal Outcomes

`end g` applies the type's automatic destruction contract exactly once, unless
the obligation was transferred or delegated. Explicit-drop objects must instead
be transferred or explicitly deinitialized on every ordinary exit path. A
`deinit` callee completes or delegates the lifetime; it does not get an implicit
whole-object drop-hook call afterward. Remaining fields retain their own duties.

Chimera uses last-use cleanup, not general lexical scope-exit cleanup. The
elaboration obligation is to insert destruction at the earliest completed
subexpression boundary after the last reachable use on that path. Future loop
uses, borrowed uses, cleanup accesses, and argument/target retention count as
uses. A branch with no future use ends the generation on that outgoing edge.

When several generations end at one boundary, destroy dependents before owners
their cleanup may access; otherwise use reverse lifetime-start order. Completed
record fields use reverse declaration order. The explicit `end` operations in
the core must obey this scheduling condition; arbitrary delayed cleanup is not
an equivalent elaboration. A constructive algorithm and proof that the schedule
is earliest are future formalization work.

Ordinary return, break, and continue carry cleanup of nonescaping generations.
Returning `none` or a user error is an ordinary return. Divergence has no
successor on which to insert cleanup. Native panic aborts without unwinding;
compile-time panic produces a source diagnostic. No rule promises cleanup after
a fatal execution operation, and no rule rolls back earlier effects.

## 5. Static Judgments

Use a typing environment `Gamma` for fixed declarations and capabilities, a
resource state `Delta`, and a refinement state `Phi`. They are analysis facts,
not an additional runtime representation.

```text
Gamma; Delta; Phi |- p : place(T, q, D)
Gamma; Delta; Phi |- e => k T -| Delta'
Gamma; Delta; Phi |- e <= (T, d) -| Delta'
Gamma; Delta; Phi |- b => bool [Phi_true, Phi_false] -| Delta'
```

The judgments respectively resolve a place, synthesize a result category and
type, check owned construction in a destination, and analyze Boolean edge
implications. `k` in the synthesis judgment distinguishes owned results from
borrowed places. A producer which needs a destination is checked by the third
judgment rather than first materialized and relocated.

`Delta` tracks initialized paths, owned generations, authority and origins,
pending initializer tokens, and retention obligations. `Phi` tracks possible
stored alternatives and the identities on which proofs depend. The logical
read type forgets stored member kind, but ownership operations must not.

### 5.1 Availability and Permissions

```text
p initialized on this path; required dependencies live
-------------------------------------------------- PLACE
Gamma; Delta; Phi |- p : place(declared-type(p), authority(p), dependencies(p))

p writable; RHS constructs declared-type(p); replacement plan valid
-------------------------------------------------- ASSIGN
Gamma; Delta; Phi |- p = RHS : declared-type(p)
```

Assignment checks the declared type, never the narrowed read type. Owned
initialization from an existing place requires copy capability unless explicit
transfer or consuming access applies. Borrowing does not confer ownership.
Moving into distinct storage requires movement capability; delegating to
`deinit` does not. Ordinary place use cannot silently transfer at last use.

No whole-place read or borrow is valid while a required field is missing.
Through a source-level borrowed alias, transfer of the referent is invalid.
Overlapping `mut` and `imm`/`mut` arguments in one call are rejected; distinct
nonoverlapping sibling paths do not overlap. These call checks do not imply
global exclusive borrowing.

### 5.2 Refinement and Mutation

A proof is indexed by the identity of the selected place and the relevant tag
versions, including ancestry needed to reach a nested payload. Let `A` be the
current set of possible stored alternatives and `logical(a)` their logical
types. A test against type set `U` has edge facts:

```text
A_true  = {a in A | logical(a) in U}
A_false = {a in A | logical(a) not in U}
```

Proofs restrict reads only while their dependencies match the current state.
Writing an unrelated sibling preserves a fact. Writing inside the selected
payload preserves its enclosing tag fact. Replacing a carrier, including
through an alias or call, invalidates facts depending on that carrier's tag.
Ending a required owner or ancestor also invalidates the dependent access.

A completed assignment establishes a fresh fact from the assigned value's known
alternatives before widening into the declared storage type. This does not
revive old saved implications or narrow every possible target of an ambiguous
reference. An uncertain RHS retains its possible alternatives; a join unions
the alternatives written on its incoming paths. Mutations without a known new
value establish no replacement fact.

A saved Boolean carries implications, not a permanent narrowing:

```text
saved = test p at identity i, version t
saved true implies proof(p in U, i, t)
use implication only if i and t still designate the tested carrier
```

Copying the bool may preserve the implication. Reassigning the bool installs
the new expression's implications. Mutation of the tested carrier leaves the
bool value intact but makes its old implication unusable.

Binding a reference to a dynamic selection fixes that selected place. A later
independent `values[index]` expression does not inherit the bound reference's
proof just because the expressions look alike. A differently laid-out subset
variant requires construction or repacking; it cannot be aliased as if the
original carrier's representation had changed.

### 5.3 Boolean Flow, Joins, and Loops

For `not b`, exchange the true and false edge states. For `b1 and b2`, analyze
`b2` only under `b1`'s true state and merge both false exits. For `b1 or b2`,
analyze `b2` only under `b1`'s false state and merge both true exits. Evaluated
operands execute once, left to right. In value position the result is still an
ordinary bool carrying only valid implications.

At a control-flow join:

- Merge only reachable incoming exits; a returning branch contributes no state.
- A place is available only if initialized on every incoming exit.
- Possible alternatives are unioned, retaining provenance for each edge.
- A proof is usable only if justified for every reaching state; version merges
  cannot resurrect a proof invalidated on one edge.
- Potential reference origins and output effects conservatively include all
  relevant incoming paths. Permissions cannot be upgraded by merging.
- A pending initializer is usable afterward only if available on every reaching
  path; consumed-on-one-path is not available-on-all-paths.

Missing owned fields require edge normalization: end the field on paths that
still own it if automatic destruction permits. Explicit-drop obligations cannot
be discharged this way. Residual cleanup must preserve the original stored
member kinds and all remaining ownership duties.

A loop header is an invariant checked against entry and every reachable
backedge. Availability promised at entry must be restored on each backedge.
An incoming refinement used by the body must likewise survive every backedge;
it is not enough that the first iteration is safe. A test inside the loop can
establish a fresh proof for that iteration. Loop exits join independently of
backedges. No termination theorem is assumed.

## 6. Elaboration Obligations

Write `source ~> core` for elaboration. This is a contract, not an assertion that
the present compiler has been proved to implement it.

| Source form | Core meaning |
| --- | --- |
| `const x = p`, `var x = p` | Copy an existing borrowed place into owned storage |
| Fresh initializer or owned call result | Construct in the consumer's destination |
| `ref x = p` | Capture the existing place and its authority/dependencies |
| `p^` in an owning context | Explicit transfer using the applicable move contract |
| Bare owning `p` passed to `deinit` | Delegate consuming access without a binding hook |
| Variant widening | Explicit selected-alternative construction; preserve member kind |
| `p is T` | Logical membership test with identity-dependent edge facts |
| `match` type pattern | The same membership refinement, without converter calls |
| Operation or selected converter | Ordinary resolved call and argument preparation |
| `and`, `or`, `not` | Short-circuit control flow with ordinary bool results |
| `for` | Source/cursor bindings, ordinary calls, loops, and variant selection |

Expected types guide destination construction, not just a later coercion.
Fresh immovable members can construct directly inside a larger variant;
completed narrower immovable variants cannot simply be relocated into it.
Conditional results propagate destinations. Inferring an expected type must
not execute argument effects early.

Source initializer order is observable and need not equal record declaration
order. Partial cleanup follows initialization order, while complete fieldwise
destruction follows declaration order. Desugaring must preserve that distinction.

Name lookup, converter candidate coherence, specialization inference, pattern
coverage, physical layout, and query invalidation are outside these reduction
rules. Their relevant contracts must be validated before this core trusts them.

## 7. Worked Source Cases

Each fenced `chimera` block below is a complete, independent source file.
`expect=42` means normal execution exits with status 42. `reject=...` means a
source error, with the expected diagnostic text fragment. These are validation
annotations for this document, not language syntax or proof certificates.

### 7.1 A Saved Boolean Is Versioned Evidence

```chimera name=saved-proof expect=42
func choose(value: int | none) int
    const number = value is int
    if number -> return value
    return 0
exit(choose(42))
```

The test saves an implication about the parameter's carrier. No write changes
its tag identity, so the true edge permits an `int` read. Nothing changes the
declared parameter type.

```chimera name=stale-proof reject=does not define operation
var value: int | none = 42
const number = value is int
value = none
if number -> exit(value + 1)
```

The assignment remains valid because storage accepts `int | none`. It changes
the carrier version, so `number` cannot justify an integer addition afterward.
The test result is still true; its implication is stale.

### 7.2 Aliases Preserve Payload Identity, Not Ownership

```chimera name=payload-alias expect=42
struct Item
    copy = trivial
    value: int
func run() int
    var source: Item | none = Item{value = 19}
    if source is Item
        ref selected = source
        selected.value += 23
        return source.value
    return 0
exit(run())
```

Writing `selected.value` does not replace `source`'s tag. The original proof
still permits its payload read. The alias owns neither the payload nor its
destruction, and requires the carrier and active-tag dependencies to survive.

### 7.3 Loop Proofs Must Survive Backedges

```chimera name=stale-loop-proof reject=loop can repeat after invalidating a type proof
var value: int | none = 19
if value is int
    loop
        const number = value + 1
        value = none
        if number > 20 -> break
```

The continuing edge has invalidated the entry proof. It cannot reach the next
integer read under the original assumption. A fresh guard on each iteration
would establish a different, local proof.

### 7.4 Destination Construction Does Not Imply Movement

```chimera name=immovable-result expect=42
struct Immovable
    move = none
    value: int
func make() Immovable -> Immovable{value = 42}
const item = make()
exit(item.value)
```

`make` constructs in the caller's destination. Returning the fresh result
requires neither a move hook nor relocation of a completed object.

### 7.5 Skipping Effects Does Not Weaken the Caller Contract

```chimera name=skipped-initializer expect=42
func produce(mut counter: int) int
    counter += 1
    return counter
func skip(init value: int) int -> 0
var counter = 42
skip(produce(counter))
exit(counter)
```

The initializer is not evaluated, so its write never occurs. The call still
checks its possible effects against captured access and lifetime constraints.

```chimera name=possibly-transferred reject=may already have been transferred
struct Item
    copy = none
    value: int
func skip(init item: Item) int -> 0
var source = Item{value = 42}
skip(source^)
exit(source.value)
```

Deferring `source^` captures its required access but does not execute transfer.
Nevertheless the caller must account for the parameter's permission to consume
it. Reading the source afterward is rejected even though this particular body
skips construction. A body-specific optimization must not weaken that callable
contract. Runtime skipping and static availability are separate claims.

### 7.6 Ordinary Error Results Do Not Roll Back Effects

```chimera name=ordinary-result expect=42
func write_then_absent(mut value: int) none
    value = 42
    return none
var value = 0
const result = write_then_absent(value)
if result is none -> exit(value)
exit(0)
```

`none` is an ordinary result, not a failure continuation. The completed write
persists. No special optional-result execution or cleanup rule is introduced.

### 7.7 Partial Transfer Preserves Remaining Obligations

```chimera name=partial-transfer expect=42
struct Item
    copy = none
    value: int
struct Pair
    first: Item
    second: Item
var pair = Pair{first = Item{value = 19}, second = Item{value = 23}}
const first = pair.first^
exit(first.value + pair.second.value)
```

The transfer leaves `pair.first` unavailable while preserving access to
`pair.second`. No whole-parent use is allowed in that state. Its residual
cleanup must not destroy the transferred first field a second time. This
program checks availability and execution, not destructor timing, since
`exit` is a terminal operation without subsequent cleanup.

### 7.8 Partial Construction Does Not Run the Whole-Object Hook

```chimera name=partial-construction expect=42
struct Leaf
    trace: Ref(int)
    drop = func(deinit self: Leaf) -> self.trace.value += 1
struct Pair
    first: Leaf
    second: int
    drop = func(deinit self: Pair) -> exit(99)
func make(trace: Ref(int)) Pair | none
    return Pair{first = Leaf{trace = trace}, second = if true -> return none else 0}
func run() int
    var trace = 0
    const result = make(Ref.from(trace))
    if result is none -> return trace + 41
    return 0
exit(run())
```

The first field is complete when the second initializer returns from `make`.
Its automatic drop increments `trace`. `Pair` never completes, so its custom
whole-object drop must not exit with status 99. This is ordinary eager construction, not a
deferred initializer region: the inner return still targets `make`.

### 7.9 Last Use Can Precede the End of the Scope

```chimera name=last-use-cleanup expect=42
struct Marker
    trace: Ref(int)
    drop = func(deinit self: Marker) -> self.trace.value += 1
func run() int
    var trace = 0
    const item = Marker{trace = Ref.from(trace)}
    _ = item
    return trace + 41
exit(run())
```

The discard explicitly keeps `item` alive through that use. At the completed
boundary afterward there is no future use, so destruction increments `trace`
before the return expression reads it. Lexical scope-exit destruction would
produce a different result. The borrowed `trace` remains alive for cleanup.

## 8. Safety Goals and Present Gaps

These are language-wide goals, not established theorems for the full core. The
mechanized subset in section 10 establishes a narrower refinement claim.

1. **Preservation:** an ordinary step preserves well-formed storage, resource
   obligations, and valid read refinements under the correspondingly updated
   static state.
2. **Progress with explicit outcomes:** a well-typed configuration can step,
   return, or reach a specified terminal operation. Divergence and documented
   execution errors are not classified as stuck configurations.
3. **Reference validity:** every executed place access has live dependencies
   and no greater authority than its origin granted.
4. **Ownership accounting:** ordinary transitions do not duplicate ownership
   or silently lose destruction obligations. A transfer changes the responsible
   owner; a completed destruction cannot be repeated for the same generation.
5. **Refinement validity:** a narrowed read selects only alternatives possible
   for that place and current relevant versions, including through joins and
   loop backedges.
6. **Initializer affinity:** forcing happens at most once per token, only while
   captures are valid; skipping performs no initializer effects.
7. **Elaboration fidelity:** elaboration preserves source effects, their order,
   destination guarantees, and required destruction timing.

An actual proof needs precise substitution and frame rules, well-formedness of
`H` and `O`, a complete account of region exits, verified function contracts,
and a defined admissible cleanup schedule. The schemas above do not fill those
gaps merely by naming the properties. Hook effects, heap primitives, and their
borrow-dependency contracts also need separate validation before extending any
theorem to full programs using them.

Native/interpreter parity tests are evidence about implementations. They are
not proofs of this model, and a proof of this model alone would not prove the
compiler or backend correct.

## 9. Compile-Time Extension

Extend the configuration with an execution phase and an evaluation-local heap.
Ordinary operation and ownership rules stay the same. Static specialization
arguments determine the resolved function instance; interpreted ordinary
arguments still occupy ordinary parameter slots during execution.

Two boundaries are distinct:

| Boundary | Rule |
| --- | --- |
| Within one evaluation | Fresh allocation identities may flow through calls, aggregates, references, and mutation |
| Publication to a canonical value | No reachable evaluation-local identity may escape |

Publication examines actual stored fields, initialized array elements, active
variant payloads, and backing owners of views. Inactive alternatives do not
introduce a retained allocation. Plain extracted data, type values, callable
identities, and symbolic permanent literal storage can be publishable.

Reached unavailable I/O or foreign operations are source diagnostics; an
unexecuted branch causes no such operation. Provider allocation refusal is an
ordinary optional result; compiler resource exhaustion is an infrastructure
failure, not simulated allocation refusal. Memoization must not share a fresh
evaluation-local allocation between independent calls.

This is an extension contract, not a complete calculus of dependent static
arguments, type computation, demand cycles, or canonical value identity. Future
allocation publication needs explicit serialization, relocation, mutability,
and ownership rules rather than relaxation of the existing boundary by accident.

## 10. Extension and Mechanization Plan

For each extension, first decide whether it changes execution, static reasoning,
or only elaboration/library definitions. State new syntax and rules, one
accepted example and one distinguishing rejection or changed behavior, and the
old invariants affected. Do not promise conservative extension without checking
old programs retain their behavior. If a foundation changes, revise the model
and explain the compatibility consequence rather than retaining obsolete rules.

### Mechanized Refinement Subset

[Refinement.lean](Refinement.lean) defines separate executable checking and
evaluation rules and proves `checker_sound`. If checking succeeds and the
initial runtime agrees with its analysis state, evaluation succeeds and the
final runtime agrees with an output analysis state. In particular, a checked
read cannot encounter a different variant tag from the one it requires. The
proof is checked by Lean's kernel without admitted proofs or custom axioms.

This subset models initialized, independent record-field slots, primitive
variant alternatives, alias binding and rebinding, type tests, saved and copied
Booleans, negation, writes, sequences, and branches. A place is a canonical
numeric path; declarations and resolved places are inputs, not inferred from
source text. A saved test captures the resolved place, not an alias name that
can later be rebound. Writing that place discards the affected implications
without changing saved Boolean values. This implements per-slot version
invalidation by forgetting implications rather than storing numeric versions.

The checker retains both branch states and checks continuations against every
state instead of merging away path distinctions. It is conservative: it also
checks branches made unreachable by literal Booleans. Field paths denote
independent leaf slots, not overlapping aggregate or inline-payload storage.
Ancestor replacement, dynamic indexing, composite Boolean operations, loops,
calls, ownership, cleanup, heap allocation, and staging remain outside this
theorem. Nor is the correspondence with Chimera elaboration proved.

The project uses Lean's bundled standard library only. Its `lean-toolchain`
pins Lean 4.24.0. With Lean installed through `elan`, run from the repository
root:

```sh
cd calculus
lake build
lake exe calculus-check
```

[Main.lean](Main.lean) checks 15 distinguishing examples over both integer and
absent initial alternatives and both values of an independent Boolean input.
Accepted examples must evaluate successfully for all four inputs; rejected
examples must also demonstrate a failing concrete evaluation. An additional
probe checks that a literal-unreachable read is rejected statically even though
all four concrete evaluations succeed. These examples complement the general
theorem; they do not prove compiler parity. Generated build files stay in the
local ignored `.lake/` directory.

### Source Correspondence

Handwritten counterparts live in the existing
[flow-typing suite](../tests/flow_typing_test.zig). New groups share the
`calculus correspondence` test prefix. Accepted cases run both native and
compile-time execution, exercise integer and absent inputs, and check results
that distinguish lost writes or stale Boolean values. Rejections check specific
diagnostic kinds rather than accepting arbitrary compilation failures.

The table names the distinguishing words of each source test group. Existing
cases are reused rather than duplicated.

| Lean example | Source coverage |
| --- | --- |
| Fresh test | Existing branches/short-circuit case and copied/negated group |
| Saved test | Existing saved-Boolean version case |
| Copied saved test | Existing saved-bool copies/joins case and copied/negated group |
| Negated saved test | Copied/negated group, including an annotated absent read |
| Sibling alias write | Copied/negated group |
| Alias rebinding | Original-place group, using a rebound `Ref` handle |
| Declared assignment type | Declared-writes/fresh-tests and post-write-source-reads groups |
| Fresh test after mutation | Declared-writes/fresh-tests group |
| Reassigned Boolean | Declared-writes/fresh-tests and post-write-source-reads groups |
| Alias chains | Copied/negated group |
| Stale saved Boolean | Existing saved-Boolean version case |
| Copied evidence after alias write | Alias-writes/joins rejection group |
| Invalidated join | Alias-writes/joins rejection group, with an independent Boolean condition |
| Unrefined read | Alias-writes/joins rejection group |
| Write outside declared variant | Declared-variant rejection group |

The model and compiler both establish fresh post-write facts. The
post-write-source-reads group accepts the exact declared-assignment and
Boolean-reassignment examples without an extra type test. It also checks that
an unchanged saved Boolean can coexist with a new fact about the written slot.
The assignment-narrowing groups cover fields, aliases, stored and ambiguously
selected handles, joined alternatives, and incremental source edits. A selected
handle gains a fact without narrowing every possible backing place. Replacing
a value with an uncertain variant still cannot reuse a stale Boolean proof.

The literal-unreachable probe agrees on both sides: an ordinary `if true` does
not exempt its other branch from static checking. Runtime reachability alone
does not justify a source read.

Run the source correspondence groups from the repository root:

```sh
zig build test --seed=0 -Doptimize=safe \
    -Dtest-source=tests/flow_typing_test.zig \
    -Dtest-filter='calculus correspondence' -j1 --summary all
```

These are reviewed example correspondences, not an automatic source translator,
an exhaustive differential test, or a proof of Chimera elaboration. The source
wrappers use functions and records to expose the modeled place operations; those
features are not thereby added to the Lean theorem.

### Next Formalization Steps

The next steps remain deliberately narrower than the language:

1. Extend the checked subset with composite Boolean implications and explicit
    parent/payload dependencies. Check its correspondence with source elaboration
    before extending the refinement theorem to those operations.
2. Add loops and explicit ownership generations, with residual field states and
   cleanup edges. Establish reference validity and ownership accounting for
   trivial/fieldwise capabilities before adding arbitrary hooks.
3. Add destination construction, call contracts, and affine initializer regions.
   Check immovable results, capture retention, partial construction, and ordinary
   exits before claiming their safety properties.
4. Add heap primitives and staging only after their effect and publication
   boundaries are explicit. Extend theorems only to the newly modeled subset.

Markdown remains the language-wide explanation; the Lean files describe only
their named subset. Keep assumed contracts and the correspondence with prose
explicit as the subset grows. Lean is an independent verification tool, not a
dependency of the compiler build or its routine Zig tests.

## 11. Evidence Map

| Contract | Existing evidence |
| --- | --- |
| Place authority, origins, and carrier dependencies | [Reference tests](../tests/reference_test.zig) |
| Saved proofs, mutation, alias selection, joins, and backedges | [Flow-typing tests](../tests/flow_typing_test.zig) |
| Transfer, ownership hooks, and destination/initializer behavior | [Language tests](../tests/language_test.zig) and [binding tests](../tests/binding_test.zig) |
| Evaluation-local storage and snapshots | [Interpreter tests](../tests/comptime_interpreter_test.zig) |
| Borrowed/owned alternatives and pattern projection | [Match tests](../tests/match_test.zig) and [tuple tests](../tests/tuple_test.zig) |
| Explicit results and evaluation order through conversion | [Converter tests](../tests/converter_test.zig) |
| Publication, typing, and stage boundaries | [Architecture](../docs/ARCHITECTURE.md) |
| Panic and CLI execution outcomes | [Compiler guide](../docs/COMPILER.md) and [panic tests](../tests/panic_test.zig) |

The source blocks in section 7 provide small discriminating examples, not
coverage of every rule. Keep compiler regression coverage in the existing
suites. See the [compiler guide](../docs/COMPILER.md#verify) for verification commands;
documentation-only edits do not require a full compiler test run.