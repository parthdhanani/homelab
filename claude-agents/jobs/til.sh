#!/bin/bash
# til.sh — weekly TIL writer + spaced-repetition review (Sun morning IST).
#
# Why the agent writes these and not Parth: the TIL habit died on 2026-04-04 and
# ReadLater died on 2026-03-16, both for the same reason — every PKM surface that
# required typing prose has an empty tail. The material was never the problem; the
# authorship was. He generates real gotchas weekly (commit bodies, session summaries)
# and none of it becomes a durable note. This reads that week's output and writes the
# TILs that were actually earned, in the vault's existing format.
#
# Hard rule enforced in the prompt: a TIL is a *transferable concept*, not a changelog
# entry. "Fixed the nginx config" is not a TIL. "nginx add_header is not cumulative
# across nesting levels" is.
#
# The EMAIL is built on two of the best-replicated findings in learning research:
#
#   1. Testing effect / retrieval practice (Roediger & Karpicke 2006). Trying to recall
#      an answer and failing beats re-reading the answer. So every card leads with a
#      QUESTION and every answer sits in a separate block far below — scrolling to it is
#      a deliberate act, which is the whole point. A note you re-read feels learned and
#      isn't; that fluency illusion is exactly what this layout attacks.
#   2. Spacing effect with expanding intervals (Cepeda et al. 2006). A lesson seen once
#      is gone. Each TIL is resurfaced at 7 / 21 / 60 / 150 days, then retired. Fixed
#      intervals, not SM-2: grading requires a click-back channel this job doesn't have,
#      and the spacing benefit is robust without it. Adding grading later = per-card
#      links into duel.service's HMAC scheme.
#
# Deliberately capped at 2 review cards + <=3 new. A 12-card email gets archived unread,
# which scores zero on every effect above.
JOB=til
source "$(dirname "$0")/../lib/common.sh"

TIL_DIR="$PKM/50 Collections/TIL"
mkdir -p "$TIL_DIR"
SINCE=$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)
WEEK=$(date -u +%Y-%m-%d)
STATE="$AGENT_STATE/til-review.json"

# ---- gather the week's raw material -------------------------------------------------
# Commit subjects AND bodies: the body is where the actual gotcha usually is.
COMMITS=""
for r in /home/ubuntu/AI_Space /home/ubuntu/.claude /opt/cryptex /opt/cryptex/data/pkm; do
    [ -d "$r/.git" ] || continue
    c=$(git -C "$r" log --since="$SINCE" --pretty=format:'--- %s%n%b' 2>/dev/null \
        | grep -vE '^memory: auto-commit|^$' | head -120)
    [ -n "$c" ] && COMMITS+="## repo: $r"$'\n'"$c"$'\n\n'
done

