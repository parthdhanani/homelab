#!/bin/bash
# PreToolUse hook — blocks destructive commands, validates iptables
# Receives JSON on stdin: { "tool_name": "Bash", "tool_input": { ... } }

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
READ_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Sensitive path pattern
SENSITIVE_PATTERN='(\.ssh|\.gnupg|\.aws|\.config/gcloud)(/|$)|/id_rsa\b|/id_ed25519\b|\bid_rsa\b|\bid_ed25519\b|\.pem$|\.key$|authorized_keys|known_hosts'

# ── Read tool: block sensitive paths (with path traversal normalization) ──────
if [[ "$TOOL" == "Read" ]]; then
    NORM_PATH=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$READ_PATH" 2>/dev/null || echo "$READ_PATH")
    if echo "$NORM_PATH" | grep -qE "$SENSITIVE_PATTERN"; then
        echo "BLOCKED: Read access to sensitive credential path denied." >&2
        exit 2
    fi
    exit 0
fi

# ── Write/Edit tools: block writes to sensitive paths ─────────────────────────
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" || "$TOOL" == "MultiEdit" ]]; then
    WRITE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    NORM_WRITE=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$WRITE_PATH" 2>/dev/null || echo "$WRITE_PATH")
    if echo "$NORM_WRITE" | grep -qE "$SENSITIVE_PATTERN"; then
        echo "BLOCKED: Write access to sensitive credential path denied." >&2
        exit 2
    fi
    exit 0
fi

[[ "$TOOL" != "Bash" ]] && exit 0

# ── Credential path access (Bash) ─────────────────────────────────────────────
if echo "$CMD" | grep -qE "$SENSITIVE_PATTERN"; then
    echo "BLOCKED: Access to SSH/credentials path denied." >&2
    exit 2
fi

# Block shell redirection from sensitive paths (e.g. cat < ~/.ssh/config)
if echo "$CMD" | grep -qE '<\s*(~|/Users/[^/]+)?/?\.(ssh|gnupg|aws)/'; then
    echo "BLOCKED: Shell redirection from credential directory denied." >&2
    exit 2
fi

# ── Environment variable leakage (secret-named vars only) ─────────────────────
if echo "$CMD" | grep -qE '^\s*(env|printenv)\s*$|echo\s+\$(API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|ACCESS_KEY|AUTH_KEY|DB_PASS|OPENAI|ANTHROPIC|GEMINI)[A-Z_]*\b'; then
    echo "BLOCKED: env/echo of secret-named environment variable may leak credentials." >&2
    exit 2
fi

# ── Docker unsafe mounts ──────────────────────────────────────────────────────
if echo "$CMD" | grep -qE 'docker\s+run.*-v\s*/(:|etc:|var/run/docker\.sock)'; then
    echo "BLOCKED: Unsafe Docker volume mount (root, /etc, or docker socket)." >&2
    exit 2
fi
if echo "$CMD" | grep -qE 'docker\s+run.*--mount[^"]*source=/'; then
    echo "BLOCKED: docker --mount with system path source." >&2
    exit 2
fi

# ── Git destructive operations ────────────────────────────────────────────────
# Force push: --force, -f, and +refspec variants
if echo "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b|\+[a-zA-Z0-9_/:-]+)'; then
    echo "BLOCKED: git push --force (or +refspec). Ask user to confirm explicitly." >&2
    exit 2
fi

# Hard reset
if echo "$CMD" | grep -qE 'git\s+reset\s+--hard'; then
    echo "BLOCKED: git reset --hard destroys uncommitted work. Use git stash or ask user to confirm." >&2
    exit 2
fi

# ── rm -rf on root or home ────────────────────────────────────────────────────
if echo "$CMD" | grep -qE 'rm\s+-rf\s+(\/\s*$|~[\/\s]*$|\$HOME[\/\s]*$|/Users/parthdhanani/?(\s|$)|~/\.claude/?(\s|$)|~/.claude/?(\s|$)|\$HOME/\.claude/?(\s|$)|/Users/parthdhanani/\.claude/?(\s|$)|~/Downloads/Work/?(\s|$)|/Users/parthdhanani/Downloads/Work/?(\s|$))'; then
    echo "BLOCKED: rm -rf on home, root, .claude root, or critical project directories." >&2
    exit 2
fi

# ── iptables validation ───────────────────────────────────────────────────────
if echo "$CMD" | grep -q "iptables"; then
    if ! ~/.claude/hooks/validators/iptables-check.sh "$CMD" >/dev/null 2>&1; then
        echo "BLOCKED: iptables rule rejected. VPS requires -I INPUT 6, never DROP port 22." >&2
        exit 2
    fi
    # iptables validation passed — VPS rules: -I INPUT 6, never DROP port 22, ports 80/443 for HTTP/S
fi

exit 0
