#!/bin/bash
# CRYPTEX — Deploy all containers
# Run on VPS: cd /opt/cryptex && ./scripts/deploy.sh
# Idempotent: safe to re-run (rebuilds/recreates as needed)

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
ENV_FILE="${COMPOSE_DIR}/.env"

echo ""
echo "CRYPTEX Deploy"
echo "────────────────────────────"

# ── Pre-flight checks ──

if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then
    echo "ERROR: Run as root or user with docker access"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker not installed"
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose not installed"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found. Run ./scripts/setup-env.sh first"
    exit 1
fi

if [ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
    echo "ERROR: docker-compose.yml not found in ${COMPOSE_DIR}"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Resolve deployment profile ──

DEPLOY_PROFILE="${DEPLOY_PROFILE:-personal}"
DEPLOY_SERVICES="${DEPLOY_SERVICES:-all}"

# Helper: check if a service is included in this deployment
svc_enabled() {
    local svc="$1"
    [ "$DEPLOY_PROFILE" = "personal" ] && return 0
    [[ " $DEPLOY_SERVICES " == *" $svc "* ]] && return 0
    return 1
}

if [ "$DEPLOY_PROFILE" = "custom" ]; then
    echo "Profile: CUSTOM (services: ${DEPLOY_SERVICES})"
else
    echo "Profile: PERSONAL (all services)"
fi

# ── Pre-flight: validate required env vars ──
echo "Validating environment..."
REQUIRED_VARS=(
    DOMAIN CF_TUNNEL_TOKEN
    POSTGRES_PASSWORD POSTGRES_USER
    MOODLE_DB_PASSWORD MOODLE_ADMIN_PASSWORD
    N8N_ADMIN_PASSWORD
    VAULTWARDEN_ADMIN_TOKEN
    REDIS_PASSWORD
    FORGEJO_SECRET_KEY
    KOPIA_SERVER_USER KOPIA_SERVER_PASSWORD
)
# TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID are optional — alerts disabled if absent
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "  NOTE: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — health alerts disabled"
fi
_MISSING=()
for _var in "${REQUIRED_VARS[@]}"; do
    [ -z "${!_var:-}" ] && _MISSING+=("$_var")
done
if [ ${#_MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing required env vars:"
    printf "  - %s\n" "${_MISSING[@]}"
    echo "Run ./scripts/setup-env.sh to regenerate .env"
    exit 1
fi
# Validate N8N_ENCRYPTION_KEY is exactly 64 hex chars (32 bytes)
if [ -n "${N8N_ENCRYPTION_KEY:-}" ] && [ ${#N8N_ENCRYPTION_KEY} -ne 64 ]; then
    echo "ERROR: N8N_ENCRYPTION_KEY must be exactly 64 hex chars (32 bytes), got ${#N8N_ENCRYPTION_KEY}"
    echo "  Fix: N8N_ENCRYPTION_KEY=\"\$(openssl rand -hex 32)\""
    exit 1
fi
echo "  All required vars present."

# ── Create data directories ──

echo "Ensuring data directories..."
# Fix ownership — cloud-init creates /opt/cryptex as root, ubuntu can't mkdir inside it
# Exclude postgres data dir: postgres manages its own ownership (uid 999).
# Rechowning it on re-deploy corrupts file access and breaks queries.
sudo chown -R "$(whoami):$(whoami)" "${COMPOSE_DIR}/data" 2>/dev/null || true
# Restore service-specific ownership after the blanket chown
sudo chown -R 999:999 "${COMPOSE_DIR}/data/postgres"    2>/dev/null || true  # postgres
sudo chown -R 33:33   "${COMPOSE_DIR}/data/moodledata"  2>/dev/null || true  # www-data (Moodle)
mkdir -p "${COMPOSE_DIR}/data"/{postgres,moodle,moodledata,vaultwarden,n8n,adguard/work,adguard/conf,tianji,kopia/repository,kopia/config,kopia/cache,kopia/logs,traxlrs,tailscale,portfolio,forgejo,aquasoul,actualbudget,moodle-uploads,moodle-plugins/{theme,format},openwebui,searxng,stirling-pdf/{trainingData,configs},rclone/config,pkm,quartz-output,quartz-app}
# ActualBudget: pre-create subdirs, owned by 'actual' user (uid 1001, gid 1001)
# actual-server image defines: useradd --uid 1001 actual; cap_drop:ALL removes CAP_DAC_OVERRIDE
# so even root can't write without correct ownership — must match uid 1001 exactly
mkdir -p "${COMPOSE_DIR}/data/actualbudget/server-files"
mkdir -p "${COMPOSE_DIR}/data/actualbudget/user-files"
sudo chown -R 1001:1001 "${COMPOSE_DIR}/data/actualbudget" 2>/dev/null || true
mkdir -p "${COMPOSE_DIR}/configs/n8n-workflows"

# ── Deploy initial configs (first run only) ──

# AdGuard Home: deploy initial config with unencrypted DoH enabled
if [ ! -f "${COMPOSE_DIR}/data/adguard/conf/AdGuardHome.yaml" ]; then
    echo "Deploying initial AdGuard Home config (DoH enabled)..."
    cp "${COMPOSE_DIR}/configs/adguard/AdGuardHome.yaml" "${COMPOSE_DIR}/data/adguard/conf/AdGuardHome.yaml"

    # Inject admin credentials via bcrypt (avoids setup wizard on first open)
    if command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" 2>/dev/null; then
        ADGUARD_HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode())
" "${ADGUARD_ADMIN_PASSWORD}")
        python3 -c "
import sys, re
config, name, hsh = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config) as f:
    content = f.read()
users_entry = 'users:\n  - name: {}\n    password: {}'.format(name, hsh)
content = re.sub(r'^# Empty.*\nusers: \[\]', users_entry, content, flags=re.MULTILINE)
with open(config, 'w') as f:
    f.write(content)
" "${COMPOSE_DIR}/data/adguard/conf/AdGuardHome.yaml" "${ADGUARD_ADMIN_USER}" "${ADGUARD_HASH}" \
        && echo "  AdGuard credentials injected (user: ${ADGUARD_ADMIN_USER})" \
        || echo "  WARNING: AdGuard credential injection failed — set password in AdGuard UI"
    else
        echo "  WARNING: python3-bcrypt not found. Run: pip3 install bcrypt"
        echo "  AdGuard admin credentials NOT pre-set — complete setup wizard on first open"
    fi
fi

# Portfolio: deploy placeholder if no index.html exists
if [ ! -f "${COMPOSE_DIR}/data/portfolio/index.html" ]; then
    echo "Deploying portfolio placeholder..."
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Portfolio</title></head><body><h1>Coming Soon</h1></body></html>' > "${COMPOSE_DIR}/data/portfolio/index.html"
fi

# AquaSoul: deploy placeholder if no index.html exists
if [ ! -f "${COMPOSE_DIR}/data/aquasoul/index.html" ]; then
    echo "Deploying AquaSoul placeholder..."
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>AquaSoul Studio</title></head><body><h1>Coming Soon</h1></body></html>' > "${COMPOSE_DIR}/data/aquasoul/index.html"
fi

# ── Generate nginx configs from templates (inject actual domain names) ──

echo "Generating nginx configs from templates..."
DOMAIN="${DOMAIN}" envsubst '${DOMAIN}' \
    < "${COMPOSE_DIR}/configs/nginx/portfolio.conf.template" \
    > "${COMPOSE_DIR}/configs/nginx/portfolio.conf"
echo "  portfolio.conf → ${DOMAIN}"

if [ -n "${AQUASOUL_DOMAIN:-}" ]; then
    # Build server_name: primary domain + www + optional test subdomain
    AQUASOUL_SERVER_NAMES="${AQUASOUL_DOMAIN} www.${AQUASOUL_DOMAIN}"
    [ -n "${AQUASOUL_TEST_DOMAIN:-}" ] && AQUASOUL_SERVER_NAMES="${AQUASOUL_SERVER_NAMES} ${AQUASOUL_TEST_DOMAIN}"
    AQUASOUL_SERVER_NAMES="${AQUASOUL_SERVER_NAMES}" envsubst '${AQUASOUL_SERVER_NAMES}' \
        < "${COMPOSE_DIR}/configs/nginx/aquasoul.conf.template" \
        > "${COMPOSE_DIR}/configs/nginx/aquasoul.conf"
    echo "  aquasoul.conf → ${AQUASOUL_SERVER_NAMES}"
else
    # Disable AquaSoul vhost if domain not configured
    echo "# AquaSoul domain not configured — vhost disabled" > "${COMPOSE_DIR}/configs/nginx/aquasoul.conf"
    echo "  aquasoul.conf → disabled (AQUASOUL_DOMAIN not set)"
fi

# ── Fix ownership ──

# n8n runs as uid 1000 (node user) — ensure data dir is writable
sudo chown -R 1000:1000 "${COMPOSE_DIR}/data/n8n"

# moodle-uploads: writable by n8n (uid 1000), readable by moodle (uid 33)
sudo chown -R 1000:33 "${COMPOSE_DIR}/data/moodle-uploads" 2>/dev/null || true
sudo chmod -R 750 "${COMPOSE_DIR}/data/moodle-uploads" 2>/dev/null || true

# Deploy SCORM import script (optional — only if present in configs)
if [ -f "${COMPOSE_DIR}/configs/moodle-scripts/scorm-import.php" ]; then
    cp "${COMPOSE_DIR}/configs/moodle-scripts/scorm-import.php" \
       "${COMPOSE_DIR}/data/moodle-uploads/scorm-import.php"
    echo "  scorm-import.php deployed to moodle-uploads"
fi

# ActualBudget: already handled above via mkdir + chown 1001

# Redis: remove stale appendonlydir (appendonly is disabled; dir causes permission crash loops)
# Also fix /data ownership to redis user (uid 999) in case of prior root writes
if docker volume inspect cryptex_redis_data >/dev/null 2>&1; then
    docker run --rm -v cryptex_redis_data:/data alpine \
        sh -c "rm -rf /data/appendonlydir; chown -R 999:999 /data 2>/dev/null || true"
fi

# ── Generate PgBouncer userlist.txt ──
# auth_type = scram-sha-256 (matching postgres 16 default password_encryption)
# Plaintext passwords here — PgBouncer performs SCRAM exchange with postgres on behalf of clients
# File is 644 (edoburu image runs as postgres user, not root — needs world-readable)
echo "Generating PgBouncer userlist.txt..."
PGBOUNCER_CONF_DIR="${COMPOSE_DIR}/configs/pgbouncer"
mkdir -p "$PGBOUNCER_CONF_DIR"

cat > "${PGBOUNCER_CONF_DIR}/userlist.txt" <<USERLIST
"${MOODLE_DB_USER}" "${MOODLE_DB_PASSWORD}"
"${N8N_DB_USER}" "${N8N_DB_PASSWORD}"
"${TIANJI_DB_USER}" "${TIANJI_DB_PASSWORD}"
"${TRAXLRS_DB_USER}" "${TRAXLRS_DB_PASSWORD}"
"${FORGEJO_DB_USER}" "${FORGEJO_DB_PASSWORD}"
"${MINIFLUX_DB_USER:-miniflux_user}" "${MINIFLUX_DB_PASSWORD}"
"pgbouncer_admin" "${POSTGRES_PASSWORD}"
USERLIST
chmod 644 "${PGBOUNCER_CONF_DIR}/userlist.txt"
echo "  userlist.txt generated (7 users, scram-sha-256)"

# Install shell tools (idempotent via apt)
echo "  Installing shell tools..."
sudo apt-get install -y -q fzf ripgrep bat fd-find jq socat unzip 2>/dev/null | tail -1
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

# zoxide
if ! command -v zoxide >/dev/null 2>&1; then
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sudo bash 2>/dev/null | tail -1
fi

# starship
if ! command -v starship >/dev/null 2>&1; then
    curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes 2>/dev/null | tail -1
fi

# yazi
YAZI_BIN="/usr/local/bin/yazi"
if [ ! -f "$YAZI_BIN" ]; then
    YAZI_VER=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || echo "v26.1.22")
    cd /tmp
    wget -q "https://github.com/sxyazi/yazi/releases/download/${YAZI_VER}/yazi-aarch64-unknown-linux-musl.zip" -O yazi.zip
    unzip -q yazi.zip
    sudo mv yazi-aarch64-unknown-linux-musl/yazi "$YAZI_BIN"
    sudo mv yazi-aarch64-unknown-linux-musl/ya /usr/local/bin/ya
    rm -rf yazi.zip yazi-aarch64-unknown-linux-musl
    cd "$COMPOSE_DIR"
fi

# Claude Code + Gemini CLI (global npm)
if ! command -v claude >/dev/null 2>&1 || ! command -v gemini >/dev/null 2>&1; then
    echo "  Installing Claude Code + Gemini CLI..."
    sudo npm install -g @anthropic-ai/claude-code @google/gemini-cli 2>/dev/null | tail -3
fi

# Shell env for ubuntu user
if ! grep -q 'bashrc_cryptex' /home/ubuntu/.bashrc 2>/dev/null; then
    cat >> /home/ubuntu/.bashrc << 'SHELLENV'

# Cryptex terminal tools
source ~/.bashrc_cryptex
SHELLENV
fi
cat > /home/ubuntu/.bashrc_cryptex << 'SHELLENV'
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
export TERM=xterm-256color
export COLORTERM=truecolor

# PKM vault — accessible directly by Claude Code and shell
export PKM="/opt/cryptex/data/pkm"

eval "$(zoxide init bash)"
eval "$(starship init bash)"
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
alias ll='ls -lahF'
alias cat='batcat --paging=never'
alias cd='z'
alias f='yazi'
alias cryptex='cd /opt/cryptex'
alias pkm='cd /opt/cryptex/data/pkm'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
alias health='/opt/cryptex/scripts/health-check.sh'
alias notes-build='docker run --rm -v /opt/cryptex/data/pkm:/vault:ro -v /opt/cryptex/data/quartz-output:/output -v /opt/cryptex/data/quartz-app:/app -w /app node:22-alpine sh -c "npx quartz build --directory /vault --output /output"'
SHELLENV

# ── Build custom images ──

echo "Building custom images..."
cd "$COMPOSE_DIR"
docker compose build moodle traxlrs
# n8n uses official image — tools (qpdf/pdftotext) installed via n8n-tools init container

# ── Pull images ──

echo "Pulling images..."
docker compose pull --ignore-buildable

# ── Deploy ──

echo "Starting containers..."
if [ "$DEPLOY_PROFILE" = "custom" ]; then
    # Start only selected services (docker compose resolves depends_on automatically)
    # shellcheck disable=SC2086
    docker compose up -d --remove-orphans $DEPLOY_SERVICES
else
    docker compose up -d --remove-orphans
fi

# ── Wait for PostgreSQL ──

echo "Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if docker exec cryptex-postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
        echo "PostgreSQL ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: PostgreSQL not ready after 30s"
        docker logs cryptex-postgres --tail 20
        exit 1
    fi
    sleep 1
done

# ── Initialize Kopia repository (first run only) ──

if svc_enabled "kopia" && ! docker exec cryptex-kopia kopia repository status >/dev/null 2>&1; then
    # Wait for Kopia HTTP server — wget returns 401 (auth required) which looks like failure.
    # Use container health status instead.
    echo "Waiting for Kopia..."
    for _ki in $(seq 1 30); do
        _ks=$(docker inspect --format='{{.State.Health.Status}}' cryptex-kopia 2>/dev/null || echo "none")
        [ "$_ks" = "healthy" ] && break
        [ "$_ki" -eq 30 ] && echo "  WARNING: Kopia not healthy after 90s — attempting init anyway" && break
        sleep 3
    done
    if [ -n "${B2_KEY_ID:-}" ] && [ -n "${B2_APP_KEY:-}" ]; then
        echo "Initializing Kopia repository on Backblaze B2..."
        if docker exec cryptex-kopia kopia repository create b2 \
            --bucket="${B2_BUCKET_NAME:-cryptex-backups}" \
            --key-id="${B2_KEY_ID}" \
            --key="${B2_APP_KEY}" \
            --password="${KOPIA_PASSWORD}"; then
            echo "  Kopia B2 repository created"
        elif docker exec cryptex-kopia kopia repository connect b2 \
            --bucket="${B2_BUCKET_NAME:-cryptex-backups}" \
            --key-id="${B2_KEY_ID}" \
            --key="${B2_APP_KEY}" \
            --password="${KOPIA_PASSWORD}"; then
            echo "  Kopia B2 repository connected (already existed)"
        else
            echo "  WARNING: Kopia B2 init failed — see error above for details"
        fi
    else
        echo "Initializing Kopia repository (local filesystem — B2 not configured)..."
        docker exec cryptex-kopia kopia repository create filesystem \
            --path=/app/repository \
            --password="${KOPIA_PASSWORD}" \
        || echo "  Kopia local repository already exists"
    fi
fi

if svc_enabled "kopia"; then
    # Set snapshot policies (idempotent — safe to re-run)
    echo "Setting Kopia snapshot policies..."
    docker exec cryptex-kopia kopia policy set /data \
        --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        --compression=zstd-fastest 2>/dev/null || true
    docker exec cryptex-kopia kopia policy set /backups \
        --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        --compression=zstd-fastest 2>/dev/null || true
    echo "  Policies set: /data and /backups (7d / 4w / 6m retention, zstd compression)"
fi

# ── Auto-import n8n workflows ──

if svc_enabled "n8n"; then
echo "Importing n8n workflows..."
# Wait for n8n to be ready (it starts after postgres+redis)
N8N_READY=0
for i in $(seq 1 60); do
    if docker exec cryptex-n8n wget -qO /dev/null http://localhost:5678/healthz 2>/dev/null; then
        N8N_READY=1
        break
    fi
    [ "$i" -eq 60 ] && echo "  WARNING: n8n not ready after 180s, skipping workflow import" && break
    sleep 3
done

if [ "$N8N_READY" -eq 1 ]; then
    if [ -n "${N8N_ADMIN_PASSWORD:-}" ]; then
        echo "Configuring n8n: credentials, workflows, and activation..."
        N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:-${SMTP_USER:-admin@${DOMAIN}}}"

        docker exec \
            -e N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL}" \
            -e N8N_ADMIN_PASS="${N8N_ADMIN_PASSWORD}" \
            -e BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
            -e SMTP_USER="${SMTP_USER:-}" \
            -e SMTP_PASS="${SMTP_PASSWORD:-}" \
            cryptex-n8n node -e '
