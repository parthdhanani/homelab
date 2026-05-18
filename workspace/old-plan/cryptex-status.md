# Cryptex Stack — Current Status
_Last updated: 2026-04-25 | Phases 0 + 1 + 3 complete_

---

## Stack at a Glance

| | |
|---|---|
| **Host** | Oracle Cloud Always-Free ARM64 VPS (Ubuntu) |
| **Compose file** | `/opt/cryptex/docker-compose.yml` |
| **Data root** | `/opt/cryptex/data/` |
| **Containers** | 23 running, all healthy |
| **Network** | `cryptex_net` bridge — 172.18.0.0/16 |

---

## Running Containers

| Container | Purpose | IP | Port | RAM Limit |
|---|---|---|---|---|
| `cryptex-postgres` | Shared DB (postgres:16-alpine) | .2 | 5432 (internal) | 1G |
| `cryptex-pgbouncer` | Connection pooler | .29 | 5432 (internal) | 64M |
| `cryptex-redis` | Cache + queue (persistence enabled) | .3 | 6379 (internal) | 256M |
| `cryptex-cloudflared` | Cloudflare Tunnel (outbound only) | .4 | — | 128M |
| `cryptex-socket-proxy` | Filtered Docker API | .28 | 2375 (internal) | 64M |
| `cryptex-portfolio` | nginx — psidex.com + aquasoul | .10 | — | 64M |
| `cryptex-moodle` | LMS | .7 | — | 2G |
| `cryptex-traxlrs` | xAPI LRS | .13 | — | 512M |
| `cryptex-vaultwarden` | Password manager | .6 | — | 150M |
| `cryptex-n8n-tools` | Init container (qpdf/pdftotext bins) | .35 | — | — |
| `cryptex-n8n` | Workflow automation | .8 | — | 600M |
| `cryptex-adguard` | DNS ad-blocking | .12 | 53 (host) | 256M |
| `cryptex-kopia` | Backup (local repo — R2 pending) | .19 | 51515 (internal) | 768M |
| `cryptex-dockhand` | Docker mgmt + logs + update alerts + vuln scan | .40 | 3000 | 256M |
| `cryptex-uptime-kuma` | Uptime monitoring + status page | .41 | 3001 | 256M |
| `cryptex-forgejo` | Self-hosted Git | .31 | — | 512M |
| `cryptex-miniflux` | RSS reader | .14 | — | 128M |
| `cryptex-actualbudget` | Budget tracker | .17 | — | 256M |
| `cryptex-openwebui` | AI chat UI (Gemini/Claude) | .30 | — | 1.5G |
| `cryptex-searxng` | Private search | .32 | — | 256M |
| `cryptex-alist` | Cloud storage aggregator | .39 | 5244 (internal) | 256M |
| `cryptex-stirling-pdf` | PDF tools | .33 | — | 2G |
| `cryptex-it-tools` | Developer utilities | .36 | — | 128M |
| `cryptex-notes` | Quartz static site (PKM→HTML) | .37 | — | 64M |
| `cryptex-shlink` | URL shortener (go.psidex.com) | .42 | 8080 (internal) | 256M |
| `cryptex-shlink-web` | Shlink web UI (links.psidex.com) | .43 | 8080 (internal) | 64M |

**Removed in this upgrade:**
- `cryptex-tianji` — was causing postgres connection exhaustion; replaced by Uptime Kuma + Dockhand
- `cryptex-diun` — replaced by Dockhand
- `cryptex-dozzle` — replaced by Dockhand
- `cryptex-rclone` — WebDAV abandoned (CF blocks PROPFIND)
- `cryptex-quartz-builder` — removed from compose; cron-only is correct (`/opt/cryptex/scripts/quartz-build.sh`)

---

## Key Config Files

| File | Purpose |
|---|---|
| `/opt/cryptex/docker-compose.yml` | All service definitions |
| `/opt/cryptex/.env` | All secrets + env vars |
| `/opt/cryptex/configs/postgres/init-databases.sh` | DB + user creation (runs on first start) |
| `/opt/cryptex/configs/pgbouncer/pgbouncer.ini` | Pooler routing (moodle, n8n, traxlrs, miniflux) |
| `/opt/cryptex/configs/pgbouncer/userlist.txt` | Pgbouncer user passwords |
| `/opt/cryptex/configs/n8n-workflows/` | n8n workflow JSON exports |
| `/opt/cryptex/configs/n8n-workflows/_archive/` | Archived dead workflows |
| `/opt/cryptex/data/searxng/limiter.toml` | SearXNG bot detection config |
| `/opt/cryptex/data/searxng/settings.yml` | SearXNG engine config |
| `/opt/cryptex/scripts/quartz-build.sh` | PKM → HTML builder (runs via cron every 15min) |

