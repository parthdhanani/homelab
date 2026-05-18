# Cryptex Architecture Upgrade Plan
_Created: 2026-04-24 | Principle: Bauhaus + Occam's Razor_

---

## Tianji Feature Audit — Are We Downgrading?

| Tianji feature | Replacement | Verdict |
|---|---|---|
| Website analytics (PV/UV, UTM) | Umami | Upgrade |
| Uptime monitoring + status page | Uptime Kuma | Upgrade — 90+ notification channels, 20s intervals |
| Server/container metrics | Dockhand | Upgrade — Docker-native, vuln scanning |
| Notifications/webhooks | Uptime Kuma | Upgrade |
| URL shortener (v1.27.12+) | Shlink | Covered |
| Worker/function execution | n8n | n8n is superior, no regression |
| AI Gateway | OpenWebUI/LibreChat | Not a regression if unused |
| Surveys, Lighthouse, Warehouse | Nothing | Not needed |

---

## OpenWebUI → LibreChat Decision

### FerretDB constraint
FerretDB v2 requires DocumentDB extension — a custom postgres build. **Cannot share `cryptex-postgres:17-alpine`.**

| Approach | Extra containers | Shareable postgres? | Viable? |
|---|---|---|---|
| `ferretdb-eval:2` (bundled postgres+ferretdb) | 1 image = both | No | Yes — but SSPL licence (eval) |
| Separate `postgres-documentdb` + `ferretdb` | 2 | No | Yes — cleanest production path |
| FerretDB v1 JSONB (legacy) | 1 | **Yes** — standard postgres | Viable but deprecated path |

### Container delta if switching
```
Remove: cryptex-openwebui (1)
Add:    cryptex-librechat + cryptex-ferretdb-eval (2, eval bundles postgres)
Net:    +1 container
RAM:    LibreChat ~400MB + ferretdb-eval ~200MB = ~600MB vs OpenWebUI 722MB → lighter
```

### Recommendation: Replace OpenWebUI with LibreChat + ferretdb-eval
- Net +1 container but lighter RAM than current OpenWebUI
- LibreChat is a strict feature upgrade: conversation forking, artifacts, better multi-model management, code execution, better RAG
- SearXNG integration preserved (LibreChat supports custom search endpoints)
- Reuses existing `cryptex-redis` for sessions/queues (no new Redis)
- **Risk:** `ferretdb-eval` SSPL licence — review if production use is restricted; FerretDB is working on a production image
- **Backup:** ferretdb-eval stores data at `/data` — mount as bind volume for Kopia coverage

### If staying with OpenWebUI (fallback)
Fix: bump limit 1G → 1.5G, update model to `gemini-2.5-flash`. No other changes needed.

---

## Container Delta — 27 → 28 (or 29 with LibreChat)

### Remove (5)
| Container | Reason |
|---|---|
| `cryptex-diun` | → Dockhand |
| `cryptex-dozzle` | → Dockhand |
| `cryptex-tianji` | → Uptime Kuma + Umami + Shlink. LIVE postgres connection exhaustion. |
| `cryptex-rclone` | WebDAV abandoned (CF blocks PROPFIND) |
| `cryptex-quartz-builder` | Remove from compose — cron-only is correct pattern |

### Add (6 base, +1 if LibreChat)
| Container | Purpose | DB | RAM |
|---|---|---|---|
| `cryptex-dockhand` | Docker mgmt + logs + metrics + update notifications + vuln scan | SQLite | 256M |
| `cryptex-uptime-kuma` | Uptime monitoring + status page + notifications | SQLite | 256M |
| `cryptex-umami` | Web analytics | Postgres (shared) | 256M |
| `cryptex-shlink` | URL shortener + click analytics | Postgres (shared) | 256M |
| `cryptex-woodpecker-server` | CI server (Forgejo OAuth) | Postgres (shared) | 256M |
| `cryptex-woodpecker-agent` | CI pipeline runner | None | 256M |
| `cryptex-librechat` *(optional)* | AI chat UI (replaces OpenWebUI) | via ferretdb | 512M |
| `cryptex-ferretdb-eval` *(optional)* | MongoDB-compat proxy + postgres (bundled) | Internal | 256M |

