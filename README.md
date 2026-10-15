# DevRobotics (iOS)

Personal companion app for **Polaris**, a Raspberry Pi 5 that runs devrobotics.dev tooling.
Built with SwiftUI and SwiftPM, and built/installed with [xtool](https://github.com/xtool-org/xtool) (no Xcode project).

- **Status**: live Pi health (CPU temp, load, memory, disk, services), with a cached fallback.
- **Lights**: on/off, brightness and presets for the Govee lamps via the lights API.
- **Frames**: write photos and stories offline, send them to the Pi, preview and publish.
- **Settings**: Pi address and token (stored in the iOS Keychain; nothing is hard-coded).

## Layout

- `Sources/DevRobotics/`: the iOS app.
- `server/`: `polaris_app_api.py`, the Pi-side backend (Flask, served tailnet-only via Tailscale Serve on port 8443), plus its systemd unit.

## Build and install

```sh
brew install xtool-org/tap/xtool
xtool setup          # one-time Apple login
xtool dev            # build, sign, install on a connected iPhone
```

Free Apple IDs expire after 7 days; re-run `xtool dev` to reinstall.

## Fonts

Inter and JetBrains Mono are bundled under the SIL Open Font License 1.1; see `LICENSES/`.
