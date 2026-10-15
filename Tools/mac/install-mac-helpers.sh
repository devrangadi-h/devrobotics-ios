#!/bin/zsh
# Installs the DevRobotics watcher (auto-reinstall when the phone is plugged in) and helper (the app's
# "Reinstall from my Mac" button) as LaunchAgents. Undo with Tools/mac/uninstall-mac-helpers.sh.
# Usage: Tools/mac/install-mac-helpers.sh [--print-only]
# Token: kept if ~/.config/devrobotics/installer_token exists; else from $DEVROBOTICS_INSTALLER_TOKEN;
# else read from the Pi with `ssh polaris 'cat ~/.config/polaris/lights_token'`. It is never printed.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AGENTS="${DEVROBOTICS_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
CONF="$HOME/.config/devrobotics"
TOKEN_FILE="$CONF/installer_token"
LOGS="$HOME/Library/Logs/DevRobotics"
PRINT=0; [ "$1" = "--print-only" ] && PRINT=1
UIDN=$(id -u)

plist() {  # label, script
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$2</string></array>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGS/$1.out.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$1.err.log</string>
</dict></plist>
PL
}

if [ "$PRINT" = 1 ]; then
  echo "[print-only] nothing will be written, loaded or contacted."
  echo "would create: $LOGS, $CONF (700)"
  if [ -s "$TOKEN_FILE" ]; then echo "token: keeping existing $TOKEN_FILE"
  elif [ -n "$DEVROBOTICS_INSTALLER_TOKEN" ]; then echo "token: would write from \$DEVROBOTICS_INSTALLER_TOKEN to $TOKEN_FILE (600)"
  else echo "token: would run ssh polaris 'cat ~/.config/polaris/lights_token' and write $TOKEN_FILE (600)"; fi
  for pair in "dev.devrobotics.watcher:devrobotics-watcher" "dev.devrobotics.helper:devrobotics-helper"; do
    L=${pair%%:*}; S=${pair##*:}
    echo "\nwould write $AGENTS/$L.plist:"; plist "$L" "$HERE/$S"
    echo "would run: launchctl bootstrap gui/$UIDN $AGENTS/$L.plist"
  done
  exit 0
fi

mkdir -p "$LOGS" "$AGENTS"; chmod +x "$HERE/devrobotics-watcher" "$HERE/devrobotics-helper"
mkdir -p "$CONF"; chmod 700 "$CONF"
if [ ! -s "$TOKEN_FILE" ]; then
  T="${DEVROBOTICS_INSTALLER_TOKEN:-}"
  if [ -z "$T" ]; then T=$(ssh polaris 'cat ~/.config/polaris/lights_token' 2>/dev/null | tr -d '[:space:]'); fi
  [ -n "$T" ] || { echo "No token available. Set DEVROBOTICS_INSTALLER_TOKEN or make 'ssh polaris' work." >&2; exit 1; }
  ( umask 077; printf '%s\n' "$T" > "$TOKEN_FILE" )   # printf is a builtin: the token is not in any process argument
  chmod 600 "$TOKEN_FILE"; unset T
  echo "Token saved to $TOKEN_FILE (600)."
fi

for pair in "dev.devrobotics.watcher:devrobotics-watcher" "dev.devrobotics.helper:devrobotics-helper"; do
  L=${pair%%:*}; S=${pair##*:}
  launchctl bootout "gui/$UIDN/$L" 2>/dev/null || true
  plist "$L" "$HERE/$S" > "$AGENTS/$L.plist"
  launchctl bootstrap "gui/$UIDN" "$AGENTS/$L.plist"
  echo "Loaded $L"
done
echo "Done. Logs: $LOGS. Remove with Tools/mac/uninstall-mac-helpers.sh"
