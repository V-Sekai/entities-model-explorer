#!/bin/sh
# Build Model Explorer.app from HEAD and the Sandbox-capable engine, sign it, and put it in a .dmg.
#
#   tools/make_dmg.sh <out dir>
#
# Environment:
#   ENGINE   the double-precision macOS editor binary (default ../engine-sandbox/bin/godot.macos.editor.double.arm64)
#   SIGN_ID  codesign identity (default "-", an ad-hoc signature that only runs on this Mac).
#            "Developer ID Application: Ernest Lee (F48WQK5Y2R)" signs for release: the private key is
#            in the login keychain and in release-signing.keychain-db, and codesign needs one of them
#            unlocked (security unlock-keychain <path>); without that it stops with errSecInternalComponent.
#   KEYCHAIN optional: the keychain codesign searches (default: the search list)
#   NOTARIZE 1 to notarize and staple the .dmg with the App Store Connect key kept in OpenBao
#            (secret/agents-own/<cn>/apple-notary-key: key_id, issuer_id, p8); needs a real SIGN_ID
#   LABEL    file name suffix (default: the short commit)
# The app is the engine binary plus a copy of the project (git archive HEAD, imported once). It runs the
# project from ~/Library/Application Support/Model Explorer/<build>, so the signed bundle is never written to.
# The auto-rig weights (the w folder) are not in it: R auto-rigs only where they are present.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(mkdir -p "$1" && cd "$1" && pwd)
engine=${ENGINE:-$here/../engine-sandbox/bin/godot.macos.editor.double.arm64}
sign_id=${SIGN_ID:--}
sha=$(git -C "$here" rev-parse --short HEAD)
label=${LABEL:-$sha}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/dmg/Model Explorer.app"
proj="$app/Contents/Resources/project"
[ -x "$engine" ] || { echo "no engine at $engine"; exit 1; }

mkdir -p "$app/Contents/MacOS" "$proj"
git -C "$here" archive HEAD | tar -x -C "$proj"
rm -rf "$proj/guest"
for f in skintokens.elf usd.elf motion.elf headfit.elf persona.elf mm.elf mujoco.elf; do [ -f "$here/$f" ] && cp "$here/$f" "$proj/"; done
# walk mode and the obstacle course need mm.elf, mujoco.elf and motion/mm (tools/fetch_guest_assets.sh puts them there)
[ -d "$here/motion/mm" ] && mkdir -p "$proj/motion" && cp -R "$here/motion/mm" "$proj/motion/mm"
cat > "$proj/addons/vsk_version/build_constants.gd" <<EOF
# Set by the build system, do not modify!
const BUILD_LABEL = "build @ $sha"
const BUILD_DATE_STR = "$(date -u +%Y-%m-%d)"
EOF
( cd "$proj" && "$engine" --headless --path . --import >/dev/null 2>&1 || true )
cp "$engine" "$app/Contents/Resources/godot"
cp "$here/LICENSE" "$app/Contents/Resources/LICENSE-model-explorer.txt"
# The MIT, BSD and Apache-2.0 parts need their notices to ship with the binaries, the NVIDIA and Meta licences a NOTICE:
# the walk-mode set of tools/licences/licgen.py (no weights), beside the app (before signing) and at the top of the volume.
python3 "$here/tools/licences/licgen.py" "$work/notices" >/dev/null
for f in LICENSE.md NOTICE CITATION.cff; do cp "$work/notices/walk-mode/$f" "$app/Contents/Resources/$f"; done
mkdir -p "$work/dmg"
cat > "$app/Contents/MacOS/Model Explorer" <<'E'
#!/bin/sh
res="$(cd "$(dirname "$0")/../Resources" && pwd)"
ver="$(grep BUILD_LABEL "$res/project/addons/vsk_version/build_constants.gd" | sed 's/.*"\(.*\)".*/\1/' | tr ' @' '__')"
data="$HOME/Library/Application Support/Model Explorer/$ver"
if [ ! -d "$data/project" ]; then mkdir -p "$data" && cp -R "$res/project" "$data/project"; fi
exec "$res/godot" --path "$data/project" -- "$@"
E
chmod +x "$app/Contents/MacOS/Model Explorer" "$app/Contents/Resources/godot"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Model Explorer</string>
<key>CFBundleDisplayName</key><string>Model Explorer</string>
<key>CFBundleIdentifier</key><string>org.v-sekai.model-explorer</string>
<key>CFBundleExecutable</key><string>Model Explorer</string>
<key>CFBundleShortVersionString</key><string>0.1.0-$sha</string>
<key>CFBundleVersion</key><string>$sha</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
cat > "$work/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
EOF
kc=""
[ -n "${KEYCHAIN:-}" ] && kc="--keychain $KEYCHAIN"
if [ "$sign_id" = "-" ]; then
  # shellcheck disable=SC2086
  codesign --force --deep --sign - "$app"
else
  # shellcheck disable=SC2086
  codesign --force --timestamp --options runtime --entitlements "$work/entitlements.plist" $kc --sign "$sign_id" "$app/Contents/Resources/godot"
  # shellcheck disable=SC2086
  codesign --force --timestamp --options runtime --entitlements "$work/entitlements.plist" $kc --sign "$sign_id" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

cat > "$work/dmg/README.txt" <<EOF
Model Explorer $sha. Drag Model Explorer to Applications and open it.
Drop a .glb, .gltf, .vrm or .usd on the window. R auto-rigs a .glb where the rig weights are installed.
This is $( [ "$sign_id" = "-" ] && echo "an unsigned build: open it with right-click, Open." || echo "signed by $sign_id." )
EOF
for f in LICENSE.md NOTICE CITATION.cff; do cp "$work/notices/walk-mode/$f" "$work/dmg/$f"; done
ln -s /Applications "$work/dmg/Applications"
suffix=""; [ "$sign_id" = "-" ] && suffix="-unsigned"
dmg="$out/Model-Explorer-0.1.0-$label$suffix.dmg"
rm -f "$dmg"
hdiutil create -volname "Model Explorer" -srcfolder "$work/dmg" -ov -format UDZO "$dmg" >/dev/null
[ "$sign_id" != "-" ] && codesign --force --timestamp $kc --sign "$sign_id" "$dmg"

if [ "${NOTARIZE:-0}" = 1 ]; then
  [ "$sign_id" != "-" ] || { echo "notarizing needs a real SIGN_ID"; exit 1; }
  . "$HOME/.local/bin/bao-login.sh" >/dev/null
  p8="$work/notary.p8"; umask 077
  bao kv get -field=p8 "secret/agents-own/$BAO_CN/apple-notary-key" > "$p8"
  key_id=$(bao kv get -field=key_id "secret/agents-own/$BAO_CN/apple-notary-key")
  issuer=$(bao kv get -field=issuer_id "secret/agents-own/$BAO_CN/apple-notary-key")
  xcrun notarytool submit "$dmg" --key "$p8" --key-id "$key_id" --issuer "$issuer" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi
echo "$dmg"
