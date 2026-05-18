# CRYPTEX — Project Context

**Stack:** 22-container Docker Compose on Oracle Cloud ARM64 (Ubuntu)
**Network:** 172.18.0.0/16 (bridge: cryptex_net)
**Remote path:** /opt/cryptex
**SSH key:** ~/.ssh/cryptex_vps
**SSH user:** ubuntu

---

## Services

| Container | Purpose |
|-----------|---------|
| cryptex-postgres | Shared DB (Moodle, n8n, Tianji, TRAX, Forgejo, Miniflux) |
| cryptex-redis | Cache + queue (n8n, Moodle sessions) |
| cryptex-cloudflared | Cloudflare Tunnel — outbound only, no open inbound ports |
| cryptex-socket-proxy | Filtered Docker API for Dozzle/DIUN + n8n exec (tecnativa/docker-socket-proxy) |
| cryptex-portfolio | nginx serving portfolio + AquaSoul Studio (two sites, one container) |
| cryptex-moodle | LMS (custom Dockerfile build) |
| cryptex-traxlrs | xAPI Learning Record Store (custom Dockerfile build) |
| cryptex-vaultwarden | Password manager |
| cryptex-n8n | Workflow automation (custom Dockerfile with qpdf for bank statements) |
| cryptex-adguard | DNS filtering (port 53 exposed to host) |
| cryptex-tianji | Monitoring + public status page |
| cryptex-kopia | Backup server (local + Backblaze B2 offsite) |
| cryptex-diun | Docker image update notifier |
| cryptex-holyclaude | HolyClaude web terminal — CloudCLI UI + Claude Code + Gemini + Codex (coderluii/holyclaude:latest) |
| cryptex-dozzle | Container log viewer |
| cryptex-forgejo | Self-hosted Git |
| cryptex-miniflux | RSS reader + AI morning digest source |
| cryptex-actualbudget | Self-hosted budget tracker (ActualBudget) |
| cryptex-openwebui | AI chat interface — OpenWebUI with Gemini API |
| cryptex-searxng | Private self-hosted search engine |
| cryptex-stirling-pdf | Self-hosted PDF tools (merge, split, OCR, compress) |
| tailscale (host) | Backup SSH access — host-installed, not a container |

---

## Cloudflare Tunnel Routes

```
<DOMAIN>                → cryptex-portfolio:80  (Parth portfolio)
aquasoulstudio.in       → cryptex-portfolio:80  (AquaSoul Studio — same nginx)
learn.<DOMAIN>          → cryptex-moodle:80
lrs.<DOMAIN>            → cryptex-traxlrs:80
vault.<DOMAIN>          → cryptex-vaultwarden:80
n8n.<DOMAIN>            → cryptex-n8n:5678
dns.<DOMAIN>            → cryptex-adguard:80
monitor.<DOMAIN>        → cryptex-tianji:12345  (admin — protect)
status.<DOMAIN>         → cryptex-tianji:12345  (public status page)
backup.<DOMAIN>         → cryptex-kopia:51515
code.<DOMAIN>           → cryptex-holyclaude:3001
logs.<DOMAIN>           → cryptex-dozzle:8080
git.<DOMAIN>            → cryptex-forgejo:3000
news.<DOMAIN>           → cryptex-miniflux:8080
budget.<DOMAIN>         → cryptex-actualbudget:5006
chat.<DOMAIN>           → cryptex-openwebui:8080
search.<DOMAIN>         → cryptex-searxng:8080
pdf.<DOMAIN>            → cryptex-stirling-pdf:8080
```

Zero Trust policies: portfolio + status = public; dns.*/dns-query = bypass; everything else = email/SSO auth.

---

## Scripts

| Script | Run where | Purpose |
|--------|-----------|---------|
| `transfer-to-vps.sh [VPS_IP]` | Local Mac | SCP project files + Claude config to VPS |
| `setup-env.sh` | VPS | Interactive .env generator |
| `deploy.sh` | VPS | Build images, pull, start all containers, install cron |
| `health-check.sh` | VPS (cron */5m) | Check container health states |
| `backup.sh` | VPS (cron 3AM) | Local + B2 offsite backup |
| `update.sh` | VPS | Pull new images + recreate containers |
| `restore-env.sh` | VPS | Restore .env from encrypted backup |
| `disable-signups.sh` | VPS | Disable Vaultwarden + Forgejo signups post-setup |
| `update-adguard.sh` | VPS | Merge new AdGuard template config without losing credentials |
| `bootstrap.sh` | VPS (sudo) | Full server bootstrap for fresh or existing Ubuntu installs |
| `cryptex.sh` | Local Mac | Master deploy wizard (Terraform → transfer → SSH instructions) |
| `generate-profiles.sh` | Local Mac | Generate Apple .mobileconfig for DoH DNS |
| `setup-terraform.sh` | Local Mac | Init Terraform for Oracle Cloud provisioning |

