# Cloudflare Tunnel Routes — Local Audit Baseline

The tunnel is dashboard-managed (token-only, no local config). This file is the
local record to diff against — update it when routes change in the CF dashboard.
Last verified: 2026-07-09.

| Hostname | Target | ZT Access |
|---|---|---|
| code.psidex.com | 172.18.0.1:8084 (host code-server via nginx) | Yes |
| term.psidex.com | 172.18.0.1:8085 (cryptex-terminal / ghostty-web + herdr, host service via nginx) | Yes |
| go.psidex.com | 172.18.0.42:8080 (shlink) | None — short links must be public |
| links.psidex.com | 172.18.0.43:8080 (shlink-web) | Yes |
| analytics.psidex.com | 172.18.0.44:3000 (umami) | Yes + Bypass /api/send |
| status.psidex.com | 172.18.0.41:3001 (uptime-kuma) | None — public status page (exposes service names) |
| docker.psidex.com | 172.18.0.40:3000 (dockhand) | Yes |
| notes.psidex.com | 172.18.0.48:8080 (cryptex-ignis, browser Obsidian on live PKM vault — replaces static MkDocs "notes" nginx, 2026-07-09) | Yes (CF Access only — no app-level guard, fully editable vault) |
| aqua.psidex.com | 172.18.0.10:80 (portfolio) | None — public portfolio |
| git.psidex.com | 172.18.0.31:3000 (forgejo) | Yes |
| sb.psidex.com | 172.18.0.1:5050 (host sb-tool gunicorn, direct — nginx :8086 proxy unused) | None — intentional: coworkers use /course/ without CF Access login |
| chat.psidex.com | librechat | Yes (confirmed 2026-05-30) |
| files.psidex.com | openlist/alist | — |
| watch.psidex.com | 172.18.0.1:12055 (kinolist-server.service, host systemd, serves built dist/) | Yes (302 to login confirmed) |
| dev.psidex.com | 172.18.0.1:5173 (kinolist-dev.service, host systemd running vite dev server — added 2026-07-09, previously an unsupervised stray process) | Yes (302 to login confirmed) |

Rules (from Phase 4 decisions):
- New route → must use 172.18.0.1:<port> for host services (CF bridge pattern), container IP for containers
- Default ZT Access ON unless the service functionally requires anonymous access
- After any route change: update this file + verify public URL
