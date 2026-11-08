#!/usr/bin/env bash
# Reproduce the Linux leg of .github/workflows/release.yml locally (WSL or any Linux box), so a
# packaging mistake is caught in under a minute instead of a 5+ minute CI round trip.
# Needs: gh (authenticated: GH_TOKEN or `gh auth login`), git, elixir, curl, unzip, tar, zip, perl.
#   pixi run build                 full fetch + pck export + package + FDB round-trip test
#   pixi run build --skip-fetch    reuse an already-populated $CACHE (faster re-runs while
#                                   iterating on package_desktop.exs/export_presets.cfg only)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
CACHE="${LOCAL_BUILD_CACHE:-$here/.local-build-cache}"
ENGINE="$CACHE/engine"
NOTICES="$CACHE/notices"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ENGINE_TAG="${ENGINE_TAG:-v0.0.0-20261106225526-d632cdf2be4c}"
FDB_RELEASE="${FDB_RELEASE:-7.3.79-weftspun-dev.2}"
APP=walk-mode-viewer

skip_fetch=0
[ "${1:-}" = "--skip-fetch" ] && skip_fetch=1

if [ "$skip_fetch" = 0 ] || [ ! -f "$ENGINE/godot.linuxbsd.editor.double.x86_64" ]; then
  echo "== fetching the double-precision engine ($ENGINE_TAG)"
  mkdir -p "$ENGINE"
  cd "$ENGINE"
  # package_desktop.exs's "package" step lays out macOS, Windows AND Linux unconditionally, even
  # when only the Linux leg is run here, so all three templates are needed. Windows and Linux are
  # the real --export-release embed_pck templates (patch_embed_templates/1 in package_desktop.exs
  # points custom_template/release at them); macOS keeps the sibling-pck fallback.
  for f in godot.linuxbsd.editor.double.x86_64 \
           godot.linuxbsd.template_release.double.x86_64 \
           godot.macos.template_release.double.arm64 \
           godot.windows.template_release.double.x86_64.llvm.exe \
           libfdb_c.so libfdb_c.dylib fdb_c.dll \
           fdbserver.linux.x86_64 fdbserver.macos.arm64 fdbserver.windows.x86_64.exe \
           SHA256SUMS; do
    gh release download "$ENGINE_TAG" -R V-Sekai-fire/entities-zone -p "$f" --clobber
  done
  chmod +x godot.* fdbserver.*
  cp "$here/LICENSE" LICENSE-model-explorer.txt

  echo "== fetching fdbcli ($FDB_RELEASE)"
  mkdir -p "$ENGINE/cli" && cd "$ENGINE/cli"
  for f in fdbcli.linux.x86_64 fdbcli.macos.arm64 fdbcli.windows.x86_64.exe; do
    gh release download "$FDB_RELEASE" -R V-Sekai-fire/datasource-foundationdb -p "$f" --clobber
  done
  mv fdbcli.* "$ENGINE/" && chmod +x "$ENGINE"/fdbcli.*
  cd "$here"

  echo "== fetching the guest programs and walk data"
  tools/fetch_guest_assets.sh

  rm -rf "$CACHE/mm-repo" "$CACHE/station"
  git clone -q --depth 1 --filter=blob:none --sparse \
    https://github.com/V-Sekai-fire/interactor-motion-matching-guest.git "$CACHE/mm-repo"
  git -C "$CACHE/mm-repo" sparse-checkout set data

  git clone -q --filter=blob:none https://github.com/V-Sekai-fire/entities-sakuragaoka-station.git "$CACHE/station"
  git -C "$CACHE/station" checkout -q d9c0f0f916c1e7280fab4f09fc685c6ea679d814

  mkdir -p "$NOTICES"
  cp LICENSE "$NOTICES/LICENSE.md"
  printf '%s\n' "V-Sekai Model Explorer, walk mode viewer (local build test)" > "$NOTICES/NOTICE"
  printf '%s\n' 'cff-version: 1.2.0' 'message: "local build test"' 'title: "V-Sekai Model Explorer"' > "$NOTICES/CITATION.cff"
else
  echo "== --skip-fetch: reusing $ENGINE, $CACHE/mm-repo, $CACHE/station"
fi

echo "== exporting the pck"
export GODOT="$ENGINE/godot.linuxbsd.editor.double.x86_64"
export ENGINE NOTICES
export ELF="$here/skintokens.elf" USD_ELF="$here/usd.elf" MOTION_ELF="$here/motion.elf" \
       HEADFIT_ELF="$here/headfit.elf" MM_ELF="$here/mm.elf" MUJOCO_ELF="$here/mujoco.elf" \
       PERSONA_ELF="$here/persona.elf"
export MM_DATA="$CACHE/mm-repo/data/kimodo-locomotion:$CACHE/mm-repo/data/o3de-motionmatching"
export STATION_DIR="$CACHE/station"
elixir tools/package_desktop.exs pck "$WORK/out"

echo "== packaging the linux build (real --export-release embed_pck)"
mkdir -p "$WORK/no-weights"
elixir tools/package_desktop.exs package "$WORK/out" "$WORK/no-weights" walk-mode
d="$WORK/out/walk-mode/linux/$APP"
ls -la "$d"
if [ -f "$d/$APP.pck" ]; then
  echo "FAIL: a sibling $APP.pck shipped on Linux -- embed_pck did not actually embed"
  exit 1
fi
echo "ok: no sibling .pck next to the Linux exe (really embedded)"

echo "== FDB-selftest round trip (mirrors release.yml's verify job)"
exe="$d/$APP"
fails=0
set +e  # the control cases below are MEANT to exit non-zero; -e would abort on the first one
run() {
  label=$1; want_rc=$2; want=$3; bin=$4; shift 4
  if [ -n "$bin" ]; then export WEFT_FDB_BIN_DIR="$bin"; else unset WEFT_FDB_BIN_DIR; fi
  export WEFT_FDB_STATE_DIR="$WORK/fdb-state"
  rm -f "$WEFT_FDB_STATE_DIR/selftest-result.txt"
  out=$(perl -e 'alarm 240; exec @ARGV' "$exe" --headless -- --fdb-selftest "$@" 2>&1); rc=$?
  line=$(head -1 "$WEFT_FDB_STATE_DIR/selftest-result.txt" 2>/dev/null)
  echo "== $label: rc=$rc  $line"
  if [ "$rc" = "$want_rc" ] && echo "$line" | grep -Eq "$want"; then
    echo "   ok"
  else
    echo "   WRONG, wanted rc=$want_rc and /$want/"
    echo "$out" | tail -15
    fails=$((fails + 1))
  fi
}
mkdir -p "$WORK/empty"
run "control: no fdbserver" 1 'FAIL plant=false mode=roundtrip fdbserver and fdbcli not found' "$WORK/empty"
run "round trip through the packaged server" 0 'PASS plant=false mode=roundtrip fdbserver [0-9]+ on port' ""
run "second start reads the row the first wrote" 0 'PASS plant=false mode=read' "" --fdb-selftest-read
run "planted wrong value" 1 'FAIL plant=true mode=roundtrip read back' "" --fdb-selftest-plant
rm -rf "$WORK/fdb-state"
run "control: a fresh state has no row" 1 'FAIL plant=false mode=read no row from an earlier run' "" --fdb-selftest-read
echo "== no server left running"
if pgrep -l fdbserver; then fails=$((fails + 1)); else echo "   none"; fi
echo "failed cases: $fails"
[ "$fails" = 0 ] && echo "LOCAL-BUILD-TEST-OK"
exit "$fails"