const http = require("http");
const fs = require("fs");

function req(method, path, body, headers) {
  return new Promise((resolve) => {
    const opts = {
      hostname: "localhost", port: 5678, path, method,
      headers: { "Content-Type": "application/json", ...(headers || {}) }
    };
    const r = http.request(opts, (res) => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end", () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data), headers: res.headers }); }
        catch(e) { resolve({ status: res.statusCode, body: data, headers: res.headers }); }
      });
    });
    r.on("error", () => resolve({ status: 0, body: null, headers: {} }));
    if (body) r.write(JSON.stringify(body));
    r.end();
  });
}

async function main() {
  const email = process.env.N8N_ADMIN_EMAIL;
  const pass = process.env.N8N_ADMIN_PASS;
  const botToken = process.env.BOT_TOKEN;

  // Setup owner (first run — idempotent, fails silently if already exists)
  await req("POST", "/rest/owner/setup", {
    email, firstName: "Admin", lastName: "Cryptex", password: pass, agree: true
  });

  // Login — n8n v1+ returns JWT in body, not set-cookie
  const loginRes = await req("POST", "/rest/login", { email, password: pass });
  const token = loginRes.body && loginRes.body.data && loginRes.body.data.token;
  if (!token) {
    console.log("WARNING: n8n login failed.");
    console.log("  Check N8N_ADMIN_EMAIL and N8N_ADMIN_PASSWORD in .env match your n8n account.");
    console.log("  If you have not visited n8n UI yet, these credentials will be auto-created on first deploy.");
    console.log("  Manual fallback: n8n UI → Credentials → Add Telegram API → paste bot token");
    console.log("                   n8n UI → each workflow → toggle Active");
    return;
  }
  const authHeader = { "Authorization": "Bearer " + token };
  console.log("  n8n login: OK");

  // Create Telegram credential (skip if exists)
  if (botToken) {
    const credListRes = await req("GET", "/rest/credentials", null, authHeader);
    const creds = (credListRes.body && credListRes.body.data) ? credListRes.body.data : [];
    const telegramCred = creds.find(c => c.type === "telegramApi");
    if (!telegramCred) {
      const createRes = await req("POST", "/rest/credentials", {
        name: "Telegram Bot",
        type: "telegramApi",
        data: { accessToken: botToken }
      }, authHeader);
      if (createRes.status < 300) {
        console.log("  Telegram credential created (ID: " + createRes.body.id + ")");
        // Update workflow files credential ID references to match real ID
        const realId = createRes.body.id;
        const wfDir = "/opt/workflows";
        try {
          const files = fs.readdirSync(wfDir).filter(f => f.endsWith(".json"));
          for (const f of files) {
            const fp = wfDir + "/" + f;
            let content = fs.readFileSync(fp, "utf8");
            if (content.includes("a0000000-0000-0000-0000-000000000001")) {
              // Update in-memory only — do not write back to read-only volume
              // The workflow JSON will use the real ID when POSTed via API below
            }
          }
        } catch(e) {}
        process.env.REAL_CRED_ID = String(realId);
      } else {
        console.log("  Telegram credential: failed to create (" + createRes.status + ")");
      }
    } else {
      console.log("  Telegram credential: already exists (ID: " + telegramCred.id + ")");
      process.env.REAL_CRED_ID = String(telegramCred.id);
    }
  }

  // Create Gmail IMAP credential (skip if exists)
  const smtpUser = process.env.SMTP_USER;
  const smtpPass = process.env.SMTP_PASS;
  if (smtpUser && smtpPass) {
    const credListRes2 = await req("GET", "/rest/credentials", null, authHeader);
    const creds2 = (credListRes2.body && credListRes2.body.data) ? credListRes2.body.data : [];
    const imapCred = creds2.find(c => c.type === "imap");
    if (!imapCred) {
      const createImapRes = await req("POST", "/rest/credentials", {
        name: "Gmail IMAP",
        type: "imap",
        data: {
          host: "imap.gmail.com",
          port: 993,
          secure: true,
          user: smtpUser,
          password: smtpPass
        }
      }, authHeader);
      if (createImapRes.status < 300) {
        console.log("  Gmail IMAP credential created (ID: " + createImapRes.body.id + ")");
        process.env.REAL_IMAP_CRED_ID = String(createImapRes.body.id);
      } else {
        console.log("  Gmail IMAP credential: failed to create (" + createImapRes.status + ")");
      }
    } else {
      console.log("  Gmail IMAP credential: already exists (ID: " + imapCred.id + ")");
      process.env.REAL_IMAP_CRED_ID = String(imapCred.id);
    }
  }

  // Get existing workflows (dedup by ID first, fall back to name)
  const existRes = await req("GET", "/rest/workflows?limit=200", null, authHeader);
  const existing = (existRes.body && existRes.body.data) ? existRes.body.data : [];
  const byId = {};
  const byName = {};
  for (const wf of existing) { byId[wf.id] = wf; byName[wf.name] = wf; }

  // Import each workflow file via REST API
  const wfDir = "/opt/workflows";
  let files;
  try { files = fs.readdirSync(wfDir).filter(f => f.endsWith(".json")).sort(); }
  catch(e) { console.log("  ERROR: cannot read " + wfDir); return; }

  const realCredId = process.env.REAL_CRED_ID;
  let created = 0, updated = 0;

  for (const file of files) {
    let wfData;
    try {
      let raw = fs.readFileSync(wfDir + "/" + file, "utf8");
      // Replace placeholder credential IDs with real ones
      if (realCredId) {
        raw = raw.replace(/a0000000-0000-0000-0000-000000000001/g, realCredId);
      }
      const realImapId = process.env.REAL_IMAP_CRED_ID;
      if (realImapId) {
        raw = raw.replace(/b0000000-0000-0000-0000-000000000002/g, realImapId);
      }
      wfData = JSON.parse(raw);
    } catch(e) { console.log("  Parse error: " + file); continue; }

    // Strip active field — activate separately after import
    const { active, id: fileId, ...wfPayload } = wfData;

    // Prefer ID match (stable across renames); fall back to name match
    const existWf = (fileId && byId[fileId]) || byName[wfData.name];
    let res;
    if (existWf) {
      // Update existing (PUT replaces the workflow)
      const matchType = (fileId && byId[fileId]) ? "id" : "name";
      res = await req("PUT", "/rest/workflows/" + existWf.id,
        { ...wfPayload, id: existWf.id }, authHeader);
      if (res.status < 300) { updated++; console.log("  Updated: " + file + " (" + matchType + " match)"); }
      else { console.log("  Update failed: " + file + " (status " + res.status + ")"); }
    } else {
      // Create new
      res = await req("POST", "/rest/workflows", wfPayload, authHeader);
      if (res.status < 300) { created++; console.log("  Created: " + file); }
      else { console.log("  Create failed: " + file + " (status " + res.status + ")"); }
    }
  }
  console.log("  Workflows: " + created + " created, " + updated + " updated");

  // Activate all workflows
  const allRes = await req("GET", "/rest/workflows?limit=200", null, authHeader);
  const allWfs = (allRes.body && allRes.body.data) ? allRes.body.data : [];
  let activated = 0;
  for (const wf of allWfs) {
    if (!wf.active) {
      const r = await req("PATCH", "/rest/workflows/" + wf.id, { active: true }, authHeader);
      if (r.status < 300) activated++;
    }
  }
  console.log("  Activated " + activated + " workflow(s) — " + allWfs.length + " total");
}

