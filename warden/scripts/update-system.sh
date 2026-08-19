#!/usr/bin/env bash
# System update sweep for jarvis TUI's "Updates" pane (apt/npm/pip/docker images).
#
# Design decisions (don't relitigate without re-reading these):
# - apt: full upgrade of everything apt reports upgradable. Safe by construction —
#   apt won't offer a package unless its deps resolve.
# - npm -g: `npm update -g` only ever bumps within what's already installed; it
#   won't add new globals. Safe.
# - pip: NEVER touch packages living in /usr/lib/python3/dist-packages — those are
#   apt-owned (python3-*) debs. Upgrading them via pip forks them from dpkg's
#   tracking and can desync the system Python (this box has PyGObject, dbus-python,
#   launchpadlib etc. wired into apt/software-properties). Only touch packages in
#   ~/.local/lib/python3.10/site-packages (pip --user installs).
# - pip: skip any package pip itself refuses to move because of a hard pin from
#   another installed package (pip's resolver will print a conflict) — don't force it.
# - docker images: this repo's update surface is Dockhand (sqlite at
#   /opt/cryptex/data/dockhand/db/dockhand.db, table pending_container_updates).
#   We only report what Dockhand has already detected; we do not pull/recreate
#   containers here — that's a deploy action, not a package update, and needs
#   per-service judgement (env vars, migrations, volumes).
#
# Usage: update-system.sh [--dry-run]
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

say() { printf '\n=== %s ===\n' "$1"; }

say "apt"
sudo apt-get update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1)
if [[ -z "$UPGRADABLE" ]]; then
    echo "nothing to upgrade"
else
    echo "$UPGRADABLE"
    if [[ $DRY_RUN -eq 0 ]]; then
        # shellcheck disable=SC2086
        sudo apt-get -y upgrade $UPGRADABLE
    fi
fi

say "npm -g"
if command -v npm >/dev/null; then
    npm outdated -g || true
    if [[ $DRY_RUN -eq 0 ]]; then
        npm update -g
    fi
else
    echo "npm not found, skipping"
fi

say "pip (--user only, apt-owned dist-packages skipped)"
PIP_OUTDATED_JSON=$(pip list --outdated --format=json 2>/dev/null || echo "[]")
USER_SITE="$HOME/.local/lib"
PIP_TARGETS=$(python3 - "$PIP_OUTDATED_JSON" "$USER_SITE" <<'PY'
import json, subprocess, sys
data = json.loads(sys.argv[1])
user_site = sys.argv[2]
targets = []
for pkg in data:
    name = pkg["name"]
    out = subprocess.run(["pip", "show", name], capture_output=True, text=True).stdout
    loc = ""
    for line in out.splitlines():
        if line.startswith("Location:"):
            loc = line.split(":", 1)[1].strip()
    if loc.startswith(user_site):
        targets.append(name)
print("\n".join(targets))
PY
)
if [[ -z "$PIP_TARGETS" ]]; then
    echo "nothing pip-user-owned to upgrade"
else
    echo "$PIP_TARGETS"
    if [[ $DRY_RUN -eq 0 ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            if ! pip install --user -U "$pkg" 2>&1 | tee /tmp/pip-upgrade-out.txt; then
                echo "  -> FAILED: $pkg (see above), skipped"
                continue
            fi
            if grep -qi "ERROR: pip's dependency resolver" /tmp/pip-upgrade-out.txt; then
                echo "  -> dependency conflict upgrading $pkg, reverting"
                orig=$(echo "$PIP_OUTDATED_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d:
    if p['name']=='$pkg':
        print(p['version'])
")
                [[ -n "$orig" ]] && pip install --user "$pkg==$orig" >/dev/null 2>&1
            fi
        done <<< "$PIP_TARGETS"
        rm -f /tmp/pip-upgrade-out.txt
    fi
fi

say "docker images (via Dockhand's own detection)"
DOCKHAND_DB="/opt/cryptex/data/dockhand/db/dockhand.db"
if [[ -f "$DOCKHAND_DB" ]]; then
    COUNT=$(sqlite3 "$DOCKHAND_DB" "SELECT COUNT(*) FROM pending_container_updates;" 2>/dev/null || echo 0)
    if [[ "$COUNT" -eq 0 ]]; then
        echo "no pending image updates per Dockhand"
    else
        sqlite3 -header -column "$DOCKHAND_DB" "SELECT container_name, current_image, checked_at FROM pending_container_updates;"
        echo "(review + pull/recreate manually per service — not automated here)"
    fi
else
    echo "Dockhand db not found at $DOCKHAND_DB, skipping"
fi

say "reboot check"
if [[ -f /var/run/reboot-required ]]; then
    echo "REBOOT REQUIRED:"
    cat /var/run/reboot-required.pkgs 2>/dev/null || true
else
    echo "no reboot required"
fi
