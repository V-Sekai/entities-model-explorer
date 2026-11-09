/-
Explode layout: proof that exploded pieces never intersect.

Each piece is an axis-aligned box (centre `c`, half extents `h`) in world space with a direction
`v` (out from the model centre). Pieces are placed one at
a time in an order the viewer picks (nearest the centre first); each moves along
its own direction by the smallest candidate amount `t ≥ 0` at which its box is at
least `gap` away, on some axis, from every box placed before it. Placed boxes never move again. The proof holds for any pieces, directions and order.

`layout_sound` proves that every two boxes of a layout are separated (`Separated`), and
`separated_disjoint` that separated boxes share no point; each mesh lies inside its box, so no two
meshes of the exploded view intersect.

The viewer's GDScript (`addons/model_explode/explode.gd`) runs the same placement in floating
point; `lake exe explode_check` re-checks a layout it printed, in exact rationals.
-/
import Mathlib

namespace Explode

/-- A piece before placement: box centre, half extents, direction. -/
structure Piece where
  c : Fin 3 → ℚ
  h : Fin 3 → ℚ
  v : Fin 3 → ℚ

/-- A placed box. -/
structure Box where
  c : Fin 3 → ℚ
  h : Fin 3 → ℚ

def moved (p : Piece) (t : ℚ) : Box := ⟨fun k => p.c k + t * p.v k, p.h⟩

/-- At least `gap` apart on some axis. -/
def Separated (gap : ℚ) (a b : Box) : Prop := ∃ k, a.h k + b.h k + gap ≤ |a.c k - b.c k|

instance (gap : ℚ) (a b : Box) : Decidable (Separated gap a b) := by
  unfold Separated; infer_instance

/-- `p` moved by `t` is separated from every box already placed. -/
def freeAt (gap : ℚ) (placed : List Box) (p : Piece) (t : ℚ) : Bool :=
  placed.all fun q => decide (Separated gap q (moved p t))

/-- Upper end of the open interval of `t` where `|d + t * w| < H` (none when `w = 0`). -/
def axisUpper (d w H : ℚ) : Option ℚ :=
  if w = 0 then none else some (max ((H - d) / w) ((-H - d) / w))

/-- Where a free spot can start: `0`, or the end of some axis interval against a placed box.
Only used to propose `t`; soundness rests on `freeAt` alone. -/
def candidates (gap : ℚ) (placed : List Box) (p : Piece) : List ℚ :=
  (0 :: placed.flatMap fun q =>
    (List.finRange 3).filterMap fun k => axisUpper (p.c k - q.c k) (p.v k) (q.h k + p.h k + gap)
  ).filter (0 ≤ ·)

/-- The smallest candidate at which `p` is free. -/
def place (gap : ℚ) (placed : List Box) (p : Piece) : Option ℚ :=
  ((candidates gap placed p).mergeSort (· ≤ ·)).find? (freeAt gap placed p)

def layoutFrom (gap : ℚ) : List Box → List Piece → Option (List Box)
  | acc, [] => some acc
  | acc, p :: ps =>
    match place gap acc p with
    | some t => layoutFrom gap (acc ++ [moved p t]) ps
    | none => none

/-- Place `ps` in order (the caller picks the order). -/
def layout (gap : ℚ) (ps : List Piece) : Option (List Box) := layoutFrom gap [] ps

lemma place_free {gap : ℚ} {placed : List Box} {p : Piece} {t : ℚ}
    (h : place gap placed p = some t) : ∀ q ∈ placed, Separated gap q (moved p t) := by
  have hf : freeAt gap placed p t = true := List.find?_some h
  unfold freeAt at hf
  intro q hq
  have := List.all_eq_true.mp hf q hq
  simpa using this

lemma layoutFrom_sound {gap : ℚ} :
    ∀ {acc : List Box} {ps : List Piece} {out : List Box},
      acc.Pairwise (Separated gap) → layoutFrom gap acc ps = some out →
      out.Pairwise (Separated gap)
  | acc, [], out, hacc, h => by
    simp only [layoutFrom, Option.some.injEq] at h; subst h; exact hacc
  | acc, p :: ps, out, hacc, h => by
    unfold layoutFrom at h
    split at h
    · rename_i t ht
      refine layoutFrom_sound ?_ h
      rw [List.pairwise_append]
      refine ⟨hacc, List.pairwise_singleton _ _, ?_⟩
      intro a ha b hb
      rw [List.mem_singleton] at hb
      subst hb
      exact place_free ht a ha
    · exact absurd h (by simp)

/-- The guarantee: every two boxes of a layout are separated. -/
theorem layout_sound {gap : ℚ} {ps : List Piece} {out : List Box}
    (h : layout gap ps = some out) : out.Pairwise (Separated gap) :=
  layoutFrom_sound List.Pairwise.nil h

/-! ## Separated boxes share no point -/

def InBox (b : Box) (x : Fin 3 → ℚ) : Prop := ∀ k, |x k - b.c k| ≤ b.h k

theorem separated_disjoint {gap : ℚ} {a b : Box} (hg : 0 < gap)
    (h : Separated gap a b) : ¬ ∃ x, InBox a x ∧ InBox b x := by
  rintro ⟨x, ha, hb⟩
  obtain ⟨k, hk⟩ := h
  have t1 := ha k
  have t2 := hb k
  have tri : |a.c k - b.c k| ≤ |x k - a.c k| + |x k - b.c k| := by
    have := abs_sub_le (a.c k) (x k) (b.c k)
    rwa [abs_sub_comm (a.c k) (x k)] at this
  linarith

/-! ## Checks run by the build -/

def unit (x : ℚ) : Fin 3 → ℚ := fun _ => x
def axis0 (x : ℚ) : Fin 3 → ℚ := fun k => if k = 0 then x else 0

/-- Two unit boxes at the same centre, the second moving along +x: it stops 2 + gap away. -/
example : (layout (1 / 10) [⟨unit 0, unit 1, axis0 1⟩, ⟨unit 0, unit 1, axis0 1⟩]).map
    (·.map (·.c 0)) = some [0, 21 / 10] := by
  native_decide

/-- The control: a piece that cannot move (direction 0) inside another box is refused. -/
example : (layout (1 / 10) [⟨unit 0, unit 1, unit 0⟩, ⟨unit 0, unit 1, unit 0⟩]).isNone := by
  native_decide

end Explode
