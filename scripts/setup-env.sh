#!/bin/bash
# CRYPTEX — Interactive .env generator
# Run on VPS: cd /opt/cryptex && ./scripts/setup-env.sh

set -euo pipefail

ENV_FILE="/opt/cryptex/.env"

if [ -f "$ENV_FILE" ]; then
    echo "WARNING: .env already exists at $ENV_FILE"
    read -rp "Overwrite? (y/N): " confirm
    [[ "$confirm" != "y" ]] && echo "Aborted." && exit 0
fi

# ── Helpers ──

gen_password() { openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "${1:-24}"; }
gen_hex() { openssl rand -hex "${1:-32}"; }
gen_base64_key() { echo "base64:$(openssl rand -base64 32)"; }

prompt() {
    local var_name="$1" prompt_text="$2" default="$3"
    local value
    if [ -n "$default" ]; then
        read -rp "$prompt_text [$default]: " value
        printf -v "$var_name" '%s' "${value:-$default}"
    else
        read -rp "$prompt_text: " value
        printf -v "$var_name" '%s' "$value"
    fi
}

prompt_secret() {
    local var_name="$1" prompt_text="$2"
    local value
    read -rsp "$prompt_text: " value
    echo
    printf -v "$var_name" '%s' "$value"
}

echo ""
echo "CRYPTEX — Environment Setup"
echo "────────────────────────────"
echo ""

# ── Installation Profile ──

echo "Select installation profile:"
echo "  1) Personal  — Full stack (all 22 services, recommended)"
echo "  2) Custom    — Choose which services to install"
read -rp "Profile [1]: " PROFILE_CHOICE
PROFILE_CHOICE="${PROFILE_CHOICE:-1}"

DEPLOY_PROFILE="personal"
DEPLOY_SERVICES="all"

if [ "$PROFILE_CHOICE" = "2" ]; then
    DEPLOY_PROFILE="custom"
    echo ""
    echo "Core services (always included): postgres, redis, cloudflared, socket-proxy, portfolio"
    echo ""
    echo "Select optional services (Enter = yes, type 'n' = skip):"
    echo ""

    SELECTED=""

    select_svc() {
        local svc="$1" label="$2"
        read -rp "  Include ${label}? [Y/n]: " c
        [[ "${c,,}" != "n" ]] && SELECTED="${SELECTED} ${svc}"
    }

    echo "── Learning ──────────────────────────────"
    select_svc "moodle"        "Moodle LMS"
    select_svc "traxlrs"       "TRAX LRS (xAPI Learning Record Store)"

    echo "── Automation ────────────────────────────"
    select_svc "n8n"           "n8n Workflow Automation"

    echo "── AI & Tools ────────────────────────────"
    select_svc "workstation"   "Workstation (web terminal + Claude Code)"

    echo "── Security & Network ────────────────────"
    select_svc "vaultwarden"   "Vaultwarden (Password Manager)"
    select_svc "adguard"       "AdGuard Home (DNS Filter + DoH)"
    select_svc "tailscale"     "Tailscale VPN"

    echo "── Monitoring & Backup ───────────────────"
    select_svc "tianji"        "Tianji (Analytics + Public Status Page)"
    select_svc "kopia"         "Kopia (Encrypted Backup — local + B2)"
    select_svc "dozzle"        "Dozzle (Container Log Viewer)"
    select_svc "diun"          "DIUN (Docker Image Update Notifier)"

    echo "── Productivity ──────────────────────────"
    select_svc "forgejo"       "Forgejo (Self-hosted Git)"
    select_svc "miniflux"      "Miniflux (RSS Reader + AI Digest)"

    echo "── Finance ───────────────────────────────"
    select_svc "actualbudget"  "ActualBudget (Finance Tracker)"

    # Core always included; add selected optional services
    DEPLOY_SERVICES="postgres redis cloudflared socket-proxy portfolio${SELECTED}"

    echo ""
    echo "Selected: ${DEPLOY_SERVICES}"
