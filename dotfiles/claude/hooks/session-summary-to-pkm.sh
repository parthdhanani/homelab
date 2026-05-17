#!/usr/bin/env bash
# Append a haiku-summarized session note to PKM inbox.
# Stop hook receives JSON on stdin with: session_id, transcript_path, cwd, hook_event_name
# Fails silently — never block session end.

set +e

INBOX="/home/ubuntu/pkm/00 Capture/Inbox.md"
[ -d "$(dirname "$INBOX")" ] || exit 0

PAYLOAD=$(cat)
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // ""' 2>/dev/null)
CWD=$(echo "$PAYLOAD"       | jq -r '.cwd // ""'             2>/dev/null)
SID=$(echo "$PAYLOAD"       | jq -r '.session_id // "" | .[0:8]' 2>/dev/null)

[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract user prompts and tool action signals from transcript (last 50 turns)
# Exits with code 1 (no output) if no real user prompts found — skips haiku call for idle sessions
RECENT=$(tail -n 50 "$TRANSCRIPT" 2>/dev/null | python3 <<'PY'
import sys, json
prompts, edits = [], []
for line in sys.stdin:
    try:
        msg = json.loads(line)
        if msg.get('type') == 'user' and isinstance(msg.get('message',{}).get('content'), str):
            t = msg['message']['content'].strip()
            if t and not t.startswith('<') and len(t) < 500:
                prompts.append(t)
        elif msg.get('type') == 'assistant':
            for c in msg.get('message',{}).get('content',[]):
                if c.get('type') == 'tool_use' and c.get('name') in ('Edit','Write','Bash'):
                    inp = c.get('input',{})
                    if 'file_path' in inp: edits.append(f"edit:{inp['file_path']}")
                    elif 'command' in inp: edits.append(f"bash:{inp['command'][:80]}")
    except: pass
# Only emit if there was real user activity (at least 2 prompts or any edits)
if len(prompts) < 2 and not edits:
    sys.exit(1)
print("PROMPTS:\n" + "\n".join(f"- {p}" for p in prompts[-5:]))
print("\nACTIONS:\n" + "\n".join(f"- {a}" for a in edits[-8:]))
PY
)

[ -z "$RECENT" ] && exit 0

# Summarize with haiku, 20s timeout. Fall back to raw extract on failure.
SUMMARY=$(timeout 20 claude -p --model haiku "Summarize this Claude Code session in 2 sentences for a PKM inbox. Focus on what was decided or changed, not what was attempted. No preamble.

$RECENT" 2>/dev/null)

[ -z "$SUMMARY" ] && SUMMARY="(haiku unavailable) ${RECENT:0:300}"

TS=$(date '+%Y-%m-%d %H:%M')
{
  echo ""
  echo "## $TS — session $SID @ $(basename "$CWD")"
  echo "$SUMMARY"
} >> "$INBOX"

# Store session summary in ob1 memory engine (non-blocking)
if [ -n "$SUMMARY" ]; then
    PAYLOAD=$(python3 -c "
import json, sys
summary = sys.argv[1]
sid = sys.argv[2]
print(json.dumps({'content': summary, 'source': 'session', 'tags': ['session-summary'], 'session_id': sid}))
" "$SUMMARY" "$SID" 2>/dev/null)
    if [ -n "$PAYLOAD" ]; then
        curl -sf --max-time 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            http://172.18.0.52:8000/api/remember 2>/dev/null || true
    fi
fi

exit 0
