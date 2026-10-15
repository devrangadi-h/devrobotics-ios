#!/bin/zsh
# One-command removal of the DevRobotics watcher and helper LaunchAgents.
# Usage: Tools/mac/uninstall-mac-helpers.sh [--purge] [--print-only]
#   --purge  also delete the token, state file and logs.
AGENTS="${DEVROBOTICS_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
UIDN=$(id -u)
PURGE=0; PRINT=0
for a in "$@"; do [ "$a" = "--purge" ] && PURGE=1; [ "$a" = "--print-only" ] && PRINT=1; done
run() { if [ "$PRINT" = 1 ]; then echo "would run: $*"; else "$@" 2>/dev/null || true; fi; }
for L in dev.devrobotics.watcher dev.devrobotics.helper; do
  run launchctl bootout "gui/$UIDN/$L"
  run rm -f "$AGENTS/$L.plist"
done
if [ "$PURGE" = 1 ]; then
  run rm -f "$HOME/.config/devrobotics/installer_token"
  run rm -rf "$HOME/Library/Logs/DevRobotics" "$HOME/Library/Application Support/DevRobotics"
fi
[ "$PRINT" = 1 ] || echo "DevRobotics Mac helpers removed.${PURGE:+ }"
