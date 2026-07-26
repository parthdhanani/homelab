#!/bin/bash
# duel.sh — weekly taste-duel invite (Sun evening IST).
# Sends TWO posters and one link. Deliberately not a vote-per-link design: mail scanners
# and Gmail's image/link prefetch issue GETs on anything in the body, which would cast
# votes Parth never made. The link opens the app; votes are POSTs from that page.
# One click therefore also chains into unlimited pairs instead of a single verdict.
JOB=duel
source "$(dirname "$0")/../lib/common.sh"

DUEL_DIR=/opt/cryptex/duel
RANK="$PKM/50 Collections/Movies/🏆 Taste Ranking.md"

[ -x "$DUEL_DIR/duel.py" ] || { log "duel.py missing"; exit 0; }
systemctl is-active --quiet duel.service || { log "duel.service not active — not sending a dead link"; exit 1; }

TOKEN=$(python3 "$DUEL_DIR/duel.py" --token) || { log "token generation failed"; exit 1; }
# psidex.com/d/ not watch.psidex.com: watch.* is behind Cloudflare Access, and a mail
# client that isn't logged in would bounce to a CF login page instead of the duel.
# The token IS the auth for this path. watch.* is the browsable surface (link below).
URL="https://psidex.com/d/?t=$TOKEN"
LIST_URL="https://watch.psidex.com/list/movies"

# Pull the same pair the app would show, so the email previews real posters.
PAIR=$(python3 - <<'PY'
import json, sys
sys.path.insert(0, "/opt/cryptex/duel")
import duel
films, ratings = duel.load_films(), duel.load_ratings()
pair = duel.pick_pair(films, ratings)
if not pair:
    sys.exit(1)
a, b = (films[x] for x in pair)
voted = sum(r["n"] for r in ratings.values()) // 2
print(json.dumps({"a": a, "b": b, "voted": voted, "total": len(films),
                  "rated": len(ratings)}))
PY
) || { log "no pair available (need >=2 watched films)"; exit 0; }

A_T=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["a"]["title"])')
B_T=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["b"]["title"])')
A_P=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["a"]["poster"] or "")')
B_P=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["b"]["poster"] or "")')
A_Y=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["a"]["year"] or "")')
B_Y=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["b"]["year"] or "")')
VOTED=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["voted"])')
RATED=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rated"])')
TOTAL=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')

# Current top 3, if any votes exist yet — makes the email worth opening even without voting.
TOP=""
if [ "$VOTED" -gt 0 ] && [ -f "$RANK" ]; then
    TOP=$(grep -E '^\| [0-9]+ \|' "$RANK" | head -3 \
        | sed -E 's/^\| ([0-9]+) \| \[\[[^|]*\\\|([^]]*)\]\][^|]*\| ([0-9]+) .*/\1. \2 — \3/')
fi

poster_cell() {  # $1=url $2=title $3=year
    if [ -n "$1" ]; then
        printf '<td width="50%%" align="center" style="padding:6px"><img src="%s" width="200" style="border-radius:10px;display:block;border:1px solid #26262a"><div style="font:600 15px sans-serif;color:#e8e8e6;margin-top:9px">%s</div><div style="font:13px sans-serif;color:#8a8a94">%s</div></td>' "$1" "$2" "$3"
    else
        printf '<td width="50%%" align="center" style="padding:6px"><div style="width:200px;height:300px;background:#1c1c20;border:1px solid #26262a;border-radius:10px;display:inline-block;line-height:300px;color:#8a8a94;font:13px sans-serif">no poster</div><div style="font:600 15px sans-serif;color:#e8e8e6;margin-top:9px">%s</div><div style="font:13px sans-serif;color:#8a8a94">%s</div></td>' "$2" "$3"
    fi
}

TOP_HTML=""
[ -n "$TOP" ] && TOP_HTML="<div style=\"font:13px sans-serif;color:#8a8a94;margin-top:26px;line-height:1.7\"><b style=\"color:#c8c8cc\">Leaderboard so far</b><br>$(printf '%s' "$TOP" | sed 's/$/<br>/')</div>"

BODY=$(cat <<HTML
<div style="background:#0b0b0c;padding:30px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">
<div style="max-width:520px;margin:0 auto;text-align:center">
  <div style="font:13px sans-serif;letter-spacing:.14em;text-transform:uppercase;color:#6a6a74">Taste duel</div>
  <div style="font:600 19px sans-serif;color:#e8e8e6;margin:8px 0 20px">Which would you rather rewatch tonight?</div>
  <table width="100%" cellpadding="0" cellspacing="0"><tr>
    $(poster_cell "$A_P" "$A_T" "$A_Y")
    $(poster_cell "$B_P" "$B_T" "$B_Y")
  </tr></table>
  <div style="margin:24px 0 8px">
    <a href="$URL" style="background:#e8e8e6;color:#0b0b0c;text-decoration:none;font:600 15px sans-serif;padding:13px 30px;border-radius:10px;display:inline-block">Pick one →</a>
  </div>
  <div style="font:13px sans-serif;color:#6a6a74;line-height:1.6;margin-top:12px">
    One tap per pair, keeps going as long as you do.<br>
    $VOTED votes so far · $RATED of $TOTAL watched films ranked
  </div>
  $TOP_HTML
  <div style="font:12.5px sans-serif;color:#6a6a74;margin-top:20px">
    <a href="$LIST_URL" style="color:#8a8a94">Browse the full list</a>
    &nbsp;·&nbsp;
    <a href="https://watch.psidex.com/notes/taste-map" style="color:#8a8a94">Taste map</a>
    &nbsp;·&nbsp;
    <a href="https://watch.psidex.com/notes/til" style="color:#8a8a94">TIL</a>
  </div>
  <div style="font:11.5px sans-serif;color:#4a4a52;margin-top:22px;line-height:1.6">
    Link expires in 21 days. Ranking lives in the vault at<br>Collections/Movies/🏆 Taste Ranking.md
  </div>
</div></div>
HTML
)

send_mail "🎬 Taste duel — $A_T vs $B_T" "$BODY" html
log "sent duel invite ($A_T vs $B_T), $VOTED votes so far"