fi

echo ""

# ── Required Inputs ──

prompt DOMAIN "Primary domain (e.g. example.com)" ""
prompt CF_TUNNEL_TOKEN "Cloudflare Tunnel token" ""
prompt TS_AUTHKEY "Tailscale auth key (or 'skip')" "skip"

echo ""
echo "── AquaSoul Studio (optional second site) ──"
prompt AQUASOUL_DOMAIN "Second domain (optional, e.g. your-second-domain.com), or press Enter to skip" ""
# Validate: if it doesn't contain a dot it's not a domain — treat as skip
if [[ "$AQUASOUL_DOMAIN" != *.* ]]; then
    AQUASOUL_DOMAIN=""
fi

echo ""
echo "── Gmail SMTP (for notifications) ──"
echo "Get an App Password: Google Account → Security → 2-Step → App Passwords"
prompt SMTP_USER "Gmail address" ""
if [ -n "$SMTP_USER" ]; then
    prompt_secret SMTP_PASSWORD "Gmail App Password (16 chars, no spaces)"
else
    SMTP_PASSWORD=""
fi

echo ""
echo "── Git Identity (for Workstation container) ──"
prompt GIT_AUTHOR_NAME "Git author name" ""
prompt GIT_AUTHOR_EMAIL "Git author email" ""

echo ""
echo "── Telegram Bot (real-time alerts + container management) ──"
echo "Create a bot: Telegram → @BotFather → /newbot → copy token"
echo "Get chat ID: Message your bot, then visit:"
echo "  https://api.telegram.org/bot<TOKEN>/getUpdates"
prompt TELEGRAM_BOT_TOKEN "Infra Bot token (or 'skip')" "skip"
if [ "$TELEGRAM_BOT_TOKEN" != "skip" ]; then
    prompt TELEGRAM_CHAT_ID "Your Telegram chat ID" ""
else
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
fi

echo ""
echo "── PKM Bot (Claude Channels — Obsidian vault via Telegram) ──"
echo "Create a SEPARATE bot: @BotFather → /newbot (name it 'Parth PKM' or similar)"
echo "This bot lets you query/update your Obsidian vault from Telegram."
prompt PKM_BOT_TOKEN "PKM Bot token (or 'skip')" "skip"
if [ "$PKM_BOT_TOKEN" = "skip" ]; then
    PKM_BOT_TOKEN=""
fi

echo ""
echo "── Backblaze B2 (offsite backup) ──"
echo "Create bucket: B2 Cloud Storage → Buckets → Create (private)"
echo "Create key: App Keys → Add New (restrict to bucket)"
prompt B2_KEY_ID "B2 Key ID (or 'skip')" "skip"
if [ "$B2_KEY_ID" != "skip" ]; then
    prompt_secret B2_APP_KEY "B2 Application Key"
    prompt B2_BUCKET_NAME "B2 Bucket name" "cryptex-backups"
else
    B2_KEY_ID=""
    B2_APP_KEY=""
    B2_BUCKET_NAME=""
fi

echo ""
echo "── Moodle ──"
prompt MOODLE_ADMIN_EMAIL "Moodle admin email" "admin@${DOMAIN}"
prompt MOODLE_SITE_NAME "Moodle site name" ""

echo ""
echo "── TRAX LRS ──"
prompt TRAXLRS_ADMIN_EMAIL "TRAX LRS admin email" "${MOODLE_ADMIN_EMAIL}"
prompt TRAXLRS_ENDPOINT_USERNAME "TRAX xAPI endpoint username (used by Moodle/SCORM)" "lrsuser"

echo ""
echo "── Gemini API (AI workflows — morning digest, weekly analysis) ──"
echo "  Get key: https://aistudio.google.com/app/apikey"
prompt GEMINI_API_KEY "Gemini API key (or 'skip')" "skip"
if [ "$GEMINI_API_KEY" = "skip" ]; then
    GEMINI_API_KEY=""
fi