---

## Postgres Connection Routing

```
Services → pgbouncer (transaction mode) → postgres
  moodle, n8n, traxlrs, miniflux

Services → postgres DIRECT (prepared statements incompatible with pgbouncer)
  forgejo (XORM ORM)
```

---

## Credentials Updated in This Session

| Service | Change | Current Value / Location |
|---|---|---|
| **Vaultwarden** | Admin token upgraded to Argon2id hash | `/opt/cryptex/.env` → `VAULTWARDEN_ADMIN_TOKEN` |
| **Kopia UI** | New login user added | User: `admin@cryptex` · Password: see `KOPIA_SERVER_PASSWORD` in `.env` |
| **Dockhand** | New service (first-run setup in UI) | `http://172.18.0.40:3000` · needs CF tunnel route |
| **Uptime Kuma** | New service (first-run setup in UI) | `http://172.18.0.41:3001` · needs CF tunnel route |

---

## Cloudflare Tunnel — Pending Manual Routes

Add these in **CF Zero Trust dashboard → Tunnels → cryptex → Public Hostname**:

| Subdomain | Service URL | Purpose |
|---|---|---|
| `docker.psidex.com` | `http://172.18.0.40:3000` | Dockhand (Docker mgmt) |
| `status.psidex.com` | `http://172.18.0.41:3001` | Uptime Kuma (status page) |
| `go.psidex.com` | `http://172.18.0.42:8080` | Shlink (URL shortener) |
| `links.psidex.com` | `http://172.18.0.43:8080` | Shlink Web UI |

---

## Cron Jobs (root)

| Schedule | Job |
|---|---|
| `0 3 * * *` | Kopia backup |
| `30 2 * * *` | Postgres VACUUM |
| `*/5 * * * *` | Health check |
| `0 5 * * 0` | Weekly image pull + update |
| `0 4 * * 0` | Weekly docker prune |
| `*/15 * * * *` | Quartz PKM build |
| `*/1 * * * *` | Moodle cron |

---

## Host Services (systemd)

| Service | What | Port |
|---|---|---|
| `zellij-web.service` | Web terminal | 127.0.0.1:8082 (→ nginx → code.psidex.com) |
| `zellij-proxy.service` | socat bridge for Docker containers | 172.18.0.1:8082 |
| `rclone-webdav.service` | WebDAV for Mac Finder / iOS | 0.0.0.0:8080 |
| `code-server` | VS Code in browser | 0.0.0.0:8084 (→ nginx → code.psidex.com) |

---

## What Still Needs Doing

### 🔴 Critical (data-loss risk)
- **Kopia → Cloudflare R2**: Local-only backup. Disk failure = total loss. Need R2 bucket + S3 API key from CF dashboard.

### 🟠 Maintenance Window Required
- **Postgres 16 → 17**: ~20min downtime. Full dump/restore. All services stop. Plan documented in `cryptex-upgrade-plan.md`.

### 🟡 Zero-Downtime Config (Phase 4)
- Image pinning: swap `:latest` → major version tags on key services
- Update process: change Sunday cron from blind `pull+up` to `pull only` (Dockhand handles alerting)
- n8n workflow `08-weekly-ai-digest.json`: hardcoded `"22 Docker containers"` string needs updating
- External monitoring: free Cloudflare Health Check or UptimeRobot on `psidex.com` (Uptime Kuma is inside VPS — doesn't survive VPS failure)

### 🟢 Decisions Needed
- **Forgejo**: 0 repos, 512M limit. Options:
  - A: Commit — push code there, add Woodpecker CI
  - B: Remove — saves 512M + postgres connections
- **Uptime Kuma setup**: Add monitors for all public services + host ports after CF tunnel routes are live
- **Dockhand setup**: Configure notification channel (Telegram/email) for image update alerts

---

## Upgrade Plan Reference

Full analysis, per-container issues, and phase details:
`/home/ubuntu/AI_Space/cryptex-upgrade-plan.md`
