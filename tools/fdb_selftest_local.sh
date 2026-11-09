#!/bin/bash
# Local twin of the release workflow's verify job: start the packaged FoundationDB server through
# FdbServer.gd, round-trip a row through the SQLite module, and prove the controls fail.
#
#   GODOT=<double editor/runtime> FDB_BIN=<dir with fdbserver and fdbcli> tools/fdb_selftest_local.sh
#
# GODOT needs libfdb_c beside it. FDB_BIN holds the two binaries under the plain names fdbserver
# and fdbcli. Every case must print its expected FDB-SELFTEST verdict AND exit as expected: an exit
# code alone proves nothing, since a project that cannot start also exits 1.
set -u
: "${GODOT:?set GODOT to the engine binary}" "${FDB_BIN:?set FDB_BIN to the folder with fdbserver and fdbcli}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; fails=0
mkdir -p "$T/proj/core" "$T/home" "$T/empty"
cp "$HERE/vsk_model_explorer/core/FdbServer.gd" "$T/proj/core/"
printf '[gd_scene format=3]\n\n[node name="Main" type="Node"]\n' > "$T/proj/main.tscn"
printf 'config_version=5\n\n[application]\n\nconfig/name="FdbTest"\nrun/main_scene="res://main.tscn"\n\n[autoload]\n\nFdbServer="*res://core/FdbServer.gd"\n' > "$T/proj/project.godot"

case_run() { # <label> <bin dir> <state dir> <want rc> <want regex> [extra user args]
  label=$1; bin=$2; st=$3; wantrc=$4; want=$5; shift 5
  echo "== $label =="
  ( cd "$T/proj" && env -i PATH=/usr/bin:/bin HOME="$T/home" WEFT_FDB_BIN_DIR="$bin" WEFT_FDB_STATE_DIR="$st" \
      perl -e 'alarm 170; exec @ARGV' "$GODOT" --headless --path . -- --fdb-selftest "$@" > "$T/case.log" 2>&1; echo $? > "$T/case.rc" )
  rc=$(cat "$T/case.rc"); line=$(grep -E 'FDB-SELFTEST' "$T/case.log" | head -1)
  echo "  rc=$rc  line: ${line:-<none>}"
  if [ "$rc" = "$wantrc" ] && echo "$line" | grep -Eq "$want"; then echo "  OK"; else echo "  WRONG (wanted rc=$wantrc and /$want/)"; grep -v -E '^\s*$' "$T/case.log" | head -6 | cut -c1-200; fails=$((fails+1)); fi
  if pgrep -f "fdbserver.*$T" > /dev/null; then echo "  SERVER STILL RUNNING after quit"; fails=$((fails+1)); else echo "  server gone after quit"; fi
}
S="$T/state with space"
case_run "CONTROL: no fdbserver in the bin dir" "$T/empty" "$T/ctl state" 1 'FAIL plant=false mode=roundtrip fdbserver and fdbcli not found'
case_run "REAL: packaged server, SQLite round trip" "$FDB_BIN" "$S" 0 'PASS plant=false mode=roundtrip fdbserver [0-9]+ on port'
port1=$(sed -E 's/.*:([0-9]+)$/\1/' "$S/fdb.cluster")
case_run "PERSIST: a second start reads the row the first run wrote" "$FDB_BIN" "$S" 0 "PASS plant=false mode=read fdbserver [0-9]+ on port $port1" --fdb-selftest-read
case_run "PERSIST CONTROL: a fresh state has no row" "$FDB_BIN" "$T/fresh state" 1 'FAIL plant=false mode=read no row from an earlier run' --fdb-selftest-read
case_run "PLANT: wrong expected value" "$FDB_BIN" "$S" 1 'FAIL plant=true mode=roundtrip read back .*-planted' --fdb-selftest-plant
rm -rf "$T"
echo "RESULT: $fails wrong case(s)"; exit "$fails"