echo ""
echo "── OpenWebUI (AI chat interface) ──"
echo "  Admin email will be your SMTP email (${SMTP_USER:-your-gmail})"
OPENWEBUI_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
echo "  Auto-generated admin password: ${OPENWEBUI_ADMIN_PASSWORD}"
echo "  (saved to .env — use this to log in at chat.DOMAIN)"

echo ""
echo "── AdGuard Home ──"
prompt ADGUARD_ADMIN_USER "AdGuard admin username" "admin"

echo ""
echo "── Vaultwarden ──"
prompt VAULTWARDEN_USER_EMAIL "Vaultwarden account email (what you'll register with)" "${SMTP_USER}"

echo ""
echo "── Bank Statement Automation ──"
echo "n8n watches Gmail for bank statement emails and auto-processes PDFs"
prompt BANK_EMAIL_DOMAIN "Bank sender email domain (e.g. hdfcbank.com, icicibank.com)" "skip"
if [ "$BANK_EMAIL_DOMAIN" = "skip" ]; then
    BANK_EMAIL_DOMAIN=""
    BANK_PDF_PASSWORD=""
else
    echo "PDF password is usually your DOB: DDMMYYYY format (e.g. 15081995)"
    prompt_secret BANK_PDF_PASSWORD "Bank statement PDF password"
fi

echo ""
echo "── Miniflux (RSS reader) ──"
prompt MINIFLUX_ADMIN_USER "Miniflux admin username" "admin"

# ── Generate All Secrets ──

echo ""
echo "Generating secrets..."

POSTGRES_PASSWORD=$(gen_password 24)
MOODLE_DB_PASSWORD=$(gen_password 24)
MOODLE_ADMIN_PASSWORD=$(gen_password 16)
TRAXLRS_DB_PASSWORD=$(gen_password 24)
TRAXLRS_APP_KEY=$(gen_base64_key)
TRAXLRS_ADMIN_PASSWORD=$(gen_password 16)
TRAXLRS_ENDPOINT_PASSWORD=$(gen_password 16)
N8N_DB_PASSWORD=$(gen_password 24)
N8N_ENCRYPTION_KEY=$(gen_hex 32)
N8N_ADMIN_PASSWORD=$(gen_password 16)
TIANJI_DB_PASSWORD=$(gen_password 24)
TIANJI_JWT_SECRET=$(gen_hex 32)
VAULTWARDEN_ADMIN_TOKEN=$(gen_password 48)
KOPIA_PASSWORD=$(gen_password 24)
KOPIA_SERVER_PASSWORD=$(gen_password 24)
FORGEJO_DB_PASSWORD=$(gen_password 24)
FORGEJO_SECRET_KEY=$(gen_hex 64)
ADGUARD_ADMIN_PASSWORD=$(gen_password 16)
VAULTWARDEN_USER_PASSWORD=$(gen_password 16)
MINIFLUX_DB_PASSWORD=$(gen_password 24)
MINIFLUX_ADMIN_PASSWORD=$(gen_password 16)
ACTUALBUDGET_PASSWORD=$(gen_password 16)
REDIS_PASSWORD=$(gen_password 24)

# ── Write .env ──

cat > "$ENV_FILE" <<EOF
# CRYPTEX — Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# DO NOT commit this file

# Installation Profile (personal = all services, custom = DEPLOY_SERVICES list)
DEPLOY_PROFILE="${DEPLOY_PROFILE}"
DEPLOY_SERVICES="${DEPLOY_SERVICES}"

# Domain
DOMAIN="${DOMAIN}"

# Cloudflare
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN}"

# Tailscale
TS_AUTHKEY="${TS_AUTHKEY}"

# Gmail SMTP (used by Vaultwarden, DIUN, Moodle)
SMTP_USER="${SMTP_USER}"
SMTP_PASSWORD="${SMTP_PASSWORD}"

# PostgreSQL
POSTGRES_USER="cryptex_admin"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"

