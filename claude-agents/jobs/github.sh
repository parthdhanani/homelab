#!/bin/bash
# github.sh — weekly OSS digest (Tue evening IST). Tier 1: hidden-gem self-hosting tools
# for your stack. Tier 2: what's genuinely trending this week. Cross-run deduped.
JOB=github
source "$(dirname "$0")/../lib/common.sh"

SEEN="$AGENT_STATE/github-seen.tsv"   # DATE<tab>REPO_URL<tab>NAME — memory of what we've shown
touch "$SEEN"

# Deterministic list of what Parth already runs. The model gets it as guidance;
# lib/gh_gate.py then enforces it against the GitHub API regardless (2026-07-28
# digest pitched pocket-id, uptime-kuma, wg-easy, neko, frp — all already in use).
INV="$AGENT_STATE/stack-inventory.txt"
bash "$AGENT_HOME/lib/stack_inventory.sh" > "$INV.tmp" 2>/dev/null && mv "$INV.tmp" "$INV"
OWNED_BLOCK=""
[ -s "$INV" ] && OWNED_BLOCK="

ALREADY RUNNING on my VPS — never recommend these, or a near-identical alternative to one, unless it's a direct migration win you can justify in the sentence:
$(paste -sd', ' "$INV")"

cutoff60=$(date -u -d '60 days ago' +%F 2>/dev/null || date -u -v-60d +%F)
EXCLUDE=$(awk -F'\t' -v c="$cutoff60" '$1>=c{print "- "$3" ("$2")"}' "$SEEN" | tail -200)
DEDUP_BLOCK=""
[ -n "$EXCLUDE" ] && DEDUP_BLOCK="

ALREADY SHOWN in the last 60 days — do NOT repeat these repos unless something major changed (e.g. a big new release), in which case lead with what's NEW:
$EXCLUDE"

PROMPT="You are curating my weekly GitHub digest. Build ONE ranked pool across these two categories, ordering by genuine interest/quality — Hidden Gems & Self-Hosting leads by default:

Hidden Gems & Self-Hosting: underrated, well-built self-hosted/infra tools relevant to my stack
(Docker, Cloudflare Tunnel, nginx, Oracle Cloud VPS, JavaScript/TypeScript, Python, AI/LLM tooling,
e-learning/SCORM/xAPI). Explain briefly why it's a hidden gem, not just what it does.

A repo only counts as a hidden gem if it clears ONE of these two bars:
  (a) UNDER THE RADAR — roughly 5k stars or fewer. Genuinely good, not yet widely known.
  (b) FAST RISER — bigger than that, but young (under ~18 months) and growing fast
      (very roughly 1500+ stars/month), i.e. it EARNED the stars recently rather
      than accumulating them over five years. A breakout I'd regret missing counts,
      no matter how high the absolute star count has already climbed.
A famous, mature project (10k+ stars, years old, slow steady growth) is NEVER a hidden
gem here, however good it is — I already know about those. These bars are verified
against the GitHub API after you answer, so guessed star counts will not get anything
past the filter; if you're unsure a repo qualifies, include it and let the check decide.

Trending This Week: what's actually trending/new on GitHub right now, including outside my
stack if it's significant.

Rules:
- SKIP a category entirely if it genuinely has nothing worth including — no placeholder line, no sentence explaining why.
- Cap the WHOLE digest at ~10-12 repos total combined — signal over coverage, never pad.
- MAX 2 repos solving the same job. Over 17 weeks this digest has sent me ~8 different
  tunnel/NAT tools, ~9 different uptime monitors and ~9 different AI code-review tools —
  never the same URL twice, but the same recommendation over and over. A different repo
  answering a question I've already answered is a repeat. Prefer breadth across problems.
- Output one '## ' markdown section per category you're including, only for categories with content. Heading text = the category name exactly as given above (\"Hidden Gems & Self-Hosting\" or \"Trending This Week\"), nothing else added.
- Format every item EXACTLY as:  - **[owner/repo](https://github.com/owner/repo)** — one sentence on what it does and why it matters to me specifically. (★ star count if known)
- Consolidate forks/mirrors of the same project into one entry.
- No trailing \"Sources:\"/links list — every item already links its own repo. Do not repeat those links in a separate list at the end.
- No preamble, no closing remarks, no \"here's my final list\" or similar framing line. Your response must begin with the literal characters \"## \" — nothing before it, not even one sentence.$DEDUP_BLOCK"

log "curating weekly GitHub digest (excluding $(printf '%s' "$EXCLUDE" | grep -c .) recently-seen)..."
BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

# Enforce the gates against the live GitHub API: drops already-running tools, corrects
# hallucinated star counts, removes dead/archived/stale repos, caps per-category repeats,
# and keeps fast risers that a flat star ceiling would have thrown away.
GATED=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/gh_gate.py" "$INV" 2>>"$AGENT_LOG/github.log")
if [ -n "$(printf '%s' "$GATED" | grep -oE '^- \*\*\[')" ]; then
    BRIEF="$GATED"
else
    # Everything was filtered out. That is a real signal (it happened for 2026-07-28),
    # not a failure — say so plainly rather than emailing a hollow digest.
    log "all candidates filtered by gh_gate — sending nothing-this-week note"
    BRIEF="## Nothing worth your time this week

Every candidate this week was either something you already run, a mature project you'd
already know, or stale. No filler — the next issue will only arrive with real signal."
fi

today=$(date -u +%F)
printf '%s' "$BRIEF" | grep -oE '\[[^]]+\]\(https://github\.com/[^)]+\)' | while read -r pair; do
    n=$(printf '%s' "$pair" | sed -E 's/^\[([^]]*)\].*/\1/')
    u=$(printf '%s' "$pair" | sed -E 's/.*\((https:\/\/github\.com\/[^)]+)\)$/\1/')
    printf '%s\t%s\t%s\n' "$today" "$u" "$n" >> "$SEEN"
done
cutoff90=$(date -u -d '90 days ago' +%F 2>/dev/null || date -u -v-90d +%F)
awk -F'\t' -v c="$cutoff90" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

write_pkm "00 Capture/Daily/Agents/github-trending.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "GitHub Weekly" "$(date -u '+%A, %d %B %Y')")
# require_links guards against link-less hallucinated output. A deliberate
# nothing-this-week note has no links by design, so it bypasses that check.
case "$BRIEF" in
    "## Nothing worth your time this week"*) : ;;
    *) require_links "$HTML" || exit 1 ;;
esac
send_mail "GitHub Weekly — $(date -u '+%a %d %b')" "$HTML" html
log "done"
