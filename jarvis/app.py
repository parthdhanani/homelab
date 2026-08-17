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
    ("ask", "7", "?", "Ask"),
    ("ops", "8", "⚙", "Ops"),
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

class HomePane(Vertical):
    def compose(self) -> ComposeResult:
        yield LoadingIndicator(id="home-loading")
        yield Static("", id="home-body")

    def on_mount(self) -> None:
        self.query_one("#home-body", Static).display = False
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        text = f"[dim]refreshed {datetime.now().strftime('%H:%M:%S')} — r to refresh[/dim]\n\n"

        if os.path.exists(DAILY_REPORT):
            try:
                with open(DAILY_REPORT) as fh:
                    d = json.load(fh)
                verdict = d.get("verdict")
                vstyle = "bold #6fae6f" if verdict == "OK" else "bold #c15a5a"
                text += f"[bold #c9932f]DAILY VERDICT[/bold #c9932f]  [{vstyle}]{verdict}[/{vstyle}]"
                if d.get("issue_list"):
                    text += f"   [dim]{d['issue_list']}[/dim]"
                text += f"   [dim]({d.get('date','?')})[/dim]\n\n"
                sysd = d.get("system", {})
                text += (f"  disk {sysd.get('disk_human','?')}    "
                         f"mem free {sysd.get('mem_free_mb','?')}MB / {sysd.get('mem_total_mb','?')}MB    "
                         f"containers {sysd.get('containers_running','?')} up\n\n")
            except (json.JSONDecodeError, OSError):
                pass

        try:
            svc = gs.cluster_services()
            fails = [n for n in svc["nodes"] if n["meta"].get("status") == "FAIL"]
            ok = sum(1 for n in svc["nodes"] if n["meta"].get("status") == "OK")
            text += f"[bold #c9932f]SERVICES[/bold #c9932f]  [bold #6fae6f]{ok} OK[/bold #6fae6f]"
            if fails:
                text += f"  [bold #c15a5a]{len(fails)} FAILING: " + ", ".join(n["label"] for n in fails) + "[/bold #c15a5a]"
            text += f"  ·  {len(svc['nodes'])} total\n\n"
        except Exception:  # noqa: BLE001
            pass

        active_jobs = 0
        for job in gs.CLAUDE_AGENT_JOBS:
            if gs._job_status(job).get("active_state") == "active":
                active_jobs += 1
        text += f"[bold #c9932f]AGENTS[/bold #c9932f]  {len(gs.CLAUDE_AGENT_JOBS)} scheduled, {active_jobs} running now\n\n"

        out = _run(["bash", STATUS_SCRIPT], timeout=20)
        text += "[bold #c9932f]== cryptex-status ==[/bold #c9932f]\n"
        for line in out.splitlines():
            if line.startswith("!!"):
                text += f"[bold #c15a5a]{line}[/bold #c15a5a]\n"
            elif line.startswith("=="):
                text += f"\n[bold #c9932f]{line}[/bold #c9932f]\n"
            else:
                text += f"{line}\n"
        self.app.call_from_thread(self._set, text)

    def _set(self, text: str) -> None:
        self.query_one("#home-loading", LoadingIndicator).display = False
        body = self.query_one("#home-body", Static)
        body.display = True
        body.update(text)


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

    #home-body { padding: 0 1; }
    #home-loading { height: 3; }
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
        Binding("7", "goto('ask')", "", show=False),
        Binding("8", "goto('ops')", "", show=False),
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
