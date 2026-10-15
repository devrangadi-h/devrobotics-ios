#!/bin/zsh
# Stamps build info into Resources/BuildStamp.json (gitignored), then runs `xtool dev` (all other args passed through).
# Usage: Tools/install.sh [--stamp-only] [--dry-run] [xtool dev args...]
#   --stamp-only  stamp and exit.
#   --dry-run     stamp, take the lock, print the xtool command and the install record, but install nothing and
#                 write no record (the record goes to stdout).
# Only one install runs at a time (lock dir below); on success it writes last-install.json for the Mac watcher.
# Env: DEVROBOTICS_XTOOL (override the xtool binary, for tests), DEVROBOTICS_SUPPORT_DIR.
set -e
cd "$(dirname "$0")/.."
DRY=0; STAMP_ONLY=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --stamp-only) STAMP_ONLY=1 ;;
    --dry-run) DRY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done


if [ "$STAMP_ONLY" = 0 ]; then
SUPPORT="${DEVROBOTICS_SUPPORT_DIR:-$HOME/Library/Application Support/DevRobotics}"
LOCK="$SUPPORT/install.lock.d"
mkdir -p "$SUPPORT"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "another install is already running (pid $OLD)" >&2
    exit 75
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"   # stale lock
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
fi

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
[ "$STAMP_ONLY" = 1 ] && exit 0

EXPIRES=$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)
RECORD="{\"build\":\"$BUILD\",\"commit\":\"$COMMIT\",\"builtAt\":\"$BUILT\",\"expiresAt\":\"$EXPIRES\"}"
XTOOL="${DEVROBOTICS_XTOOL:-xtool}"

if [ "$DRY" = 1 ]; then
  echo "dry-run: would run: $XTOOL dev ${ARGS[*]}"
  echo "dry-run: would record: $RECORD"
  exit 0
fi

"$XTOOL" dev "${ARGS[@]}"
echo "$RECORD" > "$SUPPORT/last-install.json.tmp" && mv "$SUPPORT/last-install.json.tmp" "$SUPPORT/last-install.json"
echo "Installed build $BUILD ($COMMIT); record written."
