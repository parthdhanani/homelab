#!/usr/bin/env bash
# fleet-verify.sh — weekly guardian: ensure every GitHub-DR repo is committed AND
# pushed. Auto-pushes repos that are ahead (already committed, just not pushed) over
# gh HTTPS token WITHOUT changing the repo's configured remote. Anything still
# uncommitted or unpushed -> Telegram alert. Never auto-commits (that would be unsafe).
# Also triggers pkm-github-sync so the KB stays current. Runs as ubuntu.
set -uo pipefail

[ -f /opt/cryptex/.env ] && { set -a; . /opt/cryptex/.env 2>/dev/null; set +a; }
alert() {
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -sf --max-time 8 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

mapfile -t REPOS < <(find /home /opt -name .git \( -type d -o -type f \) 2>/dev/null \
  | sed 's#/\.git$##' \
  | grep -vE '/\.cache/|/\.claude/jobs/|/plugins/marketplaces/|/node_modules/|/\.git\.local-backup|/\.gemini/antigravity-cli/brain/' \
  | sort -u)

problems=""
for r in "${REPOS[@]}"; do
  case "$r" in /opt/cryptex|/opt/cryptex/data/pkm) continue;; esac   # Kopia-DR, git dirtiness expected
  br=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
  slug=$(git -C "$r" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')
  dirty=$(git -C "$r" status --porcelain 2>/dev/null | grep -c .)
  lh=$(git -C "$r" rev-parse HEAD 2>/dev/null)
  rh=$(gh api "repos/${slug}/commits/${br}" --jq .sha 2>/dev/null || true)

  if [ -z "$slug" ]; then problems+=$'\n'"NO REMOTE: $(basename "$r")"; continue; fi
  # push already-committed-but-unpushed work
  if [ "$lh" != "$rh" ] && [ "$dirty" = 0 ]; then
    git -C "$r" push -q "https://github.com/${slug}.git" "$br" 2>/dev/null \
      && { echo "pushed $slug:$br"; rh=$lh; } \
      || problems+=$'\n'"PUSH FAILED: $slug:$br"
  fi
  [ "$dirty" -gt 0 ] && problems+=$'\n'"UNCOMMITTED ($dirty): $(basename "$r")"
  [ "$lh" != "$rh" ] && [ "$dirty" = 0 ] && problems+=$'\n'"UNPUSHED: $slug:$br"
done

/opt/cryptex/scripts/pkm-github-sync.sh >/dev/null 2>&1 || problems+=$'\n'"pkm-github-sync failed"

if [ -n "$problems" ]; then
  alert "⚠️ fleet-verify: not fully on GitHub:${problems}"
  echo "PROBLEMS:${problems}"; exit 1
fi
echo "fleet-verify: all GitHub-DR repos committed and pushed."
