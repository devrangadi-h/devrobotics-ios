#!/usr/bin/env python3
"""polaris-app-api: backend for the DevRobotics iPhone app.

Listens on 127.0.0.1 only; Tailscale Serve exposes it to the tailnet over HTTPS.
Auth: the same bearer token as the lights API (header or `polaris_token` cookie,
the cookie being what lets a WKWebView load preview CSS/JS/images).

Everything lives outside the site repo (STATE) so nothing here is ever published.
"""
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from flask import Flask, Response, abort, jsonify, request, send_file, send_from_directory

HOME = Path.home()
TOKEN_PATH = Path(os.environ.get("POLARIS_TOKEN_PATH", HOME / ".config/polaris/lights_token"))
INBOX = Path(os.environ.get("FRAMES_INBOX", HOME / "frames-inbox"))
SITE = Path(os.environ.get("SITE_REPO", HOME / "devrobotics-site"))
FRAMES_PY = SITE / "_tools/frames/frames.py"
FRAMES_PYTHON = HOME / "frames-tools/.venv/bin/python"
STATE = Path(os.environ.get("APP_STATE", HOME / "polaris-app-state"))
SCRATCH = STATE / "preview-site"
THUMBS = STATE / "thumbs"
BLOBS = STATE / "blobs"
DRAFTS = STATE / "drafts"
LOCK_PATH = STATE / ".job.lock"
CACHE_CAP = int(os.environ.get("APP_CACHE_CAP_BYTES", 2 * 1024 ** 3))
THUMBS_CAP = int(os.environ.get("APP_THUMBS_CAP_BYTES", 512 * 1024 ** 2))
MAX_DRAFTS = int(os.environ.get("APP_MAX_DRAFTS", "3"))
DRAFT_TTL = int(os.environ.get("APP_DRAFT_TTL_SECONDS", str(24 * 3600)))
SERVER_VERSION = "polaris-app-api 1.1.0"
SERVICES = ["lights-api.service", "local-chat-ui.service", "flower-tracker.timer", "polaris-app-api.service"]

SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
IMAGE_EXT = {".jpg", ".jpeg", ".heic", ".heif"}
CLIP_EXT = {".mp4", ".mov"}
PHOTO_ORDER = ["place", "gps", "alt", "focus", "date"]
STORY_ORDER = ["title", "place", "cover", "gps", "date", "summary", "alt"]
KINDS = {"photo": ("photos", "photo.md", PHOTO_ORDER), "story": ("stories", "story.md", STORY_ORDER)}

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
STATE.mkdir(parents=True, exist_ok=True)
THUMBS.mkdir(parents=True, exist_ok=True)
SCRATCH.mkdir(parents=True, exist_ok=True)
BLOBS.mkdir(parents=True, exist_ok=True)
DRAFTS.mkdir(parents=True, exist_ok=True)


# ---------- auth ----------

def _token() -> str:
    return TOKEN_PATH.read_text().strip()


@app.before_request
def require_token():
    sent = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not sent:
        sent = request.cookies.get("polaris_token", "")
    if not sent or not hmac.compare_digest(sent, _token()):
        return jsonify({"error": "unauthorized"}), 401


# ---------- helpers ----------

def err(msg, code=400, **extra):
    return jsonify({"error": msg, **extra}), code


def entry_dir(kind, slug) -> Path:
    if kind not in KINDS:
        abort(404)
    if not SLUG_RE.match(slug):
        abort(400, "bad slug")
    return INBOX / KINDS[kind][0] / slug


def safe_name(name: str) -> str:
    n = os.path.basename(name or "").strip()
    n = re.sub(r"[^A-Za-z0-9._ -]", "_", n)
    if not n or n.startswith(".") or Path(n).suffix.lower() not in IMAGE_EXT | CLIP_EXT:
        raise ValueError(f"unsupported file name: {name!r}")
    return n


def one_line(v) -> str:
    return re.sub(r"\s+", " ", str(v)).strip()


def render_md(kind, fields, body) -> str:
    out = ["---"]
    for k in KINDS[kind][2]:
        v = fields.get(k)
        if v is not None and one_line(v) != "":
            out.append(f"{k}: {one_line(v)}")
    out.append("---")
    return "\n".join(out) + "\n" + (body or "").strip("\n") + "\n"


def parse_md(text: str):
    lines = text.splitlines()
    fields, body = {}, []
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            ln = lines[i]
            if ln.strip() and not ln.lstrip().startswith("#") and ":" in ln:
                k, v = ln.split(":", 1)
                fields[k.strip()] = v.strip()
            i += 1
        body = lines[i + 1:]
    else:
        body = lines
    return fields, "\n".join(body).strip("\n")


def entry_files(folder: Path, md_name: str):
    out = []
    for p in sorted(folder.iterdir()):
        if p.name == md_name or p.name.startswith("."):
            continue
        ext = p.suffix.lower()
        if ext in IMAGE_EXT:
            t = "image"
        elif ext in CLIP_EXT:
            t = "clip"
        else:
            continue
        out.append({"name": p.name, "type": t, "size": p.stat().st_size})
    return out


def published_slugs():
    return set(load_items(SITE / "frames.json").keys())


def read_entry(kind, slug, with_body=True):
    folder = entry_dir(kind, slug)
    md = folder / KINDS[kind][1]
    if not md.exists():
        return None
    fields, body = parse_md(md.read_text(errors="replace"))
    e = {
        "kind": kind,
        "slug": slug,
        "fields": fields,
        "files": entry_files(folder, KINDS[kind][1]),
        "modified": int(max([md.stat().st_mtime] + [p.stat().st_mtime for p in folder.iterdir()])),
    }
    if with_body:
        e["body"] = body
    return e


