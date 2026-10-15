#!/bin/zsh
# Stamps build info into Resources/BuildStamp.json (gitignored), then runs `xtool dev` (all args passed through).
# Usage: Tools/install.sh [--stamp-only] [xtool dev args...]
set -e
cd "$(dirname "$0")/.."
OUT=Sources/DevRobotics/Resources/BuildStamp.json
VERSION=1.0.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null | grep -v BuildStamp.json)" ]; then COMMIT="$COMMIT-dirty"; fi
BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SWIFT=$(swift --version 2>/dev/null | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/')
XCODE=$(xcodebuild -version 2>/dev/null | head -1 | sed 's/Xcode //')
SDK=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
cat > "$OUT" <<JSON
{"version":"$VERSION","build":"$BUILD","commit":"$COMMIT","builtAt":"$BUILT","swift":"$SWIFT","xcode":"$XCODE","sdk":"$SDK"}
JSON
echo "Stamped: $VERSION · build $BUILD · $COMMIT · $BUILT"
if [ "$1" = "--stamp-only" ]; then exit 0; fi
exec xtool dev "$@"
