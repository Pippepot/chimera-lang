import Std

namespace Chimera.Refinement

inductive Tag where
  | integer
  | boolean
  | unit
  | none
  deriving DecidableEq, Repr

inductive Value where
  | integer (value : Int)
  | boolean (value : Bool)
  | unit
  | none
  deriving DecidableEq, Repr

def Value.tag : Value -> Tag
  | .integer _ => .integer
  | .boolean _ => .boolean
  | .unit => .unit
  | .none => .none

abbrev Place := List Nat
abbrev Declarations := Place -> List Tag
abbrev Aliases := Nat -> Place

def update {Key Item : Type} [DecidableEq Key]
    (items : Key -> Item) (key : Key) (value : Item) : Key -> Item :=
  fun selected => if selected = key then value else items selected

inductive Access where
  | direct (place : Place)
  | alias (name : Nat)
  deriving Repr

def resolve (aliases : Aliases) : Access -> Place
  | .direct place => place
  | .alias name => aliases name

inductive Boolean where
  | literal (value : Bool)
  | test (target : Access) (tag : Tag)
  | saved (name : Nat)
  | negated (operand : Boolean)
  deriving Repr

inductive Guard where
  | unknown
  | literal (value : Bool)
  | test (place : Place) (tag : Tag)
  | negated (operand : Guard)

def Guard.Holds (heap : Place -> Value) : Guard -> Bool -> Prop
  | .unknown, _ => True
  | .literal expected, actual => actual = expected
  | .test place tag, actual => actual = decide ((heap place).tag = tag)
  | .negated operand, actual => operand.Holds heap (!actual)

def Guard.forget (written : Place) : Guard -> Guard
  | .unknown => .unknown
  | .literal value => .literal value
  | .test place tag => if place = written then .unknown else .test place tag
  | .negated operand => .negated (operand.forget written)

structure Runtime where
  heap : Place -> Value
  booleans : Nat -> Bool
  aliases : Aliases

structure Analysis where
  possible : Place -> List Tag
  booleans : Nat -> Guard
  aliases : Aliases

structure Compatible (analysis : Analysis) (runtime : Runtime) : Prop where
  values : forall place, List.Mem (runtime.heap place).tag (analysis.possible place)
  booleans : forall name, (analysis.booleans name).Holds runtime.heap (runtime.booleans name)
  aliases : analysis.aliases = runtime.aliases

def evaluateBoolean (runtime : Runtime) : Boolean -> Bool
  | .literal value => value
  | .test target tag => decide ((runtime.heap (resolve runtime.aliases target)).tag = tag)
  | .saved name => runtime.booleans name
  | .negated operand => !(evaluateBoolean runtime operand)

def analyzeBoolean (analysis : Analysis) : Boolean -> Guard
  | .literal value => .literal value
  | .test target tag => .test (resolve analysis.aliases target) tag
  | .saved name => analysis.booleans name
  | .negated operand => .negated (analyzeBoolean analysis operand)

def permits (possible : List Tag) (expected : Tag) : Bool :=
  possible.all fun actual => decide (actual = expected)

theorem boolean_valid (compatible : Compatible analysis runtime) (expression : Boolean) :
    (analyzeBoolean analysis expression).Holds runtime.heap (evaluateBoolean runtime expression) := by
  induction expression with
  | literal value => rfl
  | test target tag => simp [analyzeBoolean, evaluateBoolean, Guard.Holds, compatible.aliases]
  | saved name => exact compatible.booleans name
  | negated operand induction =>
    simpa [analyzeBoolean, evaluateBoolean, Guard.Holds] using induction

theorem read_valid (compatible : Compatible analysis runtime)
    (accepted : permits (analysis.possible (resolve analysis.aliases target)) expected = true) :
    (runtime.heap (resolve runtime.aliases target)).tag = expected := by
  have member := compatible.values (resolve analysis.aliases target)
  have all := List.all_eq_true.mp accepted _ member
  simpa [compatible.aliases] using all