def load_items(path: Path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return {(i.get("type"), i.get("slug")): i for i in data.get("items", [])}


def diff_items(new, old):
    changes = []
    for k, v in new.items():
        if k not in old:
            changes.append({"change": "new", "kind": k[0], "slug": k[1]})
        elif v != old[k]:
            changes.append({"change": "changed", "kind": k[0], "slug": k[1]})
    for k in old:
        if k not in new:
            changes.append({"change": "removed", "kind": k[0], "slug": k[1]})
    return changes


# ---------- jobs ----------

JOBS = {}
BUSY = threading.Lock()


class JobFailed(Exception):
    """Raised by a job to fail with a structured result (e.g. draft-preview issues)."""

    def __init__(self, msg, result=None):
        super().__init__(msg)
        self.result = result


class Job:
    def __init__(self, kind):
        self.id = uuid.uuid4().hex[:12]
        self.kind = kind
        self.state = "running"
        self.log = []
        self.result = None
        self.started = time.time()
        self.finished = None

    def line(self, s):
        self.log.append(s.rstrip())
        del self.log[:-400]

    def run(self, cmd, cwd=None, check=True, env=None):
        self.line("$ " + " ".join(str(c) for c in cmd))
        p = subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for ln in p.stdout:
            self.line(ln)
        rc = p.wait()
        if check and rc != 0:
            raise RuntimeError(f"command failed ({rc}): {' '.join(str(c) for c in cmd)}")
        return rc

    def json(self, with_log=True):
        d = {"id": self.id, "kind": self.kind, "state": self.state, "result": self.result,
             "started": int(self.started), "finished": int(self.finished) if self.finished else None}
        if with_log:
            d["log"] = self.log[-120:]
        return d


def start_job(kind, fn):
    if not BUSY.acquire(blocking=False):
        return None

    job = Job(kind)
    JOBS[job.id] = job
    for old in sorted(JOBS.values(), key=lambda j: j.started)[:-10]:
        JOBS.pop(old.id, None)

    def runner():
        lock = None
        try:
            # cross-process lock so the daily purge timer never deletes under a running job
            lock = open(LOCK_PATH, "w")
            fcntl.flock(lock, fcntl.LOCK_EX)
            job.result = fn(job)
            job.state = "done"
        except Exception as e:  # noqa: BLE001
            job.line(f"ERROR: {e}")
            job.state = "failed"
            job.result = getattr(e, "result", None) or {"error": str(e)}
        finally:
            job.finished = time.time()
            if lock:
                lock.close()
            BUSY.release()

    threading.Thread(target=runner, daemon=True).start()
    return job


def validate_inbox():
    p = subprocess.run([str(FRAMES_PY), "validate", "--inbox", str(INBOX)], capture_output=True, text=True, cwd=SITE)
    lines = [l for l in (p.stdout + p.stderr).splitlines() if l.strip()]
    return p.returncode == 0, lines


def preview_job(job: Job):
    ok, lines = validate_inbox()
    for l in lines:
        job.line(l)
    if not ok:
        raise RuntimeError("inbox has errors; fix them first")
    # Copy the site into a scratch dir (never touch the real worktree). _media is kept
    # between runs so the incremental build cache works.
    job.run(["rsync", "-a", "--delete", "--exclude", ".git", "--exclude", "_media", "--exclude", "TODO.md",
             f"{SITE}/", f"{SCRATCH}/"])
    job.run([FRAMES_PY, "build", "--repo", SCRATCH, "--inbox", INBOX, "--jobs", "2"], cwd=SITE)
    changes = diff_items(load_items(SCRATCH / "frames.json"), load_items(SITE / "frames.json"))
    return {"changes": changes, "builtAt": int(time.time())}


def git(job, *args, check=True):
    return job.run(["git", *args], cwd=SITE, check=check)


def publish_job(job: Job):
    ok, lines = validate_inbox()
    for l in lines:
        job.line(l)
    if not ok:
        raise RuntimeError("inbox has errors; fix them first")
    before = load_items(SITE / "frames.json")
    tracked = ["frames.json", "frames.html", "frames", "polaris-log.json"]
    try:
        # media build + R2 upload first, so pages never point at missing files
        job.run([FRAMES_PY, "publish"], cwd=SITE)
        changes = diff_items(load_items(SITE / "frames.json"), before)
        if not changes:
            job.line("nothing changed; nothing to publish")
            git(job, "checkout", "--", "frames.json", "frames.html", "frames", check=False)
            return {"changes": [], "pushed": False}
        parts = []
        for c in changes:
            parts.append(f"{c['change']} {c['kind']} {c['slug']}")
        summary = "Published Frames from iPhone: " + ", ".join(parts)
        log_path = SITE / "polaris-log.json"
        log = json.loads(log_path.read_text())
        now = dt.datetime.now()
        log.append({
            "date": now.strftime("%Y-%m-%d"),
            "time": now.strftime("%H:%M"),
            "summary": summary,
            "details": "Published from the DevRobotics iPhone app: " + ", ".join(parts) + ".",
            "files": ["frames.json", "frames.html"],
        })
        log_path.write_text(json.dumps(log, indent=2, ensure_ascii=False) + "\n")
        git(job, "add", "--", *tracked)
        git(job, "commit", "-m", summary, "--", *tracked)
    except Exception:
        git(job, "checkout", "--", "frames.json", "frames.html", "frames", "polaris-log.json", check=False)
        git(job, "clean", "-fdq", "--", "frames", check=False)
        raise
    # push; the Pi status updater pushes to main too, so rebase on rejection
    for attempt in range(1, 4):
        if git(job, "push", "origin", "main", check=False) == 0:
            return {"changes": changes, "pushed": True}
        git(job, "pull", "--rebase", "--autostash", "origin", "main", check=False)
        time.sleep(2 * attempt)
    raise RuntimeError("committed locally but push failed; it will go out with the next publish")


# ---------- status ----------

def read_text(p, default=""):
    try:
        return Path(p).read_text()
    except OSError:
        return default


def cpu_percent():
    def snap():
        v = [int(x) for x in read_text("/proc/stat").splitlines()[0].split()[1:]]
        return sum(v), v[3] + v[4]
    t1, i1 = snap()
    time.sleep(0.25)
    t2, i2 = snap()
    return round(100 * (1 - (i2 - i1) / max(t2 - t1, 1)), 1)


def service_state(name):
    p = subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True)
    return p.stdout.strip() or "unknown"


