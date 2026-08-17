# jarvis

The cryptex control panel, in a terminal. Run: `jarvis` (installed at `/usr/local/bin/jarvis`, same pattern as `cryptex-status`).

Sidebar-navigated, live by default (auto-refreshes every 15s), reuses `graph-server/graph_server.py`'s cluster loaders directly — same live truth the graph.psidex.com dashboard shows, no second data source to drift out of sync.

Styled with a real Textual `Theme` (design tokens, not scattered hex) matching the graph-viz instrument-panel palette — brass accent on warm graphite. Tables use zebra striping for row-scannability; the sidebar's active section gets an accent-colored left border, not just a background tint; data loads show a spinner instead of a static "loading…" label until real content lands.

Home is a fixed **grid dashboard** (btop/wtfutil pattern), not a scrolling status dump — 8 color-coded stat tiles (services, containers, disk, memory, agents, backup-drill freshness, health-check pass/warn/fail, pending package/image updates) plus 3 live sparklines (host CPU, host memory, 1-min load average — real `psutil`/`os.getloadavg()` host stats, not aggregated docker-container usage), a reclaimable-disk-space tile, an issues panel, and a latest-feed preview, all visible on screen at once. Tiles go green/amber/red by real threshold (disk ≥85% fail, ≥70% warn; mem ≥90%/≥75%; backup drill stale after 2/7 days; load ≥1x cores warn, ≥2x fail), so a problem is visible without navigating anywhere.

## Sections (sidebar, number keys 1-9)

- **1 Home** — glanceable grid dashboard: 8 stat tiles + 3 live host-resource sparklines + reclaimable-space tile + issues + latest feed, all at once
- **2 Containers** — all 16 containers with live `docker stats` (cpu/mem), uptime, ports. `a` start · `x` stop · `z` restart — each behind a confirm prompt
- **3 Access** — every service on the box, public or not, one table: 15 public routes (status, gated/public, real URL on select) plus 12 internal-only containers (status, image, ports) that never had a home before
- **4 Agents** — the 13 `claude-agent@*` scheduled jobs; select a row for its live log tail (last 200 lines) in the split pane; `s` runs one now (confirmed)
- **5 Feeds** — the actual content each agent job writes, not its log: news digest, deepdive, TIL/monitor, movies, github-trending, weekly-digest, ops-alerts — from `PKM/00 Capture/Daily/Agents/*.md`, latest section only
- **6 Crons** — all systemd timers + root/ubuntu crontabs
- **7 Updates** — every outdated package/image in one table: `apt list --upgradable`, `npm outdated -g`, `pip list --outdated`, plus dockhand's log-reported image updates and `docker system df` reclaimable space per type. Slow calls (apt/npm/pip, ~15s combined) are cached 5 min so the 15s auto-refresh doesn't re-pay the cost on every tick. To actually apply what this pane shows, run `scripts/update-system.sh` (`--dry-run` to preview) — it upgrades apt/npm/pip-user-owned packages safely (skips apt-owned `python3-*` dist-packages and anything pinned by another installed package) and reports Dockhand's pending image updates without auto-pulling them
- **8 Ask** — free-text questions answered by `claude -p`, grounded only in this session's live cluster data (read-only, no tool access)
- **9 Ops** — the real `/ops` toolset: `self-audit.sh` (Claude-layer health), `backup-verify.sh` (Kopia integrity), `ccusage daily` (token usage), `health-check.sh`

## Keys

`1`-`9` jump to a section · `r` refresh current section · `l` pause/resume live auto-refresh · `a`/`x`/`z` start/stop/restart selected container · `s` run selected agent job now · `q` quit

Every mutating action (container start/stop/restart, run agent job) requires an explicit confirm and logs one line to the Activity bar at the bottom.

## Install

```
pip install --user -r requirements.txt
```

Already symlinked: `/usr/local/bin/jarvis -> /opt/cryptex/jarvis/jarvis`.
