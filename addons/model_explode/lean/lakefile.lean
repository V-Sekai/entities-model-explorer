import Lake
open Lake DSL

package model_explode where

-- Pinned to the toolchain like the workspace's other Mathlib proofs (lean-deform-exact).
require mathlib from git
  "https://github.com/leanprover-community/mathlib4.git" @ "v4.30.0"

@[default_target]
lean_lib Explode where

lean_exe explode_check where
  root := `Main
