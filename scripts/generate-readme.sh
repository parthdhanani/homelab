#!/bin/bash
# Generates CRYPTEX-README.md with all service credentials from .env
# Run on VPS: cd /opt/cryptex && ./scripts/generate-readme.sh

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
source "${COMPOSE_DIR}/.env"

VPS_IP=$(curl -sf https://checkip.amazonaws.com 2>/dev/null || echo 'YOUR_VPS_IP')
mkdir -p "${COMPOSE_DIR}/backups"
OUT="${COMPOSE_DIR}/backups/CRYPTEX-README.md"

cat > "$OUT" << EOF
# CRYPTEX — Deployment Reference
Generated: $(date)

---

## VPS Access

| Method | Details |
|--------|---------|
| SSH | \`ssh ubuntu@${VPS_IP} -i ~/.ssh/cryptex_vps\` |
| HolyClaude (Claude Code web) | https://code.${DOMAIN} |
| Container logs | https://log.${DOMAIN} |

---

## Service Credentials

| Service | URL | Login |
|---------|-----|-------|
| AdGuard | https://ad.${DOMAIN} | ${ADGUARD_ADMIN_USER} / ${ADGUARD_ADMIN_PASSWORD} |
| Vaultwarden | https://vault.${DOMAIN} | ${VAULTWARDEN_USER_EMAIL} / ${VAULTWARDEN_USER_PASSWORD} |
| Moodle LMS | https://learn.${DOMAIN} | ${MOODLE_ADMIN_USER:-admin} / ${MOODLE_ADMIN_PASSWORD:-see .env} |
| n8n Automation | https://n8n.${DOMAIN} | ${N8N_ADMIN_EMAIL:-see .env} / ${N8N_ADMIN_PASSWORD:-see .env} |
| Kopia Backup | https://backup.${DOMAIN} | ${KOPIA_SERVER_USER:-admin} / ${KOPIA_SERVER_PASSWORD:-${KOPIA_PASSWORD:-see .env}} |
| OpenWebUI (AI chat) | https://chat.${DOMAIN} | ${ADMIN_EMAIL:-admin@${DOMAIN}} / ${OPENWEBUI_ADMIN_PASSWORD:-not-set} |
| Forgejo Git | https://git.${DOMAIN} | admin (set on first visit) |
| Tianji Analytics | https://status.${DOMAIN} | email signup on first visit |
| SearXNG | https://search.${DOMAIN} | no auth (Zero Trust protected) |
| Stirling PDF | https://pdf.${DOMAIN} | no auth (Zero Trust protected) |
| ActualBudget | https://money.${DOMAIN} | set on first visit |
| Miniflux RSS | https://news.${DOMAIN} | set on first visit |

---

## Database Passwords

| Database | User | Password |
|----------|------|---------|
| moodle | ${MOODLE_DB_USER} | ${MOODLE_DB_PASSWORD} |
| n8n | ${N8N_DB_USER} | ${N8N_DB_PASSWORD} |
| forgejo | ${FORGEJO_DB_USER} | ${FORGEJO_DB_PASSWORD} |
| tianji | ${TIANJI_DB_USER} | ${TIANJI_DB_PASSWORD} |
| traxlrs | ${TRAXLRS_DB_USER} | ${TRAXLRS_DB_PASSWORD} |
| miniflux | ${MINIFLUX_DB_USER:-miniflux_user} | ${MINIFLUX_DB_PASSWORD} |
| postgres superuser | ${POSTGRES_USER} | ${POSTGRES_PASSWORD} |

---

## API Keys

| Service | Key |
|---------|-----|
| Gemini API | ${GEMINI_API_KEY:-not set} |
| Telegram Bot Token | ${TELEGRAM_BOT_TOKEN:-not set — needed for alerts} |
| Telegram Chat ID | ${TELEGRAM_CHAT_ID:-not set} |

---

## Cloudflare Tunnel Routes

\`\`\`
${DOMAIN}                → cryptex-portfolio:80       (public)
your-second-domain.com        → cryptex-portfolio:80       (public)
learn.${DOMAIN}          → cryptex-moodle:80
lrs.${DOMAIN}            → cryptex-traxlrs:80
vault.${DOMAIN}          → cryptex-vaultwarden:80
n8n.${DOMAIN}            → cryptex-n8n:5678
dns.${DOMAIN}            → cryptex-adguard:80
status.${DOMAIN}         → cryptex-tianji:12345       (public)
monitor.${DOMAIN}        → cryptex-tianji:12345
backup.${DOMAIN}         → cryptex-kopia:51515
code.${DOMAIN}           → cryptex-holyclaude:3001
log.${DOMAIN}            → cryptex-dozzle:8080
git.${DOMAIN}            → cryptex-forgejo:3000
news.${DOMAIN}           → cryptex-miniflux:8080
money.${DOMAIN}          → cryptex-actualbudget:5006
chat.${DOMAIN}           → cryptex-openwebui:8080
search.${DOMAIN}         → cryptex-searxng:8080
pdf.${DOMAIN}            → cryptex-stirling-pdf:8080
\`\`\`

Zero Trust policies:
- Public: ${DOMAIN}, your-second-domain.com, status.${DOMAIN}
- Bypass: dns.${DOMAIN}/dns-query* (DoH — no browser auth possible)
- Email auth: everything else → must use ${SMTP_USER:-your-gmail}

---

## Emergency Access

**Primary SSH:**
\`\`\`
ssh ubuntu@${VPS_IP} -i ~/.ssh/cryptex_vps
\`\`\`

**If SSH key is lost:**
Use Oracle Cloud console → Instance → Launch Cloud Shell

**Tailscale backup SSH:**
Set TAILSCALE_AUTH_KEY in .env → run ./scripts/deploy.sh
Approve at: https://login.tailscale.com/admin/machines

---

## AdGuard DoH DNS Profile

File location on VPS: /opt/cryptex/configs/profiles/cryptex-doh.mobileconfig

Pull to Mac:
  scp ubuntu@oracle:/opt/cryptex/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/

macOS install: double-click the file → System Settings → Privacy & Security → Profiles → Install
iOS install: AirDrop → Settings → General → VPN & Device Management → Install

Requires: Cloudflare Zero Trust bypass policy for dns.${DOMAIN}/dns-query*

---

*Store this file securely — contains all service passwords*
EOF

chmod 600 "$OUT"
echo "README generated: ${OUT}"
echo "Pull to Mac: scp ubuntu@oracle:${OUT} ~/Downloads/CRYPTEX-README.md"
