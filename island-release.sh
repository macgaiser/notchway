#!/bin/zsh
# Builds a release ZIP of Notchway that runs on other Macs without an Apple Developer account:
# ad-hoc signed, Apple silicon only (the phone daemon is built for arm64).
# On first launch macOS asks once: System Settings > Privacy & Security > "Open Anyway".
# Usage: ./island-release.sh <version>      e.g. ./island-release.sh 0.1.0
set -o pipefail
cd "${0:A:h}"

VERSION="${1:?Version angeben, z. B. 0.1.0}"
OUT="build-release"
APP="$OUT/Build/Products/Release/Notchway.app"
DIST="dist"

# Notchway's Google client is compiled in only for this build (see island-build.sh).
GOOGLE_CLIENT_JSON="${ISLAND_GOOGLE_CLIENT:-../extern/notchway-google-client.json}"
BUILTIN="boringNotch/Island/GoogleClientBuiltIn.swift"
if [[ -f "$GOOGLE_CLIENT_JSON" ]]; then
  cp "$BUILTIN" "$BUILTIN.orig"
  trap 'mv -f "$BUILTIN.orig" "$BUILTIN"' EXIT
  python3 - "$GOOGLE_CLIENT_JSON" "$BUILTIN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get("installed") or d.get("web") or d
open(sys.argv[2], "w").write('enum GoogleClientBuiltIn {\n    static let id = "%s"\n    static let secret = "%s"\n}\n' % (d["client_id"], d["client_secret"]))
PY
else
  echo "Kein Google-Client gefunden: die Anmeldung geht dann nur mit eigenem Client." >&2
fi

rm -rf "$OUT"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$OUT" -skipMacroValidation -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGNING_ALLOWED=YES \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" -A5 | tail -40
[[ ${pipestatus[1]} -eq 0 && -d "$APP" ]] || exit 1

# Phone service.
DAEMON_SRC="${ISLAND_DAEMON_SRC:-../extern/sc-jitunayak}"
[[ -f "$DAEMON_SRC/Cargo.toml" ]] || { echo "Daemon-Quelle fehlt: $DAEMON_SRC" >&2; exit 1; }
(cd "$DAEMON_SRC" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release --offline --bin smartconnectd --bin smartconnect-fex -p smartconnect-mac -p smartconnect-fex 2>&1 | grep -E "^error|Finished" | tail -3)
HELPER="$DAEMON_SRC/target/release/smartconnect-mac-helper"
swiftc -O -swift-version 5 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DAEMON_SRC/macapp/HelperInfo.plist" \
  -o "$HELPER" "$DAEMON_SRC/macapp/SmartConnectHelper.swift" 2>&1 | grep -E "error" | head -5

mkdir -p "$APP/Contents/Helpers"
cp "$DAEMON_SRC/target/release/smartconnectd" "$DAEMON_SRC/target/release/smartconnect-fex" "$HELPER" "$APP/Contents/Helpers/"
for tool in smartconnect-mac-helper smartconnect-fex smartconnectd; do
  codesign --force --sign - "$APP/Contents/Helpers/$tool" 2>&1 | grep -v "replacing existing signature"
done

# Sign again from the inside out, keeping the entitlements xcodebuild resolved.
ENT="$(mktemp -t notchway-ent)"
codesign -d --entitlements "$ENT" --xml "$APP" 2>/dev/null
find "$APP/Contents" \( -name "*.xpc" -o -name "*.framework" -o -name "*.app" \) -not -path "$APP" -prune 2>/dev/null | while read -r nested; do
  codesign --force --sign - --preserve-metadata=entitlements,identifier "$nested" 2>&1 | grep -v "replacing existing signature"
done
codesign --force --sign - --entitlements "$ENT" "$APP" 2>&1 | grep -v "replacing existing signature"
rm -f "$ENT"
codesign --verify --strict --deep "$APP" && echo "Signatur in Ordnung."

mkdir -p "$DIST"
ZIP="$DIST/Notchway-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "Notchway-$VERSION.zip" | tee "Notchway-$VERSION.zip.sha256")
echo "Fertig: $ZIP"