# Moodle
MOODLE_DB_USER="moodle_user"
MOODLE_DB_PASSWORD="${MOODLE_DB_PASSWORD}"
MOODLE_ADMIN_USER="admin"
MOODLE_ADMIN_PASSWORD="${MOODLE_ADMIN_PASSWORD}"
MOODLE_ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL}"
MOODLE_SITE_NAME="${MOODLE_SITE_NAME}"

# TRAX LRS
TRAXLRS_DB_USER="traxlrs_user"
TRAXLRS_DB_PASSWORD="${TRAXLRS_DB_PASSWORD}"
TRAXLRS_APP_KEY="${TRAXLRS_APP_KEY}"
TRAXLRS_ADMIN_EMAIL="${TRAXLRS_ADMIN_EMAIL}"
TRAXLRS_ADMIN_PASSWORD="${TRAXLRS_ADMIN_PASSWORD}"
TRAXLRS_ENDPOINT_USERNAME="${TRAXLRS_ENDPOINT_USERNAME}"
TRAXLRS_ENDPOINT_PASSWORD="${TRAXLRS_ENDPOINT_PASSWORD}"

# n8n
N8N_DB_USER="n8n_user"
N8N_DB_PASSWORD="${N8N_DB_PASSWORD}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}"
N8N_ADMIN_EMAIL="${SMTP_USER:-admin@${DOMAIN}}"
N8N_ADMIN_PASSWORD="${N8N_ADMIN_PASSWORD}"

# Tianji
TIANJI_DB_USER="tianji_user"
TIANJI_DB_PASSWORD="${TIANJI_DB_PASSWORD}"
TIANJI_JWT_SECRET="${TIANJI_JWT_SECRET}"

# Vaultwarden
VAULTWARDEN_ADMIN_TOKEN="${VAULTWARDEN_ADMIN_TOKEN}"

# Gemini API (AI workflows — morning digest, weekly analysis)
GEMINI_API_KEY="${GEMINI_API_KEY}"

# OpenWebUI
OPENWEBUI_ADMIN_PASSWORD="${OPENWEBUI_ADMIN_PASSWORD}"
OPENWEBUI_SIGNUP_ENABLED="false"

# SearXNG
SEARXNG_SECRET_KEY="$(openssl rand -hex 32)"

# AdGuard Home
ADGUARD_ADMIN_USER="${ADGUARD_ADMIN_USER}"
ADGUARD_ADMIN_PASSWORD="${ADGUARD_ADMIN_PASSWORD}"

# Vaultwarden user (reference — register at vault.DOMAIN with these)
VAULTWARDEN_USER_EMAIL="${VAULTWARDEN_USER_EMAIL}"
VAULTWARDEN_USER_PASSWORD="${VAULTWARDEN_USER_PASSWORD}"
VAULTWARDEN_SIGNUPS_ALLOWED="false"

# Kopia
KOPIA_PASSWORD="${KOPIA_PASSWORD}"
KOPIA_SERVER_USER="admin"
KOPIA_SERVER_PASSWORD="${KOPIA_SERVER_PASSWORD}"

# Git Identity (Workstation container)
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL}"

# Forgejo (self-hosted Git)
FORGEJO_DB_USER="forgejo_user"
FORGEJO_DB_PASSWORD="${FORGEJO_DB_PASSWORD}"
FORGEJO_SECRET_KEY="${FORGEJO_SECRET_KEY}"

# Telegram Bot (n8n alerts + container management)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

# PKM Bot (Claude Channels — Obsidian vault via Telegram)
PKM_BOT_TOKEN="${PKM_BOT_TOKEN}"

# Redis password (all consumers: Moodle sessions, n8n)
REDIS_PASSWORD="${REDIS_PASSWORD}"

# Backblaze B2 (offsite backup)
B2_KEY_ID="${B2_KEY_ID}"
B2_APP_KEY="${B2_APP_KEY}"
B2_BUCKET_NAME="${B2_BUCKET_NAME}"

