#!/usr/bin/env bash
# 03-secrets.sh — provision the runtime .env from .env.example.
#
# Modes:
#   --interactive (default)  prompt for each missing value
#   --skeleton               copy .env.example to .env with placeholders, do not prompt
#   --check                  verify .env has no placeholder values left, exit non-zero otherwise
#
# Idempotent: re-running never overwrites existing real values; only fills missing keys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

MODE="${1:-}"
[ -z "$MODE" ] && MODE="--interactive"

ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

[ -f "$ENV_EXAMPLE" ] || fail "missing $ENV_EXAMPLE"

# Create empty .env if missing
if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "created empty .env"
fi
# Restrict permissions
chmod 600 "$ENV_FILE"

PLACEHOLDER_PATTERN='^(CHANGE_ME|<.*>|REPLACE_ME|)$'

# Helper: get current value of a key from .env (empty if missing)
get_env() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# Helper: set key in .env (replace or append)
set_env() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Replace existing
    local escaped
    escaped="$(printf '%s\n' "$value" | sed -e 's/[\/&|]/\\&/g')"
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# Generate strong random value
gen_secret() {
  openssl rand -base64 32 | tr -d '\n=' | cut -c1-32
}

# Determine which keys to handle
KEYS_FROM_EXAMPLE=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | cut -d= -f1)

case "$MODE" in
  --check)
    bad=0
    for key in $KEYS_FROM_EXAMPLE; do
      val=$(get_env "$key")
      if [[ -z "$val" || "$val" =~ ^(CHANGE_ME|REPLACE_ME|\<.*\>)$ ]]; then
        echo "  missing/placeholder: $key"
        bad=$((bad + 1))
      fi
    done
    if [ "$bad" -gt 0 ]; then
      fail ".env has $bad missing or placeholder value(s)"
    fi
    ok ".env passes all checks"
    ;;
  --skeleton)
    for key in $KEYS_FROM_EXAMPLE; do
      cur=$(get_env "$key")
      if [ -z "$cur" ]; then
        example_val=$(grep -E "^${key}=" "$ENV_EXAMPLE" | head -n1 | cut -d= -f2-)
        set_env "$key" "$example_val"
      fi
    done
    ok ".env skeleton populated (placeholders only — fill before running 04-stack.sh)"
    ;;
  --interactive)
    log "Filling .env interactively. Press ENTER to keep existing values."
    for key in $KEYS_FROM_EXAMPLE; do
      cur=$(get_env "$key")
      example_val=$(grep -E "^${key}=" "$ENV_EXAMPLE" | head -n1 | cut -d= -f2-)
      hint="$example_val"
      [ -n "$cur" ] && hint="$cur (current)"
      # Offer auto-generation for typical secret keys
      if [[ "$key" == *PASSWORD* || "$key" == *SECRET* || "$key" == *KEY* || "$key" == *TOKEN* ]] && [ -z "$cur" ]; then
        read -r -p "  $key [hint: $hint, type 'gen' to autogenerate]: " val
        if [ "$val" = "gen" ]; then
          val=$(gen_secret)
          echo "    generated: $val"
        fi
      else
        read -r -p "  $key [hint: $hint]: " val
      fi
      if [ -n "$val" ]; then
        set_env "$key" "$val"
      elif [ -z "$cur" ]; then
        set_env "$key" "$example_val"
      fi
    done
    ok ".env populated"
    ;;
  *)
    fail "unknown mode: $MODE (use --interactive | --skeleton | --check)"
    ;;
esac
