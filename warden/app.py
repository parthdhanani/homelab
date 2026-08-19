#!/usr/bin/env python3
"""Jarvis — the cryptex control panel, in a terminal.

Sidebar-navigated, one category per concern: Home, Containers, Access,
Agents, Feeds, Crons, Ask, Ops. Every number on screen comes from a real
command run at open-time — nothing here is invented or cached across
restarts. The only mutating actions (container start/stop/restart, run an
agent job now) sit behind an explicit confirm and are logged to the
Activity strip at the bottom.

Run: jarvis   (installed at /usr/local/bin/jarvis -> this file)
"""
import json
import os
import subprocess
import sys
from datetime import datetime

import psutil
from rich.text import Text

sys.path.insert(0, "/opt/cryptex/graph-server")
import graph_server as gs  # noqa: E402

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal, VerticalScroll, Container
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import (
    Header, Footer, Static, Input, Log, Button, ListView, ListItem, Label,
    Markdown, DataTable, ContentSwitcher, Rule, LoadingIndicator,
)

# A real design-token theme (Textual's Theme system — same mechanism behind
# its builtin "nord"/"gruvbox" themes) instead of hex scattered through the
# stylesheet. One source of truth for every color; CSS below only ever
# references the $tokens.
# Cyan HUD palette — arc-reactor glow on near-black, not a warm dashboard.
JARVIS_THEME = Theme(
    name="jarvis",
    dark=True,
    primary="#3ad6d6",       # cyan glow — accent, focus, active nav, graph base
    secondary="#2a7a8c",
    accent="#5eeaea",
    warning="#e8b64c",
    error="#e2534f",
    success="#3ad6d6",
    foreground="#c9e8e8",
    background="#050a0d",
    surface="#0a1418",
    panel="#0e1c22",
    boost="#123038",
)

# Gradient stops (dim -> glow) per status, used by Graph for column shading.
GRAPH_COLORS = {
    "ok": ("#0e3a3a", "#5eeaea"),
    "warn": ("#3a2e0e", "#f0c060"),
    "fail": ("#3a1414", "#f06868"),
    "neutral": ("#122238", "#6f9bdc"),
}
_BLOCKS = " ▁▂▃▄▅▆▇█"


def _hex_lerp(c1: str, c2: str, t: float) -> str:
    t = max(0.0, min(1.0, t))
    r1, g1, b1 = int(c1[1:3], 16), int(c1[3:5], 16), int(c1[5:7], 16)
    r2, g2, b2 = int(c2[1:3], 16), int(c2[3:5], 16), int(c2[5:7], 16)
    return f"#{round(r1 + (r2 - r1) * t):02x}{round(g1 + (g2 - g1) * t):02x}{round(b1 + (b2 - b1) * t):02x}"

STATUS_SCRIPT = "/opt/cryptex/scripts/cryptex-status.sh"
HEALTH_SCRIPT = "/opt/cryptex/scripts/health-check.sh"
UPDATE_SCRIPT = "/opt/cryptex/jarvis/scripts/update-system.sh"
SELF_AUDIT_SCRIPT = os.path.expanduser("~/.claude/scripts/self-audit.sh")
BACKUP_VERIFY_SCRIPT = "/opt/cryptex/scripts/backup-verify.sh"
DAILY_REPORT = "/var/log/cryptex-daily-report.json"
AGENT_LOGS_DIR = os.path.expanduser("~/claude-agents/logs")
FEEDS_DIR = "/opt/cryptex/data/pkm/00 Capture/Daily/Agents"

FEEDS = {
    "news": "news-feed.md",
    "deepdive": "deepdive.md",
    "monitor": "monitor.md",
    "movies": "movies.md",
    "movies-tv": "movies-tv.md",
    "movies-anime": "movies-anime.md",
    "github-trending": "github-trending.md",
    "weekly-digest": "weekly-digest.md",
    "ops-alerts": "ops-alerts.md",
}

STATUS_STYLE = {
    "OK": "bold #3ad6d6", "FAIL": "bold #e2534f",
    "DISABLED": "dim", "UNKNOWN": "bold #e8b64c",
}

# key -> (number, glyph, label). Plain box-drawing glyphs only — no nerd-font
# dependency, so this renders identically over any SSH client / terminal.
NAV_ITEMS = [
    ("home", "1", "●", "Home"),
    ("containers", "2", "▣", "Containers"),
    ("access", "3", "◈", "Access"),
    ("agents", "4", "◆", "Agents"),
    ("feeds", "5", "▤", "Feeds"),
    ("crons", "6", "◷", "Crons"),
    ("updates", "7", "↑", "Updates"),
    ("ask", "8", "?", "Ask"),
    ("ops", "9", "⚙", "Ops"),
]