def assume (analysis : Analysis) : Guard -> Bool -> Analysis
  | .unknown, _ => analysis
  | .literal _, _ => analysis
  | .test place tag, truth =>
    let remaining := (analysis.possible place).filter fun actual => decide (actual = tag) == truth
    { analysis with possible := update analysis.possible place remaining }
  | .negated operand, truth => assume analysis operand (!truth)

def writeAnalysis (analysis : Analysis) (target : Access) (value : Value) : Analysis :=
  let place := resolve analysis.aliases target
  { analysis with
    possible := update analysis.possible place [value.tag]
    booleans := fun name => (analysis.booleans name).forget place }

def writeRuntime (runtime : Runtime) (target : Access) (value : Value) : Runtime :=
  { runtime with heap := update runtime.heap (resolve runtime.aliases target) value }

def saveAnalysis (analysis : Analysis) (name : Nat) (expression : Boolean) : Analysis :=
  { analysis with booleans := update analysis.booleans name (analyzeBoolean analysis expression) }

def saveRuntime (runtime : Runtime) (name : Nat) (expression : Boolean) : Runtime :=
  { runtime with booleans := update runtime.booleans name (evaluateBoolean runtime expression) }

def aliasAnalysis (analysis : Analysis) (name : Nat) (target : Access) : Analysis :=
  { analysis with aliases := update analysis.aliases name (resolve analysis.aliases target) }

def aliasRuntime (runtime : Runtime) (name : Nat) (target : Access) : Runtime :=
  { runtime with aliases := update runtime.aliases name (resolve runtime.aliases target) }

theorem forget_valid {guard : Guard} {heap : Place -> Value} {truth : Bool}
  {written : Place} {value : Value} (held : guard.Holds heap truth) :
    (guard.forget written).Holds (update heap written value) truth := by
  induction guard generalizing truth with
  | unknown => trivial
  | literal expected => exact held
  | test place tag =>
    by_cases same : place = written
    · simp [Guard.forget, same, Guard.Holds]
    · simpa [Guard.forget, same, Guard.Holds, update] using held
  | negated operand induction => exact induction held

theorem assume_valid {guard : Guard} (compatible : Compatible analysis runtime)
    (held : guard.Holds runtime.heap truth) :
    Compatible (assume analysis guard truth) runtime := by
  induction guard generalizing truth with
  | unknown => exact compatible
  | literal expected => exact compatible
  | negated operand induction => exact induction held
  | test place tag =>
    constructor
    · intro selected
      by_cases same : selected = place
      · subst selected
        simp only [assume, update]
        apply List.mem_filter.mpr
        constructor
        · exact compatible.values place
        · simpa [Guard.Holds] using held.symm
      · simpa [assume, update, same] using compatible.values selected
    · exact compatible.booleans
    · exact compatible.aliases

theorem write_valid (compatible : Compatible analysis runtime) :
    Compatible (writeAnalysis analysis target value) (writeRuntime runtime target value) := by
  constructor
  · intro selected
    by_cases same : selected = resolve runtime.aliases target
    · simpa [writeAnalysis, writeRuntime, update, compatible.aliases, same]
      using (List.Mem.head [] : List.Mem value.tag [value.tag])
    · simpa [writeAnalysis, writeRuntime, update, compatible.aliases, same]
        using compatible.values selected
  · intro name
    simpa [writeAnalysis, writeRuntime, compatible.aliases]
      using forget_valid (written := resolve runtime.aliases target) (value := value)
        (compatible.booleans name)
  · exact compatible.aliases

theorem save_valid (compatible : Compatible analysis runtime) :
    Compatible (saveAnalysis analysis name expression) (saveRuntime runtime name expression) := by
  constructor
  · exact compatible.values
  · intro selected
    by_cases same : selected = name
    · simpa [saveAnalysis, saveRuntime, update, same]
        using boolean_valid compatible expression
    · simpa [saveAnalysis, saveRuntime, update, same] using compatible.booleans selected
  · exact compatible.aliases

