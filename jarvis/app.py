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

sys.path.insert(0, "/opt/cryptex/graph-server")
import graph_server as gs  # noqa: E402

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal, VerticalScroll, Container
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import (
    Header, Footer, Static, Input, Log, Button, ListView, ListItem, Label,
    Markdown, DataTable, ContentSwitcher, Rule, LoadingIndicator, Sparkline,
)

# A real design-token theme (Textual's Theme system — same mechanism behind
# its builtin "nord"/"gruvbox" themes) instead of hex scattered through the
# stylesheet. One source of truth for every color; CSS below only ever
# references the $tokens.
JARVIS_THEME = Theme(
    name="jarvis",
    dark=True,
    primary="#c9932f",       # brass — accent, focus, active nav
    secondary="#8a7550",
    accent="#c9932f",
    warning="#d1a94a",
    error="#c15a5a",
    success="#6fae6f",
    foreground="#e8e0d0",
    background="#17140f",
    surface="#1d1912",
    panel="#221d15",
    boost="#2a241a",
)

STATUS_SCRIPT = "/opt/cryptex/scripts/cryptex-status.sh"
HEALTH_SCRIPT = "/opt/cryptex/scripts/health-check.sh"
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
    "OK": "bold #6fae6f", "FAIL": "bold #c15a5a",
    "DISABLED": "dim", "UNKNOWN": "bold #d1a94a",
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
        return [ln.split("/")[0] for ln in out.splitlines() if ln and not ln.startswith("Listing")]
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
    """One glanceable metric: label, big value, one-line sub-detail — all
    colored by status. The unit of the Home grid (btop/wtfutil-style: many
    of these tiled on screen at once beats one long scrolling status dump)."""

    def __init__(self, label: str, tile_id: str):
        super().__init__(id=tile_id, classes="stat-tile")
        self.label_text = label

    def compose(self) -> ComposeResult:
        yield Static(self.label_text, classes="stat-label")
        yield Static("—", classes="stat-value", id=f"{self.id}-value")
        yield Static("", classes="stat-sub", id=f"{self.id}-sub")

    def set_value(self, value: str, sub: str = "", status: str = "neutral") -> None:
        v = self.query_one(f"#{self.id}-value", Static)
        v.update(value)
        v.set_classes(f"stat-value stat-{status}")
        self.query_one(f"#{self.id}-sub", Static).update(sub)


