#!/bin/sh
# Compile the C that `skintokens-viewer -- --bintr-emit` wrote into native translations.
#
#   tools/compile_bintr.sh <c dir> <out dir> macos|linux|windows
#
# macos: Apple clang (-dynamiclib); linux: clang (-fPIC); windows: llvm-mingw's
# x86_64-w64-mingw32-clang (the add-on's own Windows toolchain), from Linux or WSL.
# Set CC to override the compiler and JOBS the parallel compiles (default: all cores).
# Each bintr-<HASH>.c becomes bintr-<HASH>.dylib, .so or .dll. With GODOT_SANDBOX_BINTR_UNITS=<n>
# set while emitting, a translation comes as bintr-<HASH>.<i>.c units: each compiles on its own
# core and the objects link into the one library. The flags are the ones
# interactor-skintokens-guest's tools/check_bintr.exs proves.
set -eu
src=$1 out=$2 os=$3
mkdir -p "$out"
case $os in
  macos) cc=${CC:-clang} ext=dylib link="-dynamiclib -Wl,-x" pic="" ;;
  linux) cc=${CC:-clang} ext=so link="-s" pic="-fPIC" ;;
  windows) cc=${CC:-x86_64-w64-mingw32-clang} ext=dll link="-s" pic="" ;;
  *) echo "unknown OS $os"; exit 2 ;;
esac
ls "$src"/bintr-*.c > /dev/null 2>&1 || { echo "no bintr-*.c in $src"; exit 1; }
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 4)}
obj=$(mktemp -d)
trap 'rm -rf "$obj"' EXIT
# Every C file to an object, in parallel.
CC_=$cc FLAGS="-O2 -std=c99 -fexceptions -fvisibility=hidden -fomit-frame-pointer $pic" OBJ=$obj
export CC_ FLAGS OBJ
# shellcheck disable=SC2016
ls "$src"/bintr-*.c | xargs -P "$jobs" -I{} sh -c \
  'b=$(basename "{}" .c); echo "$ $CC_ $b.c"; $CC_ $FLAGS -c -x c "{}" -o "$OBJ/$b.o"'
# One library per hash, from its single file or from all of its units.
n=0
for h in $(ls "$src"/bintr-*.c | sed -E 's|.*/bintr-([0-9A-F]{8}).*|\1|' | sort -u); do
  lib="$out/bintr-$h.$ext"
  # shellcheck disable=SC2086
  "$cc" -shared $link $(ls "$obj"/bintr-"$h".o "$obj"/bintr-"$h".[0-9]*.o 2> /dev/null) -o "$lib"
  echo "linked $(basename "$lib")"
  n=$((n + 1))
done
echo "BINTR-OK $n translation(s) in $out"
