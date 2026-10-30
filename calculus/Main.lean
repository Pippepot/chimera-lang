import Refinement

open Chimera.Refinement

private def subject : Access := .direct [0, 0]
private def sibling : Access := .direct [0, 1]
private def probe : Boolean := .test subject .integer

private def block (commands : List Command) : Command :=
  commands.foldr .sequence .skip

private def declarations : Declarations := fun _ => [.integer, .none]

private structure Example where
  name : String
  command : Command
  accepted : Bool := true

private def examples : List Example := [
  { name := "fresh test"
    command := .branch probe (.read subject .integer) (.read subject .none) },
  { name := "saved test"
    command := block [.save 0 probe, .branch (.saved 0) (.read subject .integer) .skip] },
  { name := "copied saved test"
    command := block [.save 0 probe, .save 1 (.saved 0),
      .branch (.saved 1) (.read subject .integer) .skip] },
  { name := "negated saved test"
    command := block [.save 0 probe,
      .branch (.negated (.saved 0)) (.read subject .none) (.read subject .integer)] },
  { name := "write through sibling alias preserves evidence"
    command := block [.alias 0 subject, .alias 1 sibling, .save 0 (.test (.alias 0) .integer),
      .write (.alias 1) .none, .branch (.saved 0) (.read (.alias 0) .integer) .skip] },
  { name := "alias rebinding does not retarget captured evidence"
    command := block [.alias 0 subject, .save 0 (.test (.alias 0) .integer), .alias 0 sibling,
      .write (.alias 0) .none, .branch (.saved 0) (.read subject .integer) .skip] },
  { name := "assignment uses declared rather than narrowed type"
    command := .branch probe (block [.write subject .none, .read subject .none]) .skip },
  { name := "fresh test after mutation"
    command := block [.write subject .none,
      .branch probe (.read subject .integer) (.read subject .none)] },
  { name := "reassigned Boolean replaces its old evidence"
    command := block [.save 0 probe, .write subject .none, .save 0 (.literal false),
      .branch (.saved 0) .skip (.read subject .none)] },
  { name := "alias chains retain place identity"
    command := block [.alias 0 subject, .alias 1 (.alias 0),
      .branch (.test (.alias 1) .integer) (.read (.alias 1) .integer) (.read subject .none)] },
  { name := "stale saved Boolean after direct write"
    command := block [.save 0 probe, .write subject .none,
      .branch (.saved 0) (.read subject .integer) .skip]
    accepted := false },
  { name := "copied evidence invalidated by an alias write"
    command := block [.alias 0 subject, .save 0 probe, .save 1 (.saved 0),
      .write (.alias 0) .none, .branch (.saved 1) (.read subject .integer) .skip]
    accepted := false },
  { name := "join cannot resurrect evidence invalidated on one path"
    command := block [.alias 0 subject, .save 0 probe,
      .branch (.saved 1) (.write (.alias 0) .none) .skip,
      .branch (.saved 0) (.read subject .integer) .skip]
    accepted := false },
  { name := "unrefined read"
    command := .read subject .integer
    accepted := false },
  { name := "write outside the declared variant"
    command := .write subject (.boolean true)
    accepted := false }
]

private def initialRuntime (value : Value) (flag : Bool) : Runtime :=
  { heap := update (fun _ => .none) [0, 0] value
    booleans := fun _ => flag
    aliases := fun _ => [] }

def main : IO Unit := do
  let analysis := initialAnalysis declarations (fun _ => [])
  let inputs := [Value.integer 42, Value.none].flatMap fun value =>
    [false, true].map fun flag => initialRuntime value flag
  for sample in examples do
    let accepted := (check declarations sample.command analysis).isSome
    unless accepted == sample.accepted do
      throw (IO.userError s!"unexpected checker result: {sample.name}")
    let evaluations := inputs.map fun runtime => evaluate declarations sample.command runtime
    if sample.accepted then
      unless evaluations.all (fun result => result.isSome) do
        throw (IO.userError s!"accepted command failed evaluation: {sample.name}")
    else
      unless evaluations.any (fun result => result.isNone) do
        throw (IO.userError s!"rejection has no demonstrated counterexample: {sample.name}")
    IO.println s!"{sample.name}: {if accepted then "accepted" else "rejected"}"
  let unreachable : Command := .branch (.literal true) .skip (.read subject .integer)
  unless (check declarations unreachable analysis).isNone do
    throw (IO.userError "literal-unreachable read was not statically checked")
  for runtime in inputs do
    unless (evaluate declarations unreachable runtime).isSome do
      throw (IO.userError "literal-unreachable read was evaluated")
  IO.println "literal-unreachable read: rejected statically, safe dynamically"
  IO.println s!"{examples.length} examples and 1 unreachable-branch probe passed"