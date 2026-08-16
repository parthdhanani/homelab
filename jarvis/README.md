# jarvis

Terminal control panel for the cryptex VPS. Run: `jarvis` (installed at `/usr/local/bin/jarvis`, same pattern as `cryptex-status`).

Reuses `graph-server/graph_server.py`'s live cluster loaders directly (no duplicated logic, no second data source) — same data the graph.psidex.com dashboard shows, in a terminal.

## Tabs

- **Overview** — daily-report verdict (`/var/log/cryptex-daily-report.json`) + live `cryptex-status.sh` run
- **Services** — every public route (from `TUNNEL.md`) and internal container, cross-checked against real `docker ps`/`systemctl` state → OK/FAIL/DISABLED/UNKNOWN
- **Agents** — the 13 `claude-agent@*` scheduled jobs with live systemd state + last run; select a row to see its live log tail (last 200 lines) in the split pane; `s` starts one now
- **Feeds** — the actual content each agent job writes, not its log: news digest, deepdive, TIL/monitor, movies, github-trending, weekly-digest, ops-alerts — pulled straight from `PKM/00 Capture/Daily/Agents/*.md`, latest section only
- **Crons** — all systemd timers + root/ubuntu crontabs
- **Ask** — free-text questions answered by `claude -p`, grounded only in this session's live cluster data (read-only, no tool access)
- **Ops** — the real `/ops` toolset, wired to the same scripts it dispatches to: `self-audit.sh` (Claude-layer health), `backup-verify.sh` (Kopia integrity), `ccusage daily` (token usage), `health-check.sh`

## Keys

`r` refresh active tab · `o` open selected service's URL (prints it, doesn't auto-launch a browser from the VPS) · `s` start selected agent job · `q` quit

## Install

```
pip install --user -r requirements.txt
```

Already symlinked: `/usr/local/bin/jarvis -> /opt/cryptex/jarvis/jarvis`.
