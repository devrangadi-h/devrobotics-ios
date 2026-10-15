# Polaris lights API

Flask service controlling two Govee H607C lamps through the Govee OpenAPI.
Binds `127.0.0.1:$PORT` (default 5000); Tailscale Serve provides HTTPS.
All routes need `Authorization: Bearer <token>` (401 otherwise). CORS allows
`https://devrobotics.dev` and `https://www.devrobotics.dev`.

## Routes

`lamp` is optional on power/brightness/preset/colortemp/color: `"all"`
(default) or a 0-based index. Bad input returns `400 {"error": ...}`.
Lamps are called sequentially, with retry/backoff on Govee 429.

| Route | Body | Notes |
|---|---|---|
| GET `/api/lights/ping` | | `{"ok":true}` |
| GET `/api/lights/state` | | `{ok, updatedAt, timer, lamps:[{index,name,online,on,brightness,colorTempK,color}]}`; cached ~5 s |
| POST `/api/lights/power` | `{"value":"on"\|"off","lamp"}` | `{ok, responses}` (unchanged) |
| POST `/api/lights/brightness` | `{"value":1-100,"lamp"}` | `{ok, responses}` (unchanged) |
| POST `/api/lights/preset` | `{"value":"bright_white_cool"\|"bright_white_warm","lamp"}` | unchanged shape |
| POST `/api/lights/colortemp` | `{"value":2000-9000,"lamp"}` | clamped to each lamp's range; adds `applied` |
| POST `/api/lights/color` | `{"r","g","b":0-255,"lamp"}` | sent as `(r<<16)+(g<<8)+b` |
| POST `/api/lights/timer` | `{"minutes":1-720,"action":"off"}` or `{"cancel":true}` | one timer, in-process, lost on restart |

If `lamps.json` is missing or invalid, lamp routes return `503`.
`/state`: a failed lamp is `online:false` with null fields; `colorTempK` and
`color` are mutually exclusive (whichever mode the lamp is in).

## Config (env vars, defaults under `~/.config/polaris/`)

- `LAMPS_PATH` = `lamps.json`:
  `[{"device":"<id>","sku":"H607C","name":"Floor lamp left"}, ...]`
- `API_KEY_PATH` = `govee_api_key`
- `TOKEN_PATH` = `lights_token`
- `PORT` = 5000

No IDs or keys are in this repo.

## Deploy (on the Pi)

```
cd /home/polaris/polaris
cp lights_api.py lights_api.py.bak
# create lamps.json from the current hardcoded IDs (the two "device" values in the .bak)
python3 - <<'EOF'
import re, json, os
s = open("lights_api.py.bak").read()
ids = re.findall(r'"device":\s*"([^"]+)"', s)
names = ["Floor lamp left", "Floor lamp right"]
p = os.path.expanduser("~/.config/polaris/lamps.json")
json.dump([{"device": d, "sku": "H607C", "name": n} for d, n in zip(ids, names)], open(p, "w"), indent=2)
os.chmod(p, 0o600)
EOF
cp <repo>/server/lights/lights_api.py lights_api.py
sudo systemctl restart lights-api.service
curl -s -H "Authorization: Bearer $(cat ~/.config/polaris/lights_token)" 127.0.0.1:5000/api/lights/state
```

## Rollback

```
cp /home/polaris/polaris/lights_api.py.bak /home/polaris/polaris/lights_api.py
sudo systemctl restart lights-api.service
```

## Govee limits

Device state is limited to about 30 requests/min per device, and control
calls are rate-limited per device; hence the 5 s state cache, optimistic
updates after successful control calls, and sequential calls.