main().catch(e => console.log("n8n setup error:", e.message));
' 2>&1 | sed 's/^/  /'
    else
        echo "  N8N_ADMIN_PASSWORD not set in .env — workflows not auto-configured."
        echo "  Add N8N_ADMIN_EMAIL and N8N_ADMIN_PASSWORD to .env, then re-run deploy.sh"
    fi
fi  # end N8N_READY
fi  # end svc_enabled n8n

if svc_enabled "miniflux"; then
# ── Auto-subscribe Miniflux RSS feeds ──

echo "Configuring Miniflux RSS feeds..."
# Wait for Miniflux to be ready
# Use docker inspect for IP only after container is confirmed healthy (avoids race on startup)
MFLUX_IP=""
MFLUX_READY=0
for i in $(seq 1 30); do
    _ms=$(docker inspect --format='{{.State.Health.Status}}' cryptex-miniflux 2>/dev/null || echo "none")
    if [ "$_ms" = "healthy" ]; then
        _ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "cryptex_net").IPAddress}}' cryptex-miniflux 2>/dev/null || true)
        if [ -n "$_ip" ] && curl -sf -u "${MINIFLUX_ADMIN_USER}:${MINIFLUX_ADMIN_PASSWORD}" \
            "http://${_ip}:8080/v1/feeds" >/dev/null 2>&1; then
            MFLUX_IP="$_ip"
            MFLUX_READY=1
            break
        fi
    fi
    [ "$i" -eq 30 ] && echo "  WARNING: Miniflux not ready after 90s, skipping feed setup" && break
    sleep 3
