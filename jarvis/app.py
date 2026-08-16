#!/usr/bin/env python3
"""Jarvis — terminal assistant for the cryptex VPS.

Not a status page: this is the same surface `/ops` and the claude-agents
feeds already produce, brought into one place you can move through with a
keyboard. Read-only except two explicit actions (start an agent job now,
open a service URL) — both require you to select the row first.

Run: jarvis   (installed at /usr/local/bin/jarvis -> this file)
"""
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, "/opt/cryptex/graph-server")
import graph_server as gs  # noqa: E402

from textual.app import App, ComposeResult
from textual.containers import Vertical, Horizontal, VerticalScroll
from textual.widgets import (
    Header, Footer, TabbedContent, TabPane, DataTable, Static, Input,
    Log, Button, ListView, ListItem, Label, Markdown,
)

STATUS_SCRIPT = "/opt/cryptex/scripts/cryptex-status.sh"
HEALTH_SCRIPT = "/opt/cryptex/scripts/health-check.sh"
SELF_AUDIT_SCRIPT = os.path.expanduser("~/.claude/scripts/self-audit.sh")
BACKUP_VERIFY_SCRIPT = "/opt/cryptex/scripts/backup-verify.sh"
DAILY_REPORT = "/var/log/cryptex-daily-report.json"
AGENT_LOGS_DIR = os.path.expanduser("~/claude-agents/logs")
FEEDS_DIR = "/opt/cryptex/data/pkm/00 Capture/Daily/Agents"

# label -> feed filename. This is the actual content each claude-agent job
# produces (not its pass/fail log) — what the user calls "my agents' feeds".
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
    "OK": "bold green", "FAIL": "bold red",
    "DISABLED": "dim", "UNKNOWN": "yellow",
}


def _run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return "(timed out)"
    except OSError as e:
        return f"(failed to run: {e})"


def _latest_section(text: str) -> str:
    """These feed files are append-only, one '## <timestamp>' section per run.
    Return only the last section — the rest is history, not today's feed."""
    parts = text.split("\n## ")
    if len(parts) <= 1:
        return text.strip()
    return ("## " + parts[-1]).strip()


class OverviewPane(Vertical):
    def compose(self) -> ComposeResult:
        yield Static("loading…", id="overview-body")

    def on_mount(self) -> None:
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        text = f"[dim]refreshed {datetime.now().strftime('%H:%M:%S')} — r to refresh[/dim]\n\n"

        verdict, issue_list = None, None
        if os.path.exists(DAILY_REPORT):
            try:
                with open(DAILY_REPORT) as fh:
                    d = json.load(fh)
                verdict = d.get("verdict")
                issue_list = d.get("issue_list")
                vstyle = "bold green" if verdict == "OK" else "bold red"
                text += f"[bold #c9932f]== daily report ({d.get('date', '?')}) ==[/bold #c9932f]\n"
                text += f"verdict: [{vstyle}]{verdict}[/{vstyle}]"
                if issue_list:
                    text += f"  ({issue_list})"
                text += "\n"
                sysd = d.get("system", {})
                text += (f"disk {sysd.get('disk_human','?')}  ·  "
                         f"mem free {sysd.get('mem_free_mb','?')}MB/{sysd.get('mem_total_mb','?')}MB  ·  "
                         f"containers {sysd.get('containers_running','?')}\n\n")
            except (json.JSONDecodeError, OSError):
                pass

        out = _run(["bash", STATUS_SCRIPT], timeout=20)
        for line in out.splitlines():
            if line.startswith("!!"):
                text += f"[bold red]{line}[/bold red]\n"
            elif line.startswith("=="):
                text += f"\n[bold #c9932f]{line}[/bold #c9932f]\n"
            else:
                text += f"{line}\n"
        self.app.call_from_thread(self._set, text)

    def _set(self, text: str) -> None:
        self.query_one("#overview-body", Static).update(text)