class SparkTile(Vertical):
    """Stat tile backed by a live trend line instead of a static number —
    history persists across refreshes for the life of the app."""

    def __init__(self, label: str, tile_id: str):
        super().__init__(id=tile_id, classes="stat-tile")
        self.label_text = label
        self.history: list = []

    def compose(self) -> ComposeResult:
        yield Static(self.label_text, classes="stat-label")
        # Sparkline colors each bar by its value's position within the
        # *current window's own* min/max — a flat-low series still paints
        # solid max_color. Pin both ends to the same accent so the shape
        # of the trend carries the signal, not a misleading per-bar tint.
        yield Sparkline([], id=f"{self.id}-spark", min_color="#c9932f", max_color="#c9932f")
        yield Static("", classes="stat-sub", id=f"{self.id}-sub")

    def push(self, value: float, sub: str = "") -> None:
        self.history.append(value)
        self.history = self.history[-40:]
        self.query_one(Sparkline).data = self.history
        self.query_one(f"#{self.id}-sub", Static).update(sub)


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
            yield SparkTile("HOST CPU", "tile-host-cpu")
            yield SparkTile("HOST MEM", "tile-host-mem")
            yield SparkTile("LOAD (1m)", "tile-load")
            yield StatTile("RECLAIMABLE", "tile-reclaim")
            yield Static("", id="home-issues", classes="panel wide")
            yield Static("", id="home-feed", classes="panel wide")

    def on_mount(self) -> None:
        self.query_one("#dashboard-grid").display = False
        self.refresh_data()

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

        d["active_jobs"] = sum(
            1 for job in gs.CLAUDE_AGENT_JOBS
            if gs._job_status(job).get("active_state") == "active"
        )

        try:
            with open("/var/log/cryptex-restore-check.log") as fh:
                lines = fh.readlines()
            d["backup_line"] = lines[-1].strip() if lines else ""
        except OSError:
            d["backup_line"] = ""

        cleanup_out = _run(["systemctl", "show", "disk-cleanup.timer",
                             "--property=LastTriggerUSec"], timeout=5)
        d["cleanup_last"] = cleanup_out.strip().split("=", 1)[-1] if "=" in cleanup_out else ""

        d["host_cpu"] = psutil.cpu_percent(interval=0.5)
        vm = psutil.virtual_memory()
        d["host_mem"] = vm.percent
        d["load1"], d["load5"], d["load15"] = os.getloadavg()

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

        self.query_one("#tile-agents", StatTile).set_value(
            str(len(gs.CLAUDE_AGENT_JOBS)),
            f"{d['active_jobs']} running now" if d["active_jobs"] else "idle",
            "warn" if d["active_jobs"] else "neutral",
        )

        backup_status, backup_value, backup_sub = "neutral", "?", "no drill log"
        if d["backup_line"]:
            date_str = d["backup_line"].split(" DRILL ", 1)[0]
            try:
                age_days = (datetime.now() - datetime.strptime(date_str, "%Y-%m-%d")).days
                backup_status = "ok" if age_days < 2 else ("warn" if age_days < 7 else "fail")
                backup_value = f"{age_days}d ago"
                backup_sub = "drill passed" if backup_status == "ok" else "drill stale — check"
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

        self.query_one("#tile-host-cpu", SparkTile).push(d["host_cpu"], f"{d['host_cpu']:.0f}% of {psutil.cpu_count()} cores")
        self.query_one("#tile-host-mem", SparkTile).push(d["host_mem"], f"{d['host_mem']:.0f}% used")
        load_status = "fail" if d["load1"] >= psutil.cpu_count() * 2 else ("warn" if d["load1"] >= psutil.cpu_count() else "ok")
        self.query_one("#tile-load", SparkTile).push(d["load1"], f"{d['load1']:.2f} / {d['load5']:.2f} / {d['load15']:.2f}")

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

        issues = f"[bold]VERDICT:[/bold] {d['verdict']}"
        if d["issue_list"]:
            issues += f"  —  {d['issue_list']}"
        if d["fails"]:
            issues += "\n[bold #c15a5a]services down:[/bold #c15a5a] " + ", ".join(n["label"] for n in d["fails"])
        if d["unhealthy"]:
            issues += "\n[bold #c15a5a]unhealthy containers:[/bold #c15a5a] " + ", ".join(d["unhealthy"])
        if total_updates:
            issues += f"\n[bold #d1a94a]{total_updates} package/image updates pending[/bold #d1a94a] — see Updates (7)"
        if reclaim_bits:
            issues += "\n[dim]docker reclaimable: " + ", ".join(reclaim_bits) + " — r on Containers won't clear this, run docker system prune[/dim]"
        if not d["fails"] and not d["unhealthy"] and not d["issue_list"] and not total_updates:
            issues += "\n[dim]nothing needs attention[/dim]"
        self.query_one("#home-issues", Static).update(issues)

        if d["newest_feed"]:
            age_min = int((datetime.now().timestamp() - d["newest_mtime"]) / 60)
            age = f"{age_min}m ago" if age_min < 60 else f"{age_min // 60}h ago"
            feed_text = f"[bold]LATEST FEED:[/bold] {d['newest_feed']} · {age}\n[dim]{d['newest_preview']}[/dim]"
        else:
            feed_text = "[bold]LATEST FEED:[/bold]\n[dim]no feed files found[/dim]"
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
            style = STATUS_STYLE.get(state, "#c15a5a" if state == "DOWN" else "")
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
            text = f"[bold #c9932f]{n['meta'].get('url', '')}[/bold #c9932f]"
        else:
            text = f"[bold #c9932f]{n['label']}[/bold #c9932f]  [dim](internal container — not exposed via a tunnel route)[/dim]"
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
        table.add_columns("job", "state", "last start")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        rows = []
        for job in gs.CLAUDE_AGENT_JOBS:
            st = gs._job_status(job)
            rows.append((job, st.get("active_state") or "?", st.get("last_start") or "?"))
        self.app.call_from_thread(self._set, rows)

    def _set(self, rows: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._rows = rows
        for job, state, last in rows:
            style = "#6fae6f" if state == "active" else ("dim" if state in ("inactive", "dead") else "#c9932f")
            table.add_row(job, f"[{style}]{state}[/{style}]", last)

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
        yield DataTable(id="crons-table", zebra_stripes=True)

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("timer/entry", "kind", "detail")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        data = gs.cluster_crons()
        self.app.call_from_thread(self._set, data["nodes"])

    def _set(self, nodes: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        for n in nodes:
            meta = n["meta"]
            detail = meta.get("next_run") or meta.get("schedule") or ""
            table.add_row(n["label"], n["kind"], detail)


class UpdatesPane(Vertical):
    """apt/npm/pip/docker-image outdated packages, disk-cleanup timer status,
    and reclaimable docker space — the "what needs attention on the system
    layer" view the Home tiles only summarize."""

    def compose(self) -> ComposeResult:
        yield Static("", id="updates-summary")
        yield DataTable(id="updates-table", zebra_stripes=True)

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("source", "package", "current", "latest")
        self.refresh_data()

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
        summary += ("[bold #d1a94a]docker reclaimable: " + ", ".join(reclaim_bits) + "[/bold #d1a94a]"
                    if reclaim_bits else "[dim]nothing reclaimable in docker[/dim]")
        self.query_one("#updates-summary", Static).update(summary)


class AskPane(Vertical):
    def compose(self) -> ComposeResult:
        yield Input(placeholder="Ask about your setup — grounded in live data…", id="ask-input")
        yield Log(id="ask-log", highlight=True)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        question = event.value.strip()
        if not question:
            return
        log = self.query_one("#ask-log", Log)
        log.write_line(f"\n> {question}")
        log.write_line("(thinking…)")
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
        log = self.query_one("#ask-log", Log)
        log.write_line(answer)


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
    #sidebar ListView { background: $surface; }
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
        layout: grid; grid-size: 4 5; grid-gutter: 1 1;
        grid-rows: 7 7 7 1fr 1fr; padding: 0 1;
    }
    .stat-tile {
        background: $surface; border: solid $panel; padding: 0 1;
        height: 100%;
    }
    .stat-label { color: $text-muted; text-style: bold; }
    .stat-value { text-style: bold; height: 1fr; content-align: left middle; }
    .stat-value.stat-ok { color: $success; }
    .stat-value.stat-warn { color: $warning; }
    .stat-value.stat-fail { color: $error; }
    .stat-value.stat-neutral { color: $primary; }
    .stat-sub { color: $text-muted; }
    #tile-cpu Sparkline { height: 1fr; }
    .panel {
        background: $surface; border: solid $panel; padding: 1;
        column-span: 2;
    }
    .panel.wide { column-span: 4; height: 1fr; }
    DataTable { height: 1fr; }
    DataTable > .datatable--cursor { background: $boost; }
    #ops-buttons { height: 3; }
    #ask-log, #ops-log { height: 1fr; border: solid $panel; }
    #agents-left { width: 45%; }
    #agents-log { width: 55%; border: solid $panel; }
    #feeds-left { width: 28; }
    #feeds-right { width: 1fr; padding: 0 2; }
    #feeds-list { height: 1fr; }
    #containers-hint, #access-hint, #agents-hint { color: $text-muted; padding: 0 1; }
    #updates-summary { height: auto; padding: 1; background: $surface; border: solid $panel; margin-bottom: 1; }
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
        self._container_action("restart", "Restart")

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
