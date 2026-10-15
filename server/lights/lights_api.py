#!/usr/bin/env python3
"""Polaris lights API: Flask front for two Govee lamps via the Govee OpenAPI.

Config (no secrets in this file):
  LAMPS_PATH     JSON list [{"device": "...", "sku": "H607C", "name": "..."}]
                 default ~/.config/polaris/lamps.json
  API_KEY_PATH   Govee API key file, default ~/.config/polaris/govee_api_key
  TOKEN_PATH     bearer token file, default ~/.config/polaris/lights_token
  PORT           listen port (default 5000), bound to 127.0.0.1
"""
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.request
import uuid

from flask import Flask, jsonify, request

CONF_DIR = os.path.expanduser("~/.config/polaris")
API_KEY_PATH = os.environ.get("API_KEY_PATH", os.path.join(CONF_DIR, "govee_api_key"))
TOKEN_PATH = os.environ.get("TOKEN_PATH", os.path.join(CONF_DIR, "lights_token"))
LAMPS_PATH = os.environ.get("LAMPS_PATH", os.path.join(CONF_DIR, "lamps.json"))
ALLOWED_ORIGINS = {"https://devrobotics.dev", "https://www.devrobotics.dev"}
GOVEE_BASE = "https://openapi.api.govee.com/router/api/v1"
CACHE_TTL = 5.0
DEFAULT_TEMP_RANGE = (2000, 9000)

CAP_POWER = {"type": "devices.capabilities.on_off", "instance": "powerSwitch"}
CAP_BRIGHT = {"type": "devices.capabilities.range", "instance": "brightness"}
CAP_TEMP = {"type": "devices.capabilities.color_setting", "instance": "colorTemperatureK"}
CAP_RGB = {"type": "devices.capabilities.color_setting", "instance": "colorRgb"}

app = Flask(__name__)


class ConfigError(Exception):
    pass


# ---------------------------------------------------------------- config
def load_token() -> str:
    try:
        with open(TOKEN_PATH, "r") as f:
            return f.read().strip()
    except OSError:
        raise ConfigError("token file unavailable")


def load_api_key() -> str:
    try:
        with open(API_KEY_PATH, "r") as f:
            return f.read().strip()
    except OSError:
        raise ConfigError("Govee API key file unavailable")


def load_lamps() -> list:
    try:
        with open(LAMPS_PATH, "r") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        raise ConfigError("lamps config missing or invalid")
    lamps = []
    if isinstance(raw, list):
        for i, item in enumerate(raw):
            if isinstance(item, dict) and item.get("device") and item.get("sku"):
                lamps.append({
                    "device": str(item["device"]),
                    "sku": str(item["sku"]),
                    "name": str(item.get("name") or f"Lamp {i + 1}"),
                })
    if not lamps:
        raise ConfigError("lamps config has no lamps")
    return lamps


@app.errorhandler(ConfigError)
def on_config_error(e):
    return jsonify({"error": f"service not configured: {e}"}), 503


# ---------------------------------------------------------------- auth/cors
@app.after_request
def add_cors_headers(resp):
    origin = request.headers.get("Origin")
    if origin in ALLOWED_ORIGINS:
        resp.headers["Access-Control-Allow-Origin"] = origin
        resp.headers["Vary"] = "Origin"
        resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
        resp.headers["Access-Control-Allow-Private-Network"] = "true"
    return resp


@app.before_request
def require_token():
    if request.method == "OPTIONS":
        return ("", 204)
    sent = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not sent or not hmac.compare_digest(sent, load_token()):
        return jsonify({"error": "unauthorized"}), 401


# ---------------------------------------------------------------- govee
_govee_lock = threading.Lock()  # serialises all Govee calls (sequential, rate-friendly)


def _govee_request(method: str, path: str, payload=None) -> dict:
    """One Govee call with small retry/backoff on 429. Returns parsed JSON
    or {"error": ...}. Never includes secrets."""
    url = GOVEE_BASE + path
    headers = {"Govee-API-Key": load_api_key(), "Content-Type": "application/json"}
    data = json.dumps(payload).encode() if payload is not None else None
    result = {"error": "unknown"}
    for attempt in range(3):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore")
            result = {"error": f"HTTP {e.code}", "body": body}
            if e.code == 429 and attempt < 2:
                try:
                    wait = float(e.headers.get("Retry-After", ""))
                except (TypeError, ValueError):
                    wait = 1.5 * (attempt + 1)
                time.sleep(min(max(wait, 0.5), 5.0))
                continue
            return result
        except (urllib.error.URLError, OSError, ValueError) as e:
            return {"error": str(e)}
    return result


def _ok(resp: dict) -> bool:
    return isinstance(resp, dict) and "error" not in resp and resp.get("code", 200) == 200


def control_one(lamp: dict, cap: dict) -> dict:
    payload = {
        "requestId": str(uuid.uuid4()),
        "payload": {"device": lamp["device"], "sku": lamp["sku"], "capability": cap},
    }
    with _govee_lock:
        return _govee_request("POST", "/device/control", payload)