**Update notifications:** Dockhand replaces DIUN fully. It watches all running image tags, detects newer registry versions, and adds Grype/Trivy CVE scanning on top. The n8n `01-diun-intelligence.json` workflow (Gemini analysis of DIUN webhooks) becomes redundant — archive it in Phase 1.

---

## Per-Container Analysis & Issues

### cryptex-postgres
- Memory: 196MB / 1GB ✅
- **🔴 LIVE:** `FATAL: too many connections for role "tianji_user"` — Tianji bypasses pgbouncer, exhausting per-role slot. Active right now. Resolved by removing Tianji (Phase 1).
- **🟠** `WARNING: you don't own a lock of type ExclusiveLock` — repeated, from cancelled Tianji transactions
- **🟡** `max_connections=60` tight for 8-DB stack → bump to 100 (Phase 3)
- **🟡** `effective_cache_size=512MB` → should be 768MB (70% of 1GB limit)
- **🟡** Upgrade to `postgres:17-alpine` (Phase 3, dump/restore required)

### cryptex-pgbouncer
- Memory: 1.66MB / 64MB ✅
- **🟡** Healthcheck `nc -z` is TCP-only (acceptable for restart detection, document it)
- **🟡** Add umami, woodpecker, shlink entries (Phase 1/2)
- **🟡** Forgejo configured in pgbouncer.ini but compose uses direct postgres — fix compose (Phase 4)

### cryptex-redis
- Memory: 40MB / 256MB ✅
- **🟠** No persistence — `--save` and `--appendonly` absent. Restart = full wipe (Moodle sessions, n8n cache).
- **🟡** Named volume `cryptex_redis_data` at `/var/lib/docker/volumes/` — NOT in Kopia's `/opt/cryptex/data` scope. Acceptable (cache only). Document.
- Fix: add `--save 60 1 --appendonly yes`

### cryptex-cloudflared
- Memory: 45MB / 128MB ✅ No issues.

### cryptex-socket-proxy
- Memory: 26MB / 64MB ✅
- **🔴** `EXEC: 1` — only used by archived workflow. Container escape risk.
- **🟡** `NETWORKS: 0`, `VOLUMES: 0` → enable for Dockhand
- **Keep:** n8n workflows actively call it (health-summary, storage-monitor, weekly-digest)

### cryptex-portfolio
- Memory: 9MB / 64MB ✅
- `read_only: true` + tmpfs — good. No issues.

### cryptex-moodle
- Memory: 118MB / 2GB — low actual, 2GB appropriate for PHP-FPM spikes
- **🟡** Custom Dockerfile — requires manual version bump
- **🟡** `SYS_CHROOT` capability — needed for PHP-FPM; document explicitly

### cryptex-traxlrs
- Memory: 112MB / 512MB ✅ No issues.

### cryptex-vaultwarden
- Memory: 56MB / 150MB ✅
- **🔴 Security:** Plain text `ADMIN_TOKEN` — Vaultwarden warns every startup. Must be Argon2 hash.
  - Fix (Phase 0): `docker exec cryptex-vaultwarden /vaultwarden hash --preset owasp` → update `.env`
- **🟡** SQLite — Kopia covers file at `/opt/cryptex/data/vaultwarden/db.sqlite3`. Acceptable.
- **🟡** `WEBSOCKET_ENABLED: true` — verify nginx has `Upgrade` + `Connection: upgrade` headers

### cryptex-n8n
- Memory: 243MB / 600MB ✅
- **🟠** `07-vault-sync.json` calls `docker exec cryptex-workstation` — container doesn't exist. Already broken.
- **🟠** `01-diun-intelligence.json` — dies when DIUN removed (Phase 1)
- **🟡** `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]` with `user: 1000:1000` — audit if all caps needed

### cryptex-n8n-tools
- Exits cleanly ✅ (restart:no, by design). Keep as-is.

### cryptex-adguard
- Memory: 592MB / 1GB — HIGH
- **🟠 Live error:** `chtimes operation not permitted` on filter files — ownership mismatch. Filter updates failing.
  - Fix (Phase 0): `sudo chown -R root:root /opt/cryptex/data/adguard/` + restart
- **🟡** 1GB limit excessive; reduce log/stats retention to 7d → drop limit to 256M
- **🟡** Healthcheck comment says "port 53" but tests port 80 — fix comment

### cryptex-tianji
- Memory: 432MB / 512MB — near ceiling
- **🔴 LIVE:** Causing postgres connection exhaustion right now
- **Removal:** Phase 1 (urgent)