done

if [ "$MFLUX_READY" -eq 1 ]; then
    MFLUX_BASE="http://${MFLUX_IP}:8080/v1"
    MFLUX_AUTH="${MINIFLUX_ADMIN_USER}:${MINIFLUX_ADMIN_PASSWORD}"

    # Check if feeds already exist (idempotent)
    EXISTING_FEEDS=$(curl -sf -u "$MFLUX_AUTH" "${MFLUX_BASE}/feeds" | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "${EXISTING_FEEDS}" -gt 0 ]; then
        echo "  Feeds already configured (${EXISTING_FEEDS} feeds) — skipping"
    else
        # Create categories
        FOOTBALL_CAT=$(curl -sf -u "$MFLUX_AUTH" -X POST "${MFLUX_BASE}/categories" \
            -H "Content-Type: application/json" -d '{"title":"Football"}' | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")

        NEWS_CAT=$(curl -sf -u "$MFLUX_AUTH" -X POST "${MFLUX_BASE}/categories" \
            -H "Content-Type: application/json" -d '{"title":"News"}' | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")

        TECH_CAT=$(curl -sf -u "$MFLUX_AUTH" -X POST "${MFLUX_BASE}/categories" \
            -H "Content-Type: application/json" -d '{"title":"Tech & AI"}' | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")

        add_feed() {
            local url="$1" cat_id="$2"
            curl -sf -u "$MFLUX_AUTH" -X POST "${MFLUX_BASE}/feeds" \
                -H "Content-Type: application/json" \
                -d "{\"feed_url\":\"${url}\",\"category_id\":${cat_id}}" >/dev/null 2>&1 || true
        }

        # Football feeds
        add_feed "https://feeds.bbci.co.uk/sport/football/teams/manchester-united/rss.xml" "${FOOTBALL_CAT}"
        add_feed "https://www.skysports.com/rss/12040" "${FOOTBALL_CAT}"
        add_feed "https://www.reddit.com/r/reddevils/.rss" "${FOOTBALL_CAT}"
        add_feed "https://www.reddit.com/r/soccer/.rss" "${FOOTBALL_CAT}"
        echo "  Football feeds: 4 added"

        # News feeds
        add_feed "https://feeds.bbci.co.uk/news/rss.xml" "${NEWS_CAT}"
        add_feed "https://feeds.reuters.com/reuters/topNews" "${NEWS_CAT}"
        add_feed "https://www.theguardian.com/world/rss" "${NEWS_CAT}"
        echo "  News feeds: 3 added"

        # Tech & AI feeds
        add_feed "https://www.reddit.com/r/apphookup/.rss" "${TECH_CAT}"
        add_feed "https://www.reddit.com/r/macapps/.rss" "${TECH_CAT}"
        add_feed "https://www.reddit.com/r/ClaudeAI/.rss" "${TECH_CAT}"
        echo "  Tech & AI feeds: 3 added (apphookup, macapps, ClaudeAI)"
    fi
fi  # end Miniflux MFLUX_READY

fi  # end svc_enabled miniflux

# ── Initialise Quartz (PKM vault → static site builder) ──

QUARTZ_APP="${COMPOSE_DIR}/data/quartz-app"
QUARTZ_OUT="${COMPOSE_DIR}/data/quartz-output"

if [ ! -f "${QUARTZ_APP}/package.json" ]; then
    echo "Installing Quartz (first run)..."
    mkdir -p "${QUARTZ_APP}" "${QUARTZ_OUT}"
    # Clone Quartz into app dir and install deps — runs in node container to avoid Node on host
    docker run --rm \
        -v "${QUARTZ_APP}:/app" \
        -w /app \
        node:22-alpine \
        sh -c "
            apk add --no-cache git &&
            git clone --depth 1 https://github.com/jackyzha0/quartz.git . &&
            npm ci
        " && echo "  Quartz installed OK"

    # Initial build
    if [ -d "${COMPOSE_DIR}/data/pkm" ] && [ "$(ls -A "${COMPOSE_DIR}/data/pkm" 2>/dev/null)" ]; then
        echo "Running initial Quartz build..."
        docker run --rm \
            -v "${COMPOSE_DIR}/data/pkm:/vault:ro" \
            -v "${QUARTZ_OUT}:/output" \
            -v "${QUARTZ_APP}:/app" \
            -w /app \
            node:22-alpine \
            sh -c "npx quartz build --directory /vault --output /output" \
            && echo "  Initial build complete"
    else
        echo "  PKM vault empty — Quartz will build once vault is synced"
    fi
else
    echo "  Quartz already installed ($(cat "${QUARTZ_APP}/package.json" | grep '"version"' | head -1 | tr -d ' ,"version:'))"
fi

# ── Install cron jobs (idempotent) ──

echo "Setting up automated maintenance cron jobs..."
CRON_MARKER="# CRYPTEX-MANAGED"

# Build the cron block
CRON_BLOCK="${CRON_MARKER}-START
# Daily backup at 3:00 AM UTC
0 3 * * * /opt/cryptex/scripts/backup.sh >> /var/log/cryptex-backup.log 2>&1
# Weekly Docker cleanup (Sunday 4:00 AM UTC)
# No --volumes: named volumes (redis_data, diun_data, n8n_tools) must not be pruned
0 4 * * 0 docker system prune -af --filter label!=cryptex >> /var/log/cryptex-prune.log 2>&1
# Daily PostgreSQL vacuum (2:30 AM UTC)
30 2 * * * docker exec cryptex-postgres psql -U ${POSTGRES_USER} -d postgres -c 'VACUUM ANALYZE;' >> /var/log/cryptex-vacuum.log 2>&1
# Health check every 5 minutes — full log for audit trail
*/5 * * * * /opt/cryptex/scripts/health-check.sh >> /var/log/cryptex-health.log 2>&1
# Weekly auto-update (Sunday 5:00 AM UTC — after prune, before digest)
0 5 * * 0 /opt/cryptex/scripts/update.sh >> /var/log/cryptex-update.log 2>&1
# Quartz build every 15 minutes — rebuild PKM vault → static HTML for notes.DOMAIN
*/15 * * * * docker run --rm --network cryptex_cryptex_net -v /opt/cryptex/data/pkm:/vault:ro -v /opt/cryptex/data/quartz-output:/output -v /opt/cryptex/data/quartz-app:/app -w /app node:22-alpine sh -c 'npx quartz build --directory /vault --output /output' >> /var/log/cryptex-quartz.log 2>&1
# Daily Stirling PDF temp cleanup (1:00 AM UTC — delete processed files older than 1 hour)
0 1 * * * docker exec cryptex-stirling-pdf find /tmp -name '*.pdf' -mmin +60 -delete 2>/dev/null; true
# Monthly n8n execution log cleanup (1st of month, 1:30 AM)
30 1 1 * * docker exec -e NODE_ENV=production cryptex-n8n sh -c 'cd /home/node/.n8n && node -e "const{Db}=require(\"@n8n/db\");const d=Db.getInstance();d.getRepository(\"execution_entity\").delete({stoppedAt:null})" 2>/dev/null' || true
${CRON_MARKER}-END"

# Moodle cron is only needed when Moodle is part of this deployment
if svc_enabled moodle; then
    CRON_BLOCK="${CRON_BLOCK/${CRON_MARKER}-END/# Moodle cron — required for SCORM completion, grade calc, email notifications
* * * * * docker exec cryptex-moodle php /var/www/html/admin/cli/cron.php >> /var/log/cryptex-moodle-cron.log 2>&1
${CRON_MARKER}-END}"
fi

# Replace or append cron block
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "$CURRENT_CRON" | grep -q "${CRON_MARKER}-START"; then
    # Replace existing block
    NEW_CRON=$(echo "$CURRENT_CRON" | sed "/${CRON_MARKER}-START/,/${CRON_MARKER}-END/d")
    echo "${NEW_CRON}
${CRON_BLOCK}" | crontab -
else
    # Append
    echo "${CURRENT_CRON}
${CRON_BLOCK}" | crontab -
fi
if svc_enabled moodle; then
    echo "  Cron jobs installed (backup 3AM, prune Sun 4AM, vacuum 2:30AM, health */5m, moodle cron */1m, auto-update Sun 5AM)"
else
    echo "  Cron jobs installed (backup 3AM, prune Sun 4AM, vacuum 2:30AM, health */5m, auto-update Sun 5AM) — moodle cron skipped (not in profile)"
fi

# ── Log rotation (prevent unbounded log growth) ──

echo "Configuring log rotation..."
sudo tee /etc/logrotate.d/cryptex >/dev/null <<'LOGROTATE_EOF'
/var/log/cryptex-moodle-cron.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
/var/log/cryptex-health.log
/var/log/cryptex-backup.log
/var/log/cryptex-prune.log
/var/log/cryptex-vacuum.log
/var/log/cryptex-update.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
LOGROTATE_EOF
echo "  /etc/logrotate.d/cryptex installed (moodle daily/7d, others weekly/4w)"

# ── Verify Kopia B2 connectivity ──

if svc_enabled "kopia"; then
    if [ -n "${B2_KEY_ID:-}" ] && [ -n "${B2_APP_KEY:-}" ]; then
        if docker exec cryptex-kopia kopia repository status >/dev/null 2>&1; then
            echo "Kopia B2 repository: connected"
            echo "  Access UI: https://backup.${DOMAIN}"
        else
            echo "WARNING: Kopia repository not connected — check B2 credentials or run:"
            echo "  docker exec cryptex-kopia kopia repository connect b2 --bucket=${B2_BUCKET_NAME:-cryptex-backups} --key-id=... --key=..."
        fi
    else
        echo "Kopia B2 not configured. To enable offsite backup:"
        echo "  Add B2_KEY_ID, B2_APP_KEY, B2_BUCKET_NAME to .env then re-run deploy.sh"
        echo "  Without B2: Kopia uses local filesystem at /app/repository"
    fi
fi

# ── Verify rclone WebDAV ──

if svc_enabled "rclone"; then
    if docker exec cryptex-rclone rclone version >/dev/null 2>&1; then
        echo "rclone WebDAV: running"
        echo "  Mount URL: https://files.${DOMAIN}"
        echo ""
        echo "  macOS Finder: ⌘K → https://files.${DOMAIN}"
        echo "    User: ${RCLONE_WEBDAV_USER:-cryptex}"
        echo "    Password: (from RCLONE_WEBDAV_PASS in .env)"
        echo ""
        echo "  iOS Files app: ... → Connect to Server → https://files.${DOMAIN}"
        echo "    Registered user: ${RCLONE_WEBDAV_USER:-cryptex} + password"
        echo ""
        echo "  Folders exposed:"
        echo "    /portfolio       — static site files"
        echo "    /aquasoul        — AquaSoul Studio files"
        echo "    /moodle-uploads  — SCORM zips + course content"
        echo "    /pkm             — Personal Knowledge Base (editable from iOS Obsidian via WebDAV)"
        echo ""
        echo "  NOTE: For large files (SCORM >500MB) use SCP instead:"
        echo "    scp -i ~/.ssh/cryptex_vps localfile.zip ubuntu@VPS_IP:/opt/cryptex/data/moodle-uploads/"
    else
        echo "WARNING: rclone container not responding — check logs: docker logs cryptex-rclone"
    fi
fi

# ── Create rollback directory ──

mkdir -p "${COMPOSE_DIR}/.rollback"

# ── Validate containers ──

echo ""
echo "Container Status:"
echo "────────────────────────────"

if [ "$DEPLOY_PROFILE" = "custom" ]; then
    EXPECTED=$(echo "${DEPLOY_SERVICES}" | wc -w | tr -d ' ')
else
    EXPECTED=$(docker compose config --services 2>/dev/null | wc -l | tr -d ' ')
fi
RUNNING=$(docker compose ps --format '{{.State}}' | grep -c "running" || true)

docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "Running: ${RUNNING}/${EXPECTED}"

if [ "$RUNNING" -lt "$EXPECTED" ]; then
    echo ""
    echo "WARNING: Not all containers running. Check logs:"
    docker compose ps --format '{{.Name}} {{.State}}' | grep -v running || true
fi

echo ""
echo "⚠  SECURITY: Vaultwarden signups are OPEN (required for first account setup)."
echo "   Forgejo registration is already disabled by default."
echo ""
echo "   ACTION REQUIRED after registering your Vaultwarden account:"
echo "   ./scripts/disable-signups.sh"
echo "   (closes public registration — vault.${DOMAIN}/register will no longer work)"

# ── Generate AdGuard DNS profiles ──

if svc_enabled "adguard"; then
echo ""
echo "Generating AdGuard DNS profiles..."
if bash "${COMPOSE_DIR}/scripts/generate-profiles.sh" > /dev/null 2>&1; then
    echo "  Generated: ${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig"
    VPS_IP=$(curl -sf https://ipv4.icanhazip.com || hostname -I | awk '{print $1}')
    echo "  Download to Mac:"
    echo "  scp -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP}:${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/"
    echo "  Then: double-click the file → System Settings → Privacy & Security → Profiles → Install"
    echo "  iOS: AirDrop the file → Settings → General → VPN & Device Management → Install"
else
    echo "  WARNING: Profile generation failed — run manually: ./scripts/generate-profiles.sh ${DOMAIN}"
fi
fi  # end svc_enabled adguard

# ── Print Cloudflare Tunnel routes ──

echo ""
echo "════════════════════════════════════════════════════"
echo "CLOUDFLARE TUNNEL ROUTES"
echo "Configure these in Cloudflare Zero Trust dashboard:"
echo "════════════════════════════════════════════════════"
echo ""
echo "${DOMAIN}                → http://cryptex-portfolio:80"
[ -n "${AQUASOUL_DOMAIN:-}" ] && echo "${AQUASOUL_DOMAIN}       → http://cryptex-portfolio:80"
echo "learn.${DOMAIN}         → http://cryptex-moodle:80"
echo "lrs.${DOMAIN}           → http://cryptex-traxlrs:80"
echo "vault.${DOMAIN}         → http://cryptex-vaultwarden:80"
echo "n8n.${DOMAIN}           → http://cryptex-n8n:5678"
echo "dns.${DOMAIN}           → http://cryptex-adguard:80"
echo "monitor.${DOMAIN}       → http://cryptex-tianji:12345"
echo "status.${DOMAIN}        → http://cryptex-tianji:12345"
echo "backup.${DOMAIN}        → http://cryptex-kopia:51515"
echo "logs.${DOMAIN}          → http://cryptex-dozzle:8080"
echo "git.${DOMAIN}           → http://cryptex-forgejo:3000"
echo "news.${DOMAIN}          → http://cryptex-miniflux:8080"
echo "budget.${DOMAIN}        → http://cryptex-actualbudget:5006"
echo "chat.${DOMAIN}          → http://cryptex-openwebui:8080"
echo "search.${DOMAIN}        → http://cryptex-searxng:8080"
echo "pdf.${DOMAIN}           → http://cryptex-stirling-pdf:8080"
echo "files.${DOMAIN}         → http://cryptex-rclone:8080"
echo "tools.${DOMAIN}         → http://cryptex-it-tools:80"
echo "notes.${DOMAIN}         → http://cryptex-notes:80  (Quartz static site)"
echo ""
echo "ZERO TRUST POLICIES:"
echo "  Public:    ${DOMAIN} (portfolio)"
[ -n "${AQUASOUL_DOMAIN:-}" ] && echo "  Public:    ${AQUASOUL_DOMAIN} (AquaSoul Studio)"
echo "  Public:    status.${DOMAIN} (Tianji public status page)"
echo "  Bypass:    dns.${DOMAIN}/dns-query* (DoH for Apple devices)"
echo "  Protected: All other subdomains (email/SSO auth)"
echo "  Protected: notes.${DOMAIN} (Quartz PKM — personal notes)"
echo ""

echo "════════════════════════════════════════════════════"
echo "TAILSCALE VPN SETUP"
echo "════════════════════════════════════════════════════"
echo ""

# Auto-connect Tailscale if authkey provided
if [ -n "${TS_AUTHKEY:-}" ]; then
    if command -v tailscale >/dev/null 2>&1; then
        if tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
            echo "Tailscale already running — re-authenticating..."
        fi
        if sudo tailscale up \
            --authkey="${TS_AUTHKEY}" \
            --hostname=cryptex-vps \
            --advertise-routes=172.18.0.0/16 \
            --accept-dns=false \
            --timeout=30s 2>&1; then
            echo "  Tailscale: connected (hostname=cryptex-vps)"
        else
            echo "  WARNING: tailscale up failed — connect manually (see instructions below)"
        fi
    else
        echo "  WARNING: tailscale not installed — run bootstrap.sh first"
    fi
else
    echo "  TS_AUTHKEY not set — connect Tailscale manually:"
fi
echo ""
echo "You need to approve subnet routing in the Tailscale admin:"
echo ""
echo "Step 1 — Open Tailscale admin console:"
echo "  https://login.tailscale.com/admin/machines"
echo "  Find 'cryptex' (or your VPS hostname) in the list"
echo ""
echo "Step 2 — Enable subnet routing (exposes Docker network to your devices):"
echo "  Click the machine → Edit route settings"
echo "  Enable: 172.18.0.0/16"
echo "  Click 'Save'"
echo ""
echo "Step 3 — Add AdGuard as Tailscale DNS (optional but recommended):"
echo "  https://login.tailscale.com/admin/dns"
echo "  Nameservers → Add nameserver → Custom → 172.18.0.12"
echo "  Enable 'Override local DNS'"
echo "  All Tailscale devices now use your AdGuard for DNS"
echo ""

echo "════════════════════════════════════════════════════"
echo "CLAUDE CODE + GEMINI — ONE-TIME AUTHENTICATION"
echo "════════════════════════════════════════════════════"
echo ""
echo "Claude Code + Gemini CLI are installed on the host (not in a container)."
echo "Authenticate once — credentials persist in ~/.claude and ~/.config/gemini."
echo ""
echo "1. Open terminal:"
echo "   https://code.${DOMAIN}"
echo "   (or SSH in directly)"
echo ""
echo "2. Authenticate Claude Code:"
echo "   claude"
echo "   (follow the OAuth flow in your browser)"
echo ""
echo "3. Authenticate Gemini CLI:"
echo "   gemini"
echo "   (follow the Google auth flow)"
echo ""

echo "════════════════════════════════════════════════════"
echo "ALL CREDENTIALS"
echo "════════════════════════════════════════════════════"
echo ""
svc_enabled "n8n" && cat <<CREDS
n8n Workflow Automation
  URL:      https://n8n.${DOMAIN}
  Email:    ${N8N_ADMIN_EMAIL:-${SMTP_USER:-check .env}}
  Password: ${N8N_ADMIN_PASSWORD:-check .env}
  Status:   Workflows auto-imported and activated

CREDS
svc_enabled "moodle" && cat <<CREDS
Moodle LMS
  URL:      https://learn.${DOMAIN}
  User:     admin
  Password: ${MOODLE_ADMIN_PASSWORD}

CREDS
svc_enabled "traxlrs" && cat <<CREDS
TRAX LRS
  URL:      https://lrs.${DOMAIN}
  Email:    ${TRAXLRS_ADMIN_EMAIL}
  Password: ${TRAXLRS_ADMIN_PASSWORD}
  xAPI:     ${TRAXLRS_ENDPOINT_USERNAME} / ${TRAXLRS_ENDPOINT_PASSWORD}

CREDS
svc_enabled "vaultwarden" && cat <<CREDS
Vaultwarden (Password Manager)
  URL:      https://vault.${DOMAIN}/register  ← register here first
  Email:    ${VAULTWARDEN_USER_EMAIL}
  Password: ${VAULTWARDEN_USER_PASSWORD}
  Admin:    https://vault.${DOMAIN}/admin  (token: ${VAULTWARDEN_ADMIN_TOKEN})

CREDS
svc_enabled "kopia" && cat <<CREDS
Kopia Backup
  URL:      https://backup.${DOMAIN}
  User:     admin
  Password: ${KOPIA_SERVER_PASSWORD}

CREDS
svc_enabled "adguard" && cat <<CREDS
AdGuard Home (DNS)
  URL:      https://dns.${DOMAIN}
  User:     ${ADGUARD_ADMIN_USER}
  Password: ${ADGUARD_ADMIN_PASSWORD}

CREDS
svc_enabled "miniflux" && cat <<CREDS
Miniflux (RSS Reader)
  URL:      https://news.${DOMAIN}
  User:     ${MINIFLUX_ADMIN_USER}
  Password: ${MINIFLUX_ADMIN_PASSWORD}
  Feeds:    Auto-subscribed (Football, News, Tech & AI)

CREDS
svc_enabled "forgejo" && cat <<CREDS
Forgejo (Git)
  URL:      https://git.${DOMAIN}
  Note:     First visitor to URL becomes admin — go there now

CREDS
svc_enabled "actualbudget" && cat <<CREDS
ActualBudget (Finance Tracker)
  URL:      https://budget.${DOMAIN}
  Password: ${ACTUALBUDGET_PASSWORD}
  Note:     Set password on first visit; import bank CSVs from n8n bank-statements folder

CREDS
svc_enabled "tianji" && cat <<CREDS
Tianji (Monitoring)
  URL:      https://monitor.${DOMAIN}
  Note:     First visitor to URL becomes admin — go there now

CREDS

echo "════════════════════════════════════════════════════"
echo "FIRST-RUN CHECKLIST"
echo "════════════════════════════════════════════════════"
echo ""
echo "  [ ] Cloudflare Zero Trust — add tunnel routes + policies (see above)"
svc_enabled "tailscale" && echo "  [ ] Tailscale — approve subnet 172.18.0.0/16 at:"
svc_enabled "tailscale" && echo "      https://login.tailscale.com/admin/machines"
echo "  [ ] Claude Code — open https://code.${DOMAIN}, run 'claude' to auth"
echo "  [ ] Gemini CLI  — run 'gemini' to auth at same terminal"
svc_enabled "vaultwarden" && echo "  [ ] Vaultwarden — register at https://vault.${DOMAIN}/register"
svc_enabled "vaultwarden" && echo "      then run: ./scripts/disable-signups.sh"
svc_enabled "actualbudget" && echo "  [ ] ActualBudget — visit https://budget.${DOMAIN}, set password: ${ACTUALBUDGET_PASSWORD}"
svc_enabled "forgejo" && echo "  [ ] Forgejo — visit https://git.${DOMAIN} (first visit = admin account)"
svc_enabled "tianji" && echo "  [ ] Tianji — visit https://monitor.${DOMAIN} (first visit = admin)"
svc_enabled "tianji" && echo "  [ ] Tianji SMTP — Settings → Notification → Email → enter Gmail SMTP"
if svc_enabled "adguard"; then
    echo "  [ ] AdGuard DNS profile — install on Mac:"
    if [ -f "${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig" ]; then
        echo "      VPS_IP set above — copy SCP command and run on your Mac"
    else
        echo "      ./scripts/generate-profiles.sh then SCP the .mobileconfig to your Mac"
    fi
fi
echo ""
svc_enabled "vaultwarden" && echo "  Store all credentials in Vaultwarden after registering."
echo ""
echo "Deploy complete."

# ── Generate README.md with all credentials and post-deploy instructions ──

VPS_IP_FOR_README=$(curl -sf https://ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
README_PATH="${COMPOSE_DIR}/README.md"

cat > "$README_PATH" <<CRYPTEX_README
# CRYPTEX — Deployed $(date '+%Y-%m-%d %H:%M UTC')

**Server:** ${VPS_IP_FOR_README}
**Domain:** ${DOMAIN}
$([ -n "${AQUASOUL_DOMAIN:-}" ] && echo "**AquaSoul:** ${AQUASOUL_DOMAIN}")

---

## Service URLs

| Service | URL |
|---------|-----|
| Portfolio | https://${DOMAIN} |
$([ -n "${AQUASOUL_DOMAIN:-}" ] && echo "| AquaSoul Studio | https://${AQUASOUL_DOMAIN} |")
| Moodle LMS | https://learn.${DOMAIN} |
| TRAX LRS | https://lrs.${DOMAIN} |
| Vaultwarden | https://vault.${DOMAIN} |
| n8n | https://n8n.${DOMAIN} |
| AdGuard DNS | https://dns.${DOMAIN} |
| Tianji Monitor | https://monitor.${DOMAIN} |
| Status Page | https://status.${DOMAIN} |
| Kopia Backup | https://backup.${DOMAIN} |
| Workstation | https://code.${DOMAIN} |
| Dozzle Logs | https://logs.${DOMAIN} |
| Forgejo Git | https://git.${DOMAIN} |
| Miniflux RSS | https://news.${DOMAIN} |
| ActualBudget | https://budget.${DOMAIN} |

---

## Credentials

### n8n
- URL: https://n8n.${DOMAIN}
- Email: ${N8N_ADMIN_EMAIL:-${SMTP_USER:-see .env}}
- Password: ${N8N_ADMIN_PASSWORD:-see .env}

### Moodle
- URL: https://learn.${DOMAIN}
- User: admin
- Password: ${MOODLE_ADMIN_PASSWORD:-see .env}

### TRAX LRS
- URL: https://lrs.${DOMAIN}
- Email: ${TRAXLRS_ADMIN_EMAIL:-see .env}
- Password: ${TRAXLRS_ADMIN_PASSWORD:-see .env}
- xAPI Endpoint user: ${TRAXLRS_ENDPOINT_USERNAME:-see .env} / ${TRAXLRS_ENDPOINT_PASSWORD:-see .env}

### Vaultwarden
- URL: https://vault.${DOMAIN}  ← click "Create Account" (do NOT go to /register)
- Email: ${VAULTWARDEN_USER_EMAIL:-see .env}
- Password: ${VAULTWARDEN_USER_PASSWORD:-see .env}
- Admin panel: https://vault.${DOMAIN}/admin  token: ${VAULTWARDEN_ADMIN_TOKEN:-see .env}

### AdGuard Home
- URL: https://dns.${DOMAIN}
- User: ${ADGUARD_ADMIN_USER:-see .env}
- Password: ${ADGUARD_ADMIN_PASSWORD:-see .env}

### Kopia Backup
- URL: https://backup.${DOMAIN}
- User: admin
- Password: ${KOPIA_SERVER_PASSWORD:-see .env}

### Miniflux
- URL: https://news.${DOMAIN}
- User: ${MINIFLUX_ADMIN_USER:-see .env}
- Password: ${MINIFLUX_ADMIN_PASSWORD:-see .env}

### Forgejo
- URL: https://git.${DOMAIN}
- Note: First visitor becomes admin — go there first

### Tianji
- URL: https://monitor.${DOMAIN}
- Note: First visitor becomes admin

### ActualBudget
- URL: https://budget.${DOMAIN}
- Password: ${ACTUALBUDGET_PASSWORD:-see .env}

---

## Post-Deploy Checklist

1. [ ] Cloudflare Zero Trust — add all tunnel routes above
2. [ ] Cloudflare Zero Trust — set policies (portfolio + status = public, rest = email auth)
3. [ ] Visit Forgejo (https://git.${DOMAIN}) — first visit creates admin
4. [ ] Visit Tianji (https://monitor.${DOMAIN}) — first visit creates admin
5. [ ] Register Vaultwarden — click "Create Account" on login page
6. [ ] Register ActualBudget — set password on first visit
7. [ ] Run: ./scripts/disable-signups.sh
8. [ ] Claude Code: visit https://code.${DOMAIN} → run: claude login
9. [ ] Tailscale: approve at https://login.tailscale.com/admin/machines → enable subnet 172.18.0.0/16

---

## AdGuard DNS Profile (Apple Devices)

SCP to your Mac:
\`\`\`bash
scp -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP_FOR_README}:${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/
\`\`\`
Then: double-click the file → System Settings → Privacy & Security → Profiles → Install
iOS: AirDrop the file → Settings → General → VPN & Device Management → Install

---

## Emergency Access (if Cloudflare is down)

SSH: \`ssh -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP_FOR_README}\`

*Generated by deploy.sh — store this file securely*
CRYPTEX_README

chmod 600 "$README_PATH"
echo ""
echo "📋 README.md generated at: ${README_PATH}"
echo ""
echo "Copy to your Mac:"
echo "  scp -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP_FOR_README}:${README_PATH} ~/Downloads/CRYPTEX-README.md"
if [ -f "${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig" ]; then
    echo ""
    echo "Copy AdGuard DNS profile to your Mac:"
    echo "  scp -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP_FOR_README}:${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/"
fi

# ── Auto pull-down: copy important files from VPS to Mac ─────────────────────
# Runs from Mac via: ssh oracle './scripts/deploy.sh' — or separately after deploy
echo ""
echo "════════════════════════════════════════════════"
echo "POST-DEPLOY: PULL FILES TO MAC"
echo "════════════════════════════════════════════════"
echo "Run these on your Mac to pull all generated files:"
echo ""
echo "  # README (all credentials, endpoints, emergency access)"
echo "  scp ubuntu@oracle:${COMPOSE_DIR}/backups/CRYPTEX-README.md ~/Downloads/CRYPTEX-README.md"
echo ""
echo "  # AdGuard DoH DNS profile (install on iPhone/Mac)"
echo "  scp ubuntu@oracle:${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/"
echo ""
echo "  # Encrypted .env backup (store securely)"
echo "  scp ubuntu@oracle:${COMPOSE_DIR}/.env.encrypted ~/Downloads/cryptex-.env.encrypted"
echo ""
echo "Or run all at once:"
echo "  ssh oracle 'cat ${COMPOSE_DIR}/backups/CRYPTEX-README.md' > ~/Downloads/CRYPTEX-README.md"
echo "  scp ubuntu@oracle:${COMPOSE_DIR}/configs/profiles/cryptex-doh.mobileconfig ~/Downloads/ 2>/dev/null || echo '(DNS profile not generated yet — run generate-profiles.sh)'"
echo "  scp ubuntu@oracle:${COMPOSE_DIR}/.env.encrypted ~/Downloads/cryptex-.env.encrypted"