# AquaSoul Studio (optional second site — leave blank to disable CF tunnel route)
AQUASOUL_DOMAIN="${AQUASOUL_DOMAIN}"

# Bank Statement Automation (n8n IMAP trigger)
BANK_EMAIL_DOMAIN="${BANK_EMAIL_DOMAIN}"
BANK_PDF_PASSWORD="${BANK_PDF_PASSWORD}"

# ActualBudget (self-hosted budget tracker)
ACTUALBUDGET_PASSWORD="${ACTUALBUDGET_PASSWORD}"

# Miniflux (RSS reader)
MINIFLUX_DB_USER="miniflux_user"
MINIFLUX_DB_PASSWORD="${MINIFLUX_DB_PASSWORD}"
MINIFLUX_ADMIN_USER="${MINIFLUX_ADMIN_USER}"
MINIFLUX_ADMIN_PASSWORD="${MINIFLUX_ADMIN_PASSWORD}"
EOF

chmod 600 "$ENV_FILE"

# ── Encrypted backup ──

echo ""
read -rp "Create encrypted .env backup? (Y/n): " do_encrypt
if [[ "${do_encrypt,,}" != "n" ]]; then
    openssl aes-256-cbc -pbkdf2 -salt -in "$ENV_FILE" -out "${ENV_FILE}.encrypted"
    echo "Encrypted backup: ${ENV_FILE}.encrypted"
    echo "Restore with: ./scripts/restore-env.sh"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo "SAVE THESE CREDENTIALS"
echo "════════════════════════════════════════════════════"
echo ""
echo "Moodle:        admin / ${MOODLE_ADMIN_PASSWORD}"
echo "               URL: https://learn.${DOMAIN}"
echo ""
echo "TRAX LRS:      ${TRAXLRS_ADMIN_EMAIL} / ${TRAXLRS_ADMIN_PASSWORD}"
echo "               URL: https://lrs.${DOMAIN}"
echo "  xAPI endpoint: ${TRAXLRS_ENDPOINT_USERNAME} / ${TRAXLRS_ENDPOINT_PASSWORD}"
echo "               (use these in Moodle → TRAX LRS plugin settings)"
echo ""
echo "AdGuard:       ${ADGUARD_ADMIN_USER} / ${ADGUARD_ADMIN_PASSWORD}"
echo "               URL: https://dns.${DOMAIN}  (auto-configured — no setup wizard)"
echo ""
echo "Vaultwarden:   ${VAULTWARDEN_USER_EMAIL} / ${VAULTWARDEN_USER_PASSWORD}"
echo "               URL: https://vault.${DOMAIN}/register  (register, then disable signups)"
echo "               Admin token: ${VAULTWARDEN_ADMIN_TOKEN}"
echo "               Admin panel: https://vault.${DOMAIN}/admin"
echo ""
echo "Kopia:         admin / ${KOPIA_SERVER_PASSWORD}"
echo "               URL: https://backup.${DOMAIN}"
echo ""
echo "Workstation:   https://code.${DOMAIN}  (protected by Cloudflare Zero Trust)"
echo ""
echo "Miniflux:      ${MINIFLUX_ADMIN_USER} / ${MINIFLUX_ADMIN_PASSWORD}"
echo "               URL: https://news.${DOMAIN}"
echo "               Add feeds via UI — n8n digest runs automatically at 12pm IST"
echo ""
echo "Forgejo:       (create admin via web UI on first visit)"
echo "               URL: https://git.${DOMAIN}"
echo ""
echo "n8n Admin:     ${SMTP_USER:-admin@${DOMAIN}} / ${N8N_ADMIN_PASSWORD}"
echo "               URL: https://n8n.${DOMAIN}"
echo ""
echo "Telegram Bot:  $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo "configured — workflows auto-imported and activated by deploy.sh" || echo "not set — run setup-env.sh again or add manually to .env")"
echo "Git:           ${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>"
echo ""
echo "════════════════════════════════════════════════════"
echo ""
echo "Next: ./scripts/deploy.sh"