### cryptex-kopia
- Memory: 357MB / 2GB — limit massively oversized
- **🔴** Backup local-only — disk failure = total loss
- **🟠 K1 — UI Access Denied:** No repository user added. Server-control user ≠ UI user.
  - Fix (Phase 0): `docker exec cryptex-kopia kopia server users add <user>@cryptex --user-password <pass>`
- **🟠 K2 — Log spam:** Healthcheck runs unauthenticated every 30s → 2,880 "failed login" lines/day
  - Fix (Phase 4): change healthcheck to `nc -z 127.0.0.1 51515`
- **🟡** Drop limit 2G → 768M

### cryptex-diun
- Memory: 61MB — being removed (Phase 1)

### cryptex-dozzle
- Memory: 12MB — being removed (Phase 1)

### cryptex-forgejo
- Memory: 95MB / 512MB ✅
- **🟡** Compose uses `cryptex-postgres:5432` direct — pgbouncer.ini already configured for forgejo. Fix compose.
- **🟡** `FORGEJO_DISABLE_REGISTRATION:-false` — if env var missing, registration OPEN. Change default to `true`.

### cryptex-miniflux
- Memory: 13MB / 128MB ✅ Excellent. No issues.

### cryptex-actualbudget
- Memory: 151MB / 256MB — normal for Node.js. No issues.

### cryptex-openwebui
- Memory: 722MB / 1GB — approaching limit
- **🟠** `DEFAULT_MODELS: gemini-2.0-flash-exp` — `-exp` models retire without notice
- **🟡** Limit 1G → 1.5G (if keeping), or replace with LibreChat
- **Decision point:** Replace with LibreChat + ferretdb-eval, or keep with fixes

### cryptex-searxng
- Memory: 131MB / 256MB ✅
- **🟠** `limiter.toml missing` — bot detection/rate limiter disabled
  - Fix (Phase 0): create `/opt/cryptex/data/searxng/limiter.toml`
- **🟠** `wikidata engine init failed (KeyError: 'name')` — broken engine loading as inactive
  - Fix (Phase 0): disable wikidata in `settings.yml`
- **🟠** `X-Forwarded-For not set` — nginx not passing real IP; bot detection blind
  - Fix (Phase 0): add to searxng nginx block: `proxy_set_header X-Real-IP $http_cf_connecting_ip;` + `proxy_set_header X-Forwarded-For $http_cf_connecting_ip;`
- **🟡** `no-new-privileges: false` — override without documented reason; likely removable
- **🟡** `SEARXNG_SECRET_KEY:-changeme` — remove default fallback

### cryptex-rclone
- Memory: 80MB — unused. Being removed (Phase 1).

### cryptex-alist
- Memory: 94MB / 256MB ✅ No issues.

### cryptex-stirling-pdf
- Memory: 1.26GB / 3GB — high idle (JVM pre-allocation)
- **🟡** `InitialRAMPercentage=30` → change to 10; drop limit 3G → 2G
- **🟡** `no-new-privileges: false` — Tesseract requires it; document explicitly
- **🟡** `SECURITY_ENABLE_LOGIN: false` — no auth; CF Zero Trust only

### cryptex-it-tools
- Memory: 14MB / 128MB ✅ No issues.

### cryptex-notes
- Memory: 9MB / 64MB ✅ No issues.

### cryptex-quartz-builder
- Exits cleanly. `apk add coreutils` on every exec (minor). Being removed from compose.

---

## Socket Proxy — KEEP

Three active n8n workflows call it directly:
| Workflow | Endpoint | Purpose |
|---|---|---|
| `02-health-summary.json` | `/containers/json` | Daily health → Telegram |
| `03-storage-monitor.json` | `/system/df` | Disk alerts → Telegram |
| `08-weekly-ai-digest.json` | `/containers/json` + `/info` | Weekly Gemini digest |

Dockhand also routes through it via `DOCKER_HOST: tcp://cryptex-socket-proxy:2375`.

Permission changes: `EXEC: 1→0`, `NETWORKS: 0→1`, `VOLUMES: 0→1`

---

## Database Plan

### New postgres databases (add to `init-databases.sh`)
- `umami` + `umami_user`
- `woodpecker` + `woodpecker_user`
- `shlink` + `shlink_user`

