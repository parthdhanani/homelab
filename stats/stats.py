#!/usr/bin/env python3
"""stats.py — read-only host stats aggregator for the Obsidian vault-hud plugin.

Why this exists: Ignis (browser Obsidian) runs in a container with no visibility
into host Docker/systemd/backup state, which is most of what a mission-control
view needs. This exposes that state as JSON over the docker bridge, same trust
model as duel.py (bridge-only, not internet-routable).

Stdlib only. Binds the docker bridge host IP so cryptex-ignis (172.18.0.48) can
reach it directly.
"""
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("STATS_BIND", "172.18.0.1")
PORT = int(os.environ.get("STATS_PORT", "8091"))
PKM = os.environ.get("PKM", "/opt/cryptex/data/pkm")
INBOX = os.path.join(PKM, "00 Capture", "Inbox.md")
USAGE_LOG = os.path.expanduser("~/.claude/usage.jsonl")
JOBS = ["news", "monitor", "jobhunt", "ops", "digest", "github", "deepdive", "movies"]


def _run(cmd: list, timeout: int = 8) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def docker_status() -> dict:
    running = _run(["docker", "ps", "--format", "{{.Names}}"]).splitlines()
    unhealthy = [
        line.split()[0]
        for line in _run(["docker", "ps", "--format", "{{.Names}} {{.Status}}"]).splitlines()
        if "unhealthy" in line.lower()
    ]
    exited = [
        line
        for line in _run(
            ["docker", "ps", "-a", "--filter", "status=exited", "--format", "{{.Names}} {{.Status}}"]
        ).splitlines()
        if "Exited (0" not in line
    ]
    return {"running": len(running), "unhealthy": unhealthy, "exited_nonzero": exited}


def backup_age_hours() -> float:
    for path in ("/backup-stage", "/backups"):
        out = _run(
            ["docker", "exec", "cryptex-kopia", "kopia", "snapshot", "list", path,
             "--max-results=1", "--json"]
        )
        if not out:
            continue
        try:
            snaps = json.loads(out)
        except ValueError:
            continue
        if snaps:
            start = snaps[0]["startTime"].split(".")[0].replace("Z", "+00:00")
            dt = datetime.fromisoformat(start)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return round((datetime.now(timezone.utc) - dt).total_seconds() / 3600, 1)
    return -1.0


def failed_units() -> list:
    out = _run(["systemctl", "--failed", "--no-legend"])
    return [line.split()[0] for line in out.splitlines() if line.strip()]


def job_status(job: str) -> dict:
    unit = f"claude-agent@{job}.service"
    out = _run(
        ["systemctl", "show", unit, "-p",
         "ExecMainStatus,ActiveState,ExecMainStartTimestamp"]
    )
    props = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k] = v
    status = props.get("ExecMainStatus", "")
    active = props.get("ActiveState", "")
    started = props.get("ExecMainStartTimestamp", "")
    return {
        "job": job,
        "exit_status": status or None,
        "active_state": active or None,
        "last_start": started or None,
        "ok": status == "0",
    }


def ob1_health() -> bool:
    out = _run(["curl", "-sf", "--max-time", "3", "http://127.0.0.1:8000/health"])
    return bool(out)


def inbox_directives(limit: int = 5) -> list:
    """Top unchecked items, most-recent-first — mirrors the DIRECTIVES panel.
    Cheap heuristic: last N unchecked '- [ ]' lines in the inbox."""
    try:
        with open(INBOX, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        s = line.strip()
        if s.startswith("- [ ]"):
            out.append(s[5:].strip())
            if len(out) >= limit:
                break
    return list(reversed(out))


def recent_notes(limit: int = 5) -> list:
    """Most recently modified markdown files in the vault, excluding dotdirs."""
    entries = []
    for root, dirs, files in os.walk(PKM):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.endswith(".md"):
                p = os.path.join(root, f)
                try:
                    mtime = os.path.getmtime(p)
                except OSError:
                    continue
                entries.append((mtime, os.path.relpath(p, PKM)))
    entries.sort(reverse=True)
    return [{"path": p, "mtime": int(m)} for m, p in entries[:limit]]


def claude_5h_usage() -> dict:
    """Last known q5h fraction from the local usage log — same signal the CLI itself uses."""
    try:
        last = None
        with open(USAGE_LOG, encoding="utf-8") as fh:
            for line in fh:
                last = line
        if not last:
            return {}
        rec = json.loads(last)
        return {
            "q5h": rec.get("q5h"),
            "q5h_reset": rec.get("q5h_reset"),
            "qstatus": rec.get("qstatus"),
        }
    except (OSError, ValueError):
        return {}


def build_stats() -> dict:
    return {
        "ts": int(time.time()),
        "docker": docker_status(),
        "backup_age_hours": backup_age_hours(),
        "failed_units": failed_units(),
        "jobs": [job_status(j) for j in JOBS],
        "ob1_up": ob1_health(),
        "directives": inbox_directives(),
        "recent_notes": recent_notes(),
        "claude_usage": claude_5h_usage(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "stats"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.rstrip("/") not in ("/vault-stats", ""):
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(build_stats()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def demo():
    """Self-check: pure helpers behave sanely even with no docker/systemd available."""
    assert isinstance(failed_units(), list)
    assert isinstance(inbox_directives(3), list)
    assert isinstance(recent_notes(3), list)
    d = docker_status()
    assert "running" in d and "unhealthy" in d and "exited_nonzero" in d
    js = job_status("__no_such_job__")
    assert js["job"] == "__no_such_job__"
    assert set(js) == {"job", "exit_status", "active_state", "last_start", "ok"}
    stats = build_stats()
    assert set(stats) == {
        "ts", "docker", "backup_age_hours", "failed_units", "jobs",
        "ob1_up", "directives", "recent_notes", "claude_usage",
    }
    print("stats.py self-check OK")


if __name__ == "__main__":
    import sys

    if "--demo" in sys.argv:
        demo()
    else:
        srv = ThreadingHTTPServer((BIND, PORT), Handler)
        print(f"stats serving on {BIND}:{PORT}/vault-stats", flush=True)
        srv.serve_forever()
