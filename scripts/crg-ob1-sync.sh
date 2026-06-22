#!/bin/bash
# Nightly: regenerate code-review-graph architecture wiki for tracked code repos,
# ingest a summary into OB1. Mirrors graphify→OB1 (infra) for the CODE domain.
# Idempotent via content hash. Silent failure — never disturb the system.
set +e
export PATH="/home/ubuntu/.local/bin:$PATH"
CRG=/home/ubuntu/.local/bin/code-review-graph
OB1_TOKEN=$(cat /home/ubuntu/.claude/secrets/ob1.token 2>/dev/null)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Repos to sync: any with a CRG index. AI_Space is the live daemon repo;
# add more paths here as they become active.
REPOS="/home/ubuntu/AI_Space"

for REPO in $REPOS; do
    [ -d "$REPO/.code-review-graph" ] || continue
    cd "$REPO" || continue
    "$CRG" update  >/dev/null 2>&1   # incremental re-index
    "$CRG" wiki    >/dev/null 2>&1   # regenerate community wiki

    WIKI="$REPO/.code-review-graph/wiki/index.md"
    [ -f "$WIKI" ] || continue

    HASH=$(sha256sum "$WIKI" | cut -d' ' -f1)
    HASHFILE="$REPO/.code-review-graph/.ob1-last-hash"
    [ "$HASH" = "$(cat "$HASHFILE" 2>/dev/null)" ] && continue   # unchanged → skip

    STATS=$("$CRG" status 2>/dev/null)
    NODES=$(echo "$STATS" | awk -F': ' '/Nodes/{print $2}')
    EDGES=$(echo "$STATS" | awk -F': ' '/Edges/{print $2}')
    FILES=$(echo "$STATS" | awk -F': ' '/Files/{print $2}')
    COMMS=$(grep -c '\.md)' "$WIKI" 2>/dev/null)
    NAME=$(basename "$REPO")

    SUMMARY="code-review-graph wiki for ${NAME} at ${TS}: ${FILES} files, ${NODES} nodes, ${EDGES} edges, ${COMMS} architecture communities. AST-precise code-structure knowledge graph."

    curl -sf --max-time 8 -X POST "http://172.18.0.52:8000/api/remember" \
        -H "Content-Type: application/json" \
        ${OB1_TOKEN:+-H "Authorization: Bearer $OB1_TOKEN"} \
        -d "{\"content\": \"${SUMMARY}\", \"source\": \"code-review-graph\", \"tags\": [\"crg\", \"code\", \"architecture\", \"knowledge-graph\", \"automated\"]}" \
        >/dev/null 2>&1 && echo "$HASH" > "$HASHFILE"
done
exit 0