### pgbouncer.ini additions
```ini
umami      = host=cryptex-postgres port=5432 dbname=umami
woodpecker = host=cryptex-postgres port=5432 dbname=woodpecker
shlink     = host=cryptex-postgres port=5432 dbname=shlink
```

### SQLite services (no pgbouncer, file in data volume)
- Uptime Kuma — `/opt/cryptex/data/uptime-kuma/`
- Dockhand — `/opt/cryptex/data/dockhand/`

### ferretdb-eval (if LibreChat adopted)
- Bundled postgres+ferretdb in one image; stores data at `/data`
- Mount: `/opt/cryptex/data/ferretdb:/data` for Kopia coverage
- **Does NOT share `cryptex-postgres`** — DocumentDB extension requires custom postgres build
- pgbouncer: not applicable (separate internal postgres)

### Named volumes NOT in Kopia scope (document, accept)
- `cryptex_redis_data` — Redis is cache only; loss = re-login, not data loss
- `cryptex_n8n_tools` — binaries only, recreated on next `docker compose up`

---

## Everything That Changes

| File / System | Change |
|---|---|
| `docker-compose.yml` | Remove 5, add 6 (or 8 with LibreChat), all resource limits + security fixes |
| `.env` | Add: umami/woodpecker/shlink DB creds, Woodpecker Forgejo OAuth, Dockhand creds, LibreChat JWT/session secrets (if adopted) |
| `configs/postgres/init-databases.sh` | Add umami, woodpecker, shlink |
| `configs/pgbouncer/pgbouncer.ini` | Add umami, woodpecker, shlink |
| `configs/pgbouncer/userlist.txt` | Add 3 new users |
| `configs/nginx/` | Add proxy configs: dockhand, uptime-kuma, umami, shlink, woodpecker, librechat (if adopted); fix SearXNG X-Forwarded-For |
| `data/searxng/limiter.toml` | Create with `[real_ip]` config |
| `data/searxng/settings.yml` | Disable wikidata engine |
| Cloudflare Tunnel | Add routes: `docker.`, `status.`, `analytics.`, `s.`, `ci.`, `chat.` |
| Kopia backup scope | Include all new data dirs |
| `configs/n8n-workflows/` | Archive `01-diun-intelligence.json`; fix/archive `07-vault-sync.json` |
| Forgejo | Create OAuth app for Woodpecker |
| Cron (root) | Weekly update: remove tianji/diun/dozzle/rclone references |

---

## Complete Issues List

### 🔴 Critical
| ID | Issue | Phase |
|---|---|---|
| C1 | Kopia local-only backup — disk failure = total loss | Phase 4 |
| C2 | SearXNG `:-changeme` secret key fallback | Phase 4 |
| C3 | **LIVE:** Tianji postgres connection exhaustion | Phase 1 (urgent) |

### 🔴 Security
| ID | Issue | Fix | Phase |
|---|---|---|---|
| S1 | Vaultwarden plain text `ADMIN_TOKEN` — warns every restart | `docker exec cryptex-vaultwarden /vaultwarden hash --preset owasp` → update `.env` | Phase 0 |
| S2 | socket-proxy `EXEC: 1` — archived workflow only; container escape risk | `EXEC: 0` | Phase 1 |
| S3 | SearXNG `no-new-privileges: false` — no documented reason | Audit; likely removable | Phase 4 |
| S4 | Stirling PDF `no-new-privileges: false` — Tesseract needs it | Document explicitly | Phase 4 |
| S5 | Forgejo `DISABLE_REGISTRATION:-false` — open if env var missing | Change default to `true` | Phase 4 |
| S6 | Image pinning — most on `:latest`; simultaneous Sunday blind updates | Pin key services to major version tags | Phase 4 |

