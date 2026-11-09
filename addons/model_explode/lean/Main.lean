/-
`explode_check <layout.txt>`: re-checks an exploded layout the viewer printed, in exact rationals.

Input lines (decimal numbers, as GDScript prints them with "%.17f"), pieces in placement order:
  gap <g>
  piece c0 c1 c2 h0 h1 h2 v0 v1 v2 t      box centre, half extents, direction, chosen move

Prints PASS only if both hold:
  1. the GDScript layout itself (each piece moved by its own t) has every two boxes at least `gap`
     apart on some axis, checked exactly (this is the property `layout_sound` proves for Lean's
     own placement);
  2. Lean's `layout` places the same pieces too; the largest difference between its moves and the
     GDScript's is printed.
Exit code 0 on PASS, 1 on FAIL.
-/
import Explode

open Explode

/-- Exact rational value of a decimal string such as `-12.50000000000000000`. -/
def parseDec (s : String) : Option ℚ := do
  let (neg, body) := if s.startsWith "-" then (true, (s.drop 1).toString) else (false, s)
  let parts := body.splitOn "."
  let ip ← (parts.headD "").toNat?
  let fs := if parts.length > 1 then parts[1]! else ""
  let fp ← if fs.isEmpty then some 0 else fs.toNat?
  let q : ℚ := ip + (fp : ℚ) / (10 ^ fs.length : ℚ)
  return if neg then -q else q

def toF (q : ℚ) : Float := Float.ofInt q.num / Float.ofNat q.den

def main (args : List String) : IO UInt32 := do
  let some path := args.head? | IO.eprintln "usage: explode_check <layout.txt>"; return 2
  let lines ← IO.FS.lines path
  let mut gap : ℚ := 0
  let mut ps : Array Piece := #[]
  let mut ts : Array ℚ := #[]
  for l in lines do
    let w := (l.splitOn " ").filter (· ≠ "")
    match w with
    | ["gap", g] => gap := (parseDec g).getD 0
    | "piece" :: xs =>
      let q := xs.filterMap parseDec
      if q.length != 10 then IO.eprintln s!"bad piece line: {l}"; return 1
      let a := q.toArray
      ps := ps.push ⟨fun k => a[k.val]!, fun k => a[3 + k.val]!, fun k => a[6 + k.val]!⟩
      ts := ts.push a[9]!
    | _ => pure ()
  let boxes := (ps.zip ts).toList.map fun (p, t) => moved p t
  let ok := decide (boxes.Pairwise (Separated gap))
  IO.println s!"pieces {ps.size} gap {toF gap}; gdscript layout pairwise separated: {ok}"
  match layout gap ps.toList with
  | none => IO.println "lean layout: none (some piece could not be placed)"; IO.println "RESULT: FAIL"; return 1
  | some out =>
    let leanT := (ps.zip out.toArray).map fun (p, b) =>
      -- recover t on an axis where the direction is not 0
      match (List.finRange 3).find? (fun k => p.v k ≠ 0) with
      | some k => (b.c k - p.c k) / p.v k
      | none => 0
    let diff := (leanT.zip ts).foldl (fun m (a, b) => max m (toF (|a - b|))) (0 : Float)
    IO.println s!"lean layout placed {out.length}; max |t_lean - t_gdscript| = {diff}"
    if ok then IO.println "RESULT: PASS"; return 0
    IO.println "RESULT: FAIL"; return 1
