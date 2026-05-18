# Cryptex Stack Audit — April 2026

## Critical

| # | Issue | Action |
|---|---|---|
| 1 | **Kopia is local-only** — 718MB repo on same disk as data. Disk failure = total loss. | Add remote backend: Cloudflare R2 (free 10GB egress), B2, or S3 |
| 2 | **SearXNG secret key fallback is `changeme`** — `${SEARXNG_SECRET_KEY:-changeme}` silently uses a known key if env var is missing | Remove default, add deploy-time assertion |

## Security

| # | Issue | Action |
|---|---|---|
| 3 | **socket-proxy `EXEC: 1`** — n8n can exec into any container via Docker API (container escape vector) | Set `EXEC: 0` unless actively used |
| 4 | **`no-new-privileges:false`** on SearXNG + Stirling PDF overrides global default | Audit if truly needed; Stirling needs it for Tesseract, SearXNG likely doesn't |
| 5 | **Everything is `:latest`** — Sunday cron updates all images simultaneously; one breaking change hits the whole stack | Pin major versions on key services (n8n, openwebui, forgejo already uses `:10`) |

## Resource / Reliability

| # | Issue | Action |
|---|---|---|
| 6 | **Tianji at 432MB / 512MB** — near ceiling at idle, will OOM on analytics spike | Bump limit to 768M |
| 7 | **AdGuard at 592MB / 1GB** — normal usage is 50–150MB; likely uncapped query log | Check AdGuard → DNS query log + Statistics retention → reduce to 7 days; drop limit to 256M |
| 8 | **Stirling PDF at 1.26GB idle** — JVM pre-allocated heap from `InitialRAMPercentage=30` | Change `InitialRAMPercentage=10`; drop container limit to 2G |
| 9 | **OpenWebUI at 721MB / 1GB** — could OOM under active API streaming | Bump limit to 1.5G |

## Operational

| # | Issue | Action |
|---|---|---|
| 10 | **Quartz builder runs `apk add coreutils` every 15min** — 96 package manager calls/day | Add existence check before apk, or bake into custom image |
| 11 | **Forgejo bypasses pgbouncer** with no documented reason (Tianji has one) | Route through pgbouncer or document ORM limitation |
| 12 | **rclone container running despite WebDAV being abandoned** (CF blocks PROPFIND) | Remove if no active use case; saves 80MB + attack surface |
| 13 | **Vaultwarden on SQLite** — not in pg_dump backup path | Kopia covers it via file backup — verify schedule alignment |

## Minor

| # | Issue | Action |
|---|---|---|
| 14 | **OpenWebUI default model `gemini-2.0-flash-exp`** — `-exp` models get retired | Switch to `gemini-2.5-flash` |
| 15 | **n8n-tools copies all of `/usr/lib`** — fragile across Alpine version drifts | Scope to only libs needed by qpdf/pdftotext (`ldd`) |

## Priority Order

```
🔴 Now      Add Kopia remote backend (R2/B2/S3)
🔴 Now      Fix SearXNG secret key fallback
🟠 Soon     Disable socket-proxy EXEC
🟠 Soon     Reduce AdGuard log retention → drop RAM limit
🟠 Soon     Bump Tianji memory limit to 768M
🟡 Next     Remove rclone if unused
🟡 Next     Fix Quartz apk install frequency
🟡 Next     Forgejo → pgbouncer or document why not
🟢 Cleanup  Pin image versions on key services
🟢 Cleanup  Update OpenWebUI default model
```

## New Services to Consider

See conversation for full analysis — Woodpecker CI, Beszel, Paperless-ngx, Changedetection.io, Headscale.