class ServicesPane(Vertical):
    def compose(self) -> ComposeResult:
        yield DataTable(id="services-table")
        yield Static("", id="services-hint")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns("status", "name", "kind", "detail")
        self.refresh_data()

    def refresh_data(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        try:
            data = gs.cluster_services()
        except Exception as e:  # noqa: BLE001 — surface failure into the UI, not a crash
            data = {"nodes": []}
            self.app.call_from_thread(
                self.query_one("#services-hint", Static).update, f"[red]failed: {e}[/red]",
            )
        self.app.call_from_thread(self._set, data["nodes"])

    def _set(self, nodes: list) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._rows = []
        for n in sorted(nodes, key=lambda n: (n["meta"].get("status") != "FAIL", n["label"])):
            meta = n["meta"]
            status = meta.get("status", "?")
            style = STATUS_STYLE.get(status, "")
            detail = meta.get("target") or meta.get("backing") or ""
            table.add_row(f"[{style}]{status}[/{style}]" if style else status,
                          n["label"], n["kind"], detail)
            self._rows.append(n)
        fails = sum(1 for n in nodes if n["meta"].get("status") == "FAIL")
        self.query_one("#services-hint", Static).update(
            f"{len(nodes)} services, {fails} failing — o=open url  r=refresh"
        )

    def selected_node(self):
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return None
        return self._rows[table.cursor_row]


class AgentsPane(Horizontal):
    """Table of scheduled jobs on the left, live log tail of the selected job on the right."""

    def compose(self) -> ComposeResult:
        with Vertical(id="agents-left"):
            yield DataTable(id="agents-table")
            yield Static("s=run now  enter/click=view log  r=refresh", id="agents-hint")
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
            style = "green" if state == "active" else ("dim" if state in ("inactive", "dead") else "yellow")
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
    """List of agent-produced content feeds; latest section rendered on the right."""

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
        yield DataTable(id="crons-table")

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
    """The real, deterministic /ops tools — not a second Overview."""

    def compose(self) -> ComposeResult:
        with Horizontal(id="ops-buttons"):
            yield Button("self-audit (Claude layer)", id="btn-audit")
            yield Button("backup-verify", id="btn-backup")
            yield Button("token usage (ccusage)", id="btn-usage")
            yield Button("health-check", id="btn-health")
        yield Log(id="ops-log", highlight=True)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        log = self.query_one("#ops-log", Log)
        jobs = {
            "btn-audit": (["bash", SELF_AUDIT_SCRIPT], "PRINT_ONLY=1 self-audit.sh", 60,
                           {"PRINT_ONLY": "1"}),
            "btn-backup": (["bash", BACKUP_VERIFY_SCRIPT], "backup-verify.sh", 60, None),
            "btn-usage": (["ccusage", "daily"], "ccusage daily", 30, None),
            "btn-health": (["bash", HEALTH_SCRIPT], "health-check.sh", 30, None),
        }
        cmd, label, timeout, env_extra = jobs[event.button.id]
        log.write_line(f"\n$ {label}")
        self.run_worker(lambda: self._run_to_log(cmd, log, timeout, env_extra), thread=True)

    def _run_to_log(self, cmd, log: Log, timeout: int, env_extra: dict) -> None:
        env = os.environ.copy()
        if env_extra:
            env.update(env_extra)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
            out = (p.stdout or "") + (p.stderr or "")
        except subprocess.TimeoutExpired:
            out = "(timed out)"
        except OSError as e:
            out = f"(failed to run: {e})"
        self.app.call_from_thread(log.write, out)


class JarvisApp(App):
    CSS = """
    Screen { background: #1b1815; }
    #overview-body { padding: 1 2; }
    #services-hint, #agents-hint { color: #7a7260; padding: 0 1; }
    DataTable { height: 1fr; }
    #ops-buttons { height: 3; }
    #ask-log, #ops-log { height: 1fr; border: solid #3a342c; }
    #agents-left { width: 45%; }
    #agents-log { width: 55%; border: solid #3a342c; }
    #feeds-left { width: 28; }
    #feeds-right { width: 1fr; padding: 1 2; }
    #feeds-list { height: 1fr; }
    """
    BINDINGS = [
        ("q", "quit", "quit"),
        ("r", "refresh_active", "refresh"),
        ("o", "open_selected", "open url"),
        ("s", "start_agent", "run job"),
    ]
    TITLE = "Jarvis — cryptex assistant"

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial="tab-overview"):
            with TabPane("Overview", id="tab-overview"):
                yield OverviewPane()
            with TabPane("Services", id="tab-services"):
                yield ServicesPane()
            with TabPane("Agents", id="tab-agents"):
                yield AgentsPane()
            with TabPane("Feeds", id="tab-feeds"):
                yield FeedsPane()
            with TabPane("Crons", id="tab-crons"):
                yield CronsPane()
            with TabPane("Ask", id="tab-ask"):
                yield AskPane()
            with TabPane("Ops", id="tab-ops"):
                yield OpsPane()
        yield Footer()

    def action_refresh_active(self) -> None:
        tabs = self.query_one(TabbedContent)
        pane = tabs.get_pane(tabs.active)
        for child in pane.walk_children():
            if hasattr(child, "refresh_data"):
                child.refresh_data()

    def action_open_selected(self) -> None:
        tabs = self.query_one(TabbedContent)
        if tabs.active != "tab-services":
            return
        pane = tabs.get_pane("tab-services").children[0]
        node = pane.selected_node()
        if not node:
            return
        url = node["meta"].get("url")
        if url:
            self.notify(f"open manually: {url}")
        else:
            self.notify("no public url for this node", severity="warning")

    def action_start_agent(self) -> None:
        tabs = self.query_one(TabbedContent)
        if tabs.active != "tab-agents":
            return
        pane = tabs.get_pane("tab-agents").children[0]
        job = pane.selected_job()
        if not job:
            return
        unit = f"claude-agent@{job}.service"
        self.notify(f"starting {unit} …")
        self.run_worker(lambda: self._start_job(unit, pane), thread=True)

    def _start_job(self, unit: str, pane) -> None:
        out = _run(["sudo", "-n", "systemctl", "start", unit], timeout=15)
        self.call_from_thread(self.notify, out or f"{unit} started")
        self.call_from_thread(pane.refresh_data)


def main():
    JarvisApp().run()


if __name__ == "__main__":
    main()