### 🟠 Operational
| ID | Issue | Fix | Phase |
|---|---|---|---|
| O1 | AdGuard `chtimes not permitted` — filter updates failing | `sudo chown -R root:root /opt/cryptex/data/adguard/` + restart | Phase 0 |
| O2 | SearXNG `limiter.toml` missing — bot detection off | Create file | Phase 0 |
| O3 | SearXNG wikidata engine broken | Disable in `settings.yml` | Phase 0 |
| O4 | SearXNG `X-Forwarded-For` not set in nginx | Add `proxy_set_header X-Real-IP $http_cf_connecting_ip` | Phase 0 |
| O5 | Kopia UI Access Denied — no repository user | `kopia server users add <user>@cryptex` | Phase 0 |
| O6 | Kopia healthcheck log spam — 2,880 failed logins/day | Change to `nc -z 127.0.0.1 51515` | Phase 4 |
| O7 | Redis no persistence — restart wipes data | `--save 60 1 --appendonly yes` | Phase 4 |
| O8 | Dead n8n workflow `07-vault-sync.json` — calls nonexistent container | Fix or archive | Phase 0 |
| O9 | Dead n8n workflow `01-diun-intelligence.json` — dies with DIUN | Archive | Phase 1 |
| O10 | Forgejo direct postgres — pgbouncer.ini already configured | One-line fix in compose | Phase 4 |

### 🟡 Resource
| ID | Issue | Fix | Phase |
|---|---|---|---|
| R1 | AdGuard 592MB / 1GB — uncapped retention | Reduce to 7d in UI → limit 1G → 256M | Phase 0 / 4 |
| R2 | Kopia 357MB / 2GB — limit oversized | Drop limit 2G → 768M | Phase 4 |
| R3 | Stirling PDF 1.26GB idle — `InitialRAMPercentage=30` | Change to 10; limit 3G → 2G | Phase 4 |
| R4 | OpenWebUI 722MB / 1GB (if kept) | Bump 1G → 1.5G | Phase 4 |
| R5 | Postgres `effective_cache_size=512MB` | → 768MB | Phase 3 |
| R6 | Postgres `max_connections=60` tight for 8 DBs | → 100 | Phase 3 |

### 🟡 Minor
| ID | Issue | Fix | Phase |
|---|---|---|---|
| M1 | OpenWebUI model `gemini-2.0-flash-exp` (if kept) | → `gemini-2.5-flash` | Phase 4 |
| M2 | AdGuard healthcheck comment wrong | Fix comment | Phase 4 |
| M3 | pgbouncer healthcheck TCP-only | Document; acceptable | — |
| M4 | n8n `CHOWN + DAC_OVERRIDE` with `user: 1000` | Audit caps | Phase 4 |
| M5 | Named volumes not in Kopia scope | Document | — |

---

## Redundancies — Final

| Pair | Verdict |
|---|---|
| rclone + alist | Redundant → remove rclone ✅ |
| quartz-builder compose + cron | Redundant → remove from compose ✅ |
| DIUN + Dozzle | Redundant → Dockhand replaces ✅ |
| `01-diun-intelligence.json` after DIUN removal | Dead → archive ✅ |
| `07-vault-sync.json` | Already broken → fix/archive ✅ |
| portfolio nginx + notes nginx | NOT redundant — different security profiles |
| n8n + Woodpecker | NOT redundant — automation vs CI/CD |
| Uptime Kuma + Dockhand | NOT redundant — external URL vs Docker internals |
| OpenWebUI + LibreChat | Redundant if both added → pick one |

---

## Resource Limits After All Changes

| Container | Before | After |
|---|---|---|
| `adguard` | 1G | 256M |
| `kopia` | 2G | 768M |
| `stirling-pdf` | 3G | 2G + `InitialRAMPercentage=10` |
| `openwebui` | 1G | removed (if LibreChat) or 1.5G (if kept) |
| `tianji` | 512M | removed |
| `librechat` (new, if adopted) | — | 512M |
| `ferretdb-eval` (new, if adopted) | — | 256M |
| `uptime-kuma` (new) | — | 256M |
| `umami` (new) | — | 256M |
| `shlink` (new) | — | 256M |
| `woodpecker-server` (new) | — | 256M |
| `woodpecker-agent` (new) | — | 256M |
| `dockhand` (new) | — | 256M |
| `postgres` | max_conn=60 | max_conn=100 + `effective_cache_size=768MB` |

---

## Postgres 16 → 17 Upgrade (Phase 3)

