import Parse.Lowering.Interval
import Parse.Lowering.Specialize
import Parse.Syntax
import Lean.Data

namespace Parse.Lowering.Translate

open Parse.Lowering.Interval
open Parse.Lowering.Specialize
open Parse.Syntax
open Lean

/-!
  Translate a specialized tree into a set of instructions that matches some input.
-/

-- Just to be able to hash prefixes
scoped instance : Hashable Char where
  hash x := x.val.toUInt64

/-- Check is the condition of an if -/
inductive Check where
  | char (char: Char)
  | range (range: Range)
  | interval (int: Interval)
  deriving Repr, Hashable, Inhabited

def Check.isChar : Check → Bool
  | .char _ => true
  | _ => false

def Check.getChar : Check → Option Char
  | .char chr => some chr
  | _ => none

inductive Consumer (inst: Type) where
  | is (matcher: String) (ok: inst) (err: inst)
  | char (char: Char) (ok: inst) (err: inst)
  | range (range: Range) (ok: inst) (err: inst)
  | map (map: Interval) (ok: inst) (err: inst)
  | chars (cases: Array (Char × inst)) (otherwise: inst)
  | mixed (cases: Array (Check × inst)) (otherwise: inst)
  | consume (num: Nat) (ok: inst)
  deriving Repr, Hashable

inductive Instruction : Bool → Type where
  | consumer (consumer: Consumer (Instruction false)) : Instruction true
  | select (code: MethodOrCall) (alts: Array (Nat × (Instruction false))) (otherwise: Instruction false) : Instruction α
  | next (chars: Nat) (next: Instruction α) : Instruction α
  | store (prop: Nat) (data: Option Nat) (next: Instruction α) : Instruction α
  | capture (prop: Nat) (next: Instruction α) : Instruction α
  | close (prop: Nat) (next: Instruction α) : Instruction α
  | call (code: Call) (next: Instruction α) : Instruction α
  | goto (to: Nat) : Instruction α
  | error (code: Nat) : Instruction α
  deriving Repr, Hashable

structure Inst where
  isCheck : Bool
  instruction : Instruction isCheck
  deriving Repr

instance : Inhabited Inst where
  default := ⟨false, .error 0⟩

instance : Inhabited (Instruction α) where
  default := Instruction.error 0

structure Machine where
  storage: Storage
  names: Array (Option String)
  nodes: Array Inst
  mapper: HashMap String Nat
  deriving Inhabited

def Machine.addNode (machine: Machine) (name: Option String := none) : (Nat × Machine) :=
  let size := machine.names.size
  (size, { machine with names := machine.names.push name
                      , nodes := machine.nodes.push (Inst.mk false (.error 0))
                      , mapper := if let some name := name
                                    then machine.mapper.insert name size
                                    else machine.mapper })

def Machine.setNode (machine: Machine) (idx: Nat) (inst: Inst) : Machine :=
  { machine with nodes := machine.nodes.set! idx inst }

-- Compilation Monad

abbrev CompileM := StateM Machine

def CompileM.addNode (name: Option String := none) : CompileM Nat :=
  StateT.modifyGet (Machine.addNode · name)

def CompileM.setNode (idx: Nat) (code: Inst) : CompileM Unit :=
  StateT.modifyGet (λmachine => ((), machine.setNode idx code))

def CompileM.run (monad: CompileM α) : Machine :=
  StateT.run monad Inhabited.default
  |> Id.run
  |> Prod.snd

-- Compile