# ---------------------------------------------------------------- cache
_cache_lock = threading.Lock()
_cache = {}  # device -> {"ts", "online", "on", "brightness", "colorTempK", "color"}
_ranges = {}  # device -> (min, max) colour temp


def _fetch_state(lamp: dict) -> dict:
    payload = {"requestId": str(uuid.uuid4()),
               "payload": {"sku": lamp["sku"], "device": lamp["device"]}}
    with _govee_lock:
        resp = _govee_request("POST", "/device/state", payload)
    st = {"ts": time.time(), "online": False, "on": None, "brightness": None,
          "colorTempK": None, "color": None}
    if not _ok(resp):
        return st
    caps = (resp.get("payload") or {}).get("capabilities") or []
    vals = {}
    for c in caps:
        if isinstance(c, dict):
            vals[c.get("instance")] = (c.get("state") or {}).get("value")
    st["online"] = bool(vals.get("online", True))
    if isinstance(vals.get("powerSwitch"), int):
        st["on"] = bool(vals["powerSwitch"])
    if isinstance(vals.get("brightness"), int):
        st["brightness"] = vals["brightness"]
    temp = vals.get("colorTemperatureK")
    rgb = vals.get("colorRgb")
    if isinstance(temp, int) and temp > 0:
        st["colorTempK"] = temp
    elif isinstance(rgb, int) and rgb > 0:
        st["color"] = {"r": (rgb >> 16) & 255, "g": (rgb >> 8) & 255, "b": rgb & 255}
    return st


def _lamp_state(lamp: dict, force=False) -> dict:
    with _cache_lock:
        st = _cache.get(lamp["device"])
    if force or not st or time.time() - st["ts"] > CACHE_TTL:
        st = _fetch_state(lamp)
        with _cache_lock:
            _cache[lamp["device"]] = st
    return st


def _optimistic(lamp: dict, **changes):
    with _cache_lock:
        st = _cache.get(lamp["device"])
        if st is None:
            return  # nothing known; next /state does a real fetch
        st.update(changes)
        st["ts"] = time.time()


def _temp_range(lamp: dict):
    dev = lamp["device"]
    if dev in _ranges:
        return _ranges[dev]
    with _govee_lock:
        resp = _govee_request("GET", "/user/devices")
    if _ok(resp):
        for d in resp.get("data") or []:
            if not isinstance(d, dict):
                continue
            r = DEFAULT_TEMP_RANGE
            for c in d.get("capabilities") or []:
                if c.get("instance") == "colorTemperatureK":
                    rr = (c.get("parameters") or {}).get("range") or {}
                    if isinstance(rr.get("min"), int) and isinstance(rr.get("max"), int):
                        r = (rr["min"], rr["max"])
            _ranges[d.get("device")] = r
    if dev not in _ranges:
        _ranges[dev] = DEFAULT_TEMP_RANGE  # don't hammer the list endpoint
    return _ranges[dev]


# ---------------------------------------------------------------- timer
_timer_lock = threading.Lock()
_timer = None  # {"action","endsAt","cancel": Event}


def _timer_snapshot():
    with _timer_lock:
        if _timer is None:
            return None
        return {"action": _timer["action"], "endsAt": _timer["endsAt"]}


def _timer_worker(t):
    global _timer
    if t["cancel"].wait(max(0.0, t["endsAt"] - time.time())):
        return
    try:
        for lamp in load_lamps():
            r = control_one(lamp, {**CAP_POWER, "value": 0})
            if _ok(r):
                _optimistic(lamp, on=False)
    except Exception:
        pass
    finally:
        with _timer_lock:
            if _timer is t:
                _timer = None


def _set_timer(minutes: int, action: str):
    global _timer
    t = {"action": action, "endsAt": int(time.time() + minutes * 60), "cancel": threading.Event()}
    with _timer_lock:
        if _timer is not None:
            _timer["cancel"].set()
        _timer = t
    threading.Thread(target=_timer_worker, args=(t,), daemon=True).start()


def _cancel_timer():
    global _timer
    with _timer_lock:
        if _timer is not None:
            _timer["cancel"].set()
            _timer = None


# ---------------------------------------------------------------- validation
def _body() -> dict:
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def _as_int(v):
    """int from int or integral numeric string/float; None if invalid. Bools rejected."""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, str):
        try:
            return int(v.strip())
        except ValueError:
            return None
    return None


def _targets(data, lamps):
    """Return (lamps_subset, error_response)."""
    sel = data.get("lamp", "all")
    if sel == "all":
        return lamps, None
    if isinstance(sel, bool) or not isinstance(sel, int):
        return None, (jsonify({"error": "lamp must be 'all' or an integer index"}), 400)
    if not 0 <= sel < len(lamps):
        return None, (jsonify({"error": f"lamp index out of range (0-{len(lamps) - 1})"}), 400)
    return [lamps[sel]], None


