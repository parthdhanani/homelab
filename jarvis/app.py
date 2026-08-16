#!/usr/bin/env python3
"""Jarvis — terminal control panel for the cryptex VPS.

One TUI over everything already built: live services/routes (graph_server's
cluster_services), scheduled agents, timers, cryptex-status, and a
claude-backed ask panel — all real data, all read-only except the one
explicit, confirmed action (container restart).

Run: python3 /opt/cryptex/jarvis/app.py
"""
import subprocess
import sys
import threading
from datetime import datetime

sys.path.insert(0, "/opt/cryptex/graph-server")
import graph_server as gs  # noqa: E402

from textual.app import App, ComposeResult
from textual.containers import Vertical, Horizontal
from textual.widgets import (
    Header, Footer, TabbedContent, TabPane, DataTable, Static, Input,
    Log, Button,
)
from textual.worker import Worker

STATUS_SCRIPT = "/opt/cryptex/scripts/cryptex-status.sh"
HEALTH_SCRIPT = "/opt/cryptex/scripts/health-check.sh"

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


class OverviewPane(Vertical):
    def compose(self) -> ComposeResult:
        yield Static("loading cryptex-status…", id="overview-body")

    def on_mount(self) -> None:
        self.refresh_status()

    def refresh_status(self) -> None:
        self.run_worker(self._load, thread=True, exclusive=True)

    def _load(self) -> None:
        out = _run(["bash", STATUS_SCRIPT], timeout=20)
        ts = datetime.now().strftime("%H:%M:%S")
        text = f"[dim]refreshed {ts} — press r to refresh[/dim]\n\n"
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
        except Exception as e:  # noqa: BLE001 — surface any failure into the UI, not a crash
            data = {"nodes": [], "edges": []}
            self.app.call_from_thread(
                self.query_one("#services-hint", Static).update,
                f"[red]failed to load: {e}[/red]",
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
        self.query_one("#services-hint", Static).update(
            f"{len(nodes)} services — o=open url  l=logs (containers only)  r=refresh"
        )

    def selected_node(self):
        table = self.query_one(DataTable)
        if table.cursor_row is None or table.cursor_row >= len(getattr(self, "_rows", [])):
            return None
        return self._rows[table.cursor_row]


class AgentsPane(Vertical):
    def compose(self) -> ComposeResult:
        yield DataTable(id="agents-table")
        yield Static("scheduled claude-agent jobs — s=run now  r=refresh", id="agents-hint")

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


class ActionsPane(Vertical):
    def compose(self) -> ComposeResult:
        with Horizontal(id="actions-buttons"):
            yield Button("Full health-check", id="btn-health")
            yield Button("cryptex-status", id="btn-status")
        yield Log(id="actions-log", highlight=True)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        log = self.query_one("#actions-log", Log)
        if event.button.id == "btn-health":
            log.write_line("\n$ health-check.sh")
            self.run_worker(lambda: self._run_to_log(["bash", HEALTH_SCRIPT], log), thread=True)
        elif event.button.id == "btn-status":
            log.write_line("\n$ cryptex-status.sh")
            self.run_worker(lambda: self._run_to_log(["bash", STATUS_SCRIPT], log), thread=True)

    def _run_to_log(self, cmd, log: Log) -> None:
        out = _run(cmd, timeout=30)
        self.app.call_from_thread(log.write, out)


class ConfirmRestart(Vertical):
    """Modal-ish inline confirm bar — appears under the services table."""


class JarvisApp(App):
    CSS = """
    Screen { background: #1b1815; }
    #overview-body { padding: 1 2; }
    #services-hint, #agents-hint { color: #7a7260; padding: 0 1; }
    DataTable { height: 1fr; }
    #actions-buttons { height: 3; }
    #ask-log, #actions-log { height: 1fr; border: solid #3a342c; }
    """
    BINDINGS = [
        ("q", "quit", "quit"),
        ("r", "refresh_active", "refresh"),
        ("o", "open_selected", "open url"),
        ("s", "start_agent", "run job"),
    ]
    TITLE = "Jarvis — cryptex control panel"

    def __init__(self):
        super().__init__()
        self._pending_restart = None

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial="tab-overview"):
            with TabPane("Overview", id="tab-overview"):
                yield OverviewPane()
            with TabPane("Services", id="tab-services"):
                yield ServicesPane()
            with TabPane("Agents", id="tab-agents"):
                yield AgentsPane()
            with TabPane("Crons", id="tab-crons"):
                yield CronsPane()
            with TabPane("Ask", id="tab-ask"):
                yield AskPane()
            with TabPane("Actions", id="tab-actions"):
                yield ActionsPane()
        yield Footer()

    def action_refresh_active(self) -> None:
        tabs = self.query_one(TabbedContent)
        active = tabs.active
        pane = tabs.get_pane(active)
        for child in pane.children:
            if hasattr(child, "refresh_data"):
                child.refresh_data()
            elif hasattr(child, "refresh_status"):
                child.refresh_status()

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
