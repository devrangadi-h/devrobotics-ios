"""Shared helpers for the DevRobotics Mac-side watcher and helper. Python 3 stdlib only.
The token is only ever handled by the helper, which reads it from its file."""
import json
import os
import subprocess
import time
from pathlib import Path

REPO = Path(os.environ.get("DEVROBOTICS_REPO", Path(__file__).resolve().parents[2]))
SUPPORT = Path(os.environ.get("DEVROBOTICS_SUPPORT_DIR", Path.home() / "Library/Application Support/DevRobotics"))
LOGDIR = Path(os.environ.get("DEVROBOTICS_LOG_DIR", Path.home() / "Library/Logs/DevRobotics"))
STATE_FILE = SUPPORT / "last-install.json"
LOCK_DIR = SUPPORT / "install.lock.d"
FORCE_FILE = SUPPORT / "force"
INSTALLER = os.environ.get("DEVROBOTICS_INSTALLER", str(REPO / "Tools/install.sh"))
IOREG_CMD = os.environ.get("DEVROBOTICS_IOREG_CMD", "ioreg -p IOUSB -w0")


def log_line(name, msg):
    LOGDIR.mkdir(parents=True, exist_ok=True)
    with open(LOGDIR / name, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def phone_connected():
    """True when an iPhone is on USB (ioreg), else when devicectl lists a connected iPhone."""
    try:
        out = subprocess.run(IOREG_CMD.split(), capture_output=True, text=True, timeout=10).stdout
        if any("iphone" in l.lower() for l in out.splitlines()):
            return True
    except Exception:
        pass
    if os.environ.get("DEVROBOTICS_IOREG_CMD"):   # fakes: never fall through to the real devicectl
        return False
    try:
        r = subprocess.run(["xcrun", "devicectl", "list", "devices", "--timeout", "5"],
                           capture_output=True, text=True, timeout=15).stdout
        return any("iphone" in l.lower() and "connected" in l.lower() and "unavailable" not in l.lower()
                   for l in r.splitlines())
    except Exception:
        return False


def read_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return None


def lock_holder():
    """PID of the live installer holding the lock, else None (stale locks are ignored)."""
    try:
        pid = int((LOCK_DIR / "pid").read_text().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return None