@app.get("/v1/status")
def status():
    mem = {}
    for ln in read_text("/proc/meminfo").splitlines():
        k, _, v = ln.partition(":")
        mem[k] = int(v.split()[0]) * 1024 if v.split() else 0
    total, free = mem.get("MemTotal", 0), mem.get("MemAvailable", 0)
    du = shutil.disk_usage("/")
    temp = read_text("/sys/class/thermal/thermal_zone0/temp").strip()
    l1, l5, l15 = os.getloadavg()
    pub = {}
    try:
        pub = json.loads(read_text(SITE / "polaris-pi-status.json", "{}"))
    except ValueError:
        pass
    last_log = None
    try:
        last_log = json.loads(read_text(SITE / "polaris-log.json", "[]"))[-1]
    except (ValueError, IndexError):
        pass
    last_pub = None
    try:
        last_pub = json.loads(read_text(SITE / "frames.json", "{}")).get("generated")
    except ValueError:
        pass
    return jsonify({
        "piOnline": True,
        "hostname": os.uname().nodename,
        "lastUpdated": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "cpuTempC": round(int(temp) / 1000, 1) if temp.isdigit() else None,
        "load1": round(l1, 2), "load5": round(l5, 2), "load15": round(l15, 2),
        "cpuPercent": cpu_percent(),
        "memory": {"usedBytes": total - free, "totalBytes": total},
        "disk": {"usedBytes": du.used, "totalBytes": du.total},
        "uptimeSeconds": int(float(read_text("/proc/uptime", "0").split()[0])),
        "history": pub.get("history", []),
        "services": [{"name": s.removesuffix(".service"), "state": service_state(s)} for s in SERVICES],
        "lastPublish": last_pub,
        "lastLog": last_log,
        "busy": BUSY.locked(),
        "kernel": os.uname().release,
        "serverVersion": SERVER_VERSION,
    })


# ---------- fan ----------
# The root helper does the writing (sudoers allows only that one command). All safety rules live HERE and again in the
# helper. An override is: mode manual|max + an end time. A watchdog thread ends it on time, ends Max early when the Pi
# has been cool, and re-applies it every FAN_REAPPLY_S; the helper has its own root timer as a last resort.

FAN_HELPER = os.environ.get("FAN_HELPER", "/usr/local/sbin/polaris-fan")
FAN_MINUTE = float(os.environ.get("FAN_TEST_SECONDS_PER_MINUTE", "60"))   # test hook; 60 in production
FAN_TEMP_FILE = os.environ.get("FAN_TEST_TEMP_FILE", "")                  # test hook; unset in production
FAN_COOL_S = float(os.environ.get("FAN_TEST_COOL_SECONDS", "30"))          # Max ends after this long below 50 C
FAN_TICK_S = float(os.environ.get("FAN_TEST_TICK_SECONDS", "1"))
FAN_REAPPLY_S = float(os.environ.get("FAN_TEST_REAPPLY_SECONDS", "10"))
FAN_FORCE_AUTO_C, FAN_FLOOR_C, FAN_NONZERO_C = 75.0, 65.0, 50.0
FAN_FLOOR_PCT, FAN_NONZERO_PCT = 50, 30
FAN_DEFAULT_MIN = {"manual": 30, "max": 15}
FAN_LOCK = threading.RLock()
FAN = {"mode": "auto", "percent": None, "until": None, "cool_since": None, "applied_at": 0.0}


def fan_log(msg):
    print(f"fan: {msg}", file=sys.stderr, flush=True)


def fan_hwmon():
    for d in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
        if read_text(d / "name").strip() == "pwmfan":
            return d
    return None


def fan_temp():
    if FAN_TEMP_FILE:
        try:
            return float(Path(FAN_TEMP_FILE).read_text().strip())
        except (OSError, ValueError):
            return None
    t = read_text("/sys/class/thermal/thermal_zone0/temp").strip()
    return int(t) / 1000 if t.isdigit() else None


def fan_pwm_for(percent):
    return int(percent * 255 / 100 + 0.5)


def fan_min_percent(temp):
    """Minimum fan percent allowed at this temperature; None means 'must be automatic' (hot or unreadable)."""
    if temp is None or temp >= FAN_FORCE_AUTO_C:
        return None
    if temp > FAN_FLOOR_C:
        return FAN_FLOOR_PCT
    if temp > FAN_NONZERO_C:
        return FAN_NONZERO_PCT
    return 0


def fan_helper(*args):
    """Run the root helper. Returns (ok, parsed-json-or-None)."""
    try:
        p = subprocess.run(["sudo", "-n", FAN_HELPER, *[str(a) for a in args]],
                           capture_output=True, text=True, timeout=15)
        try:
            data = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else None
        except ValueError:
            data = None
        return p.returncode == 0, data
    except (OSError, subprocess.SubprocessError) as e:
        fan_log(f"helper error: {e}")
        return False, None


def fan_available():
    return fan_hwmon() is not None and os.access(FAN_HELPER, os.X_OK)


def fan_to_auto(reason):
    with FAN_LOCK:
        ok, _ = fan_helper("auto")
        was = FAN["mode"]
        FAN.update(mode="auto", percent=None, until=None, cool_since=None)
        fan_log(f"auto ({reason}; was {was}; helper {'ok' if ok else 'FAILED'})")
        return ok


def fan_apply_locked(temp):
    """Push the current override to the hardware, honouring the floors. Returns False if it fell back to auto."""
    if FAN["mode"] == "auto":
        return True
    floor = fan_min_percent(temp)
    if floor is None:
        fan_to_auto(f"temperature {temp} C")
        return False
    secs = max(5, int(FAN["until"] - time.time()) + 60)   # the root-side backstop outlives ours
    if FAN["mode"] == "max":
        ok, _ = fan_helper("max", secs)
    else:
        ok, _ = fan_helper("set", fan_pwm_for(max(FAN["percent"], floor)), secs)
    if not ok:
        fan_to_auto("helper refused or failed")
        return False
    FAN["applied_at"] = time.monotonic()
    return True


