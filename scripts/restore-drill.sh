#!/bin/bash
# Monthly FULL restore drill (evolution WP 1.4/1.5, unified 6.1 deep version):
# restore the latest backup tar from the Kopia snapshot, load the postgres dump into a
# throwaway container, assert real row counts. Proves the whole chain B2->tar->psql,
# not just file integrity (that's restore-spot-check.sh's job).
set -u
exec 9>/var/lock/restore-drill.lock
flock -n 9 || exit 0

SCRATCH=/opt/cryptex/backups/restore-scratch
FAIL(){ /home/ubuntu/.claude/scripts/notify.sh "restore DRILL FAILED" "$1" critical; cleanup; exit 1; }
cleanup(){ docker rm -f restore-drill-pg >/dev/null 2>&1; sudo rm -rf "$SCRATCH"; }

AVAIL_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
[ "$AVAIL_GB" -lt 3 ] && FAIL "only ${AVAIL_GB}GB free — need 3GB headroom"

SNAP_ID=$(docker exec cryptex-kopia kopia snapshot list /backups --max-results=1 --json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
[ -z "${SNAP_ID:-}" ] && FAIL "no kopia snapshot found"

# Try newest tar; if its snapshot copy is corrupt (observed: interleaved double-write),
# fall back to the previous one and ALERT about the bad newest — two bad in a row = FAIL.
mkdir -p "$SCRATCH"
NEWEST_TAR=""
BAD_TARS=""
for CAND in $(docker exec cryptex-kopia kopia ls "$SNAP_ID" 2>/dev/null | grep '^cryptex-.*\.tar\.gz$' | sort | tail -2 | tac); do
    docker exec cryptex-kopia sh -c "rm -rf /tmp/drill && mkdir /tmp/drill && kopia restore '$SNAP_ID/$CAND' /tmp/drill/b.bin" >/dev/null 2>&1 || { BAD_TARS="$BAD_TARS $CAND(restore-failed)"; continue; }
    docker cp cryptex-kopia:/tmp/drill/b.bin "$SCRATCH/b.bin" >/dev/null 2>&1
    docker exec cryptex-kopia rm -rf /tmp/drill 2>/dev/null
    if tar -xzf "$SCRATCH/b.bin" -C "$SCRATCH" --wildcards '*/postgres_all.sql' 2>/dev/null; then
        NEWEST_TAR="$CAND"; break
    fi
    BAD_TARS="$BAD_TARS $CAND(corrupt-in-snapshot)"
done
[ -z "$NEWEST_TAR" ] && FAIL "no restorable tar in snapshot $SNAP_ID — tried:$BAD_TARS"
[ -n "$BAD_TARS" ] && /home/ubuntu/.claude/scripts/notify.sh "restore drill: newest tar bad, fallback used" "Bad in snapshot:$BAD_TARS — drill continued with $NEWEST_TAR. Investigate backup double-write (task on file)." warning
SQL=$(find "$SCRATCH" -name postgres_all.sql | head -1)
[ -s "$SQL" ] || FAIL "postgres_all.sql empty"

docker rm -f restore-drill-pg >/dev/null 2>&1
docker run --rm -d --name restore-drill-pg -e POSTGRES_PASSWORD=drill postgres:16 >/dev/null || FAIL "throwaway postgres failed to start"
for i in $(seq 1 30); do docker exec restore-drill-pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done
docker exec restore-drill-pg pg_isready -U postgres >/dev/null 2>&1 || FAIL "throwaway postgres never became ready"

docker exec -i restore-drill-pg psql -U postgres -q < "$SQL" >/dev/null 2>&1   # dump has \connect lines; errors checked via assertions below

MOODLE_ROWS=$(docker exec restore-drill-pg psql -U postgres -d moodle -tAc "SELECT count(*) FROM mdl_user" 2>/dev/null | tr -d ' ')
N8N_TABLES=$(docker exec restore-drill-pg psql -U postgres -d n8n -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
[ "${MOODLE_ROWS:-0}" -gt 0 ] 2>/dev/null || FAIL "moodle mdl_user restored with ${MOODLE_ROWS:-0} rows"
[ "${N8N_TABLES:-0}" -gt 0 ] 2>/dev/null || FAIL "n8n restored with ${N8N_TABLES:-0} tables"

cleanup
echo "$(date -u +%F) DRILL OK: $NEWEST_TAR -> moodle users=$MOODLE_ROWS n8n tables=$N8N_TABLES" >> /var/log/cryptex-restore-check.log
exit 0
