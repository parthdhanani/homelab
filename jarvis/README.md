# jarvis

Terminal control panel for the cryptex VPS. Run: `jarvis` (installed at `/usr/local/bin/jarvis`, same pattern as `cryptex-status`).

Reuses `graph-server/graph_server.py`'s live cluster loaders directly (no duplicated logic, no second data source) — same data the graph.psidex.com dashboard shows, in a terminal.

## Tabs

- **Overview** — live `cryptex-status.sh` run (containers, backup age, failed units, disk/mem, OB1 health)
- **Services** — every public route (from `TUNNEL.md`) and internal container, cross-checked against real `docker ps`/`systemctl` state → OK/FAIL/DISABLED/UNKNOWN
- **Agents** — the 13 `claude-agent@*` scheduled jobs with live systemd state + last run; `s` starts one now
- **Crons** — all systemd timers + root/ubuntu crontabs
- **Ask** — free-text questions answered by `claude -p`, grounded only in this session's live cluster data (read-only, no tool access)
- **Actions** — run `health-check.sh` / `cryptex-status.sh` on demand, output streamed to a log pane

## Keys

`r` refresh active tab · `o` open selected service's URL (prints it, doesn't auto-launch a browser from the VPS) · `s` start selected agent job · `q` quit

## Install

```
pip install --user -r requirements.txt
```

Already symlinked: `/usr/local/bin/jarvis -> /opt/cryptex/jarvis/jarvis`.