def _apply(lamps, cap, **opt):
    """Sequentially send cap to lamps; update cache on success. Returns responses."""
    out = []
    for lamp in lamps:
        r = control_one(lamp, cap)
        if _ok(r):
            _optimistic(lamp, **opt)
        out.append(r)
    return out


# ---------------------------------------------------------------- routes
@app.route("/api/lights/ping", methods=["GET"])
def api_ping():
    return jsonify({"ok": True})


@app.route("/api/lights/state", methods=["GET"])
def api_state():
    lamps = load_lamps()
    out = []
    for i, lamp in enumerate(lamps):
        st = _lamp_state(lamp)
        out.append({"index": i, "name": lamp["name"], "online": st["online"], "on": st["on"],
                    "brightness": st["brightness"], "colorTempK": st["colorTempK"],
                    "color": st["color"]})
    return jsonify({"ok": True, "updatedAt": int(time.time()), "timer": _timer_snapshot(),
                    "lamps": out})


@app.route("/api/lights/power", methods=["POST"])
def api_power():
    data = _body()
    value = data.get("value")
    if value not in ("on", "off"):
        return jsonify({"error": "value must be 'on' or 'off'"}), 400
    lamps, err = _targets(data, load_lamps())
    if err:
        return err
    on = value == "on"
    return jsonify({"ok": True, "responses": _apply(lamps, {**CAP_POWER, "value": 1 if on else 0}, on=on)})


@app.route("/api/lights/brightness", methods=["POST"])
def api_brightness():
    data = _body()
    val = _as_int(data.get("value"))
    if val is None:
        return jsonify({"error": "value must be integer 1-100"}), 400
    if not 1 <= val <= 100:
        return jsonify({"error": "value must be 1-100"}), 400
    lamps, err = _targets(data, load_lamps())
    if err:
        return err
    return jsonify({"ok": True, "responses": _apply(lamps, {**CAP_BRIGHT, "value": val}, brightness=val)})


@app.route("/api/lights/preset", methods=["POST"])
def api_preset():
    data = _body()
    preset = data.get("value")
    presets = {"bright_white_cool": (6500, 100), "bright_white_warm": (3000, 80)}
    if preset not in presets:
        return jsonify({"error": "unknown preset"}), 400
    temp, bright = presets[preset]
    lamps, err = _targets(data, load_lamps())
    if err:
        return err
    resps = [
        _apply(lamps, {**CAP_TEMP, "value": temp}, colorTempK=temp, color=None),
        _apply(lamps, {**CAP_BRIGHT, "value": bright}, brightness=bright),
    ]
    return jsonify({"ok": True, "responses": resps})


@app.route("/api/lights/colortemp", methods=["POST"])
def api_colortemp():
    data = _body()
    val = _as_int(data.get("value"))
    if val is None or not 2000 <= val <= 9000:
        return jsonify({"error": "value must be integer 2000-9000"}), 400
    lamps, err = _targets(data, load_lamps())
    if err:
        return err
    out, applied = [], []
    for lamp in lamps:
        lo, hi = _temp_range(lamp)
        v = max(lo, min(hi, val))
        r = control_one(lamp, {**CAP_TEMP, "value": v})
        if _ok(r):
            _optimistic(lamp, colorTempK=v, color=None)
        out.append(r)
        applied.append(v)
    return jsonify({"ok": True, "applied": applied, "responses": out})


@app.route("/api/lights/color", methods=["POST"])
def api_color():
    data = _body()
    chans = []
    for k in ("r", "g", "b"):
        v = _as_int(data.get(k))
        if v is None or not 0 <= v <= 255:
            return jsonify({"error": "r, g, b must be integers 0-255"}), 400
        chans.append(v)
    lamps, err = _targets(data, load_lamps())
    if err:
        return err
    r, g, b = chans
    packed = (r << 16) + (g << 8) + b
    resps = _apply(lamps, {**CAP_RGB, "value": packed}, color={"r": r, "g": g, "b": b}, colorTempK=None)
    return jsonify({"ok": True, "responses": resps})


@app.route("/api/lights/timer", methods=["POST"])
def api_timer():
    data = _body()
    if data.get("cancel") is True:
        _cancel_timer()
        return jsonify({"ok": True, "timer": None})
    if "cancel" in data and data["cancel"] is not False:
        return jsonify({"error": "cancel must be true"}), 400
    minutes = _as_int(data.get("minutes"))
    if minutes is None or not 1 <= minutes <= 720:
        return jsonify({"error": "minutes must be integer 1-720"}), 400
    action = data.get("action", "off")
    if action != "off":
        return jsonify({"error": "action must be 'off'"}), 400
    load_lamps()  # fail early with 503 if unconfigured
    _set_timer(minutes, action)
    return jsonify({"ok": True, "timer": _timer_snapshot()})


if __name__ == "__main__":
    # Only reachable locally; Tailscale Serve provides HTTPS on the tailnet.
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "5000")))
