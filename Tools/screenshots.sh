#!/bin/bash
# Build the app for the iOS simulator and capture each demo screen in light and dark mode.
# Usage: Tools/screenshots.sh <simulator-udid> [out-dir] [screen ...]
# Screens (default all): status lights frames settings story photo publish
set -euo pipefail
UDID="${1:?usage: screenshots.sh <simulator-udid> [out-dir] [screen ...]}"
OUT="${2:-/tmp/devrobotics-shots/$UDID}"
shift $(( $# < 2 ? $# : 2 ))
SCREENS=("$@")
[ ${#SCREENS[@]} -eq 0 ] && SCREENS=(status lights frames settings story photo publish)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="/tmp/devrobotics-dd-$UDID"
BUNDLE="com.hardik.devrobotics"

cd "$ROOT"
xtool dev generate-xcode-project >/dev/null
xcodebuild -workspace xtool/DevRobotics.xcworkspace -scheme DevRobotics-App \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO -quiet
APP="$(find "$DD/Build/Products" -maxdepth 3 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "no .app built" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
mkdir -p "$OUT"
# A cold simulator needs several seconds for the first launch; warm it up so the first screenshot isn't blank.
xcrun simctl launch "$UDID" "$BUNDLE" -demo >/dev/null; sleep 12; xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance "$mode"
  for s in "${SCREENS[@]}"; do
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE" -demo -screen "$s" >/dev/null
    sleep 14
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$mode.png" >/dev/null 2>&1
  done
done
echo "$OUT"
