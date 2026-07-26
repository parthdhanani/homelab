#!/bin/bash
# test_pick.sh — the pick-title regex in jobs/movies.sh, isolated. It silently matched
# nothing on TV series (year ranges, en-dash) which killed repeat-suppression for that
# collection without any error. Keep this in sync with YEARPAT in movies.sh.
YEARPAT='\([0-9]{4}([–—-] *[0-9]{0,4})?\)'
extract() { printf '%s' "$1" | grep -oE "\*\*[^(]+$YEARPAT\*\*" | head -1 | sed -E "s/\*\*//g;s/ *$YEARPAT *\$//"; }
check() { got=$(extract "$1"); [ "$got" = "$2" ] && echo "ok: [$got]" || { echo "FAIL: got [$got] want [$2]"; exit 1; }; }
check '- ![](x) **The Leftovers (2014–2017)** — Drama' 'The Leftovers'
check '- ![](x) **In This Corner of the World (2016)** — Anime' 'In This Corner of the World'
check '- **Better Call Saul (2015—2022)** — Drama' 'Better Call Saul'
check '- **Severance (2022- )** — Drama' 'Severance'
check '- **Dark (2017-2020)** — Sci-Fi' 'Dark'
echo "== PICK PARSE OK =="
