#!/bin/sh
# Fetch every guest program the viewer calls, and the walk data, and put them where the project reads them (res://):
#   usd.elf, motion.elf, headfit.elf, persona.elf, skintokens.elf, mm.elf, mujoco.elf; motion/mm/ (the 72 clips).
# The viewer calls 61 guest functions; a checkout without these ELFs can call only 28 of them, and the missing ones
# are quiet: no .usd import, no Kimodo motion, no eye blinks, no persona. In detail:
#   mm.elf          the motion-matching controller: the newest green main run of V-Sekai-fire/interactor-motion-matching-guest
#   usd.elf         the .usd, .usda, .usdc and .usdz reader: newest main artifact of V-Sekai-fire/interactor-usd-guest
#   motion.elf      the Kimodo motion generator: interactor-motion-guest
#   headfit.elf     the anime eye closes of a rigged VRM: interactor-headfit
#   persona.elf     the persona's plan for a goal: interactor-taskweft-persona
#   skintokens.elf  the rig guest: the newest artifact built from main of V-Sekai-fire/interactor-skintokens-guest. An older one lacks
#                   skintokens_motions_begin, so walk mode puts the 72 clips on the rig one job at a time (minutes, not seconds)
#   mujoco.elf      the course's colliders: project/plans/mujoco.double.elf of V-Sekai-fire/interactor-mujoco-sandbox-demo
#   motion/mm/      the clips: data/kimodo-locomotion and data/o3de-motionmatching of the motion-matching repo, laid out
#                   as tools/package_desktop.sh and guest/build.py do (<clip>.f32, clips.tsv, skeleton.txt, parents.txt)
# They are build products, not source, so git ignores them (add them to .git/info/exclude). Needs gh and python3.
#   tools/fetch_guest_assets.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
run=$(gh api "repos/V-Sekai-fire/interactor-motion-matching-guest/actions/artifacts?per_page=20" --jq '[.artifacts[]|select(.workflow_run.head_branch=="main" and .expired==false)][0].workflow_run.id')
gh run download "$run" -R V-Sekai-fire/interactor-motion-matching-guest -D "$work/mm"
cp "$work"/mm/mm-elf-*/mm.elf "$here/mm.elf"
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
gh api repos/V-Sekai-fire/interactor-mujoco-sandbox-demo/contents/project/plans/mujoco.double.elf -H "Accept: application/vnd.github.raw" > "$here/mujoco.elf"
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/V-Sekai-fire/interactor-motion-matching-guest.git "$work/repo"
git -C "$work/repo" sparse-checkout set data
python3 - "$work/repo" "$here/motion/mm" <<'P'
import pathlib, shutil, sys
repo, mm = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
mm.mkdir(parents=True, exist_ok=True)
keys, first = [], None
for d in ("data/kimodo-locomotion", "data/o3de-motionmatching"):
    for c in sorted(p for p in (repo / d).iterdir() if p.is_dir()):
        if not (c / "transforms.f32").exists():
            continue
        shutil.copy(c / "transforms.f32", mm / (c.name + ".f32"))
        if (c / "phase.f32").exists():
            shutil.copy(c / "phase.f32", mm / (c.name + ".phase.f32"))
        keys.append(c.name + ("\tloop" if (c / "loop.txt").exists() else ""))
        first = first or c
(mm / "clips.tsv").write_text("".join(k + "\n" for k in keys))
(mm / "skeleton.txt").write_text("".join((first / "skeleton.txt").read_text().splitlines(True)[3:]))
shutil.copy(first / "parents.txt", mm / "parents.txt")
print("clips", len(keys))
P
