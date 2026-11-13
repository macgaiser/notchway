#!/bin/zsh
# Builds the app with a stable signature, so macOS keeps granted permissions across builds.
# Usage: ./island-build.sh [--run]
# The team is the Xcode account's personal team; override with ISLAND_TEAM=<id>.
set -o pipefail
cd "${0:A:h}"

TEAM="${ISLAND_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | sed -n 's/.*teamID = \([A-Z0-9]*\);.*/\1/p' | head -1)}"
if [[ -z "$TEAM" ]]; then
  echo "Kein Xcode-Konto gefunden. In Xcode unter Settings → Accounts anmelden." >&2
  exit 1
fi

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" -A5 | tail -40
[[ ${pipestatus[1]} -eq 0 ]] || exit 1

APP="build/Build/Products/Debug/Boring Notch.app"

# Phone service (Smart Connect daemon). Its source lives outside this repository for now;
# set ISLAND_DAEMON_SRC to its checkout. Without it the app builds, minus the "Handy" view.
DAEMON_SRC="${ISLAND_DAEMON_SRC:-../extern/sc-jitunayak}"
if [[ -f "$DAEMON_SRC/Cargo.toml" ]]; then
  (cd "$DAEMON_SRC" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release --offline --bin smartconnectd --bin smartconnect-fex -p smartconnect-mac -p smartconnect-fex 2>&1 | grep -E "^error|warning: unused|Finished" | tail -5)
  DAEMON="$DAEMON_SRC/target/release/smartconnectd"
  # Small Swift helper the daemon starts for the Bluetooth wake and for reading the clipboard
  # (it skips entries that password managers mark as confidential).
  HELPER="$DAEMON_SRC/target/release/smartconnect-mac-helper"
  swiftc -O -swift-version 5 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DAEMON_SRC/macapp/HelperInfo.plist" \
    -o "$HELPER" "$DAEMON_SRC/macapp/SmartConnectHelper.swift" 2>&1 | grep -E "error" | head -5
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*) \([A-F0-9]\{40\}\) "Apple Development.*/\1/p' | head -1)"
  if [[ -x "$DAEMON" && -n "$IDENTITY" ]]; then
    mkdir -p "$APP/Contents/Helpers"
    cp "$DAEMON" "$APP/Contents/Helpers/smartconnectd"
    if [[ -x "$HELPER" ]]; then
      cp "$HELPER" "$APP/Contents/Helpers/smartconnect-mac-helper"
      codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/smartconnect-mac-helper" 2>&1 | grep -v "replacing existing signature"
    fi
    # File transfer to and from the phone.
    FEX="$DAEMON_SRC/target/release/smartconnect-fex"
    if [[ -x "$FEX" ]]; then
      cp "$FEX" "$APP/Contents/Helpers/smartconnect-fex"
      codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/smartconnect-fex" 2>&1 | grep -v "replacing existing signature"
    fi
    ENTITLEMENTS="$(mktemp -t island-entitlements)"
    codesign -d --entitlements "$ENTITLEMENTS" --xml "$APP" 2>/dev/null
    # No entitlements of its own: started by the app, the daemon inherits the app's sandbox.
    codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/smartconnectd" 2>&1 | grep -v "replacing existing signature"
    # Adding a file invalidates the app's seal, so the app is signed again with the same entitlements.
    codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | grep -v "replacing existing signature"
    rm -f "$ENTITLEMENTS"
    codesign --verify --strict "$APP" && echo "Handy-Dienst eingebettet und signiert."
  else
    echo "Handy-Dienst nicht eingebettet (Build oder Zertifikat fehlt)." >&2
  fi
fi

if [[ "$1" == "--run" ]]; then
  osascript -e 'tell application id "theboringteam.boringnotch" to quit' 2>/dev/null
  sleep 2
  # The media helper (a perl script) can outlive the app it belonged to.
  ps -axo pid,ppid,command | grep "${PWD}/build" | grep perl | awk '$2==1{print $1}' | xargs kill 2>/dev/null
  open "$APP"
fi