---

## Key Files

```
docker-compose.yml              # Source of truth — all service definitions
.env.example                    # Template — copy to .env on VPS, fill secrets
configs/                        # Static service configs
  nginx/                        # Portfolio + AquaSoul nginx vhosts
  adguard/AdGuardHome.yaml      # Initial AdGuard config (DoH enabled)
  postgres/                     # Init SQL scripts
  n8n-workflows/                # Automation workflow JSONs
  moodle-scripts/
    scorm-import.php            # PHP CLI for SCORM activity import (runs via docker exec)
dockerfiles/
  moodle.Dockerfile             # Custom Moodle build
  traxlrs.Dockerfile            # Custom TRAX LRS build
  n8n.Dockerfile                # n8n + qpdf/pdftotext for bank statement workflows
terraform/                      # Oracle Cloud ARM64 IaC
data/
  portfolio/                    # Static portfolio files (transferred from local)
  aquasoul/                     # AquaSoul Studio static site
  holyclaude/claude/            # Claude Code config + auth (persists across image updates)
  holyclaude/workspace/         # Projects, vault, working files
  moodle-uploads/               # SCORM zips + import script (shared n8n ↔ moodle volume)
```

---

## Deployment Workflow

```bash
# 1. Provision VPS (first time only)
cd terraform && terraform apply

# 2. Transfer from Mac
./scripts/transfer-to-vps.sh <VPS_IP>
# transfers: docker-compose.yml, configs/, scripts/, dockerfiles/,
#            Claude config (~/.claude → data/workstation/claude/),
#            portfolio files, AquaSoul files, n8n workflows

# 3. SSH in
ssh -i ~/.ssh/cryptex_vps ubuntu@<VPS_IP>

# 4. Configure
cd /opt/cryptex && ./scripts/setup-env.sh

# 5. Deploy
./scripts/deploy.sh
```

---

## Automated Maintenance (cron — installed by deploy.sh)

```
Every  1 min    — Moodle cron (SCORM completion, grades, email) [only if moodle enabled]
Every  5 min    — health-check.sh (direct Telegram fallback if n8n down)
Daily  2:30 AM  — PostgreSQL VACUUM ANALYZE
Daily  3:00 AM  — backup.sh (postgres + vaultwarden + n8n + moodle + forgejo + kopia)
Sunday 4:00 AM  — docker system prune (named cryptex volumes excluded)
Sunday 5:00 AM  — update.sh auto-update all services (custom images rebuilt with --pull)
Sunday 8:00 AM  — weekly AI digest (n8n workflow — Gemini analysis → Telegram)
```
Log rotation via /etc/logrotate.d/cryptex (installed by deploy.sh).

---

## Constraints

- **ARM64 only** — all images must support linux/arm64 (Oracle Cloud Ampere A1)
- **iptables position 6** — Oracle VPS has hardcoded ACCEPT rules at positions 1–5; new rules must insert at position 6+
- **No open inbound ports** — Cloudflare Tunnel handles all external traffic; no port 80/443 exposure needed
- **Custom builds** — moodle, traxlrs, n8n use local Dockerfiles; don't use `docker pull` for these
- **HolyClaude** — uses pre-built `coderluii/holyclaude:latest`; no local Dockerfile. Update: `docker compose pull holyclaude && docker compose up -d holyclaude`
- **HolyClaude Claude config** — mounted from `/opt/cryptex/data/holyclaude/claude` as `/home/claude/.claude`
- **SCORM pipeline** — SCORM .zip → Forgejo git push → n8n webhook → docker exec moodle php scorm-import.php (bypasses Cloudflare 100MB limit)
- **Socket proxy EXEC:1** — required for n8n to exec into containers (vault sync + SCORM import)
- **Forgejo → direct postgres** — Forgejo bypasses PgBouncer (uses cryptex-postgres:5432 directly); PgBouncer transaction mode breaks Forgejo's prepared statements. Same as Tianji.
- **Tailscale** — host-installed (not a container). Auth key in .env as TAILSCALE_AUTH_KEY. Deploy.sh runs `tailscale up` automatically. Backup SSH if Cloudflare tunnel fails.
- **SSH** — password auth disabled, pubkey only. Key: ~/.ssh/cryptex_vps
