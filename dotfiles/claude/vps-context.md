# VPS Context — Cryptex Stack (updated 2026-05-17)

## Knowledge Graph
Container purposes, ports, images, env vars, dependencies — query the graph instead of reading files:
  /opt/cryptex/graphify-out/graph.json   # queryable with: /graphify query "X"
  /opt/cryptex/graphify-out/graph.html   # visual browser
Auto-updates: nightly at 03:17 UTC via cryptex-graphify-update.timer, and on every update.sh run.
Limitation: .sh scripts not indexed (graphify doesn't detect .sh by extension).

## Host
- Oracle Free Tier, Ubuntu, 1 OCPU, single instance
- Docker network: cryptex_default on 172.18.0.0/16
- Docker socket restricted via cryptex-socket-proxy (tecnativa) — don't bypass it

## CF Tunnel Bridge Pattern
cloudflared is a container, host services need 172.18.0.1:<port> bridge:
  CF Tunnel -> 172.18.0.1:<port> -> nginx or socat -> 127.0.0.1:<port> -> service
- code-server: nginx at 172.18.0.1:8084 -> 127.0.0.1:8084. Config: /etc/nginx/sites-enabled/code-server-proxy.conf
- zellij: socat via zellij-proxy.service at 172.18.0.1:8082
- CF dashboard route URL must be http://172.18.0.1:<port>, not 127.0.0.1

## Domain -> Service Map
| Domain | Container | IP:Port | ZT Access |
|---|---|---|---|
| code.psidex.com | host code-server | 172.18.0.1:8084 | Yes |
| go.psidex.com | shlink | 172.18.0.42:8080 | None (short links need unauthenticated) |
| links.psidex.com | shlink-web | 172.18.0.43:8080 | Yes |
| analytics.psidex.com | umami | 172.18.0.44:3000 | Yes + Bypass /api/send |
| status.psidex.com | uptime-kuma | 172.18.0.41:3001 | None |
| docker.psidex.com | dockhand | 172.18.0.40:3000 | Yes |
| notes.psidex.com | notes nginx | 172.18.0.37:80 | Yes — MkDocs Material (PKM static build) |
| aqua.psidex.com | portfolio nginx | 172.18.0.10:80 | None — needs CF route (user action) |
| git.psidex.com | forgejo | 172.18.0.31:3000 | Yes |
| ci.psidex.com | [REMOVED] woodpecker-server — no active pipelines | — | — |

CF tunnel routes updated 2026-05-16 — all domains pointing to correct containers.
PENDING CF ROUTE: aqua.psidex.com -> 172.18.0.10:80 (user must add in CF dashboard)

## Self-sustaining Scripts
- watchdog.sh + health-check-cron.sh — every 5 min (single merged cron): restart unhealthy, prune at 95% disk
- notes-build.sh — every 15 min: MkDocs build (change-aware). Force: bash notes-build.sh --force
- backup-verify.sh — Sat 4AM: kopia snapshot verify (10% sample) vs B2
- /etc/logrotate.d/cryptex — daily, 14-day retention for /var/log/cryptex-*.log

## MCP Servers (stable localhost bindings — fixed 2026-05-17)
- OB1: http://127.0.0.1:8000/mcp (port bound in compose: 127.0.0.1:8000->8000)
- n8n: http://127.0.0.1:5678/mcp (port bound in compose: 127.0.0.1:5678->5678)
- Localhost never changes regardless of Docker network state. No longer fragile.

## Notes System (Quartz replaced 2026-05-17)
- MkDocs Material (Python, no volume) replaced Quartz (Node.js, 530MB build volume)
- Config: /opt/cryptex/configs/mkdocs/mkdocs.yml
- Output: /opt/cryptex/data/notes-output/ -> served by cryptex-notes nginx
- Plugins: roamlinks (handles [[wikilinks]]), search, Material dark/light theme
- Manual rebuild: bash /opt/cryptex/scripts/notes-build.sh --force

## Git Repos (initialized 2026-05-17)
- /opt/cryptex — git tracked. Excludes: .env, data/
- /home/ubuntu/AI_Space — git tracked
- Global post-commit hook at ~/.git-hooks/post-commit — POSTs commit to OB1 memory
- Push to Forgejo: git remote add origin https://git.psidex.com/parth/<repo>.git

## Key Gotchas
- Firewall rule insertion: always use position 6 in INPUT chain, never append
- kopia: credentials in env vars, healthcheck uses curl | grep -q 401 (not kopia server status)
- fail2ban chain stripping on persist prevents accumulation on reboot (iptables-save.service)
- All images pinned to semver; dockhand+umami pinned to digest (no semver tags available)
- Compose files at /opt/cryptex/
- Woodpecker connects through pgbouncer (fixed 2026-05-17, was bypassing to postgres directly)
