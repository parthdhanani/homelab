#!/bin/bash
# stack_inventory.sh — deterministic inventory of what Parth ALREADY runs.
# Emits one lowercase token per line: bare tool names and owner/repo slugs.
# Consumed by gh_gate.py to hard-exclude self-recommendations (the Jul-28 digest
# pitched pocket-id, uptime-kuma, kopia and code-review-graph — all already running).
#
# Sources: compose images, enabled systemd units, host bins, npm globals, and a
# hand-maintained extras list. Human-editable additions go in
# config/stack-extra.txt (one token per line, '#' comments allowed).

set -uo pipefail
AGENT_HOME="${AGENT_HOME:-/home/ubuntu/claude-agents}"
CRYPTEX="${CRYPTEX_DIR:-/opt/cryptex}"

# Tokens too generic to match on — a repo named "alpine" or "nginx" is the real
# thing, but these also appear as base images / transitive deps everywhere and
# would swallow unrelated candidates. Excluded from the generated token set.
STOPLIST='^(alpine|nginx|redis|postgres|mongo|node|python|ubuntu|debian|busybox|traefik|caddy|claude|flask|gunicorn|httpx|hf|fd|chromium|activate.*|.*-converter|.*\.py|__pycache__)$'

{
    # --- Docker compose images: ghcr.io/pocket-id/pocket-id:v2 -> pocket-id/pocket-id + pocket-id
    grep -rhoE '^[[:space:]]*image:[[:space:]]*\S+' \
        --include='*.yml' --include='*.yaml' "$CRYPTEX" 2>/dev/null |
        sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/@sha256.*$//; s/:[^:\/]*$//' |
        while read -r img; do
            img="${img#docker.io/}"; img="${img#ghcr.io/}"; img="${img#codeberg.org/}"
            printf '%s\n' "$img"                 # owner/repo
            printf '%s\n' "${img##*/}"           # bare name
        done

    # --- enabled systemd units (strip @instance and .type)
    systemctl list-unit-files --state=enabled --no-legend 2>/dev/null |
        awk '{print $1}' | sed -E 's/@.*$//; s/\.[a-z]+$//'

    # --- host binaries we installed ourselves
    ls /usr/local/bin "$HOME/.local/bin" "$HOME/.npm-global/bin" 2>/dev/null

    # --- extras / aliases the automatic sources can't see.
    # Emit slugs AND their bare names, so "fatedier/frp" also blocks a bare "frp".
    if [ -f "$AGENT_HOME/config/stack-extra.txt" ]; then
        grep -vE '^\s*(#|$)' "$AGENT_HOME/config/stack-extra.txt" |
            while read -r tok; do
                printf '%s\n' "$tok"
                case "$tok" in */*) printf '%s\n' "${tok##*/}" ;; esac
            done
    fi
} 2>/dev/null |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[[:space:]]//g' |
    grep -vE '^$' |
    grep -vE "$STOPLIST" |
    sort -u