theorem alias_valid (compatible : Compatible analysis runtime) :
    Compatible (aliasAnalysis analysis name target) (aliasRuntime runtime name target) := by
  constructor
  · exact compatible.values
  · exact compatible.booleans
  · simp [aliasAnalysis, aliasRuntime, compatible.aliases]

inductive Command where
  | skip
  | read (target : Access) (expected : Tag)
  | write (target : Access) (value : Value)
  | save (name : Nat) (expression : Boolean)
  | alias (name : Nat) (target : Access)
  | sequence (first second : Command)
  | branch (condition : Boolean) (whenTrue whenFalse : Command)
  deriving Repr

def checkEach (visit : Analysis -> Option (List Analysis)) : List Analysis -> Option (List Analysis)
  | [] => some []
  | first :: rest => do
    let before <- visit first
    let after <- checkEach visit rest
    pure (before ++ after)

def check (declarations : Declarations) : Command -> Analysis -> Option (List Analysis)
  | .skip, analysis => some [analysis]
  | .read target expected, analysis =>
    if permits (analysis.possible (resolve analysis.aliases target)) expected
    then some [analysis] else none
  | .write target value, analysis =>
    if (declarations (resolve analysis.aliases target)).any (fun tag => decide (tag = value.tag))
    then some [writeAnalysis analysis target value] else none
  | .save name expression, analysis => some [saveAnalysis analysis name expression]
  | .alias name target, analysis => some [aliasAnalysis analysis name target]
  | .sequence first second, analysis => do
    let states <- check declarations first analysis
    checkEach (check declarations second) states
  | .branch condition whenTrue whenFalse, analysis => do
    let guard := analyzeBoolean analysis condition
    let left <- check declarations whenTrue (assume analysis guard true)
    let right <- check declarations whenFalse (assume analysis guard false)
    pure (left ++ right)

def evaluate (declarations : Declarations) : Command -> Runtime -> Option Runtime
  | .skip, runtime => some runtime
  | .read target expected, runtime =>
    if (runtime.heap (resolve runtime.aliases target)).tag = expected
    then some runtime else none
  | .write target value, runtime =>
    if (declarations (resolve runtime.aliases target)).any (fun tag => decide (tag = value.tag))
    then some (writeRuntime runtime target value) else none
  | .save name expression, runtime => some (saveRuntime runtime name expression)
  | .alias name target, runtime => some (aliasRuntime runtime name target)
  | .sequence first second, runtime => do
    let next <- evaluate declarations first runtime
    evaluate declarations second next
  | .branch condition whenTrue whenFalse, runtime =>
    if evaluateBoolean runtime condition
    then evaluate declarations whenTrue runtime
    else evaluate declarations whenFalse runtime

theorem checkEach_member (checked : checkEach visit inputs = some outputs)
    (member : state ∈ inputs) :
    ∃ results, visit state = some results ∧ ∀ result ∈ results, result ∈ outputs := by
  induction inputs generalizing outputs with
  | nil => cases member
  | cons first rest induction =>
    cases initial : visit first with
    | none => simp [checkEach, initial] at checked
    | some before =>
      cases following : checkEach visit rest with
      | none => simp [checkEach, initial, following] at checked
      | some after =>
        have joined : before ++ after = outputs := by
          simpa [checkEach, initial, following] using checked
        rw [← joined]
        rcases List.mem_cons.mp member with same | remaining
        · subst state
          exact ⟨before, initial, fun _ accepted => List.mem_append.mpr (.inl accepted)⟩
        · obtain ⟨results, accepted, included⟩ := induction following remaining
          exact ⟨results, accepted, fun _ accepted => List.mem_append.mpr (.inr (included _ accepted))⟩