def fan_snapshot():
    h = fan_hwmon()
    temp = fan_temp()
    pwm = rpm = None
    if h:
        try:
            pwm = int(read_text(h / "pwm1").strip())
            rpm = int(read_text(h / "fan1_input").strip())
        except ValueError:
            pass
    with FAN_LOCK:
        mode, until = FAN["mode"], FAN["until"]
    floor = fan_min_percent(temp) if mode != "auto" else None
    return {"available": fan_available(), "mode": mode,
            "percent": round(pwm * 100 / 255) if pwm is not None else None, "rpm": rpm,
            "tempC": round(temp, 1) if temp is not None else None,
            "revertsAt": int(until) if until else None,
            "minPercent": floor if floor else None}


def fan_wait_spinup(timeout=3.0):
    """Right after a hold is applied the tachometer reads 0 for a second or two. Wait (bounded) for a real
    reading so the reply carries it instead of a misleading 0 RPM."""
    h = fan_hwmon()
    if not h:
        return
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if int(read_text(h / "fan1_input").strip()) > 0:
                return
        except (ValueError, OSError):
            return
        time.sleep(0.25)


def fan_watchdog():
    while True:
        time.sleep(FAN_TICK_S)
        try:
            with FAN_LOCK:
                if FAN["mode"] == "auto":
                    continue
                now = time.time()
                temp = fan_temp()
                if FAN["until"] and now >= FAN["until"]:
                    fan_to_auto("timer ended")
                elif temp is None or temp >= FAN_FORCE_AUTO_C:
                    fan_to_auto(f"temperature {temp} C")
                elif FAN["mode"] == "max" and temp < FAN_NONZERO_C:
                    FAN["cool_since"] = FAN["cool_since"] or now
                    if now - FAN["cool_since"] >= FAN_COOL_S:
                        fan_to_auto(f"max ended early, {temp} C for {FAN_COOL_S:.0f}s")
                else:
                    FAN["cool_since"] = None
                    if time.monotonic() - FAN["applied_at"] >= FAN_REAPPLY_S:
                        fan_apply_locked(temp)
        except Exception as e:  # the watchdog must never die
            fan_log(f"watchdog error: {e}")
            try:
                fan_to_auto("watchdog error")
            except Exception:
                pass


@app.get("/v1/fan")
def fan_get():
    return jsonify(fan_snapshot())


@app.post("/v1/fan")
def fan_post():
    if not fan_available():
        return err("fan control unavailable", 503)
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return err("JSON object expected")
    mode = body.get("mode")
    if mode not in ("auto", "manual", "max"):
        return err("mode must be auto, manual or max")
    if mode == "auto":
        if not fan_to_auto("requested"):
            return err("could not set automatic", 503)
        return jsonify(fan_snapshot())
    minutes = body.get("minutes", FAN_DEFAULT_MIN[mode])
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)):
        return err("minutes must be a number")
    minutes = min(120, max(1, minutes))
    percent = 100
    if mode == "manual":
        percent = body.get("percent")
        if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not 0 <= percent <= 100:
            return err("percent must be 0-100")
        percent = int(round(percent))
    with FAN_LOCK:
        temp = fan_temp()
        if fan_min_percent(temp) is None:
            fan_to_auto(f"refused {mode}: {temp} C")
            return err("too hot or temperature unreadable; staying on automatic", 409, tempC=temp)
        FAN.update(mode=mode, percent=percent, until=time.time() + minutes * FAN_MINUTE, cool_since=None)
        if not fan_apply_locked(temp):
            return err("fan helper failed; back on automatic", 503)
        fan_log(f"{mode} {percent}% for {minutes:g} min at {temp} C")
    if percent > 0:
        fan_wait_spinup()   # outside the lock: let the tach report a real RPM before we answer
    return jsonify(fan_snapshot())


def fan_start():
    """Fail-safe: whatever the previous process left behind, begin on automatic, and start the watchdog."""
    if fan_available():
        ok, _ = fan_helper("auto")
        fan_log(f"service start: reset to automatic ({'ok' if ok else 'FAILED'})")
    threading.Thread(target=fan_watchdog, daemon=True, name="fan-watchdog").start()

    def bye(*_):
        fan_helper("auto")
        os._exit(0)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, bye)


# ---------- frames: entries ----------

@app.get("/v1/frames/entries")
def list_entries():
    pub = published_slugs()
    out = []
    for kind, (sub, _md, _o) in KINDS.items():
        base = INBOX / sub
        if not base.is_dir():
            continue
        for d in sorted(base.iterdir()):
            if d.is_dir() and not d.name.startswith(("_", ".")):
                e = read_entry(kind, d.name, with_body=False)
                if e:
                    e["published"] = (kind, d.name) in pub
                    out.append(e)
    return jsonify({"entries": out})


@app.get("/v1/frames/<kind>/<slug>")
def get_entry(kind, slug):
    e = read_entry(kind, slug)
    if not e:
        return err("not found", 404)
    e["published"] = (kind, slug) in published_slugs()
    return jsonify(e)


@app.put("/v1/frames/<kind>/<slug>")
def put_entry(kind, slug):
    folder = entry_dir(kind, slug)
    md_name = KINDS[kind][1]
    creating = request.args.get("create") == "1"
    if creating and folder.exists():
        return err("an entry with that slug already exists", 409)
    if not creating and not folder.exists():
        return err("not found", 404)
    try:
        meta = json.loads(request.form.get("meta", "{}"))
        uploads = []
        for f in request.files.getlist("files"):
            uploads.append((safe_name(f.filename), f))
        delete = [safe_name(n) for n in meta.get("deleteFiles", [])]
    except (ValueError, TypeError) as e:
        return err(str(e))
    if kind == "photo":
        imgs = [n for n, _ in uploads if Path(n).suffix.lower() in IMAGE_EXT]
        if len(imgs) > 1:
            return err("a photo takes exactly one image")
        if imgs:  # replacing the image
            delete += [f["name"] for f in entry_files(folder, md_name)] if folder.exists() else []
    folder.mkdir(parents=True, exist_ok=True)
    keep = {n for n, _ in uploads}
    for n in delete:
        if n not in keep:
            (folder / n).unlink(missing_ok=True)
    for n, f in uploads:
        tmp = folder / f".{n}.part"
        f.save(tmp)
        tmp.replace(folder / n)
    (folder / md_name).write_text(render_md(kind, meta.get("fields", {}), meta.get("body", "")))
    ok, lines = validate_inbox()
    prefix = f"{KINDS[kind][0]}/{slug}/"
    mine = [l for l in lines if re.search(r"(?:^|\s)" + re.escape(prefix), l)]
    return jsonify({"ok": True, "valid": ok or not mine, "problems": mine})


