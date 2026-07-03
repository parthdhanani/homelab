# Cloudflare Tunnel Routes — Local Audit Baseline

The tunnel is dashboard-managed (token-only, no local config). This file is the
local record to diff against — update it when routes change in the CF dashboard.
Last verified: 2026-07-03.

| Hostname | Target | ZT Access |
|---|---|---|
| code.psidex.com | 172.18.0.1:8084 (host code-server via nginx) | Yes |
| term.psidex.com | 172.18.0.1:8085 (cryptex-terminal / ghostty-web + herdr, host service via nginx) | Yes |
| go.psidex.com | 172.18.0.42:8080 (shlink) | None — short links must be public |
| links.psidex.com | 172.18.0.43:8080 (shlink-web) | Yes |
| analytics.psidex.com | 172.18.0.44:3000 (umami) | Yes + Bypass /api/send |
| status.psidex.com | 172.18.0.41:3001 (uptime-kuma) | None — public status page (exposes service names) |
| docker.psidex.com | 172.18.0.40:3000 (dockhand) | Yes |
| notes.psidex.com | 172.18.0.37:80 (notes nginx) | Yes + nginx JWT-header guard (defense-in-depth, 2026-06-11) |
| aqua.psidex.com | 172.18.0.10:80 (portfolio) | None — public portfolio |
| git.psidex.com | 172.18.0.31:3000 (forgejo) | Yes |
| sb.psidex.com | 172.18.0.1:5050 (host sb-tool gunicorn, direct — nginx :8086 proxy unused) | **NONE — TODO: add ZT Access** |
| chat.psidex.com | librechat | Yes (confirmed 2026-05-30) |
| files.psidex.com | openlist/alist | — |

Rules (from Phase 4 decisions):
- New route → must use 172.18.0.1:<port> for host services (CF bridge pattern), container IP for containers
- Default ZT Access ON unless the service functionally requires anonymous access
- After any route change: update this file + verify public URL
