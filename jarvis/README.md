# jarvis

The cryptex control panel, in a terminal. Run: `jarvis` (installed at `/usr/local/bin/jarvis`, same pattern as `cryptex-status`).

Sidebar-navigated, live by default (auto-refreshes every 15s), reuses `graph-server/graph_server.py`'s cluster loaders directly — same live truth the graph.psidex.com dashboard shows, no second data source to drift out of sync.

## Sections (sidebar, number keys 1-8)

- **1 Home** — daily-report verdict, services OK/FAIL summary, agents-running count, then the full `cryptex-status.sh` dump
- **2 Containers** — all 16 containers with live `docker stats` (cpu/mem), uptime, ports. `a` start · `x` stop · `z` restart — each behind a confirm prompt
- **3 Access** — every service on the box, public or not, one table: 15 public routes (status, gated/public, real URL on select) plus 12 internal-only containers (status, image, ports) that never had a home before
- **4 Agents** — the 13 `claude-agent@*` scheduled jobs; select a row for its live log tail (last 200 lines) in the split pane; `s` runs one now (confirmed)
- **5 Feeds** — the actual content each agent job writes, not its log: news digest, deepdive, TIL/monitor, movies, github-trending, weekly-digest, ops-alerts — from `PKM/00 Capture/Daily/Agents/*.md`, latest section only
- **6 Crons** — all systemd timers + root/ubuntu crontabs
- **7 Ask** — free-text questions answered by `claude -p`, grounded only in this session's live cluster data (read-only, no tool access)
- **8 Ops** — the real `/ops` toolset: `self-audit.sh` (Claude-layer health), `backup-verify.sh` (Kopia integrity), `ccusage daily` (token usage), `health-check.sh`

## Keys

`1`-`8` jump to a section · `r` refresh current section · `l` pause/resume live auto-refresh · `a`/`x`/`z` start/stop/restart selected container · `s` run selected agent job now · `q` quit

Every mutating action (container start/stop/restart, run agent job) requires an explicit confirm and logs one line to the Activity bar at the bottom.

## Install

```
pip install --user -r requirements.txt
```

Already symlinked: `/usr/local/bin/jarvis -> /opt/cryptex/jarvis/jarvis`.