```bash
# 1. Kopia snapshot
docker exec cryptex-kopia kopia snapshot create /data

# 2. Full dump
docker exec cryptex-postgres pg_dumpall -U $POSTGRES_USER \
  > /opt/cryptex/backups/pg16_$(date +%Y%m%d_%H%M).sql

# 3. Stop all dependents (include Phase 1+2 new services)
docker compose stop moodle traxlrs n8n miniflux forgejo umami woodpecker-server shlink

# 4. Stop pgbouncer + postgres
docker compose stop pgbouncer postgres

# 5. Backup data dir
mv /opt/cryptex/data/postgres /opt/cryptex/data/postgres_pg16_bak

# 6. Update compose: postgres:16-alpine → postgres:17-alpine
#    Also update: max_connections=100, effective_cache_size=768MB

# 7. Fresh init
docker compose up -d postgres  # wait for healthy

# 8. Restore
cat /opt/cryptex/backups/pg16_*.sql | docker exec -i cryptex-postgres psql -U $POSTGRES_USER

# 9. Bring everything up
docker compose up -d

# 10. After 48h soak: rm -rf /opt/cryptex/data/postgres_pg16_bak
```

---

## Kopia → Cloudflare R2 (Phase 4)

```bash
# CF dashboard: create R2 bucket + S3-compatible API token

docker exec cryptex-kopia kopia repository connect s3 \
  --bucket=cryptex-backup \
  --endpoint=<account-id>.r2.cloudflarestorage.com \
  --access-key=... \
  --secret-access-key=...

docker exec cryptex-kopia kopia snapshot list  # verify
```

---

## Honest Addition Assessment

| Addition | Evidence of need | Add now? | Condition to add |
|---|---|---|---|
| Dockhand | Replaces 3 tools, live bugs | **Yes** | Phase 1 |
| Uptime Kuma | Tianji breaking postgres now | **Yes** | Phase 1 |
| Umami | No tracking script embedded anywhere | **Defer** | Only when you embed scripts |
| Shlink | No evidence Tianji shortlinks were used | **Defer** | Only when you have a use case |
| Woodpecker CI | **0 repos in Forgejo** — nothing to build | **Defer** | Only when repos + pipelines exist |
| LibreChat | ferretdb-eval is dev/SSPL grade | **Defer** | When FerretDB ships stable image |
| OpenWebUI fix | Current model is deprecated `-exp` | **Yes** | Phase 4 (one-line fix) |

---

## Execution Phases

### Phase 0 — Fix live issues NOW (15 min, zero compose changes)
1. **S1** — Hash Vaultwarden token: `docker exec cryptex-vaultwarden /vaultwarden hash --preset owasp` → update `.env` → restart
2. **O5/K1** — `docker exec cryptex-kopia kopia server users add <user>@cryptex --user-password <pass>`
3. **O8** — Fix or archive `07-vault-sync.json`
4. **O1** — `sudo chown -R root:root /opt/cryptex/data/adguard/` → `docker restart cryptex-adguard`
5. **O2/O3/O4** — SearXNG: create limiter.toml, disable wikidata, fix nginx X-Forwarded-For headers
6. **R1 (partial)** — AdGuard UI: reduce log + stats retention to 7 days

### Phase 1 — Core monitoring swap (27 → 24 containers, zero downtime)
_Minimum viable upgrade. Fixes all live bugs, consolidates monitoring._
1. Add to compose: Dockhand, Uptime Kuma
2. Update socket-proxy: `EXEC:0`, `NETWORKS:1`, `VOLUMES:1`
3. Update nginx + CF tunnel for new subdomains
4. Migrate Tianji monitors → Uptime Kuma
5. Archive `01-diun-intelligence.json`
6. Remove: Tianji, DIUN, Dozzle, rclone, quartz-builder (from compose)

### Phase 2 — Postgres upgrade (maintenance window ~20min)
Full dump/restore process above.
Stop list includes all services. Update max_connections=100, effective_cache_size=768MB.

### Phase 3 — Hardening (zero downtime)
1. Resource limits: adguard→256M, kopia→768M, stirling-pdf→2G (InitialRAMPercentage=10)
2. Security: S2 EXEC:0 (done Phase 1); S3/S4 document; S5 Forgejo registration default; S6 image pinning
3. O6: Kopia healthcheck → `nc -z 127.0.0.1 51515`
4. O7: Redis `--save 60 1 --appendonly yes`
5. O10: Forgejo → pgbouncer (one-line compose fix)
6. C1: Kopia → R2 remote backend
7. C2: SearXNG remove `:-changeme`
8. M1: OpenWebUI model → `gemini-2.5-flash`, bump limit → 1.5G
9. M4: n8n capabilities audit

### Phase 4 — 10/10 polish (no new containers)
_Closes the gap from 8.5 to 10. All config/process changes._