@app.delete("/v1/frames/<kind>/<slug>")
def delete_entry(kind, slug):
    folder = entry_dir(kind, slug)
    if not folder.is_dir():
        return err("not found", 404)
    shutil.rmtree(folder)
    return jsonify({"ok": True})


@app.get("/v1/frames/<kind>/<slug>/thumb/<name>")
def thumb(kind, slug, name):
    folder = entry_dir(kind, slug)
    try:
        name = safe_name(name)
    except ValueError:
        abort(400)
    src = folder / name
    if not src.is_file():
        abort(404)
    w = max(64, min(int(request.args.get("w", 600)), 1600))
    st = src.stat()
    key = hashlib.sha1(f"{src}|{st.st_mtime_ns}|{st.st_size}|{w}".encode()).hexdigest()
    dst = THUMBS / f"{key}.jpg"
    if dst.exists():
        try:
            os.utime(dst)  # LRU
        except OSError:
            pass
    else:
        tmp = THUMBS / f"{key}.tmp.jpg"
        if src.suffix.lower() in CLIP_EXT:
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vframes", "1", "-vf", f"scale={w}:-2", str(tmp)]
        else:
            code = ("import sys;from PIL import Image,ImageOps;import pillow_heif;pillow_heif.register_heif_opener();"
                    "im=ImageOps.exif_transpose(Image.open(sys.argv[1])).convert('RGB');im.thumbnail((int(sys.argv[3]),)*2);"
                    "im.save(sys.argv[2],'JPEG',quality=80)")
            cmd = [str(FRAMES_PYTHON), "-I", "-c", code, str(src), str(tmp), str(w)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not tmp.exists():
            return err("thumbnail failed", 500, detail=r.stderr[-300:])
        tmp.replace(dst)
        global THUMB_CREATED
        THUMB_CREATED += 1
        if THUMB_CREATED % 25 == 0:
            trim_dir_lru(THUMBS, THUMBS_CAP)
    return send_from_directory(THUMBS, dst.name, mimetype="image/jpeg", max_age=86400)


# ---------- frames: clip info + streamed preview ----------

CLIP_WAIT = float(os.environ.get("APP_CLIP_WAIT_SECONDS", "20"))   # how long a request waits for a transcode
CLIP_TIMEOUT = int(os.environ.get("APP_CLIP_TIMEOUT_SECONDS", "600"))
CLIP_MAX_SOURCE = int(os.environ.get("APP_CLIP_MAX_SOURCE_BYTES", str(1024 ** 3)))
_clip_gen = threading.Semaphore(1)       # one ffmpeg preview at a time
_clip_state_lock = threading.Lock()
_clip_inflight = {}                      # cache key -> threading.Event
_clip_failed = {}                        # cache key -> error text
_clipinfo_cache = {}                     # (path, mtime_ns, size) -> dict


def _clip_source(kind, slug, name):
    folder = entry_dir(kind, slug)
    try:
        name = safe_name(name)
    except ValueError:
        abort(400)
    src = folder / name
    if src.suffix.lower() not in CLIP_EXT:
        abort(400)
    if not src.is_file():
        abort(404)
    return src


@app.get("/v1/frames/<kind>/<slug>/clipinfo/<name>")
def clipinfo(kind, slug, name):
    src = _clip_source(kind, slug, name)
    st = src.stat()
    key = (str(src), st.st_mtime_ns, st.st_size)
    info = _clipinfo_cache.get(key)
    if info is None:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=width,height:stream_tags=rotate:stream_side_data=rotation:format=duration",
             "-of", "json", str(src)], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return err("probe failed", 500, detail=r.stderr[-300:])
        try:
            j = json.loads(r.stdout)
            stream = (j.get("streams") or [{}])[0]
            w, h = int(stream.get("width", 0)), int(stream.get("height", 0))
            rot = 0
            for sd in stream.get("side_data_list", []) or []:
                if "rotation" in sd:
                    rot = int(float(sd["rotation"]))
            rot = rot or int(stream.get("tags", {}).get("rotate", 0) or 0)
            if abs(rot) % 180 == 90:
                w, h = h, w
            dur = float(j.get("format", {}).get("duration", 0) or 0)
        except (ValueError, KeyError, IndexError):
            return err("probe failed", 500)
        info = {"durationSeconds": round(dur, 2), "width": w, "height": h, "sizeBytes": st.st_size}
        if len(_clipinfo_cache) > 512:
            _clipinfo_cache.clear()
        _clipinfo_cache[key] = info
    return jsonify(info)


def _transcode_clip(key, src: Path, dst: Path):
    tmp = THUMBS / f"{key}.tmp.mp4"
    try:
        with _clip_gen:
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-an",
                   "-vf", "scale='if(gt(iw,ih),min(720,iw),-2)':'if(gt(iw,ih),-2,min(720,ih))',format=yuv420p",
                   "-c:v", "libx264", "-preset", "veryfast", "-b:v", "1500k", "-maxrate", "2M", "-bufsize", "3M",
                   "-movflags", "+faststart", "-f", "mp4", str(tmp)]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=CLIP_TIMEOUT)
        if r.returncode != 0 or not tmp.exists():
            _clip_failed[key] = r.stderr[-300:] or "ffmpeg failed"
        else:
            tmp.replace(dst)
    except Exception as e:  # timeout etc.
        _clip_failed[key] = str(e)[:300]
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass
        with _clip_state_lock:
            ev = _clip_inflight.pop(key, None)
        if ev:
            ev.set()


