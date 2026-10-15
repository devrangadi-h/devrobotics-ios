# DevRobotics Mac helpers

Free Apple IDs sign for 7 days. These two LaunchAgents keep the phone's copy fresh.

| Agent | What it does |
| --- | --- |
| `dev.devrobotics.watcher` | Every 5 s checks for the iPhone on USB. On plug-in (debounced) it runs `Tools/install.sh` if the install is due. |
| `dev.devrobotics.helper` | HTTP on the Mac's **Tailscale IPv4 only** (the address is read from `mac-host`, never committed). The app's About > "Reinstall from my Mac" button talks to it. |

## When the watcher installs
On each plug-in, once, if any of: less than 24 h left on the recorded signing (`expiresAt` in
`~/Library/Application Support/DevRobotics/last-install.json`, written by `Tools/install.sh` as install + 7 d);
`git fetch` shows `origin/main` ahead of the installed commit; there is no record; or the file
`~/Library/Application Support/DevRobotics/force` exists (`touch` it; removed after a successful install).
A failed install starts a 30 min cooldown. "Unlock your iPhone" is retried every minute while plugged in.
A dirty working tree is installed as-is and recorded as `<sha>-dirty`.
The installed build is taken from the record, not read back from the phone.

## Install / remove
```
Tools/mac/install-mac-helpers.sh --print-only   # preview
Tools/mac/install-mac-helpers.sh                # writes plists, token, bootstraps both agents
Tools/mac/uninstall-mac-helpers.sh [--purge]    # boots out and removes (--purge also token, state, logs)
```
The token is the same value as the Pi's app token (`~/.config/polaris/lights_token`); it is read from
`$DEVROBOTICS_INSTALLER_TOKEN` or over `ssh polaris`, stored at `~/.config/devrobotics/installer_token` (600), and never printed.

## API (Bearer token on every route)
`GET /v1/mac/status`, `POST /v1/mac/install` (202 / 409 running / 412 no phone), `GET /v1/mac/install`.
Nothing from the client reaches a shell.

## Caveats
- The Mac must be **awake** (plugged in or `caffeinate`), logged in, and on Tailscale; the iPhone must be **unlocked and trusted**.
- The app closes and reopens when the install finishes; it only works while the installed copy still opens.
- In the app use the Mac's Tailscale **IP** (100.x.y.z): the helper speaks plain http over the encrypted tailnet and
  iOS App Transport Security only exempts IP addresses, not MagicDNS names.
- Logs: `~/Library/Logs/DevRobotics/watcher.log`, `helper.log`.
