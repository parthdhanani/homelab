# CRYPTEX — Complete Setup Reference

> **Last updated:** 2026-04-26
> **Platform:** Oracle Cloud Always-Free ARM64 (Ubuntu 22.04)
> **Stack:** 27 Docker containers + 4 host systemd services
> ⚠ This file contains credentials. Do not commit or share.

---

## Quick Reference

| Item | Value |
|---|---|
| VPS IP | Oracle Cloud (internal) — all external access via Cloudflare Tunnel |
| SSH | `ssh -i ~/.ssh/cryptex_vps ubuntu@<vps-ip>` or via `ssh.psidex.com` CF Tunnel |
| Primary domain | `psidex.com` |
| Stack root | `/opt/cryptex/` |
| Data root | `/opt/cryptex/data/` |
| Compose file | `/opt/cryptex/docker-compose.yml` |
| Secrets | `/opt/cryptex/.env` |
| Docker network | `cryptex_net` — bridge `172.18.0.0/16` |
| Gateway IP | `172.18.0.1` (host) |

---

## Table of Contents

1. [Container Map](#1-container-map)
2. [Domain & CF Tunnel Routing](#2-domain--cf-tunnel-routing)
3. [Credentials](#3-credentials)
4. [PostgreSQL Databases](#4-postgresql-databases)
5. [PgBouncer Configuration](#5-pgbouncer-configuration)
6. [Cron Jobs](#6-cron-jobs)
7. [Host Services (systemd)](#7-host-services-systemd)
8. [Scripts](#8-scripts)
9. [Key File Paths](#9-key-file-paths)
10. [Network & Firewall](#10-network--firewall)
11. [Common Operations](#11-common-operations)
12. [Pending Actions](#12-pending-actions)

---

## 1. Container Map

| Container | Image | IP | Port | Purpose |
|---|---|---|---|---|
| `cryptex-postgres` | `postgres:16-alpine` | 172.18.0.2 | 5432 | Shared PostgreSQL — all app databases |
| `cryptex-pgbouncer` | `edoburu/pgbouncer:v1.25.1-p0` | 172.18.0.29 | 5432 | Connection pooler (transaction mode) |
| `cryptex-redis` | `redis:8-alpine` | 172.18.0.3 | 6379 | Cache + Moodle sessions |
| `cryptex-cloudflared` | `cloudflare/cloudflared:2026.3.0` | 172.18.0.4 | — | Cloudflare Tunnel (outbound only, no open ports) |
| `cryptex-socket-proxy` | `tecnativa/docker-socket-proxy:v0.4.2` | 172.18.0.28 | 2375 | Filtered Docker API for Dockhand |
| `cryptex-portfolio` | `nginx:alpine` | 172.18.0.10 | 80 | psidex.com + AquaSoul Studio (two sites) + nginx redirects |
| `cryptex-notes` | `nginx:alpine` | 172.18.0.37 | 80 | Quartz static PKM site |
| `cryptex-moodle` | `cryptex-moodle` (custom) | 172.18.0.7 | 80 | Moodle LMS |
| `cryptex-traxlrs` | `cryptex-traxlrs` (custom) | 172.18.0.8 | 80 | TRAX xAPI Learning Record Store |
| `cryptex-vaultwarden` | `vaultwarden/server:1.35.7-alpine` | 172.18.0.10 | 80 | Bitwarden-compatible password manager |
| `cryptex-n8n-tools` | `alpine:3.22` (init — exits) | 172.18.0.35 | — | Init: installs qpdf+pdftotext into shared volume |
| `cryptex-n8n` | `n8nio/n8n:2.17.7` | 172.18.0.13 | 5678 | Workflow automation |
| `cryptex-adguard` | `adguard/adguardhome:v0.107.74` | 172.18.0.12 | 80/3000/53 | DNS ad-blocking (port 53 on 127.0.0.1 only) |
| `cryptex-kopia` | `kopia/kopia:0.22.3` | 172.18.0.19 | 51515 | Dedup backup — B2 `cryptex-vps/` prefix (eu-central-003) |
| `cryptex-dockhand` | `fnsys/dockhand:latest` | 172.18.0.40 | 3000 | Docker management: logs, updates, vuln scanning |
| `cryptex-uptime-kuma` | `louislam/uptime-kuma:1.23.17` | 172.18.0.41 | 3001 | Uptime monitoring + public status page |
| `cryptex-forgejo` | `codeberg.org/forgejo/forgejo:10.0.3` | 172.18.0.31 | 3000 | Self-hosted Git |
| `cryptex-miniflux` | `miniflux/miniflux:2.2.19` | 172.18.0.19 | 8080 | RSS reader |
| `cryptex-actualbudget` | `actualbudget/actual-server:26.4.0` | 172.18.0.17 | 5006 | Personal budget tracker |
| `cryptex-ferretdb` | `mongo:8` | 172.18.0.45 | 27017 | MongoDB Community — document store for LibreChat |
| `cryptex-librechat` | `ghcr.io/danny-avila/librechat:latest` | 172.18.0.46 | 3080 | AI chat UI (Gemini + Claude + SearXNG) |
| `cryptex-searxng` | `searxng/searxng:2026.4.24-a7ac696b4` | 172.18.0.32 | 8080 | Private meta search engine |
| `cryptex-alist` | `xhofe/alist:v3.60.0` | 172.18.0.39 | 5244 | Cloud storage aggregator (Google Drive etc.) |
| `cryptex-stirling-pdf` | `frooodle/s-pdf:2.9.2` | 172.18.0.33 | 8080 | PDF tools |
| `cryptex-it-tools` | `corentinth/it-tools:latest` | 172.18.0.36 | 80 | Developer utilities |
| `cryptex-shlink` | `shlinkio/shlink:5.0.2` | 172.18.0.42 | 8080 | URL shortener backend |
| `cryptex-shlink-web` | `shlinkio/shlink-web-client:4.7.0` | 172.18.0.43 | 8080 | Shlink admin UI |
| `cryptex-umami` | `ghcr.io/umami-software/umami:postgresql-latest` | 172.18.0.44 | 3000 | Web analytics |

### PostgreSQL routing

**Direct to postgres** (bypass pgbouncer): Moodle, Forgejo, Shlink
- Reason: server-side cursors (Moodle), prepared statements/XORM (Forgejo), Doctrine ORM (Shlink)

**MongoDB** (separate container, not postgres): LibreChat — users, conversations, messages stored in `cryptex-ferretdb` (mongo:8)

**Via pgbouncer**: n8n, TRAX LRS, Miniflux, Umami

---

## 2. Domain & CF Tunnel Routing

All external traffic: **Browser → Cloudflare Edge → CF Tunnel (outbound) → Container**
No inbound ports are open on the VPS. Tunnel runs as `cryptex-cloudflared`.

### Active Tunnel Routes

| Domain | Target | ZT Access Policy |
|---|---|---|
| `psidex.com` | `cryptex-portfolio:80` | None (public) |
| `www.psidex.com` | `cryptex-portfolio:80` | None (public) |
| `aqua.psidex.com` | `cryptex-portfolio:80` | None (public) |
| `public.psidex.com` | `cryptex-portfolio:80` → 302 to status page | None (public) |
| `portfolio.psidex.com` | `cryptex-portfolio:80` → 302 to go.psidex.com/prt | None (public) |
| `go.psidex.com` | `172.18.0.42:8080` (Shlink) | **None — short links are public** |
| `status.psidex.com` | `172.18.0.41:3001` (Uptime Kuma) | None (public status page) |
| `chat.psidex.com` | `http://172.18.0.46:3080` (LibreChat) ⚠ update CF | Yes |
| `vault.psidex.com` | `cryptex-vaultwarden:80` | Yes |
| `learn.psidex.com` | `cryptex-moodle:80` | Yes |
| `lrs.psidex.com` | `cryptex-traxlrs:80` | Yes |
| `n8n.psidex.com` | `cryptex-n8n:5678` | Yes |
| `git.psidex.com` | `cryptex-forgejo:3000` | Yes |
| `news.psidex.com` | `cryptex-miniflux:8080` | Yes |
| `money.psidex.com` | `cryptex-actualbudget:5006` | Yes |
| `search.psidex.com` | `cryptex-searxng:8080` | Yes |
| `files.psidex.com` | `cryptex-portfolio:80` (nginx → Alist) ⚠ update CF | Yes |
| `pdf.psidex.com` | `cryptex-stirling-pdf:8080` | Yes |
| `tools.psidex.com` | `cryptex-it-tools:80` | Yes |
| `notes.psidex.com` | `172.18.0.37:80` (Quartz) | Yes |
| `links.psidex.com` | `172.18.0.43:8080` (Shlink web UI) | Yes |
| `analytics.psidex.com` | `172.18.0.44:3000` (Umami) | Yes + Bypass `/api/send` (tracking pixel) |
| `docker.psidex.com` | `172.18.0.40:3000` (Dockhand) | Yes |
| `log.psidex.com` | `http://172.18.0.40:3000` (Dockhand) ⚠ update CF | Yes |
| `backup.psidex.com` | `cryptex-kopia:51515` | Yes |
| `ad.psidex.com` / `dns.psidex.com` | `cryptex-adguard:80` | Yes |
| `code.psidex.com` | `172.18.0.1:8084` (code-server) | Yes |
| `term.psidex.com` | `172.18.0.1:8082` (Zellij web) | Yes |
| `ssh.psidex.com` | `ssh://172.18.0.1:22` | Yes |

### nginx Redirects (inside `cryptex-portfolio`)

| Host header | Redirect target |
|---|---|
| `public.psidex.com` | `https://status.psidex.com/status/public` (302) |
| `portfolio.psidex.com` | `https://go.psidex.com/prt` (302) |
| `files.psidex.com` | `http://172.18.0.39:5244` (Alist internal, proxy) |

### ⚠ CF Dashboard — Pending Tunnel Route Updates

| Route | Current (stale) | Correct value |
|---|---|---|
| `chat.psidex.com` | — | `http://172.18.0.46:3080` ✓ done |
| `log.psidex.com` | dozzle:8080 (removed) | `http://172.18.0.40:3000` |
| `files.psidex.com` | 172.18.0.1:5245 (nothing) | `http://cryptex-portfolio:80` |

---

## 3. Credentials

### Infrastructure

**PostgreSQL superuser**
| User | `cryptex_admin` |
|---|---|
| Password | `wJA0ZIm2mRsmfS2n49n95a0e` |
| Host | `cryptex-postgres:5432` |

**Redis**
| Password | `dpbIChHFVM1oYlbVbFfBZOOe` |
|---|---|

**PgBouncer admin**
| User | `pgbouncer_admin` |
|---|---|
| Password | same as POSTGRES_PASSWORD |

**Cloudflare Tunnel token**
```
<REDACTED_CF_TUNNEL_TOKEN>
```

**Gmail SMTP (app password)**
| User | `parth1707ster@gmail.com` |
|---|---|
| Password | `femrhbbdaehiqtia` |

---

### Services

**Moodle** — `https://learn.psidex.com`
| Key | Value |
|---|---|
| Admin user | `admin` |
| Admin password | `Fyry3LrL3pMPWeJ0` |
| Admin email | `parth1707ster@gmail.com` |
| DB user | `moodle_user` |
| DB password | `XUrni3vcXHE3xB9VDSCHwr13` |
| DB connection | Direct to `cryptex-postgres:5432` |

**TRAX LRS** — `https://lrs.psidex.com`
| Key | Value |
|---|---|
| Admin email | `parth1707ster@gmail.com` |
| Admin password | `0M1dT0k4NGdwN5u9` |
| LRS endpoint user | `lrsuser` |
| LRS endpoint password | `e4JqZIkgE3tTlXx6` |
| App key | `base64:UsgnCUDeHixPGaB9yab2ZFwHIE4z+dHWqg+vsr9APcY=` |
| DB user | `traxlrs_user` |
| DB password | `4UajZ0t5NrIEMh4sv5ilzDaF` |
| DB connection | via pgbouncer |

**Vaultwarden** — `https://vault.psidex.com`
| Key | Value |
|---|---|
| User email | `parth1707ster@gmail.com` |
| User password | `pMou7dalTMSpagC2` |
| Admin token (hashed) | `$argon2id$v=19$m=19456,t=2,p=1$ju5cT6FjEfoW/g03J2/tTQ$q4QYpl1EuFUI+oXsDEoOBMQwXDyRRtqQDIOa0MQocYA` |
| Data | `/opt/cryptex/data/vaultwarden/db.sqlite3` |

**n8n** — `https://n8n.psidex.com`
| Key | Value |
|---|---|
| Admin email | `parth1707ster@gmail.com` |
| Admin password | `mcEbpZ872a7JxfIk` |
| Encryption key | `23dd0544bcc5d49691814c996e1101a63172d5e29505e948e5ea484da918f16a` |
| DB user | `n8n_user` |
| DB password | `f8Foc5CXUAKws8Q3YbzrVgTM` |
| DB connection | via pgbouncer |

**AdGuard Home** — `https://ad.psidex.com`
| Key | Value |
|---|---|
| Admin user | `admin` |
| Admin password | `5wfJPdCOmCueJFYY` |
| DNS (internal) | `172.18.0.12:53` |
| DNS (host) | `127.0.0.1:53` only (no external exposure) |

**Kopia** — `https://backup.psidex.com`
| Key | Value |
|---|---|
| Server user | `admin@cryptex` |
| Server password | `vnSQoVbhBs3SweAglxhAUEu8` |
| Repository password | `PASTE_YOUR_KOPIA_REPO_PASSWORD` |

**Forgejo** — `https://git.psidex.com`
| Key | Value |
|---|---|
| DB user | `forgejo_user` |
| DB password | `fn5hAa2x1HDpvvR0renfPANQ` |
| Secret key | `b462f2e5143b727c9b977472c98fd67695cc0eecd20c2c41b2598381f501712afc146976c350a5b14368acb31e5fbc14e0b1a8d079396ce3889e8fdc0d9121c0` |
| DB connection | Direct to `cryptex-postgres:5432` |

**Miniflux** — `https://news.psidex.com`
| Key | Value |
|---|---|
| Admin user | `admin` |
| Admin password | `Czzg132D86K5lkVV` |
| DB user | `miniflux_user` |
| DB password | `tjTEdReu3P9AAsak6CEixdVB` |
| DB connection | via pgbouncer |

**ActualBudget** — `https://money.psidex.com`
| Key | Value |
|---|---|
| Password | `NcS9ulLtxgm3rFef` |

**Shlink** — `https://go.psidex.com`
| Key | Value |
|---|---|
| Admin UI | `https://links.psidex.com` |
| API key | `PASTE_YOUR_SHLINK_API_KEY` |
| DB user | `shlink_user` |
| DB password | `1bhCeXIORhOvZANlOF4Bw9tB` |
| DB connection | Direct to `cryptex-postgres:5432` |
| Note | No ZT policy — short links are public. API key secures `/rest/*` |

**Umami** — `https://analytics.psidex.com`
| Key | Value |
|---|---|
| Admin login | `admin` / `umami` ⚠ change this |
| App secret | `1Bl4BeoqdM9MlMkN5zJW0DdS4oL25NE5` |
| DB user | `umami_user` |
| DB password | `Ughhvi2QJYY2TH4t56eexe8h` |
| DB connection | via pgbouncer |
| ZT bypass | `/api/send` (tracking pixel must be public) |

**LibreChat** — `https://chat.psidex.com`
| Key | Value |
|---|---|
| First user | `parth1707ster@gmail.com` / `RGzz68zfMsgVUdA6LPvvjw` |
| JWT secret | `49b1112dfec9de056b227c274d9545f45a2ec32c62574869bc11438a9f69b2e8` |
| JWT refresh secret | `872cd94d4fb66cfcdcc2f86d24033e654fdfef8ec35bd08a6f6fe070ea1e0c75` |
| Creds key | `e56f87d606f5e0d0a0b0933b51348e0f813ff97f7a599a03184264e36e03915e` |
| Creds IV | `65f2b45c343194d064bee1c9dcecba91` |
| DB user | `librechat_user` |
| DB password | `t4pqoWAghzagzb9BbnLakkqwkKa5LYUk` |
| Mongo URI | `mongodb://ferretdb_user:<pass>@cryptex-ferretdb:27017/LibreChat?authSource=admin` |
| Config | `/opt/cryptex/configs/librechat/librechat.yaml` |
| Endpoints | Gemini (GEMINI_API_KEY), Claude (ANTHROPIC_API_KEY ⚠ missing), SearXNG |

**MongoDB** (container `cryptex-ferretdb`, image `mongo:8`)
| Key | Value |
|---|---|
| Internal | `cryptex-ferretdb:27017` |
| Root user | `ferretdb_user` |
| Root password | `PASTE_YOUR_FERRETDB_ROOT_PASSWORD` |
| Auth DB | `admin` |
| Data | `/opt/cryptex/data/mongodb/` |
| Backup | `mongodump --archive --gzip` via backup.sh |

**Alist** — `https://files.psidex.com`
| Internal | `172.18.0.39:5244` |
|---|---|

**rclone WebDAV** (host, not container)
| Key | Value |
|---|---|
| Port | `0.0.0.0:8080` (iptables drops externally) |
| User | `cryptex` |
| Password | `Y3kwcKwM1jDLj1ansAoADzL` |
| Remote name | `vps:` |

**Backblaze B2** (offsite backup — Kopia connection pending)
| Key | Value |
|---|---|
| Key ID | `00386ba2248857d0000000003` |
| App key | `PASTE_YOUR_B2_SECRET_KEY` |
| Bucket | `cryptex` |
| Endpoint | `s3.eu-central-003.backblazeb2.com` |
| Prefix | `cryptex-vps/` (bucket had existing data with different password) |

**Gemini API**
| Key | `<REDACTED_GOOGLE_API_KEY>` |
|---|---|

**Anthropic API** ⚠ NOT YET IN `.env`
| Key | Add as `ANTHROPIC_API_KEY` in `/opt/cryptex/.env` and add to librechat environment block |
|---|---|

**Telegram** (n8n alerts — not yet configured)
| Key | Value |
|---|---|
| TELEGRAM_BOT_TOKEN | (empty) |
| TELEGRAM_CHAT_ID | (empty) |

**Bank PDF** (n8n automation)
| Key | Value |
|---|---|
| Email | `BankStatements@kotak.bank.in` |
| PDF password | `parth1707` |

---

## 4. PostgreSQL Databases

| Database | Owner | Via | Notes |
|---|---|---|---|
| `moodle` | `moodle_user` | Direct postgres | Server-side cursors (`DECLARE ... WITH HOLD`) |
| `n8n` | `n8n_user` | pgbouncer | |
| `traxlrs` | `traxlrs_user` | pgbouncer | |
| `forgejo` | `forgejo_user` | Direct postgres | XORM prepared statements |
| `miniflux` | `miniflux_user` | pgbouncer | |
| `shlink` | `shlink_user` | Direct postgres | Doctrine ORM |
| `umami` | `umami_user` | pgbouncer | Startup flag `?pgbouncer=true&connection_limit=1` |
**Superuser:** `cryptex_admin` / `wJA0ZIm2mRsmfS2n49n95a0e`
**max_connections:** 60

Note: `ferretdb` and `librechat` databases exist in PostgreSQL but are orphaned (unused). LibreChat data lives in MongoDB (`cryptex-ferretdb`).

---

## 5. PgBouncer Configuration

**Mode:** transaction — connections returned to pool after each transaction
**Pool:** 5 per database, 120 max client connections
**Config:** `/opt/cryptex/configs/pgbouncer/pgbouncer.ini`
**Userlist:** `/opt/cryptex/configs/pgbouncer/userlist.txt`

Databases in pool: `n8n`, `traxlrs`, `miniflux`, `umami`

**Bypasses pgbouncer (direct postgres):** Moodle (cursors), Forgejo (XORM), Shlink (Doctrine)

`ignore_startup_parameters = extra_float_digits,options,statement_timeout` — required for Go/Rust drivers that send extra params on connect.

---

## 6. Cron Jobs

All run as root. Check: `sudo crontab -l`

| Schedule | Job |
|---|---|
| `30 2 * * *` (daily 02:30 UTC) | VACUUM ANALYZE on all app DBs → `/var/log/cryptex-vacuum.log` |
| `0 3 * * *` (daily 03:00 UTC) | `backup.sh` → `/var/log/cryptex-backup.log` |
| `0 4 * * 0` (Sunday 04:00 UTC) | `docker system prune -af` → `/var/log/cryptex-prune.log` |
| `0 5 * * 0` (Sunday 05:00 UTC) | `update.sh` → `/var/log/cryptex-update.log` |
| `*/5 * * * *` (every 5 min) | `health-check.sh` → `/var/log/cryptex-health.log` |
| `*/15 * * * *` (every 15 min) | `quartz-build.sh` → `/var/log/cryptex-quartz.log` |
| `* * * * *` (every minute) | Moodle PHP cron — stderr → `/var/log/cryptex-moodle-cron.log`, stdout suppressed |

### Log Rotation (`/etc/logrotate.d/cryptex`)

| Files | Policy |
|---|---|
| All `cryptex-*.log` (except moodle) | daily, 7 rotations, compress, `su root root` |
| `cryptex-moodle-cron.log` | daily + size 10MB trigger, 3 rotations, compress |

---

## 7. Host Services (systemd)

| Service | Description | Bind |
|---|---|---|
| `rclone-webdav.service` | Serves VPS filesystem as WebDAV (`vps:` remote) | `0.0.0.0:8080` (iptables blocked externally) |
| `zellij-web.service` | Zellij terminal web UI | `127.0.0.1:8082` |
| `zellij-proxy.service` | socat bridge: `172.18.0.1:8082` → `127.0.0.1:8082` | Docker gateway |
| `code-server` | VS Code in browser | `0.0.0.0:8084` → `code.psidex.com` |

---

## 8. Scripts (`/opt/cryptex/scripts/`)

### `backup.sh`
Runs daily 03:00 UTC.
1. Pre-flight disk check (≥5GB required)
2. `pg_dumpall` → validates dump contains all 9 expected databases
3. Backs up: Vaultwarden SQLite, n8n config, moodledata, AdGuard conf, Forgejo repos, TRAX storage, Kopia config, PKM vault, n8n workflow JSON export, ActualBudget, `.env`
4. Tarballs to `/opt/cryptex/backups/cryptex-TIMESTAMP.tar.gz`, validates integrity
5. Retains 14 most recent tarballs
6. POSTs status to n8n webhook (`http://cryptex-n8n:5678/webhook/backup-status`)
7. Creates Kopia snapshot of `/backups`

### `health-check.sh`
Runs every 5 minutes.
- Infrastructure checks via `docker inspect` health state
- Service checks: docker inspect health + internal curl/wget
- Reports PASS / WARN / FAIL
- On failure: POSTs to n8n webhook (`/webhook/health-alert`) with 15-min debounce
- Fallback: direct Telegram API if n8n is down

### `update.sh [service]`
Runs Sunday 05:00 UTC (or manually with optional service arg).
- Single service: pull → recreate → health check → rollback if unhealthy
- Full: snapshot rollback tags → pull all → rebuild custom images (moodle, traxlrs) → restart all → health check → auto-rollback on failure
- Regenerates pgbouncer `userlist.txt` from `.env` before restart

### `quartz-build.sh`
Runs every 15 minutes, change-aware.
- Skips build if PKM vault hash unchanged since last build
- Runs `node:22-alpine` container to build Quartz static site
- Output hot-reloaded into `cryptex-notes` nginx volume

---

## 9. Key File Paths

| Path | Description |
|---|---|
| `/opt/cryptex/docker-compose.yml` | Main compose file |
| `/opt/cryptex/.env` | All secrets and environment config |
| `/opt/cryptex/data/` | All persistent container data |
| `/opt/cryptex/data/pkm/` | PKM Obsidian vault (VPS copy, Claude R/W) |
| `/opt/cryptex/data/vaultwarden/db.sqlite3` | Vaultwarden database |
| `/opt/cryptex/data/n8n/config` | n8n encryption key file |
| `/opt/cryptex/data/moodledata/` | Moodle uploaded files, SCORM packages |
| `/opt/cryptex/data/forgejo/` | Forgejo repos + config |
| `/opt/cryptex/data/adguard/` | AdGuard Home data + conf |
| `/opt/cryptex/data/kopia/` | Kopia repository + config |
| `/opt/cryptex/data/librechat/images/` | LibreChat uploaded images |
| `/opt/cryptex/data/librechat/logs/` | LibreChat API logs |
| `/opt/cryptex/data/actualbudget/` | ActualBudget database |
| `/opt/cryptex/data/dockhand/db/dockhand.db` | Dockhand SQLite (env config) |
| `/opt/cryptex/backups/` | Local backup tarballs (14 retained) |
| `/opt/cryptex/configs/pgbouncer/pgbouncer.ini` | PgBouncer config |
| `/opt/cryptex/configs/pgbouncer/userlist.txt` | PgBouncer auth (regenerated by update.sh) |
| `/opt/cryptex/configs/postgres/init-databases.sh` | DB + user creation (runs on first postgres start) |
| `/opt/cryptex/configs/nginx/` | nginx server block configs (portfolio, notes, files) |
| `/opt/cryptex/configs/librechat/librechat.yaml` | LibreChat endpoints/models config |
| `/opt/cryptex/scripts/` | backup.sh, health-check.sh, update.sh, quartz-build.sh |
| `/etc/logrotate.d/cryptex` | Log rotation config |
| `/home/ubuntu/pkm` | Symlink → `/opt/cryptex/data/pkm/` |
| `/home/ubuntu/AI_Space/` | Project docs, plans, notes |

---

## 10. Network & Firewall

### Docker Network
- Driver: bridge
- Name: `cryptex_net`
- Subnet: `172.18.0.0/16`
- Gateway: `172.18.0.1` (host)
- Containers communicate by name via Docker internal DNS

### iptables (INPUT chain — default policy DROP)

```
Rule 1   ts-input (Tailscale)
Rule 2   fail2ban-recidive
Rule 3   fail2ban-sshd
Rule 5   ACCEPT RELATED,ESTABLISHED
Rule 6   ACCEPT lo (loopback)
Rule 7   ACCEPT tcp dpt:22 (SSH)
Rule 8-10 ACCEPT icmp types
Rule 11  ACCEPT src 172.17.0.0/16 (default docker bridge)
Rule 12  ACCEPT src 172.18.0.0/16 (cryptex_net)
Rule 13  ACCEPT dst 172.18.0.0/16
```

All new rules: `iptables -I INPUT 6` (after established/related, before the DROP default).

**Port 53:** AdGuard bound to `127.0.0.1:53` only — nft also drops eth0:53.
**Port 8080:** rclone WebDAV — blocked by DROP default, only reachable from inside Docker network.

### Oracle Security Lists (hypervisor firewall)
Second independent firewall layer. Only port 22 (SSH) should be open. All other access via Cloudflare Tunnel (outbound connection, no inbound rule needed).

---

## 11. Common Operations

### Health check
```bash
/opt/cryptex/scripts/health-check.sh
```

### Update single service
```bash
cd /opt/cryptex && ./scripts/update.sh <service>
# e.g.: ./scripts/update.sh librechat
```

### Update all services (also runs Sunday 05:00 UTC automatically)
```bash
cd /opt/cryptex && ./scripts/update.sh
```

### Manual backup
```bash
/opt/cryptex/scripts/backup.sh
```

### Restart a container
```bash
docker compose -f /opt/cryptex/docker-compose.yml restart <service>
```

### View container logs
```bash
docker logs cryptex-<service> --tail 50 -f
```

### Check PostgreSQL connections
```bash
docker exec cryptex-postgres sh -c \
  'psql -U $POSTGRES_USER -c "SELECT usename, datname, count(*) FROM pg_stat_activity GROUP BY usename, datname ORDER BY usename;"'
```

### Check PgBouncer pool stats
```bash
source /opt/cryptex/.env
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" cryptex-pgbouncer \
  psql -h 127.0.0.1 -p 5432 -U pgbouncer_admin pgbouncer -c 'SHOW POOLS;'
```

### Restore from backup
```bash
ls -lh /opt/cryptex/backups/
tar -xzf /opt/cryptex/backups/cryptex-TIMESTAMP.tar.gz -C /tmp/restore/
# Restore postgres (drops and recreates all DBs)
cat /tmp/restore/TIMESTAMP/postgres_all.sql | \
  docker exec -i cryptex-postgres psql -U cryptex_admin
```

### Add Shlink short link
```bash
# Via API
curl -X POST https://go.psidex.com/rest/v3/short-urls \
  -H "X-Api-Key: PASTE_YOUR_SHLINK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"longUrl":"https://example.com","customSlug":"myslug"}'
# Or via UI: https://links.psidex.com
```

### LibreChat first-user registration
Registration is disabled (`ALLOW_REGISTRATION: "false"`). To create first user:
1. Temporarily set `ALLOW_REGISTRATION: "true"` in compose
2. `docker compose up -d --no-deps librechat`
3. Visit `https://chat.psidex.com`, register `parth1707ster@gmail.com` / `RGzz68zfMsgVUdA6LPvvjw`
4. Set `ALLOW_REGISTRATION: "false"`, restart again

### Add ANTHROPIC_API_KEY to LibreChat
```bash
# 1. Add to .env
echo 'ANTHROPIC_API_KEY="sk-ant-..."' >> /opt/cryptex/.env

# 2. Add to librechat environment block in docker-compose.yml:
#    ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}

# 3. Restart
docker compose up -d --no-deps librechat
```

### Connect Kopia to Backblaze B2
```bash
docker exec -it cryptex-kopia kopia repository connect s3 \
  --bucket=cryptex \
  --access-key=00386ba2248857d0000000003 \
  --secret-access-key=PASTE_YOUR_B2_SECRET_KEY \
  --endpoint=s3.eu-central-003.backblazeb2.com \
  --password=PASTE_YOUR_KOPIA_REPO_PASSWORD
```

### Restore MongoDB from backup
```bash
# Extract backup tarball first, then:
docker exec -i cryptex-ferretdb mongorestore \
  --username=ferretdb_user \
  --password=PASTE_YOUR_FERRETDB_ROOT_PASSWORD \
  --authenticationDatabase=admin \
  --archive --gzip < /path/to/mongodb.archive.gz
```

### Force logrotate (test)
```bash
sudo logrotate -f /etc/logrotate.d/cryptex
```

### psql into a specific database
```bash
docker exec -it cryptex-postgres sh -c 'psql -U cryptex_admin -d <dbname>'
```

---

## 12. Pending Actions

| Priority | Action |
|---|---|
| **CRITICAL** | Add `ANTHROPIC_API_KEY` to `.env` + librechat environment block → restart librechat |
| **HIGH** | CF Tunnel: `chat.psidex.com` → `http://172.18.0.46:3080` |
| **HIGH** | CF Tunnel: `log.psidex.com` → `http://172.18.0.40:3000` |
| **HIGH** | CF Tunnel: `files.psidex.com` → `http://cryptex-portfolio:80` |
| **HIGH** | Connect Kopia to Backblaze B2 (local-only backups = single point of failure) |
| **MEDIUM** | Change Umami default password (`admin/umami`) |
| **MEDIUM** | Create Shlink `prt` slug → SCORM demo URL |
| **MEDIUM** | Create Uptime Kuma public status page with slug `public` |
| **MEDIUM** | Add Umami tracking script to portfolio HTML |
| **LOW** | Set OCI budget alert ($5–10) in Oracle Cost Management |
| **LOW** | Add UptimeRobot external monitor for `psidex.com` |
| **LOW** | Postgres 16 → 17 upgrade (requires maintenance window + pg_upgrade) |
| **LOW** | Remove stale AdGuard filter returning 404 (MobileFilter) |