@app.get("/v1/frames/<kind>/<slug>/clip/<name>")
def clip(kind, slug, name):
    src = _clip_source(kind, slug, name)
    st = src.stat()
    if st.st_size > CLIP_MAX_SOURCE:
        return err("clip too large for preview", 413)
    key = hashlib.sha1(f"clip|{src}|{st.st_mtime_ns}|{st.st_size}".encode()).hexdigest()
    dst = THUMBS / f"{key}.mp4"
    if not dst.exists():
        with _clip_state_lock:
            ev = _clip_inflight.get(key)
            if ev is None and not dst.exists():
                _clip_failed.pop(key, None)
                ev = threading.Event()
                _clip_inflight[key] = ev
                threading.Thread(target=_transcode_clip, args=(key, src, dst), daemon=True).start()
        if ev is not None:
            ev.wait(CLIP_WAIT)
        if not dst.exists():
            if key in _clip_failed:
                return err("preview failed", 500, detail=_clip_failed[key])
            resp = jsonify({"status": "preparing", "retryAfter": 5})
            resp.status_code = 202
            resp.headers["Retry-After"] = "5"
            return resp
    try:
        os.utime(dst)  # LRU
    except OSError:
        pass
    return send_file(dst, mimetype="video/mp4", conditional=True, max_age=3600)


# ---------- frames: preview + publish ----------

def job_or_busy(kind, fn):
    job = start_job(kind, fn)
    if job is None:
        return err("Polaris is busy with another job; try again in a minute", 409)
    return jsonify(job.json()), 202


@app.post("/v1/frames/preview")
def preview():
    return job_or_busy("preview", preview_job)


@app.post("/v1/frames/publish")
def publish():
    return job_or_busy("publish", publish_job)


@app.get("/v1/jobs/<job_id>")
def job_status(job_id):
    job = JOBS.get(job_id)
    if not job:
        return err("unknown job", 404)
    return jsonify(job.json())


# ---------- cache accounting + purge ----------

THUMB_CREATED = 0
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
DRAFT_ID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
ACTIVE_DRAFT = None  # draftId currently being built (set while BUSY is held)


def dir_usage(path: Path, seen: set) -> int:
    """Bytes under path, counting each inode once across calls sharing `seen` (hardlinks are free)."""
    total = 0
    stack = [str(path)]
    while stack:
        d = stack.pop()
        try:
            it = list(os.scandir(d))
        except OSError:
            continue
        for e in it:
            try:
                if e.is_symlink():
                    continue
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                    continue
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            k = (st.st_dev, st.st_ino)
            if k not in seen:
                seen.add(k)
                total += st.st_size
    return total


def read_draft_meta(d: Path) -> dict:
    try:
        m = json.loads((d / "meta.json").read_text())
    except (OSError, ValueError):
        m = {}
    if not isinstance(m, dict):
        m = {}
    try:  # serving a draft touches meta.json, so its mtime counts as use
        mt = (d / "meta.json").stat().st_mtime
    except OSError:
        mt = 0
    lu = m.get("lastUsed") if isinstance(m.get("lastUsed"), (int, float)) else 0
    m["lastUsed"] = max(lu, mt)
    if not m["lastUsed"]:
        try:
            m["lastUsed"] = d.stat().st_mtime
        except OSError:
            pass
    if not isinstance(m.get("blobs"), list):
        m["blobs"] = []
    return m


def write_draft_meta(draft_id, meta):
    p = DRAFTS / draft_id / "meta.json"
    tmp = p.with_name("meta.json.tmp")
    tmp.write_text(json.dumps(meta))
    tmp.replace(p)


def list_drafts():
    out = []
    if DRAFTS.is_dir():
        for d in DRAFTS.iterdir():
            if d.is_dir() and DRAFT_ID_RE.match(d.name):
                out.append((d.name, read_draft_meta(d)))
    return out


def cache_usage() -> dict:
    seen = set()
    parts = {}
    parts["previewSite"] = dir_usage(SCRATCH, seen)  # first, so hardlinked media is counted here once
    parts["blobs"] = dir_usage(BLOBS, seen)
    parts["thumbs"] = dir_usage(THUMBS, seen)
    parts["drafts"] = dir_usage(DRAFTS, seen)
    return {"usedBytes": sum(parts.values()), "capBytes": CACHE_CAP, "parts": parts, "draftCount": len(list_drafts())}


def _files_est(path: Path):
    """[(mtime, freed_bytes_estimate, path)] for plain files directly in path, oldest first."""
    out = []
    for e in os.scandir(path):
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            continue
        if e.is_file(follow_symlinks=False):
            out.append((st.st_mtime, st.st_size if st.st_nlink == 1 else 0, e.path))
    return sorted(out)


def trim_dir_lru(path: Path, cap: int):
    files = _files_est(path)
    total = sum(s for _m, s, _p in files)
    for _m, size, p in files:
        if total <= cap:
            break
        try:
            os.unlink(p)
            total -= size
        except OSError:
            pass


def _rm(path: Path):
    shutil.rmtree(path, ignore_errors=True)


