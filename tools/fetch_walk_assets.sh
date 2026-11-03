#!/bin/sh
# Fetch what walk mode (M, WASD) and the obstacle course (O, Shift+G) need and put it where the project reads it:
#   mm.elf          the motion-matching controller: the newest green main run of V-Sekai-fire/interactor-motion-matching-guest
#   mujoco.elf      the course's colliders: project/plans/mujoco.double.elf of V-Sekai-fire/interactor-mujoco-sandbox-demo
#   motion/mm/      the clips: data/kimodo-locomotion and data/o3de-motionmatching of the motion-matching repo, laid out
#                   as tools/package_desktop.sh and guest/build.py do (<clip>.f32, clips.tsv, skeleton.txt, parents.txt)
# They are build products, not source, so git ignores them (add them to .git/info/exclude). Needs gh and python3.
#   tools/fetch_walk_assets.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
run=$(gh run list -R V-Sekai-fire/interactor-motion-matching-guest --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId')
gh run download "$run" -R V-Sekai-fire/interactor-motion-matching-guest -D "$work/mm"
cp "$work"/mm/mm-elf-*/mm.elf "$here/mm.elf"
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