theorem checker_sound (checked : check declarations command analysis = some outputs)
    (compatible : Compatible analysis runtime) :
    ∃ final state, evaluate declarations command runtime = some final ∧
      state ∈ outputs ∧ Compatible state final := by
  induction command generalizing analysis runtime outputs with
  | skip =>
    simp only [check, Option.some.injEq] at checked
    subst outputs
    exact ⟨runtime, analysis, rfl, by simp, compatible⟩
  | read target expected =>
    simp only [check] at checked
    split at checked
    next accepted =>
      simp only [Option.some.injEq] at checked
      subst outputs
      exact ⟨runtime, analysis, by simp [evaluate, read_valid compatible accepted], by simp, compatible⟩
    next => cases checked
  | write target value =>
    simp only [check] at checked
    split at checked
    next accepted =>
      simp only [Option.some.injEq] at checked
      subst outputs
      exact ⟨writeRuntime runtime target value, writeAnalysis analysis target value,
        by simp [evaluate, ← compatible.aliases, accepted], by simp, write_valid compatible⟩
    next => cases checked
  | save name expression =>
    simp only [check, Option.some.injEq] at checked
    subst outputs
    exact ⟨saveRuntime runtime name expression, saveAnalysis analysis name expression,
      rfl, by simp, save_valid compatible⟩
  | alias name target =>
    simp only [check, Option.some.injEq] at checked
    subst outputs
    exact ⟨aliasRuntime runtime name target, aliasAnalysis analysis name target,
      rfl, by simp, alias_valid compatible⟩
  | sequence first second first_induction second_induction =>
    cases first_checked : check declarations first analysis with
    | none => simp [check, first_checked] at checked
    | some states =>
      have following : checkEach (check declarations second) states = some outputs := by
        simpa [check, first_checked] using checked
      obtain ⟨middle, selected, first_evaluated, member, agrees⟩ := first_induction first_checked compatible
      obtain ⟨results, second_checked, included⟩ := checkEach_member following member
      obtain ⟨final, state, second_evaluated, member, agrees⟩ := second_induction second_checked agrees
      exact ⟨final, state, by simp [evaluate, first_evaluated, second_evaluated], included _ member, agrees⟩
  | branch condition whenTrue whenFalse true_induction false_induction =>
    cases left_checked : check declarations whenTrue (assume analysis (analyzeBoolean analysis condition) true) with
    | none => simp [check, left_checked] at checked
    | some left =>
      cases right_checked : check declarations whenFalse (assume analysis (analyzeBoolean analysis condition) false) with
      | none => simp [check, left_checked, right_checked] at checked
      | some right =>
        have joined : left ++ right = outputs := by
          simpa [check, left_checked, right_checked] using checked
        subst outputs
        cases choice : evaluateBoolean runtime condition with
        | false =>
          have held : (analyzeBoolean analysis condition).Holds runtime.heap false := by
            simpa [choice] using boolean_valid compatible condition
          obtain ⟨final, state, evaluated, member, agrees⟩ :=
            false_induction right_checked (assume_valid compatible held)
          exact ⟨final, state, by simp [evaluate, choice, evaluated], List.mem_append.mpr (.inr member), agrees⟩
        | true =>
          have held : (analyzeBoolean analysis condition).Holds runtime.heap true := by
            simpa [choice] using boolean_valid compatible condition
          obtain ⟨final, state, evaluated, member, agrees⟩ :=
            true_induction left_checked (assume_valid compatible held)
          exact ⟨final, state, by simp [evaluate, choice, evaluated], List.mem_append.mpr (.inl member), agrees⟩

def initialAnalysis (declarations : Declarations) (aliases : Aliases) : Analysis :=
  { possible := declarations, booleans := fun _ => .unknown, aliases }

theorem initial_valid (declared : forall place, List.Mem (runtime.heap place).tag (declarations place)) :
    Compatible (initialAnalysis declarations runtime.aliases) runtime := by
  exact ⟨declared, fun _ => True.intro, rfl⟩

end Chimera.Refinement