def purge(protect_draft=None, protect_blobs=(), clear=False) -> dict:
    """Evict per the contract. Caller must hold the job lock (BUSY + flock)."""
    now = time.time()
    removed = {"drafts": [], "blobs": 0, "thumbs": 0, "previewSite": False}
    protect_blobs = set(protect_blobs)
    drafts = sorted(list_drafts(), key=lambda kv: kv[1]["lastUsed"])  # oldest first

    def drop_draft(did):
        _rm(DRAFTS / did)
        removed["drafts"].append(did)

    if clear:
        for did, _m in drafts:
            if did != protect_draft:
                drop_draft(did)
        for _m, _s, p in _files_est(BLOBS) + _files_est(THUMBS):
            try:
                os.unlink(p)
            except OSError:
                continue
            removed["blobs" if os.path.dirname(p) == str(BLOBS) else "thumbs"] += 1
        return removed

    # 1. expired drafts, then everything beyond the newest MAX_DRAFTS
    kept = []
    for did, m in drafts:
        if did != protect_draft and now - m["lastUsed"] > DRAFT_TTL:
            drop_draft(did)
        else:
            kept.append((did, m))

    def evict_oldest_unprotected():
        idx = next((i for i, (did, _m) in enumerate(kept) if did != protect_draft), None)
        if idx is None:
            return False
        drop_draft(kept.pop(idx)[0])
        return True

    while len(kept) > MAX_DRAFTS and evict_oldest_unprotected():
        pass

    # leftovers from interrupted uploads
    for _m, _s, p in _files_est(BLOBS):
        if os.path.basename(p).startswith(".tmp-") and now - os.stat(p).st_mtime > 3600:
            os.unlink(p)

    # the thumbs cache has its own cap
    trim_dir_lru(THUMBS, THUMBS_CAP)

    # 2. over the global cap: older drafts, unreferenced blobs, thumbs, preview-site last
    total = cache_usage()["usedBytes"]
    while total > CACHE_CAP and evict_oldest_unprotected():
        total = cache_usage()["usedBytes"]
    if total > CACHE_CAP:
        referenced = set(protect_blobs)
        for _did, m in kept:
            referenced.update(m.get("blobs", []))
        for _m, size, p in _files_est(BLOBS):
            if total <= CACHE_CAP:
                break
            if os.path.basename(p) in referenced or os.path.basename(p).startswith(".tmp-"):
                continue
            os.unlink(p)
            removed["blobs"] += 1
            total -= size
    if total > CACHE_CAP:
        for _m, size, p in _files_est(THUMBS):
            if total <= CACHE_CAP:
                break
            os.unlink(p)
            removed["thumbs"] += 1
            total -= size
    if total > CACHE_CAP and protect_draft is None:
        # last resort; the inbox preview site is rebuilt by the next /v1/frames/preview
        for child in list(SCRATCH.iterdir()):
            _rm(child) if child.is_dir() else child.unlink()
        removed["previewSite"] = True
    return removed


def cli_purge() -> int:
    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(json.dumps({"skipped": "a job is running"}))
        return 0
    removed = purge()
    print(json.dumps({"removed": removed, **cache_usage()}))
    return 0


@app.get("/v1/cache")
def cache_info():
    return jsonify(cache_usage())


@app.post("/v1/cache/clear")
def cache_clear():
    if not BUSY.acquire(blocking=False):
        return err("Polaris is busy with another job; try again in a minute", 409)
    try:
        with open(LOCK_PATH, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            purge(clear=True)
    finally:
        BUSY.release()
    return jsonify(cache_usage())


# ---------- blob cache ----------

@app.post("/v1/blobs/missing")
def blobs_missing():
    data = request.get_json(silent=True) or {}
    hashes = data.get("hashes") if isinstance(data, dict) else None
    if not isinstance(hashes, list) or not all(isinstance(h, str) and HEX64.match(h) for h in hashes):
        return err("hashes must be a list of sha256 hex strings")
    missing = []
    for h in hashes:
        p = BLOBS / h.lower()
        if p.is_file():
            try:
                os.utime(p)  # LRU
            except OSError:
                pass
        else:
            missing.append(h)
    return jsonify({"missing": missing})


@app.put("/v1/blobs/<sha>")
def blob_put(sha):
    if not HEX64.match(sha):
        return err("bad sha256")
    sha = sha.lower()
    dst = BLOBS / sha
    tmp = BLOBS / f".tmp-{uuid.uuid4().hex}"
    h = hashlib.sha256()
    try:
        with open(tmp, "wb") as f:
            while True:
                chunk = request.stream.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
                f.write(chunk)
        if h.hexdigest() != sha:
            return err("sha256 mismatch", 400)
        tmp.replace(dst)
    finally:
        tmp.unlink(missing_ok=True)
    return jsonify({"ok": True, "sha256": sha, "size": dst.stat().st_size})


# ---------- draft preview ----------

PROBLEM_RE = re.compile(r"^(ERROR|WARNING)\s+(.+?)(?::(\d+))?: (.*)$")


def parse_issues(lines, slug):
    prefix = f"stories/{slug}/"
    out = []
    for l in lines:
        m = PROBLEM_RE.match(l)
        if not m:
            continue
        level, path, line, msg = m.group(1).lower(), m.group(2), m.group(3), m.group(4)
        mine = path.startswith(prefix)
        file = path[len(prefix):] if mine else path
        name = None
        kind = "other"
        mm = re.match(r'file "(.+?)" is not in this story folder', msg)
        if mm:
            kind, name = "missing-file", mm.group(1)
        else:
            mm = re.match(r"(?:the cover )?(.+?) has no date taken", msg)
            if mm:
                kind, name = "no-date", mm.group(1)
            elif re.search(r"<\s*insert|insert marker", msg, re.I):
                kind = "marker"
        if name is None and mine and file != "story.md":
            name = file
        issue = {"level": level, "line": int(line) if (line and mine) else None, "file": file, "message": msg, "kind": kind}
        if name:
            issue["name"] = name
        out.append(issue)
    return out


def build_draft_job(job: Job, req: dict):
    global ACTIVE_DRAFT
    ACTIVE_DRAFT = req["draftId"]
    try:
        return _build_draft(job, req)
    finally:
        ACTIVE_DRAFT = None


def _build_draft(job, req):
    draft_id, slug, files = req["draftId"], req["slug"], req["files"]
    droot = DRAFTS / draft_id
    droot.mkdir(parents=True, exist_ok=True)
    blob_hashes = [f["sha256"] for f in files if f.get("sha256")]
    meta = {"slug": slug, "lastUsed": time.time(), "blobs": blob_hashes}
    write_draft_meta(draft_id, meta)
    rm = purge(protect_draft=draft_id, protect_blobs=blob_hashes)
    job.line(f"purge: dropped {len(rm['drafts'])} draft(s), {rm['blobs']} blob(s), {rm['thumbs']} thumb(s)")

    text = render_md("story", req["fields"], req["body"])
    body_start = text.split("\n").index("---", 1) + 2  # 1-based line after the closing ---
    result = {"draftId": draft_id, "bodyStartLine": body_start, "issues": []}

    # ---- scratch inbox: symlinks to every real entry except this slug, plus the draft story
    inbox = droot / "inbox"
    _rm(inbox)
    for sub in ("photos", "stories"):
        (inbox / sub).mkdir(parents=True)
        real = INBOX / sub
        if real.is_dir():
            for e in real.iterdir():
                # only the story being edited is replaced; a same-named photo must still collide
                if not (sub == "stories" and e.name == slug):
                    (inbox / sub / e.name).symlink_to(e)
    folder = inbox / "stories" / slug
    folder.mkdir()
    (folder / "story.md").write_text(text)
    pre = []
    for f in files:
        name = f["name"]
        if f.get("remote"):
            src = INBOX / "stories" / slug / name
            if src.is_file():
                (folder / name).symlink_to(src)
            else:
                pre.append({"level": "error", "line": None, "file": name, "message": f'file "{name}" is not in the Polaris inbox', "kind": "missing-file", "name": name})
        else:
            blob = BLOBS / f["sha256"]
            if not blob.is_file():
                pre.append({"level": "error", "line": None, "file": name, "message": f'file "{name}" has not been uploaded', "kind": "missing-file", "name": name})
                continue
            try:
                os.link(blob, folder / name)
            except OSError:
                shutil.copy2(blob, folder / name)
            try:
                os.utime(blob)
            except OSError:
                pass
    if pre:
        result["issues"] = pre
        result["error"] = pre[0]["message"]
        raise JobFailed(result["error"], result)

    # ---- validate (structured issues), then build
    p = subprocess.run([str(FRAMES_PY), "validate", "--inbox", str(inbox)], capture_output=True, text=True, cwd=SITE)
    lines = [l for l in (p.stdout + p.stderr).splitlines() if l.strip()]
    for l in lines:
        job.line(l)
    issues = parse_issues(lines, slug)
    result["issues"] = issues
    errors = [i for i in issues if i["level"] == "error"]
    if p.returncode != 0 or errors:
        result["error"] = errors[0]["message"] if errors else "validation failed"
        raise JobFailed(result["error"], result)

    site = droot / "site"
    site.mkdir(exist_ok=True)
    base = SCRATCH if (SCRATCH / "frames.html").is_file() else SITE
    job.run(["rsync", "-a", "--delete", "--exclude", ".git", "--exclude", "_media", "--exclude", "TODO.md", f"{base}/", f"{site}/"])
    if base is SCRATCH and (SCRATCH / "_media").is_dir():
        # hardlink the already-processed media: ~free on disk (the pipeline replaces files atomically, never in place)
        job.run(["rsync", "-a", f"--link-dest={SCRATCH / '_media'}", f"{SCRATCH / '_media'}/", f"{site / '_media'}/"])
    tpl = SITE / "_tools/frames/story.template.html"
    if tpl.is_file():
        (site / "_tools/frames").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tpl, site / "_tools/frames/story.template.html")
    rc = job.run([FRAMES_PY, "build", "--repo", site, "--inbox", inbox, "--jobs", "2"], cwd=SITE, check=False)
    page = site / "frames" / f"{slug}.html"
    if rc != 0 or not page.is_file():
        result["error"] = "build failed"
        raise JobFailed("build failed", result)
    meta["lastUsed"] = time.time()
    write_draft_meta(draft_id, meta)
    result.update({"url": f"/frames/{slug}.html", "builtAt": int(time.time())})
    return result