1. **Image pinning** — pin all key services to major version tags (not `:latest`)
   ```yaml
   n8nio/n8n:1
   ghcr.io/open-webui/open-webui:0  # or remove if LibreChat adopted
   kopia/kopia:0
   vaultwarden/server:1-alpine
   miniflux/miniflux:2
   actualbudget/actual-server:25
   adguard/adguardhome:v0
   xhofe/alist:v3
   searxng/searxng:2025
   moonrailgun/tianji:latest  # removed in Phase 1, moot
   ```

2. **Update process discipline** — change Sunday cron from `pull + up -d` to `pull only`.
   Dockhand alerts on new versions → review → per-service `docker compose up -d --no-deps <svc>`.
   Intentional, not blind.

3. **Forgejo binary decision** (pick one, no fence-sitting):
   - **Option A:** Migrate code repos to Forgejo → Woodpecker CI becomes justified → add both
   - **Option B:** Remove Forgejo entirely → saves 95MB + 512M limit
   A service with 0 repos is a 9/10 ceiling.

4. **n8n workflow audit**
   - Fix `07-vault-sync.json` (calls `docker exec cryptex-workstation` — container doesn't exist)
   - Update `08-weekly-ai-digest.json` — remove hardcoded `"22 Docker containers"` string (dynamic count already available from socket proxy query in same workflow)
   - Audit all 12 workflows after each phase for drift

5. **Host service monitoring in Uptime Kuma** (after Phase 1)
   - Add TCP monitor: `localhost:8082` (zellij-web — your primary terminal)
   - Add TCP monitor: `localhost:8084` (code-server)
   - Add HTTP monitor: `https://psidex.com` — routes through CF tunnel; if cloudflared dies, this catches it

6. **External monitoring — zero containers, free**
   Uptime Kuma is inside the VPS — if VPS dies, Uptime Kuma dies too. Status page goes dark at the worst moment.
   - Add Cloudflare Health Checks on your domain (free tier)
   - OR UptimeRobot free tier (50 monitors, 5-min intervals) for `psidex.com`
   One external check is enough.

7. **Kopia R2** — already in plan. The only true blocker for 10/10. Until this is done, disk failure = total loss.

---

### Deferred — Add when need is established
- **Umami**: only when tracking scripts embedded in Moodle + portfolio + aquasoul
- **Shlink**: only when a URL shortening use case exists
- **Woodpecker CI**: only after Forgejo decision (Option A above) + first pipeline written
- **LibreChat + FerretDB**: when FerretDB ships stable non-eval production image
- **Postgres 17**: supported until Nov 2028; do when maintenance window is convenient, not as prerequisite

---

## Score Model

| Dimension | Current | After Phase 0+1+3 | After Phase 4 (10/10) |
|---|---|---|---|
| Live bugs | 3 active | 0 | 0 |
| Security issues | 6 | 1 | 0 |
| Offsite backup | ❌ | ✅ (R2) | ✅ |
| Monitoring coverage | Partial | Partial | Full (host + external) |
| Update process | Blind cron | Blind cron | Intentional per-service |
| Workflow accuracy | 2 dead | 1 dead | 0 dead |
| Every container justified | No | Mostly | Yes |
| External monitoring | None | None | CF/UptimeRobot |
| Image pinning | 6/24 | 6/24 | 24/24 |
| **Rating** | **4/10** | **8.5/10** | **10/10** |

---

## Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| n8n-tools init container | Keep | Custom Dockerfile breaks auto-updates |
| Socket proxy | Keep | n8n workflows depend on it; Dockhand routes through it |
| Uptime Kuma vs Dockhand | Both | Different scopes: external URL monitoring vs Docker internals |
| Forgejo SSH | Disabled | Woodpecker uses HTTPS OAuth |
| Network segmentation | Flat (single bridge) | Acceptable for single-host homelab |
| Vaultwarden SQLite | Keep | Single-user; Kopia covers file backup |
| Redis named volume | Accept | Cache only; loss = re-login, not data loss |
| LibreChat FerretDB | `ferretdb-eval:2` | Cannot share cryptex-postgres (needs DocumentDB extension) |
| Shlink domain | `s.psidex.com` | Short, clean |
| Tianji AI Gateway | Not replacing | LiteLLM Proxy if needed later |