def _run(cmd, timeout=30, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return "(timed out)"
    except OSError as e:
        return f"(failed to run: {e})"


def _humanize_age(mtime: float) -> str:
    age_min = int((datetime.now().timestamp() - mtime) / 60)
    if age_min < 60:
        return f"{age_min}m ago"
    age_hr = age_min // 60
    if age_hr < 48:
        return f"{age_hr}h ago"
    return f"{age_hr // 24}d ago"


def _latest_section(text: str) -> str:
    parts = text.split("\n## ")
    if len(parts) <= 1:
        return text.strip()
    return ("## " + parts[-1]).strip()


# apt/npm/pip outdated-package checks are slow (pip alone ~8s) and don't
# change minute-to-minute — cache for 5 min so the 15s Home auto-refresh
# doesn't repeatedly pay that cost.
_UPDATE_CACHE_TTL = 300
_update_cache: dict = {}


def _cached(key: str, fn):
    entry = _update_cache.get(key)
    now = datetime.now().timestamp()
    if entry and now - entry[0] < _UPDATE_CACHE_TTL:
        return entry[1]
    value = fn()
    _update_cache[key] = (now, value)
    return value


def _apt_upgradable() -> list:
    def fetch():
        out = _run(["apt", "list", "--upgradable"], timeout=15)
        return [
            ln.split("/")[0] for ln in out.splitlines()
            if ln and not ln.startswith("Listing") and not ln.startswith("WARNING")
        ]
    return _cached("apt", fetch)


def _npm_outdated() -> list:
    def fetch():
        out = _run(["npm", "outdated", "-g"], timeout=15)
        rows = []
        for ln in out.splitlines()[1:]:
            parts = ln.split()
            if len(parts) >= 4:
                rows.append({"name": parts[0], "current": parts[1], "latest": parts[3]})
        return rows
    return _cached("npm", fetch)


def _pip_outdated() -> list:
    def fetch():
        out = _run(["pip", "list", "--outdated", "--format=json"], timeout=20)
        try:
            data = json.loads(out)
        except (json.JSONDecodeError, ValueError):
            return []
        return [{"name": d["name"], "current": d["version"], "latest": d["latest_version"]} for d in data]
    return _cached("pip", fetch)


def _docker_image_updates() -> list:
    """Dockhand writes 'update available' lines to its own log when it finds
    one — cheap to tail, no separate polling needed."""
    out = _run(["docker", "logs", "cryptex-dockhand", "--tail", "200"], timeout=10)
    lines = [ln for ln in out.splitlines() if "update available" in ln.lower() or "newer image" in ln.lower()]
    return lines[-10:]


def _docker_reclaimable() -> dict:
    out = _run(["docker", "system", "df", "--format", "{{json .}}"], timeout=15)
    result = {}
    for ln in out.splitlines():
        try:
            d = json.loads(ln)
        except json.JSONDecodeError:
            continue
        result[d.get("Type", "?")] = d.get("Reclaimable", "?")
    return result


def _docker_ps_full() -> list:
    out = _run(["docker", "ps", "-a", "--format",
                "{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.RunningFor}}\t{{.Ports}}"])
    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            parts += [""] * (5 - len(parts))
        name, status, image, running_for, ports = parts[:5]
        rows.append({
            "name": name, "status": status, "image": image,
            "running_for": running_for, "ports": ports,
            "up": status.startswith("Up"),
            "unhealthy": "(unhealthy)" in status,
        })
    return rows


class ConfirmModal(ModalScreen):
    """Blocking yes/no confirm — used before any mutating action."""

    CSS = """
    ConfirmModal { align: center middle; }
    #confirm-box {
        width: 60; height: auto; padding: 1 2; background: $panel;
        border: solid $primary;
    }
    #confirm-msg { padding: 1 0; }
    #confirm-buttons { height: 3; align: right middle; }
    #confirm-buttons Button { margin-left: 1; }
    """

    def __init__(self, message: str):
        super().__init__()
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box"):
            yield Static(self.message, id="confirm-msg")
            with Horizontal(id="confirm-buttons"):
                yield Button("Cancel", id="cancel")
                yield Button("Confirm", id="confirm", variant="error")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm")


class Activity(Static):
    """Bottom strip — every mutating action lands one line here."""

    def log_event(self, text: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        self.update(f"[dim]{ts}[/dim]  {text}")


# ── Panes ────────────────────────────────────────────────────────────────

class StatTile(Vertical):
    """One glanceable metric: label (in the border), big value, one-line
    sub-detail — all colored by status. The unit of the Home grid
    (btop-style: many of these tiled on screen at once beats one long
    scrolling status dump). Title lives in the border itself, not a
    separate label row — frees a line for the value and reads as an
    instrument panel, not a form."""

    def __init__(self, label: str, tile_id: str):
        super().__init__(id=tile_id, classes="stat-tile")
        self.label_text = label

    def compose(self) -> ComposeResult:
        self.border_title = self.label_text
        yield Static("—", classes="stat-value", id=f"{self.id}-value")
        yield Static("", classes="stat-sub", id=f"{self.id}-sub")

    def set_value(self, value: str, sub: str = "", status: str = "neutral") -> None:
        v = self.query_one(f"#{self.id}-value", Static)
        v.update(value)
        v.set_classes(f"stat-value stat-{status}")
        self.query_one(f"#{self.id}-sub", Static).update(sub)
        self.set_classes(f"stat-tile stat-border-{status}")


class Graph(Static):
    """Multi-row block-character history graph (btop/zenith style) — not a
    flat 1-row Sparkline. Each column is rendered tallest-block-first with
    partial-block precision, colored by a dim->glow gradient so intensity
    reads at a glance instead of a single flat accent tint."""

    def __init__(self, tile_id: str, rows: int = 4, status: str = "ok"):
        super().__init__(id=tile_id)
        self.rows = rows
        self.history: list = []
        self.status = status

    def push(self, value: float, vmax: float, status: str = None) -> None:
        self.history.append(max(0.0, value))
        self.history = self.history[-80:]
        self.vmax = max(vmax, max(self.history) if self.history else 1)
        if status:
            self.status = status
        self.render_graph()

    def render_graph(self) -> None:
        w = max(self.size.width, 10)
        data = self.history[-w:]
        if not data:
            self.update("")
            return
        vmax = self.vmax or 1
        lo, hi = GRAPH_COLORS.get(self.status, GRAPH_COLORS["ok"])
        levels = self.rows * 8
        cols = []
        for v in data:
            frac = min(1.0, v / vmax)
            cols.append(round(frac * levels))
        lines = []
        for row in range(self.rows - 1, -1, -1):
            text = Text()
            floor = row * 8
            for i, col_level in enumerate(cols):
                cell = col_level - floor
                ch = _BLOCKS[max(0, min(8, cell))]
                frac = cols[i] / levels if levels else 0
                color = _hex_lerp(lo, hi, frac)
                text.append(ch, style=color)
            lines.append(text)
        combined = Text("\n").join(lines)
        self.update(combined)

    def on_resize(self) -> None:
        self.render_graph()


class GraphTile(Vertical):
    """Stat tile backed by a live multi-row Graph instead of a static
    number — history persists across refreshes for the life of the app."""

    def __init__(self, label: str, tile_id: str, vmax: float = 100):
        super().__init__(id=tile_id, classes="stat-tile")
        self.label_text = label
        self.vmax = vmax

    def compose(self) -> ComposeResult:
        self.border_title = self.label_text
        yield Graph(f"{self.id}-graph", rows=4)
        yield Static("", classes="stat-sub", id=f"{self.id}-sub")

    def push(self, value: float, sub: str = "", status: str = "ok") -> None:
        self.query_one(Graph).push(value, self.vmax, status)
        self.query_one(f"#{self.id}-sub", Static).update(sub)
        self.set_classes(f"stat-tile stat-border-{status}")


class CoreMeter(Static):
    """Per-core CPU bar row — btop/zenith signature: one thin horizontal
    bar per core rather than a single aggregate number, so an imbalanced
    load (one hot core vs sixteen idle) is visible at a glance."""

    def set_cores(self, pcts: list) -> None:
        text = Text()
        for i, pct in enumerate(pcts):
            filled = round(pct / 100 * 6)
            color = _hex_lerp("#3ad6d6", "#f06868", pct / 100)
            if i:
                text.append("  ")
            text.append(f"C{i}", style="dim")
            text.append(" ")
            text.append("█" * filled, style=color)
            text.append("░" * (6 - filled), style="dim")
            text.append(" ")
            text.append(f"{pct:>3.0f}%", style=color)
        self.update(text)


class HomePane(Vertical):
    """Everything-at-a-glance: a fixed grid of live tiles, always all
    visible — no drilling into a status dump to find the one bad number."""

    def compose(self) -> ComposeResult:
        yield LoadingIndicator(id="home-loading")
        with Container(id="dashboard-grid"):
            yield StatTile("SERVICES", "tile-services")
            yield StatTile("CONTAINERS", "tile-containers")
            yield StatTile("DISK", "tile-disk")
            yield StatTile("MEMORY", "tile-memory")
            yield StatTile("AGENTS", "tile-agents")
            yield StatTile("BACKUP", "tile-backup")
            yield StatTile("HEALTH CHECK", "tile-health")
            yield StatTile("UPDATES", "tile-updates")
            yield StatTile("RECLAIMABLE", "tile-reclaim")
            yield GraphTile("HOST CPU", "tile-host-cpu", vmax=100)
            yield GraphTile("HOST MEM", "tile-host-mem", vmax=100)
            yield GraphTile("LOAD (1m)", "tile-load", vmax=max(1, psutil.cpu_count() * 2))
            cores = CoreMeter(id="home-cores", classes="panel")
            cores.border_title = "PER-CORE CPU"
            yield cores
            yield GraphTile("NETWORK", "tile-net", vmax=1)
            procs = DataTable(id="home-procs", classes="panel", zebra_stripes=True)
            procs.border_title = "TOP PROCESSES"
            yield procs
            issues = DataTable(id="home-issues", classes="panel", zebra_stripes=True, cursor_type="row")
            issues.border_title = "ISSUES — enter to jump to pane"
            yield issues
            feed = Static("", id="home-feed", classes="panel wide")
            feed.border_title = "LATEST FEED"
            yield feed

    def on_mount(self) -> None:
        self.query_one("#dashboard-grid").display = False
        table = self.query_one("#home-procs", DataTable)
        table.add_columns("PID", "NAME", "CPU%", "MEM%")
        issues_table = self.query_one("#home-issues", DataTable)
        issues_table.add_columns("area", "issue")
        self._issue_rows: list[str] = []
        self._prev_net = None
        self.refresh_data()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "home-issues":
            return
        if event.cursor_row >= len(self._issue_rows):
            return
        self.app.action_goto(self._issue_rows[event.cursor_row])

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        d: dict = {"now": datetime.now().strftime("%H:%M:%S")}

        daily = {}
        if os.path.exists(DAILY_REPORT):
            try:
                with open(DAILY_REPORT) as fh:
                    daily = json.load(fh)
            except (json.JSONDecodeError, OSError):
                daily = {}
        d["verdict"] = daily.get("verdict", "?")
        d["issue_list"] = daily.get("issue_list", "")
        d["hc"] = daily.get("health_check", {})

        try:
            nodes = gs.cluster_services()["nodes"]
            d["fails"] = [n for n in nodes if n["meta"].get("status") == "FAIL"]
            d["ok"] = sum(1 for n in nodes if n["meta"].get("status") == "OK")
            d["total"] = len(nodes)
        except Exception:  # noqa: BLE001
            d["fails"], d["ok"], d["total"] = [], 0, 0

        containers = _docker_ps_full()
        d["up"] = sum(1 for c in containers if c["up"])
        d["container_total"] = len(containers)
        d["unhealthy"] = [c["name"] for c in containers if c["up"] and c["unhealthy"]]

        sysd = daily.get("system", {})
        d["disk_pct"] = sysd.get("disk_pct", 0)
        d["disk_human"] = sysd.get("disk_human", "?")
        mem_free = sysd.get("mem_free_mb", 0)
        mem_total = sysd.get("mem_total_mb", 0) or 1
        d["mem_pct"] = 100 - int(mem_free / mem_total * 100)
        d["mem_free"], d["mem_total"] = mem_free, mem_total

        job_statuses = dict(zip(gs.CLAUDE_AGENT_JOBS, [gs._job_status(job) for job in gs.CLAUDE_AGENT_JOBS]))
        d["active_jobs"] = sum(1 for st in job_statuses.values() if st.get("active_state") == "active")
        d["failed_job_names"] = [
            job for job, st in job_statuses.items()
            if st.get("last_start") and st.get("result") not in (None, "success")
        ]
        d["failed_jobs"] = len(d["failed_job_names"])

        try:
            cron_nodes = gs.cluster_crons()["nodes"]
            d["failed_crons"] = [n["label"] for n in cron_nodes if n["meta"].get("failed")]
        except Exception:  # noqa: BLE001
            d["failed_crons"] = []

        try:
            with open("/var/log/cryptex-restore-check.log") as fh:
                lines = fh.readlines()
            d["backup_line"] = lines[-1].strip() if lines else ""
        except OSError:
            d["backup_line"] = ""

        cleanup_out = _run(["systemctl", "show", "disk-cleanup.timer",
                             "--property=LastTriggerUSec"], timeout=5)
        d["cleanup_last"] = cleanup_out.strip().split("=", 1)[-1] if "=" in cleanup_out else ""

        d["per_core"] = psutil.cpu_percent(interval=0.5, percpu=True)
        d["host_cpu"] = sum(d["per_core"]) / len(d["per_core"]) if d["per_core"] else 0
        vm = psutil.virtual_memory()
        d["host_mem"] = vm.percent
        d["load1"], d["load5"], d["load15"] = os.getloadavg()

        net = psutil.net_io_counters()
        now_ts = datetime.now().timestamp()
        if self._prev_net:
            prev_bytes, prev_ts = self._prev_net
            elapsed = max(0.1, now_ts - prev_ts)
            d["net_bps"] = (net.bytes_sent + net.bytes_recv - prev_bytes) / elapsed
        else:
            d["net_bps"] = 0.0
        self._prev_net = (net.bytes_sent + net.bytes_recv, now_ts)

        procs = []
        for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent"]):
            info = p.info
            if info["memory_percent"] is None:
                continue
            procs.append(info)
        d["top_procs"] = sorted(procs, key=lambda i: i["memory_percent"] or 0, reverse=True)[:8]

        d["apt_pkgs"] = _apt_upgradable()
        d["npm_pkgs"] = _npm_outdated()
        d["pip_pkgs"] = _pip_outdated()
        d["docker_updates"] = _docker_image_updates()
        d["reclaimable"] = _docker_reclaimable()

        newest_feed, newest_mtime, newest_preview = None, 0, ""
        for name, fname in FEEDS.items():
            path = os.path.join(FEEDS_DIR, fname)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if mtime > newest_mtime:
                newest_mtime = mtime
                newest_feed = name
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        section = _latest_section(fh.read())
                    body_lines = [ln for ln in section.splitlines() if ln.strip() and not ln.startswith("#")]
                    newest_preview = body_lines[0][:90] if body_lines else ""
                except OSError:
                    newest_preview = ""
        d["newest_feed"], d["newest_mtime"], d["newest_preview"] = newest_feed, newest_mtime, newest_preview

        self.app.call_from_thread(self._set_all, d)

    def _set_all(self, d: dict) -> None:
        self.query_one("#home-loading", LoadingIndicator).display = False
        grid = self.query_one("#dashboard-grid")
        grid.display = True

        self.query_one("#tile-services", StatTile).set_value(
            f"{d['ok']}/{d['total']}",
            ("FAIL: " + ", ".join(n["label"] for n in d["fails"])) if d["fails"] else "all healthy",
            "fail" if d["fails"] else "ok",
        )

        self.query_one("#tile-containers", StatTile).set_value(
            f"{d['up']}/{d['container_total']}",
            ("unhealthy: " + ", ".join(d["unhealthy"])) if d["unhealthy"] else "all running",
            "fail" if d["unhealthy"] else "ok",
        )

        disk_status = "fail" if d["disk_pct"] >= 85 else ("warn" if d["disk_pct"] >= 70 else "ok")
        self.query_one("#tile-disk", StatTile).set_value(
            f"{d['disk_pct']}%", d["disk_human"], disk_status,
        )

        mem_status = "fail" if d["mem_pct"] >= 90 else ("warn" if d["mem_pct"] >= 75 else "ok")
        self.query_one("#tile-memory", StatTile).set_value(
            f"{d['mem_pct']}%", f"{d['mem_free']}MB free / {d['mem_total']}MB", mem_status,
        )

        if d["failed_jobs"]:
            agents_sub = f"{d['failed_jobs']} failed"
            agents_status = "fail"
        elif d["active_jobs"]:
            agents_sub = f"{d['active_jobs']} running now"
            agents_status = "warn"
        else:
            agents_sub = "idle"
            agents_status = "neutral"
        self.query_one("#tile-agents", StatTile).set_value(
            str(len(gs.CLAUDE_AGENT_JOBS)), agents_sub, agents_status,
        )

        backup_status, backup_value, backup_sub = "neutral", "?", "no drill log"
        if d["backup_line"]:
            date_str = d["backup_line"].split(" DRILL ", 1)[0]
            try:
                age_days = (datetime.now() - datetime.strptime(date_str, "%Y-%m-%d")).days
                # restore-drill.timer runs monthly (OnCalendar=*-*-06) — thresholds track that cadence, not a daily one
                backup_status = "ok" if age_days < 35 else ("warn" if age_days < 40 else "fail")
                backup_value = f"{age_days}d ago"
                backup_sub = "drill passed" if backup_status == "ok" else "drill overdue — check"
            except ValueError:
                backup_value = "?"
        self.query_one("#tile-backup", StatTile).set_value(backup_value, backup_sub, backup_status)

        hc = d["hc"]
        hc_status = "fail" if hc.get("fail") else ("warn" if hc.get("warn") else "ok")
        self.query_one("#tile-health", StatTile).set_value(
            f"{hc.get('pass', '?')} pass",
            f"{hc.get('warn', 0)} warn, {hc.get('fail', 0)} fail" + (
                f" — {hc['failed_services']}" if hc.get("failed_services") else ""
            ),
            hc_status,
        )

        cpu_status = "fail" if d["host_cpu"] >= 90 else ("warn" if d["host_cpu"] >= 70 else "ok")
        self.query_one("#tile-host-cpu", GraphTile).push(
            d["host_cpu"], f"{d['host_cpu']:.0f}% of {psutil.cpu_count()} cores", cpu_status,
        )
        mem_g_status = "fail" if d["host_mem"] >= 90 else ("warn" if d["host_mem"] >= 75 else "ok")
        self.query_one("#tile-host-mem", GraphTile).push(d["host_mem"], f"{d['host_mem']:.0f}% used", mem_g_status)
        load_status = "fail" if d["load1"] >= psutil.cpu_count() * 2 else ("warn" if d["load1"] >= psutil.cpu_count() else "ok")
        self.query_one("#tile-load", GraphTile).push(
            d["load1"], f"{d['load1']:.2f} / {d['load5']:.2f} / {d['load15']:.2f}", load_status,
        )

        net_kb = d["net_bps"] / 1024
        net_tile = self.query_one("#tile-net", GraphTile)
        net_tile.vmax = max(net_tile.vmax, net_kb * 1.2, 50)
        net_tile.push(net_kb, f"{net_kb:.0f} KB/s", "ok")

        self.query_one("#home-cores", CoreMeter).set_cores(d["per_core"])

        proc_table = self.query_one("#home-procs", DataTable)
        proc_table.clear()
        for p in d["top_procs"]:
            proc_table.add_row(
                str(p["pid"]), (p["name"] or "?")[:20],
                f"{p['cpu_percent'] or 0:.1f}", f"{p['memory_percent'] or 0:.1f}",
            )

        total_updates = len(d["apt_pkgs"]) + len(d["npm_pkgs"]) + len(d["pip_pkgs"]) + len(d["docker_updates"])
        upd_status = "warn" if total_updates else "ok"
        self.query_one("#tile-updates", StatTile).set_value(
            str(total_updates),
            f"apt {len(d['apt_pkgs'])} · npm {len(d['npm_pkgs'])} · pip {len(d['pip_pkgs'])} · images {len(d['docker_updates'])}",
            upd_status,
        )

        reclaim = d["reclaimable"]
        reclaim_bits = [
            f"{k} {v}" for k, v in reclaim.items()
            if v and not v.endswith("(0%)") and v != "0B"
        ]
        self.query_one("#tile-reclaim", StatTile).set_value(
            reclaim.get("Images", "?"),
            ", ".join(reclaim_bits) if reclaim_bits else "nothing to reclaim",
            "warn" if reclaim_bits else "ok",
        )

        issues_table = self.query_one("#home-issues", DataTable)
        issues_table.clear()
        self._issue_rows = []
        rows = []  # (area label, issue text, nav key)
        for n in d["fails"]:
            rows.append(("service", f"[#e2534f]{n['label']} down[/#e2534f]", "access"))
        for name in d["unhealthy"]:
            rows.append(("container", f"[#e2534f]{name} unhealthy[/#e2534f]", "containers"))
        for job in d["failed_job_names"]:
            rows.append(("agent", f"[#e2534f]{job} last run FAILED[/#e2534f]", "agents"))
        for label in d["failed_crons"]:
            rows.append(("cron", f"[#e2534f]{label} FAILED[/#e2534f]", "crons"))
        if total_updates:
            rows.append(("updates", f"[#e8b64c]{total_updates} package/image updates pending[/#e8b64c]", "updates"))
        if reclaim_bits:
            rows.append(("disk", f"[dim]reclaimable: {', '.join(reclaim_bits)}[/dim]", "containers"))
        if d["issue_list"]:
            rows.append(("self-audit", d["issue_list"], "ops"))
        if not rows:
            rows.append(("-", "[dim]nothing needs attention[/dim]", "home"))
        for area, text, nav_key in rows:
            issues_table.add_row(area, text)
            self._issue_rows.append(nav_key)

        if d["newest_feed"]:
            age_min = int((datetime.now().timestamp() - d["newest_mtime"]) / 60)
            age = f"{age_min}m ago" if age_min < 60 else f"{age_min // 60}h ago"
            feed_text = f"[bold]{d['newest_feed']}[/bold] · {age}\n[dim]{d['newest_preview']}[/dim]"
        else:
            feed_text = "[dim]no feed files found[/dim]"
        self.query_one("#home-feed", Static).update(feed_text)


class ContainersPane(Vertical):
    """Full docker control: every container, live stats, start/stop/restart."""

    def compose(self) -> ComposeResult:
        yield DataTable(id="containers-table", zebra_stripes=True)
        yield Static("", id="containers-hint")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns("state", "name", "cpu", "mem", "uptime", "ports")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.query_one("#containers-hint", Static).update("[dim]loading…[/dim]")
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        containers = _docker_ps_full()
        stats_out = _run(["docker", "stats", "--no-stream", "--format",
                           "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"], timeout=10)
        stats = {}
        for line in stats_out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                stats[parts[0]] = (parts[1], parts[2])
        self.app.call_from_thread(self._set, containers, stats)

    def _set(self, containers: list, stats: dict) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._rows = []
        for c in sorted(containers, key=lambda c: (not c["up"], c["name"])):
            state = "FAIL" if (c["up"] and c["unhealthy"]) else ("OK" if c["up"] else "DOWN")
            style = STATUS_STYLE.get(state, "#e2534f" if state == "DOWN" else "")
            cpu, mem = stats.get(c["name"], ("-", "-"))
            table.add_row(
                f"[{style}]{state}[/{style}]" if style else state,
                c["name"], cpu, mem, c["running_for"], c["ports"] or "-",
            )
            self._rows.append(c)
        up = sum(1 for c in containers if c["up"])
        self.query_one("#containers-hint", Static).update(
            f"{up}/{len(containers)} running — a=start  x=stop  z=restart  r=refresh"
        )

    def selected(self):
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return None
        return self._rows[table.cursor_row]


class AccessPane(Vertical):
    """Every service on the box, public or internal-only — the one place
    that answers "what do I have and how do I reach it." Public routes show
    their real URL; internal-only containers show their bound ports."""

    def compose(self) -> ComposeResult:
        yield DataTable(id="access-table", zebra_stripes=True)
        yield Static("[dim]enter/click a row — public routes print their URL below; internal containers print their ports[/dim]", id="access-hint")
        yield Static("", id="access-url")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns("status", "name", "reach", "access", "detail")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        try:
            nodes = gs.cluster_services()["nodes"]
        except Exception:  # noqa: BLE001
            nodes = []
        self.app.call_from_thread(self._set, nodes)

    def _set(self, nodes: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        # public routes first (the tap-to-open surface), then internal-only containers
        routes = sorted((n for n in nodes if n["kind"] == "public_route"), key=lambda n: n["label"])
        internal = sorted((n for n in nodes if n["kind"] == "internal_container"), key=lambda n: n["label"])
        self._rows = routes + internal
        for n in self._rows:
            meta = n["meta"]
            status = meta.get("status", "?")
            style = STATUS_STYLE.get(status, "")
            status_cell = f"[{style}]{status}[/{style}]" if style else status
            if n["kind"] == "public_route":
                access = meta.get("access", "")
                table.add_row(status_cell, n["label"], "public route",
                              "public" if access == "None" else "gated",
                              meta.get("backing", ""))
            else:
                table.add_row(status_cell, n["label"], "internal only", "vps-local",
                              meta.get("image", "") or "-")
        pub = len(routes)
        self.query_one("#access-hint", Static).update(
            f"[dim]{pub} public routes, {len(internal)} internal-only — enter/click for detail[/dim]"
        )

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return
        n = self._rows[table.cursor_row]
        if n["kind"] == "public_route":
            text = f"[bold #3ad6d6]{n['meta'].get('url', '')}[/bold #3ad6d6]"
        else:
            text = f"[bold #3ad6d6]{n['label']}[/bold #3ad6d6]  [dim](internal container — not exposed via a tunnel route)[/dim]"
        self.query_one("#access-url", Static).update(text)


class AgentsPane(Horizontal):
    def compose(self) -> ComposeResult:
        with Vertical(id="agents-left"):
            yield DataTable(id="agents-table", zebra_stripes=True)
            yield Static("s=run now  enter=view log  r=refresh", id="agents-hint")
        yield Log(id="agents-log", highlight=True)

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns("job", "state", "last run", "last start")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        rows = []
        for job in gs.CLAUDE_AGENT_JOBS:
            st = gs._job_status(job)
            rows.append((job, st.get("active_state") or "?", st.get("last_start") or "?",
                         st.get("result"), st.get("exit_status")))
        self.app.call_from_thread(self._set, rows)

    def _set(self, rows: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._rows = rows
        for job, state, last, result, exit_status in rows:
            style = "#3ad6d6" if state == "active" else ("dim" if state in ("inactive", "dead") else "#3ad6d6")
            if last == "?" or not result:
                last_run = "[dim]never run[/dim]"
            elif result == "success" and (exit_status in (None, "", "0")):
                last_run = "[#3ad6d6]ok[/#3ad6d6]"
            else:
                last_run = f"[#e2534f]FAIL ({result})[/#e2534f]"
            table.add_row(job, f"[{style}]{state}[/{style}]", last_run, last)

    def selected_job(self):
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return None
        return self._rows[table.cursor_row][0]

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        job = self.selected_job()
        if job:
            self.show_log(job)

    def show_log(self, job: str) -> None:
        self.run_worker(lambda: self._load_log(job), thread=True, exclusive=True)

    def _load_log(self, job: str) -> None:
        path = os.path.join(AGENT_LOGS_DIR, f"{job}.log")
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()[-200:]
            text = "".join(lines) or "(empty log)"
        except OSError as e:
            text = f"(no log: {e})"
        self.app.call_from_thread(self._set_log, job, text)

    def _set_log(self, job: str, text: str) -> None:
        log = self.query_one("#agents-log", Log)
        log.clear()
        log.write(f"=== {job}.log (tail) ===\n{text}")


class FeedsPane(Horizontal):
    def compose(self) -> ComposeResult:
        with Vertical(id="feeds-left"):
            yield ListView(
                *[ListItem(Label(name), id=f"feed-{name}") for name in FEEDS],
                id="feeds-list",
            )
        with VerticalScroll(id="feeds-right"):
            yield Markdown("select a feed on the left", id="feeds-content")

    def on_mount(self) -> None:
        self.run_worker(self._load_staleness, thread=True, exclusive=True)

    def _load_staleness(self) -> None:
        ages = {}
        for name, fname in FEEDS.items():
            path = os.path.join(FEEDS_DIR, fname)
            try:
                ages[name] = _humanize_age(os.path.getmtime(path))
            except OSError:
                ages[name] = "missing"
        self.app.call_from_thread(self._set_staleness, ages)

    def _set_staleness(self, ages: dict) -> None:
        for name, age in ages.items():
            item = self.query_one(f"#feed-{name}", ListItem)
            item.query_one(Label).update(f"{name}  [dim]{age}[/dim]")

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        name = event.item.id.removeprefix("feed-")
        self.run_worker(lambda: self._load(name), thread=True, exclusive=True)

    def _load(self, name: str) -> None:
        path = os.path.join(FEEDS_DIR, FEEDS[name])
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            content = _latest_section(text)
            mtime = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")
            content = f"*last written {mtime}*\n\n---\n\n{content}"
        except OSError as e:
            content = f"(could not read {path}: {e})"
        self.app.call_from_thread(self._set, content)

    def _set(self, content: str) -> None:
        self.query_one("#feeds-content", Markdown).update(content)


class CronsPane(Vertical):
    def compose(self) -> ComposeResult:
        yield DataTable(id="crons-table", zebra_stripes=True, cursor_type="row")
        yield Static("[dim]z=restart failed unit  r=refresh[/dim]", id="crons-hint")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_column("status", width=6)
        table.add_column("timer/entry", width=60)
        table.add_column("kind", width=15)
        table.add_column("detail", width=35)
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        data = gs.cluster_crons()
        self.app.call_from_thread(self._set, data["nodes"])

    def _set(self, nodes: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._rows = nodes
        for n in nodes:
            meta = n["meta"]
            detail = meta.get("next_run") or meta.get("schedule") or ""
            if meta.get("failed"):
                status = "[#f06868]FAIL[/#f06868]"
            else:
                status = "[dim]ok[/dim]"
            label = n["label"]
            if len(label) > 58:
                label = label[:55] + "…"
            table.add_row(status, label, n["kind"], detail)

    def selected(self):
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return None
        return self._rows[table.cursor_row]


class UpdatesPane(Vertical):
    """apt/npm/pip/docker-image outdated packages, disk-cleanup timer status,
    and reclaimable docker space — the "what needs attention on the system
    layer" view the Home tiles only summarize."""

    def compose(self) -> ComposeResult:
        yield Static("", id="updates-summary")
        with Horizontal(id="updates-buttons"):
            yield Button("dry-run", id="btn-updates-dryrun")
            yield Button("apply updates", id="btn-updates-apply", variant="warning")
        yield DataTable(id="updates-table", zebra_stripes=True)
        yield Log(id="updates-log", highlight=True)

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("source", "package", "current", "latest")
        self.query_one("#updates-log", Log).display = False
        self.refresh_data()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-updates-dryrun":
            self._run_update_script(dry_run=True)
        elif event.button.id == "btn-updates-apply":
            def after(confirmed: bool | None) -> None:
                if confirmed:
                    self._run_update_script(dry_run=False)
            self.app.push_screen(
                ConfirmModal("Apply all pending apt/npm/pip updates now?"), after,
            )

    def _run_update_script(self, dry_run: bool) -> None:
        log = self.query_one("#updates-log", Log)
        log.display = True
        log.clear()
        cmd = ["bash", UPDATE_SCRIPT] + (["--dry-run"] if dry_run else [])
        log.write_line(f"$ {' '.join(cmd)}\n")
        self.app.query_one(Activity).log_event(
            "running update-system.sh --dry-run" if dry_run else "APPLYING system updates…"
        )
        self.run_worker(lambda: self._exec_update_script(cmd, dry_run), thread=True)

    def _exec_update_script(self, cmd: list, dry_run: bool) -> None:
        out = _run(cmd, timeout=300)
        self.app.call_from_thread(self.query_one("#updates-log", Log).write, out)
        self.app.call_from_thread(
            self.app.query_one(Activity).log_event,
            "dry-run complete" if dry_run else "updates applied",
        )
        if not dry_run:
            self.app.call_from_thread(self.refresh_data)

    def refresh_data(self) -> None:
        self.query_one("#updates-summary", Static).update("[dim]loading…[/dim]")
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        d = {
            "apt": _apt_upgradable(),
            "npm": _npm_outdated(),
            "pip": _pip_outdated(),
            "images": _docker_image_updates(),
            "reclaim": _docker_reclaimable(),
            "cleanup_last": _run(
                ["systemctl", "show", "disk-cleanup.timer", "--property=LastTriggerUSec"], timeout=5
            ).strip().split("=", 1)[-1],
        }
        self.app.call_from_thread(self._set, d)

    def _set(self, d: dict) -> None:
        table = self.query_one(DataTable)
        table.clear()
        for name in d["apt"]:
            table.add_row("apt", name, "-", "-")
        for row in d["npm"]:
            table.add_row("npm", row["name"], row["current"], row["latest"])
        for row in d["pip"]:
            table.add_row("pip", row["name"], row["current"], row["latest"])
        for line in d["images"]:
            table.add_row("docker", line[:80], "-", "-")

        reclaim_bits = [
            f"{k} {v}" for k, v in d["reclaim"].items()
            if v and not v.endswith("(0%)") and v != "0B"
        ]
        total = len(d["apt"]) + len(d["npm"]) + len(d["pip"]) + len(d["images"])
        summary = f"[bold]{total} updates pending[/bold]  ·  apt {len(d['apt'])}  npm {len(d['npm'])}  pip {len(d['pip'])}  docker images {len(d['images'])}\n"
        summary += f"disk-cleanup.timer last ran: {d['cleanup_last'] or 'unknown'}\n"
        summary += ("[bold #e8b64c]docker reclaimable: " + ", ".join(reclaim_bits) + "[/bold #e8b64c]"
                    if reclaim_bits else "[dim]nothing reclaimable in docker[/dim]")
        self.query_one("#updates-summary", Static).update(summary)


class AskPane(Vertical):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._history = ""

    def compose(self) -> ComposeResult:
        yield Input(placeholder="Ask about your setup — grounded in live data…", id="ask-input")
        with VerticalScroll(id="ask-scroll"):
            yield Markdown("*ask a question to get started*", id="ask-log")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        question = event.value.strip()
        if not question:
            return
        self._history += f"\n\n---\n\n**> {question}**\n\n*(thinking…)*"
        self.query_one("#ask-log", Markdown).update(self._history)
        self.query_one(Input).value = ""
        self.run_worker(lambda: self._ask(question), thread=True, exclusive=True)

    def _ask(self, question: str) -> None:
        try:
            result = gs.ask_claude(question, "")
            answer = result.get("answer", "(no response)")
        except Exception as e:  # noqa: BLE001
            answer = f"(error: {e})"
        self.app.call_from_thread(self._append, answer)

    def _append(self, answer: str) -> None:
        self._history = self._history.rsplit("*(thinking…)*", 1)[0] + answer
        self.query_one("#ask-log", Markdown).update(self._history)
        self.query_one("#ask-scroll", VerticalScroll).scroll_end(animate=False)


class OpsPane(Vertical):
    def compose(self) -> ComposeResult:
        with Horizontal(id="ops-buttons"):
            yield Button("self-audit", id="btn-audit")
            yield Button("backup-verify", id="btn-backup")
            yield Button("token usage", id="btn-usage")
            yield Button("health-check", id="btn-health")
        yield Log(id="ops-log", highlight=True)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        log = self.query_one("#ops-log", Log)
        jobs = {
            "btn-audit": (["bash", SELF_AUDIT_SCRIPT], "self-audit.sh", 60, {"PRINT_ONLY": "1"}),
            "btn-backup": (["bash", BACKUP_VERIFY_SCRIPT], "backup-verify.sh", 60, None),
            "btn-usage": (["ccusage", "daily"], "ccusage daily", 30, None),
            "btn-health": (["bash", HEALTH_SCRIPT], "health-check.sh", 30, None),
        }
        cmd, label, timeout, env_extra = jobs[event.button.id]
        log.write_line(f"\n$ {label}")
        self.app.query_one(Activity).log_event(f"ran {label}")
        self.run_worker(lambda: self._run_to_log(cmd, log, timeout, env_extra), thread=True)

    def _run_to_log(self, cmd, log: Log, timeout: int, env_extra: dict) -> None:
        env = os.environ.copy()
        if env_extra:
            env.update(env_extra)
        out = _run(cmd, timeout=timeout, env=env)
        self.app.call_from_thread(log.write, out)


# ── App shell ────────────────────────────────────────────────────────────

class JarvisApp(App):
    CSS = """
    Screen { background: $background; layout: horizontal; }

    #sidebar {
        width: 24; background: $surface; border-right: solid $panel;
        padding: 1 0;
    }
    #sidebar ListView { background: $surface; scrollbar-size: 0 0; }
    #sidebar ListItem {
        padding: 0 2; height: 3; content-align: left middle;
        border-left: thick $surface;
    }
    #sidebar ListItem.-highlight {
        background: $boost; border-left: thick $primary;
    }
    #sidebar Label { color: $text-muted; }
    #sidebar ListItem.-highlight Label { color: $text; text-style: bold; }
    #brand {
        padding: 1 2 2 2; color: $primary; text-style: bold;
        border-bottom: solid $panel; margin-bottom: 1;
    }

    #main { width: 1fr; }
    #main-content { height: 1fr; padding: 1 2; }
    #activity-bar {
        height: 1; background: $surface; color: $text-muted; padding: 0 2;
        border-top: solid $panel;
    }

    #home-loading { height: 3; }
    #dashboard-grid {
        layout: grid; grid-size: 4 6; grid-gutter: 1 1;
        grid-rows: 7 7 7 6 1fr 1fr; padding: 0 1;
    }
    .stat-tile {
        background: $surface; border: round $panel; padding: 0 1;
        height: 100%; border-title-color: $primary; border-title-style: bold;
    }
    .stat-tile.stat-border-ok { border: round $success; }
    .stat-tile.stat-border-warn { border: round $warning; }
    .stat-tile.stat-border-fail { border: round $error; }
    .stat-tile.stat-border-neutral { border: round $panel; }
    .stat-value { text-style: bold; height: 1fr; content-align: left middle; }
    .stat-value.stat-ok { color: $success; }
    .stat-value.stat-warn { color: $warning; }
    .stat-value.stat-fail { color: $error; }
    .stat-value.stat-neutral { color: $primary; }
    .stat-sub { color: $text-muted; }
    Graph { height: 1fr; }
    .panel {
        background: $surface; border: round $panel; padding: 1;
        column-span: 2; border-title-color: $primary; border-title-style: bold;
    }
    .panel.wide { column-span: 4; height: 1fr; }
    #home-cores { height: 100%; column-span: 3; }
    #home-procs { height: 1fr; }
    #home-issues { height: 1fr; }
    DataTable, Log {
        scrollbar-size: 1 1; scrollbar-background: $surface; scrollbar-background-hover: $surface;
        scrollbar-background-active: $surface; scrollbar-color: $panel-lighten-1;
        scrollbar-color-hover: $primary; scrollbar-color-active: $primary; scrollbar-corner-color: $surface;
    }
    DataTable { height: 1fr; }
    DataTable > .datatable--cursor { background: $boost; }
    #ops-buttons, #updates-buttons { height: 3; }
    #updates-log { height: 1fr; border: round $panel; margin-top: 1; }
    #ops-log { height: 1fr; border: round $panel; }
    #ask-scroll { height: 1fr; border: round $panel; }
    #ask-log { width: 1fr; padding: 0 1; }
    #agents-left { width: 45%; }
    #agents-log { width: 55%; border: round $panel; }
    #feeds-left { width: 28; }
    #feeds-right { width: 1fr; padding: 0 2; }
    #feeds-list { height: 1fr; }
    #containers-hint, #access-hint, #agents-hint { color: $text-muted; padding: 0 1; }
    #updates-summary {
        height: auto; padding: 1; background: $surface; border: round $panel;
        margin-bottom: 1;
    }
    #access-url { padding: 1; color: $primary; }
    """

    BINDINGS = [
        Binding("q", "quit", "quit"),
        Binding("r", "refresh_active", "refresh"),
        Binding("a", "container_start", "start"),
        Binding("x", "container_stop", "stop"),
        Binding("z", "container_restart", "restart"),
        Binding("s", "start_agent", "run job"),
        Binding("1", "goto('home')", "", show=False),
        Binding("2", "goto('containers')", "", show=False),
        Binding("3", "goto('access')", "", show=False),
        Binding("4", "goto('agents')", "", show=False),
        Binding("5", "goto('feeds')", "", show=False),
        Binding("6", "goto('crons')", "", show=False),
        Binding("7", "goto('updates')", "", show=False),
        Binding("8", "goto('ask')", "", show=False),
        Binding("9", "goto('ops')", "", show=False),
        Binding("l", "toggle_live", "toggle live"),
    ]
    TITLE = "Jarvis"
    AUTO_REFRESH_SECS = 15

    live = True

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal():
            with Vertical(id="sidebar"):
                yield Static("JARVIS", id="brand")
                yield ListView(
                    *[ListItem(Label(f"{glyph}  {num}  {label}"), id=f"nav-{key}")
                      for key, num, glyph, label in NAV_ITEMS],
                    id="nav",
                )
            with Vertical(id="main"):
                with ContentSwitcher(initial="home", id="main-content"):
                    yield HomePane(id="home")
                    yield ContainersPane(id="containers")
                    yield AccessPane(id="access")
                    yield AgentsPane(id="agents")
                    yield FeedsPane(id="feeds")
                    yield CronsPane(id="crons")
                    yield UpdatesPane(id="updates")
                    yield AskPane(id="ask")
                    yield OpsPane(id="ops")
                yield Activity(f"live — auto-refresh every {self.AUTO_REFRESH_SECS}s", id="activity-bar")
        yield Footer()

    def on_mount(self) -> None:
        self.register_theme(JARVIS_THEME)
        self.theme = "jarvis"
        self._refresh_timer = self.set_interval(self.AUTO_REFRESH_SECS, self._auto_refresh)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        if event.list_view.id == "nav":
            key = event.item.id.removeprefix("nav-")
            self.query_one(ContentSwitcher).current = key

    def action_goto(self, key: str) -> None:
        self.query_one(ContentSwitcher).current = key
        nav = self.query_one("#nav", ListView)
        for i, (k, *_rest) in enumerate(NAV_ITEMS):
            if k == key:
                nav.index = i

    def _refresh_pane(self, pane_id: str) -> None:
        switcher = self.query_one(ContentSwitcher)
        pane = switcher.get_child_by_id(pane_id)
        for child in pane.walk_children():
            if hasattr(child, "refresh_data"):
                child.refresh_data()

    def action_refresh_active(self) -> None:
        switcher = self.query_one(ContentSwitcher)
        self._refresh_pane(switcher.current)
        self.query_one(Activity).log_event("refreshed")

    def _auto_refresh(self) -> None:
        """Ticks every AUTO_REFRESH_SECS — only the visible pane pays the
        cost, so hidden tabs (Ask/Ops mid-command) are never disturbed."""
        if not self.live:
            return
        switcher = self.query_one(ContentSwitcher)
        current = switcher.current
        if current in ("ask", "ops"):
            return  # live free-text/command panes — a refresh here would clobber output
        self._refresh_pane(current)

    def action_toggle_live(self) -> None:
        self.live = not self.live
        state = f"live — auto-refresh every {self.AUTO_REFRESH_SECS}s" if self.live else "paused (press l to resume)"
        self.query_one(Activity).log_event(state)

    def _current_containers_pane(self):
        switcher = self.query_one(ContentSwitcher)
        if switcher.current != "containers":
            return None
        return switcher.get_child_by_id("containers")

    def action_container_start(self) -> None:
        self._container_action("start", "Start")

    def action_container_stop(self) -> None:
        self._container_action("stop", "Stop")

    def action_container_restart(self) -> None:
        if self._current_containers_pane() is not None:
            self._container_action("restart", "Restart")
        elif self._current_crons_pane() is not None:
            self._restart_cron_unit()

    def _container_action(self, verb: str, label: str) -> None:
        pane = self._current_containers_pane()
        if pane is None:
            return
        c = pane.selected()
        if not c:
            return
        name = c["name"]

        def after(confirmed: bool | None) -> None:
            if not confirmed:
                return
            self.query_one(Activity).log_event(f"{label.lower()}ing {name}…")
            self.run_worker(lambda: self._run_container_action(verb, name, pane), thread=True)

        self.push_screen(ConfirmModal(f"{label} container [bold]{name}[/bold]?"), after)

    def _run_container_action(self, verb: str, name: str, pane) -> None:
        out = _run(["docker", verb, name], timeout=30)
        self.call_from_thread(self.query_one(Activity).log_event, f"{verb} {name}: {out.strip() or 'done'}")
        self.call_from_thread(pane.refresh_data)

    def _current_crons_pane(self):
        switcher = self.query_one(ContentSwitcher)
        if switcher.current != "crons":
            return None
        return switcher.get_child_by_id("crons")

    def _restart_cron_unit(self) -> None:
        pane = self._current_crons_pane()
        if pane is None:
            return
        node = pane.selected()
        if not node or node["kind"] != "systemd_timer":
            return
        meta = node["meta"]
        if not meta.get("failed"):
            return
        unit = node["label"]

        def after(confirmed: bool | None) -> None:
            if not confirmed:
                return
            self.query_one(Activity).log_event(f"restarting {unit}…")
            self.run_worker(lambda: self._run_restart_unit(unit, pane), thread=True)

        self.push_screen(ConfirmModal(f"Restart failed unit [bold]{unit}[/bold]?"), after)

    def _run_restart_unit(self, unit: str, pane) -> None:
        out = _run(["sudo", "-n", "systemctl", "restart", unit], timeout=30)
        self.call_from_thread(self.query_one(Activity).log_event, out.strip() or f"{unit} restarted")
        self.call_from_thread(pane.refresh_data)

    def _current_agents_pane(self):
        switcher = self.query_one(ContentSwitcher)
        if switcher.current != "agents":
            return None
        return switcher.get_child_by_id("agents")

    def action_start_agent(self) -> None:
        pane = self._current_agents_pane()
        if pane is None:
            return
        job = pane.selected_job()
        if not job:
            return
        unit = f"claude-agent@{job}.service"

        def after(confirmed: bool | None) -> None:
            if not confirmed:
                return
            self.query_one(Activity).log_event(f"starting {unit}…")
            self.run_worker(lambda: self._run_start_job(unit, pane), thread=True)

        self.push_screen(ConfirmModal(f"Run agent job [bold]{job}[/bold] now?"), after)

    def _run_start_job(self, unit: str, pane) -> None:
        out = _run(["sudo", "-n", "systemctl", "start", unit], timeout=15)
        self.call_from_thread(self.query_one(Activity).log_event, out.strip() or f"{unit} started")
        self.call_from_thread(pane.refresh_data)


def main():
    JarvisApp().run()


if __name__ == "__main__":
    main()