@app.post("/v1/frames/draft-preview")
def draft_preview():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return err("JSON body required")
    draft_id, slug = data.get("draftId"), data.get("slug")
    if not isinstance(draft_id, str) or not DRAFT_ID_RE.match(draft_id):
        return err("bad draftId")
    if not isinstance(slug, str) or not SLUG_RE.match(slug):
        return err("bad slug")
    if data.get("kind", "story") != "story":
        return err("only story drafts are supported")
    fields, body = data.get("fields") or {}, data.get("body") or ""
    if not isinstance(fields, dict) or not isinstance(body, str):
        return err("bad fields/body")
    files, seen = [], set()
    for f in data.get("files") or []:
        if not isinstance(f, dict):
            return err("bad files entry")
        try:
            name = safe_name(f.get("name"))
        except ValueError as e:
            return err(str(e))
        if name in seen:
            return err(f"duplicate file name {name!r}")
        seen.add(name)
        if f.get("remote"):
            files.append({"name": name, "remote": True})
        else:
            sha = f.get("sha256")
            if not isinstance(sha, str) or not HEX64.match(sha):
                return err(f"bad sha256 for {name!r}")
            files.append({"name": name, "sha256": sha.lower()})
    req = {"draftId": draft_id, "slug": slug, "fields": fields, "body": body, "files": files}
    return job_or_busy("draft-preview", lambda job: build_draft_job(job, req))


@app.delete("/v1/frames/draft-preview/<draft_id>")
def draft_preview_delete(draft_id):
    if not DRAFT_ID_RE.match(draft_id):
        return err("bad draftId")
    if ACTIVE_DRAFT == draft_id:
        return err("that draft is building; try again shortly", 409)
    _rm(DRAFTS / draft_id)
    return jsonify({"ok": True})


def preview_root() -> Path:
    did = request.cookies.get("polaris_preview", "")
    if did and DRAFT_ID_RE.match(did):
        site = DRAFTS / did / "site"
        if site.is_dir():
            mp = DRAFTS / did / "meta.json"
            try:
                if time.time() - mp.stat().st_mtime > 60:
                    os.utime(mp)  # LRU: still being looked at
            except OSError:
                pass
            return site
    return SCRATCH


# ---------- preview site (served at the origin root, because pages use /assets/... paths) ----------

@app.get("/")
def root():
    return err("polaris-app-api", 404)


@app.get("/<path:p>")
def preview_static(p):
    if p.startswith("v1/"):
        abort(404)
    return send_from_directory(preview_root(), p, max_age=0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "purge":
        sys.exit(cli_purge())
    fan_start()
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "5001")), threaded=True)
