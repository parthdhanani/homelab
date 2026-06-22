#!/bin/bash
# CRYPTEX — Health check for all containers
# Run on VPS: ./scripts/health-check.sh

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
cd "$COMPOSE_DIR"

# Load deployment profile to skip non-deployed containers
if [ -f "${COMPOSE_DIR}/.env" ]; then
    # shellcheck disable=SC1090
    source "${COMPOSE_DIR}/.env"
fi
DEPLOY_PROFILE="${DEPLOY_PROFILE:-personal}"
DEPLOY_SERVICES="${DEPLOY_SERVICES:-all}"

# Helper: skip check if service not in custom profile
svc_enabled() {
    local svc="$1"
    [ "$DEPLOY_PROFILE" = "personal" ] && return 0
    [[ " $DEPLOY_SERVICES " == *" $svc "* ]] && return 0
    return 1
}

echo ""
echo "CRYPTEX Health Check"
echo "────────────────────────────"
echo ""

PASS=0
FAIL=0
WARN=0

# Wrapper: check only if service is in deployment profile
# Usage: svc_check <svc_name> check|check_health <args...>
svc_check() {
    local svc="$1"; shift
    svc_enabled "$svc" || return 0
    "$@"
}

# Check container via docker exec (requires shell inside container)
check() {
    local name="$1" container="$2" check_cmd="$3"
    if docker exec "$container" sh -c "$check_cmd" >/dev/null 2>&1; then
        printf "  %-20s OK\n" "$name"
        PASS=$(( PASS + 1 ))
    else
        state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
        if [ "$state" = "running" ]; then
            printf "  %-20s WARN (running, health check failed)\n" "$name"
            WARN=$(( WARN + 1 ))
        else
            printf "  %-20s FAIL (state: %s)\n" "$name" "$state"
            FAIL=$(( FAIL + 1 ))
        fi
    fi
}

# Check container via docker inspect health state (for scratch/distroless images with no shell)
check_health() {
    local name="$1" container="$2"
    local state health
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
    if [ "$state" != "running" ]; then
        printf "  %-20s FAIL (state: %s)\n" "$name" "$state"
        FAIL=$(( FAIL + 1 ))
        return
    fi
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "unknown")
    case "$health" in
        healthy|none)
            printf "  %-20s OK\n" "$name"
            PASS=$(( PASS + 1 ))
            ;;
        starting)
            printf "  %-20s WARN (starting)\n" "$name"
            WARN=$(( WARN + 1 ))
            ;;
        *)
            printf "  %-20s WARN (health: %s)\n" "$name" "$health"
            WARN=$(( WARN + 1 ))
            ;;
    esac
}

# Check host-level command
check_host() {
    local name="$1" check_cmd="$2"
    if eval "$check_cmd" >/dev/null 2>&1; then
        printf "  %-20s OK\n" "$name"
        PASS=$(( PASS + 1 ))
    else
        printf "  %-20s FAIL\n" "$name"
        FAIL=$(( FAIL + 1 ))
    fi
}

# Infrastructure
echo "Infrastructure:"
check        "PostgreSQL"    cryptex-postgres     "pg_isready -U \$POSTGRES_USER"
check_health "PgBouncer"    cryptex-pgbouncer
check_health "Redis"         cryptex-redis
check_health "Cloudflared"   cryptex-cloudflared
check_health "Socket Proxy"  cryptex-socket-proxy

echo ""
echo "Services:"
svc_check "portfolio"    check      "Portfolio"    cryptex-portfolio    "wget -qO /dev/null http://127.0.0.1:80/"
svc_check "moodle"       check      "Moodle"       cryptex-moodle       "curl -sSo /dev/null -w '%{http_code}' http://127.0.0.1:80/ | grep -qE '^[23]'"
svc_check "traxlrs"      check      "TRAX LRS"     cryptex-traxlrs      "curl -sSo /dev/null -w '%{http_code}' http://127.0.0.1:80/ | grep -qE '^[23]'"
svc_check "vaultwarden"  check      "Vaultwarden"  cryptex-vaultwarden  "curl -fsS -o /dev/null http://127.0.0.1:80/alive"
svc_check "n8n"          check_health "n8n"          cryptex-n8n
svc_check "adguard"      check_health "AdGuard"      cryptex-adguard
svc_check "kopia"        check_health "Kopia"        cryptex-kopia
svc_check "dockhand"     check      "Dockhand"     cryptex-dockhand     "curl -sf http://127.0.0.1:3000/"
svc_check "uptime-kuma"  check_health "Uptime Kuma" cryptex-uptime-kuma
svc_check "shlink"       check_health "Shlink"      cryptex-shlink
svc_check "shlink-web"   check_health "Shlink Web"  cryptex-shlink-web
svc_check "umami"        check_health "Umami"       cryptex-umami

