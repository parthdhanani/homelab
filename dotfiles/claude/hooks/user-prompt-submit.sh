#!/bin/bash
# UserPromptSubmit hook — fires before Claude processes input
# Runs skill search + OB1 memory search in parallel for minimal latency

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")

# Infra keyword hint (instant, no subprocess)
if echo "$PROMPT" | grep -qiE '\bvps\b|iptables|docker|nginx|cloudflare|oracle|cryptex'; then
    echo "[INFRA] VPS/infra context detected — run /save after decisions."
fi

# Stale contract files (instant)
for f in ".gemini-plan.md" ".gemini-docs.md"; do
    if [ -f "$f" ]; then
        AGE=$(( ($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0)) / 3600 ))
        [ "$AGE" -gt 48 ] && echo "[STALE] $f is ${AGE}h old — verify still relevant or delete."
    fi
done

[ -z "$PROMPT" ] && exit 0

SKILL_TMP="/tmp/.skill-hook-$$"
OB1_TMP="/tmp/.ob1-hook-$$"
trap 'rm -f "$SKILL_TMP" "$OB1_TMP"' EXIT

# ── Launch both in parallel ────────────────────────────────────────────────────

# Skill search (local, fast ~50ms)
python3 ~/.claude/hooks/skill-inject.py "$PROMPT" > "$SKILL_TMP" 2>/dev/null &
SKILL_PID=$!

# OB1 semantic memory (network, up to 2s)
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1][:500]))" "$PROMPT" 2>/dev/null)
if [ -n "$ENCODED" ]; then
    curl -sf --max-time 2 "http://172.18.0.52:8000/api/search?q=${ENCODED}&k=4" > "$OB1_TMP" 2>/dev/null &
    OB1_PID=$!
fi

wait $SKILL_PID 2>/dev/null
[ -n "${OB1_PID:-}" ] && wait $OB1_PID 2>/dev/null

# ── Output results ─────────────────────────────────────────────────────────────

# Skill match first (highest-priority actionable context)
[ -s "$SKILL_TMP" ] && cat "$SKILL_TMP"

# OB1 memories
if [ -s "$OB1_TMP" ]; then
    python3 -c "
import json, sys
try:
    results = json.loads(open(sys.argv[1]).read()).get('results', [])
    hits = [r for r in results if r.get('similarity', 0) >= 0.62]
    if hits:
        print('[OB1] Relevant memories:')
        for r in hits[:3]:
            print(f'  [{r.get(\"source\",\"?\")}] ({r.get(\"similarity\",0):.2f}) {r.get(\"content\",\"\")[:180].replace(chr(10),\" \")}')
except Exception:
    pass
" "$OB1_TMP" 2>/dev/null
fi

exit 0
