#!/bin/bash
# run.sh <job> — dispatcher. Lockfile (no overlap), per-job log, emails on hard failure.
# Usage: run.sh news | monitor | jobhunt | digest | ops | github | movies | deepdive | selftest
AGENT_HOME="/home/ubuntu/claude-agents"
job="${1:-}"

[ -z "$job" ] && { echo "usage: run.sh <news|monitor|jobhunt|digest|ops|github|movies[-tv|-anime]|deepdive|selftest>"; exit 2; }

if [ -f "$AGENT_HOME/config/PAUSED" ]; then
    [ "$job" != "selftest" ] && { echo "$(date -u +%FT%TZ) [$job] System paused via config/PAUSED, skip" >> "$AGENT_HOME/logs/$job.log"; exit 0; }
fi

# ---- selftest: validates lib without spending tokens or sending mail ----
if [ "$job" = "selftest" ]; then
    source "$AGENT_HOME/lib/common.sh"
    fail=0
    [ -n "$TO" ] && echo "PASS: recipient = $TO" || { echo "FAIL: no recipient"; fail=1; }
    command -v claude >/dev/null && echo "PASS: claude on PATH" || { echo "FAIL: claude not found"; fail=1; }
    command -v msmtp >/dev/null && echo "PASS: msmtp present" || { echo "FAIL: no msmtp"; fail=1; }
    [ -d "$PKM" ] && echo "PASS: PKM path $PKM" || { echo "FAIL: PKM missing"; fail=1; }
    [ "$(slug 'http://a.com/x y')" = "http-a-com-x-y" ] && echo "PASS: slug()" || { echo "FAIL: slug()"; fail=1; }
    h1=$(printf 'abc' | md5sum); h2=$(printf 'abd' | md5sum)
    [ "$h1" != "$h2" ] && echo "PASS: hash differs on change" || { echo "FAIL: hash"; fail=1; }
    echo "test" | normalize | grep -q test && echo "PASS: normalize()" || { echo "FAIL: normalize"; fail=1; }
    for j in news monitor jobhunt jobhunt-status-sync digest ops github movies movies-tv movies-anime deepdive; do
        bash -n "$AGENT_HOME/jobs/$j.sh" && echo "PASS: syntax jobs/$j.sh" || { echo "FAIL: syntax $j"; fail=1; }
    done
    bash "$AGENT_HOME/lib/test_pick.sh" >/dev/null && echo "PASS: pick-title regex (year ranges)" || { echo "FAIL: pick-title regex"; fail=1; }
    [ $fail -eq 0 ] && echo "== SELFTEST OK ==" || echo "== SELFTEST FAILED =="
    exit $fail
fi

script="$AGENT_HOME/jobs/$job.sh"
[ -f "$script" ] || { echo "unknown job: $job"; exit 2; }

LOCK="$AGENT_HOME/state/.$job.lock"
LOG="$AGENT_HOME/logs/$job.log"
exec 9>"$LOCK"
flock -n 9 || { echo "$(date -u +%FT%TZ) [$job] already running, skip" >>"$LOG"; exit 0; }

# run job; on hard failure (rc!=0) email an alert (content jobs email themselves on success)
{
    echo "===== $(date -u +%FT%TZ) start $job ====="
    out=$(bash "$script" 2>&1); rc=$?
    echo "$out"
    echo "===== end $job rc=$rc ====="
} >>"$LOG" 2>&1

if [ "${rc:-1}" -ne 0 ]; then
    source /opt/cryptex/.env 2>/dev/null || true
    TO="${ADMIN_EMAIL:-root}"
    tail -30 "$LOG" | msmtp --from=default "$TO" 2>/dev/null <<EOF || true
To: $TO
Subject: [claude-agents FAIL] $job (rc=$rc)

$(tail -30 "$LOG")
EOF
fi
exit "${rc:-1}"
