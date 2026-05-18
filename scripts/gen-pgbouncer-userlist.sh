#!/usr/bin/env bash
# gen-pgbouncer-userlist.sh — generate configs/pgbouncer/userlist.txt from .env
# Idempotent: regenerates from current .env values.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/cryptex}"
ENV_FILE="$REPO_ROOT/.env"
OUT="$REPO_ROOT/configs/pgbouncer/userlist.txt"
TEMPLATE="$REPO_ROOT/configs/pgbouncer/userlist.txt.example"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

# Source .env into a subshell for var lookup
set -a; . "$ENV_FILE"; set +a

# Render: replace <VAR> with $VAR value
TMP=$(mktemp)
cp "$TEMPLATE" "$TMP"

# Substitute every <VARNAME> placeholder
for var in $(grep -oE '<[A-Z_][A-Z0-9_]+>' "$TEMPLATE" | sort -u | tr -d '<>'); do
  val="${!var:-}"
  if [ -z "$val" ]; then
    echo "warning: $var not set in .env — leaving placeholder" >&2
    continue
  fi
  sed -i "s|<${var}>|${val}|g" "$TMP"
done

# Strip comment lines for actual userlist (pgbouncer is fine with them but cleaner without)
mv "$TMP" "$OUT"
chmod 600 "$OUT"
echo "regenerated $OUT"