def compileAction' (data: Option Nat) : Syntax.Action → Instruction α
  | .store Capture.data prop to => Instruction.store prop data (compileAction' none to)
  | .store Capture.begin prop to => Instruction.capture prop (compileAction' none to)
  | .store Capture.close prop to => Instruction.close prop (compileAction' none to)
  | .call prop to => Instruction.call prop (compileAction' none to)
  | .goto to => Instruction.goto to
  | .error code => Instruction.error code

def gotoNext (jump: Nat) (to: Instruction α) : Instruction α :=
  if jump != 0 then (Instruction.next jump to) else to

-- The capture begin always start before the next instruction
def compileAction (jump: Nat) (capture: Bool) (data: Option Nat) (action: Syntax.Action) : Instruction α :=
  let jump := if capture then Nat.max 1 jump else jump
  match action with
  | .call prop to => Instruction.call prop (gotoNext jump (compileAction' none to))
  | .store Capture.data prop to => Instruction.store prop data (gotoNext jump ((compileAction' none to)))
  | action =>
    let inst := compileAction' data action
    if jump != 0 then Instruction.next jump inst else inst

def compileStep (jump: Nat) (step: Step Specialize.Action) : Instruction α :=
  match step.next with
  | .single action => compileAction jump step.capture step.data action
  | .select call actions otherwise =>
    let otherwise := compileAction jump step.capture step.data otherwise
    let actions := actions.map (λ(alt, action) => (alt, compileAction jump step.capture step.data action))
    Instruction.select call actions otherwise

def groupActions (alts: Array (Char × UInt64 × Instruction false)) : Array (Check × Instruction false) :=
  let alts := alts.groupByKey (·.snd.fst)
  alts.toArray.map $ λ(_, val) =>
    let scrutinee := val.map Prod.fst
    let action := (val.get! 0).snd.snd
    let check :=
      if scrutinee.size == 1 then
        Check.char (scrutinee.get! 0)
      else
        let int := (Interval.ofChars scrutinee)
        if int.size != 1
          then Check.interval int
          else Check.range (int.get! 0)
    (check, action)

def actionsToConsumer (alts: Array (Check × Instruction false)) (otherwise: Instruction false) : Consumer (Instruction false) :=
  if alts.size == 1 then
    let (check, action) := alts.get! 0
    match check with
    | .char chr => Consumer.char chr action otherwise
    | .range range => Consumer.range range action otherwise
    | .interval int => Consumer.map int action otherwise
  else
    if alts.all (Check.isChar ∘ Prod.fst) then
      let chars := alts.filterMap (λ(check, inst) => (·, inst) <$> check.getChar)
      Consumer.chars chars otherwise
    else
      Consumer.mixed alts otherwise

partial def compileTree (jump: Nat) (b: Bool) : Tree Specialize.Action → CompileM (Instruction b)
  | .fail => return Instruction.error 0
  | .done step => return compileStep jump step
  | .consume prop step => do
    let code := compileStep jump step
    let place ← CompileM.addNode
    CompileM.setNode place (Inst.mk true (Instruction.consumer (Consumer.consume prop code)))
    pure (gotoNext jump (Instruction.goto place))
  | .branch branches default => do
    let otherwise ← compileTree 0 false default
    let result ←
      match branches with
      | .string branch =>
        let jump := if branch.capture then branch.subject.length else 0
        let next ← compileTree jump false branch.next
        pure (Consumer.is branch.subject next otherwise)
      | .chars matchers => do
        let alts ← matchers.mapM $ λbranch => do
          let next ← compileTree (if branch.capture then 1 else 0) false branch.next
          pure (branch.subject, Hashable.hash next, next)
        let alts := groupActions alts
        pure $ actionsToConsumer alts otherwise
    let result := Instruction.consumer result

    match b with
    | true =>
      pure (gotoNext jump result)
    | false => do
      let place ← CompileM.addNode
      CompileM.setNode place (Inst.mk true result)
      pure (gotoNext jump (Instruction.goto place))

def compile' (grammar: Grammar) : CompileM Unit := do
  StateT.modifyGet (((), ·) ∘ (λx => {x with storage := grammar.storage }))

  for node in grammar.nodes do
    let _ ← CompileM.addNode (name := some node.name)

  for (idx, node) in grammar.nodes.mapIdx ((·, ·)) do
    let tree := Problem.solve (Problem.ofCases node.cases)
    let inst ← compileTree 0 true tree
    CompileM.setNode idx (Inst.mk true inst)

/-- Translates a Grammar into a Machine -/
def translate (grammar: Grammar) : Machine :=
  CompileM.run (compile' grammar)