echo ""
echo "Utilities:"
check_host "Zellij"       "curl -sf http://127.0.0.1:8082/"
svc_check "forgejo"       check        "Forgejo"      cryptex-forgejo      "curl -fsS -o /dev/null http://127.0.0.1:3000/"
svc_check "miniflux"      check_health "Miniflux"     cryptex-miniflux
svc_check "actualbudget"  check        "ActualBudget" cryptex-actualbudget "node -e \"require('http').get('http://127.0.0.1:5006/',r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))\""
svc_check "it-tools"      check        "IT-Tools"     cryptex-it-tools     "wget -qO /dev/null http://127.0.0.1:80/"
svc_check "searxng"       check_health "SearXNG"      cryptex-searxng
svc_check "ferretdb"      check_health "MongoDB"      cryptex-ferretdb
svc_check "librechat"     check_health "LibreChat"    cryptex-librechat
svc_check "alist"         check_health "Alist"        cryptex-alist
svc_check "stirling-pdf"  check_health "Stirling PDF" cryptex-stirling-pdf
svc_check "pocketid"     check        "PocketID"     cryptex-pocketid     "wget -qO /dev/null http://127.0.0.1:1411/healthz"
# System resources
echo ""
echo "────────────────────────────"
echo "System Resources:"
echo "  Memory: $(free -h | awk '/^Mem:/ {printf "%s / %s (%s used)", $3, $2, $5}')"
echo "  Swap:   $(free -h | awk '/^Swap:/ {printf "%s / %s", $3, $2}')"
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
DISK_DISPLAY=$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')
echo "  Disk:   ${DISK_DISPLAY}"
echo "  Containers: $(docker ps -q | wc -l) running"

# Disk threshold alert (>80%)
if [ "$DISK_PCT" -gt 80 ]; then
    echo ""
    echo "  ⚠ WARNING: Disk usage at ${DISK_PCT}% — clean old backups or docker images"
    WARN=$(( WARN + 1 ))
fi

echo ""
echo "────────────────────────────"
echo "Results: ${PASS} OK, ${WARN} WARN, ${FAIL} FAIL"

# Send alert on failures (with debounce — max 1 alert per 15 minutes)
ALERT_STATE_FILE="/tmp/cryptex-health-alert.state"
NOW=$(date +%s)

if [ "$FAIL" -gt 0 ]; then
    FAILED_LIST=$(docker compose ps --format '{{.Name}} {{.State}} ({{.Status}})' 2>/dev/null | grep -v " running " || echo "unknown")

    # Debounce: only fire alert if last alert was >15 minutes ago
    LAST_ALERT=$(cat "$ALERT_STATE_FILE" 2>/dev/null || echo 0)
    DEBOUNCE_SECS=900  # 15 minutes
    if [ $(( NOW - LAST_ALERT )) -gt "$DEBOUNCE_SECS" ]; then
        echo "$NOW" > "$ALERT_STATE_FILE"

        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
            MSG="🚨 CRYPTEX HEALTH ALERT%0A${FAIL} containers FAILED%0AFailed: ${FAILED_LIST}%0A$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_CHAT_ID}&text=${MSG}" >/dev/null 2>&1 || true
        fi
    else
        echo "  Alert suppressed (debounce: last sent $(( (NOW - LAST_ALERT) / 60 ))m ago, next in $(( (DEBOUNCE_SECS - (NOW - LAST_ALERT)) / 60 ))m)"
    fi
    exit 1
fi

# Clear alert state on clean run (so first failure after recovery fires immediately)
rm -f "$ALERT_STATE_FILE"
exit 0
