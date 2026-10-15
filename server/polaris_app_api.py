#!/usr/bin/env python3
"""polaris-app-api: backend for the DevRobotics iPhone app.

Listens on 127.0.0.1 only; Tailscale Serve exposes it to the tailnet over HTTPS.
Auth: the same bearer token as the lights API (header or `polaris_token` cookie,
the cookie being what lets a WKWebView load preview CSS/JS/images).

Everything lives outside the site repo (STATE) so nothing here is ever published.
"""
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from pathlib import Path

from flask import Flask, Response, abort, jsonify, request, send_from_directory

HOME = Path.home()
TOKEN_PATH = Path(os.environ.get("POLARIS_TOKEN_PATH", HOME / ".config/polaris/lights_token"))
INBOX = Path(os.environ.get("FRAMES_INBOX", HOME / "frames-inbox"))
SITE = Path(os.environ.get("SITE_REPO", HOME / "devrobotics-site"))
FRAMES_PY = SITE / "_tools/frames/frames.py"
FRAMES_PYTHON = HOME / "frames-tools/.venv/bin/python"
STATE = Path(os.environ.get("APP_STATE", HOME / "polaris-app-state"))
SCRATCH = STATE / "preview-site"
THUMBS = STATE / "thumbs"
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
        try:
            job.result = fn(job)
            job.state = "done"
        except Exception as e:  # noqa: BLE001
            job.line(f"ERROR: {e}")
            job.state = "failed"
            job.result = {"error": str(e)}
        finally:
            job.finished = time.time()
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
    })


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
    if not dst.exists():
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
    return send_from_directory(THUMBS, dst.name, mimetype="image/jpeg", max_age=86400)


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


# ---------- preview site (served at the origin root, because pages use /assets/... paths) ----------

@app.get("/")
def root():
    return err("polaris-app-api", 404)


@app.get("/<path:p>")
def preview_static(p):
    if p.startswith("v1/"):
        abort(404)
    return send_from_directory(SCRATCH, p, max_age=0)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "5001")), threaded=True)