# Session summaries written by the stop-hook — these carry the "why" that commits drop.
SESSIONS=$(awk -v since="$SINCE" '
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ { d=substr($2,1,10); keep=(d>=since) }
    keep { print }
' "$PKM/00 Capture/Inbox.md" 2>/dev/null | head -150)

# Existing TIL topics — the model must not re-teach something already in the vault.
EXISTING=$(for f in "$TIL_DIR"/*.md; do
    [ -f "$f" ] || continue
    t=$(grep -m1 '^topic:' "$f" 2>/dev/null | sed 's/^topic:[[:space:]]*//')
    [ -n "$t" ] && echo "- $t" || echo "- $(basename "$f" .md)"
done | head -60)

RAW="$COMMITS"$'\n'"$SESSIONS"
NEW_COUNT=0
if [ "${#RAW}" -lt 400 ]; then
    log "not enough material this week (${#RAW} chars) — no new TIL, review only"
else
    # ---- ask for the TILs -----------------------------------------------------------
    PROMPT="Below is one week of engineering output from a self-hosted infra developer:
git commit subjects+bodies and end-of-session summaries. Find the genuinely TRANSFERABLE
lessons in it and write 2-3 TIL (Today I Learned) notes.

CRITICAL — what counts as a TIL:
- YES: a concept, mechanism, or gotcha that would be true on someone else's machine.
  'tar's * crosses / unlike a shell glob, so an exclude pattern can match far more than
  intended', 'nginx add_header is not cumulative across nesting levels'.
- NO: a changelog entry or a status report. 'Fixed the backup script', 'bumped 10
  container pins', 'shipped the redaction filter' are NOT TILs. If the sentence only
  makes sense on THIS box, it is not a TIL.
- If you can only find one real lesson, write ONE. Never pad to reach three. A thin TIL
  is worse than no TIL.

Do NOT repeat anything already covered by these existing notes:
$EXISTING

Audience: strong in JS/SCORM/xAPI, nginx, Docker, iptables. Curious but non-expert in
physics/philosophy. Don't over-explain basics. Direct engineer voice, no filler, no
blogger tone.

The QUESTION field is used for retrieval practice — it is shown days later with the
answer hidden. It must therefore:
- be answerable from memory by someone who read the note, in one or two sentences;
- probe the MECHANISM ('Why does X still happen even though Y is set?'), never trivia;
- give enough context to be self-contained, but NOT contain its own answer.
Good: 'A directory has the setgid bit and group ubuntu. A root cron job writes a file
there. Why can ubuntu still not write to it?'
Bad: 'What does setgid do?' (trivia) / 'Does umask override setgid?' (yes/no giveaway).

Output STRICT format, repeated per TIL, nothing before or after:

===TIL===
SLUG: short-kebab-case-slug
TOPIC: One specific sentence naming the lesson (not a title like 'Backup Learnings')
QUESTION: The retrieval-practice question, per the rules above.
TAGS: til, tag2, tag3
BODY:
> One-sentence statement of the rule and why it matters.

## What happened
Concrete situation from the material that surfaced this. Specific.

## Why it works that way
The actual mechanism. This is the part that transfers.

## How to apply it
What to do differently next time. Concrete and checkable.
===END===

MATERIAL:
$RAW"

    if OUT=$(run_agy "$PROMPT") && printf '%s' "$OUT" | grep -q '===TIL==='; then
        # Model output goes through a file, not a heredoc: it contains backticks, quotes
        # and $ that any shell interpolation would mangle.
        printf '%s' "$OUT" > "$AGENT_STATE/til-raw.txt"
        NEW_COUNT=$(python3 "$(dirname "$0")/../lib/til_lib.py" write \
            "$TIL_DIR" "$WEEK" "$AGENT_STATE/til-raw.txt") || NEW_COUNT=0
        log "wrote $NEW_COUNT new TIL(s)"
    else
        log "no well-formed TIL in model output — review-only email this week"
    fi
fi

# ---- schedule: enrol new notes, pick what is due ------------------------------------
DUE_JSON="$AGENT_STATE/til-due.json"
python3 "$(dirname "$0")/../lib/til_lib.py" schedule "$TIL_DIR" "$WEEK" "$STATE" "$DUE_JSON"
DUE_COUNT=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['due']))" "$DUE_JSON")
log "due for review: $DUE_COUNT"

# ---- backfill questions for older notes written before the QUESTION field existed ---
NEEDQ=$(python3 "$(dirname "$0")/../lib/til_lib.py" needq "$DUE_JSON")
if [ -n "$NEEDQ" ]; then
    QPROMPT="For each numbered note below, write ONE retrieval-practice question: something
the reader must answer from memory days after reading, probing the MECHANISM, not trivia.
Self-contained (give the setup), and it must NOT contain its own answer. One or two
sentences of expected answer.

Good: 'A directory has the setgid bit and group ubuntu. A root cron job writes a file
there. Why can ubuntu still not write to it?'
Bad: 'What does setgid do?' / 'Does umask override setgid?'

Output exactly one line per note, format 'SLUG :: question'. Nothing else.

$NEEDQ"
    if QOUT=$(run_agy "$QPROMPT"); then
        printf '%s' "$QOUT" > "$AGENT_STATE/til-questions.txt"
        python3 "$(dirname "$0")/../lib/til_lib.py" mergeq "$DUE_JSON" "$AGENT_STATE/til-questions.txt" "$TIL_DIR"
        log "backfilled questions for older notes"
    else
        log "question backfill failed — those cards fall back to their topic line"
    fi
fi

# ---- render + send ------------------------------------------------------------------
TOTAL=$((NEW_COUNT + DUE_COUNT))
[ "$TOTAL" -eq 0 ] && { log "nothing new and nothing due — no email"; exit 0; }

python3 "$(dirname "$0")/../lib/til_lib.py" render \
    "$TIL_DIR" "$WEEK" "$DUE_JSON" "$AGENT_STATE/til-email.html" "$NEW_COUNT" || {
    log "render failed"; exit 1; }

SUBJ=$(python3 "$(dirname "$0")/../lib/til_lib.py" subject "$NEW_COUNT" "$DUE_COUNT")
send_mail "$SUBJ" "$(cat "$AGENT_STATE/til-email.html")" html
python3 "$(dirname "$0")/../lib/til_lib.py" commit "$DUE_JSON" "$STATE" "$WEEK"
log "sent: $NEW_COUNT new, $DUE_COUNT review"
