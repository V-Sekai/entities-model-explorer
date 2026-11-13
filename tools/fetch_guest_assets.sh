#!/bin/sh
# Fetch every guest program the viewer calls and put them where the project reads them (res://):
#   usd.elf, motion.elf, headfit.elf, persona.elf, skintokens.elf.
# The viewer calls 61 guest functions; a checkout without these ELFs can call only 28 of them, and the missing ones
# are quiet: no .usd import, no Kimodo motion, no eye blinks, no persona. In detail:
#   usd.elf         the .usd, .usda, .usdc and .usdz reader: newest main artifact of V-Sekai-fire/interactor-usd-guest
#   motion.elf      the Kimodo motion generator: interactor-motion-guest
#   headfit.elf     the anime eye closes of a rigged VRM: interactor-headfit
#   persona.elf     the persona's plan for a goal: interactor-taskweft-persona
#   skintokens.elf  the rig guest: the newest artifact built from main of V-Sekai-fire/interactor-skintokens-guest
# They are build products, not source, so git ignores them (add them to .git/info/exclude). Needs gh and python3.
#   tools/fetch_guest_assets.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sk=$(gh api "repos/V-Sekai-fire/interactor-skintokens-guest/actions/artifacts?per_page=20" --jq '[.artifacts[]|select(.workflow_run.head_branch=="main" and .expired==false)]|sort_by(.created_at)|last|"\(.workflow_run.id) \(.name)"')
gh run download "${sk%% *}" -R V-Sekai-fire/interactor-skintokens-guest -n "${sk#* }" -D "$work/sk"
cp "$work/sk/skintokens.elf" "$here/skintokens.elf"
# The newest main artifact of a guest repo, copied here as <elf>.
fetch_elf() {
  repo=$1 elf=$2
  art=$(gh api "repos/V-Sekai-fire/$repo/actions/artifacts?per_page=30" --jq '[.artifacts[]|select(.workflow_run.head_branch=="main" and .expired==false and (.name|startswith("'"${elf%.elf}"'-elf")))]|sort_by(.created_at)|last|"\(.workflow_run.id) \(.name)"')
  [ -n "$art" ] && [ "$art" != "null" ] || { echo "no artifact for $elf in $repo"; return 1; }
  gh run download "${art%% *}" -R "V-Sekai-fire/$repo" -n "${art#* }" -D "$work/$elf.d"
  cp "$work/$elf.d/$elf" "$here/$elf"
  echo "$elf from $repo ${art#* }"
}
fetch_elf interactor-usd-guest usd.elf
fetch_elf interactor-motion-guest motion.elf
fetch_elf interactor-headfit headfit.elf
fetch_elf interactor-taskweft-persona persona.elf
