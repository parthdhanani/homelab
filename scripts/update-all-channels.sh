#!/bin/bash
# CRYPTEX — Update all channels
# Covers all 10 install channels. Add new standalones to standalone-tools.json only.
# Usage: sudo bash /opt/cryptex/scripts/update-all-channels.sh [--dry-run]

set +e

SCRIPT_DIR="/opt/cryptex/scripts"
LOG="/var/log/cryptex-update-all.log"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Determine the real user (may be running under sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Ensure log is writable
touch "$LOG" 2>/dev/null || LOG="/tmp/cryptex-update-all.log"

RED=$(tput setaf 1 2>/dev/null); GRN=$(tput setaf 2 2>/dev/null)
YEL=$(tput setaf 3 2>/dev/null); CYN=$(tput setaf 6 2>/dev/null)
BLD=$(tput bold 2>/dev/null); RST=$(tput sgr0 2>/dev/null)

UPDATED=(); SKIPPED=(); FAILED=()

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
hdr() { echo ""; echo "${BLD}── $1 ──────────────────────────────────────────${RST}"; }
ok()  { echo "  ${GRN}✓${RST} $1"; UPDATED+=("$1"); }
skip(){ echo "  ${CYN}·${RST} $1 (up to date)"; SKIPPED+=("$1"); }
fail(){ echo "  ${RED}✗${RST} $1"; FAILED+=("$1"); log "FAIL: $1"; }
dry() { echo "  ${YEL}~${RST} [dry-run] $1"; }

log "=== update-all-channels start ==="
[ $DRY_RUN -eq 1 ] && echo "${YEL}DRY RUN — no changes will be made${RST}"

# ── 1. Docker containers ──────────────────────────────────────────────────────
hdr "1/10  Docker containers"
if [ $DRY_RUN -eq 1 ]; then
    dry "docker compose pull + up -d"
    # Show any registry-pulled containers already running a stale digest
    while IFS= read -r cname; do
        running_img=$(docker inspect "$cname" --format '{{.Image}}' 2>/dev/null)
        img_tag=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null)
        has_remote=$(docker inspect "$img_tag" --format '{{len .RepoDigests}}' 2>/dev/null)
        [ "${has_remote:-0}" -eq 0 ] && continue  # skip locally-built images
        latest_img=$(docker inspect "$img_tag" --format '{{.Id}}' 2>/dev/null)
        if [ -n "$running_img" ] && [ -n "$latest_img" ] && [ "$running_img" != "$latest_img" ]; then
            dry "$cname running stale digest ($img_tag) — would restart"
        fi
    done < <(docker ps --format '{{.Names}}')
else
    cd /opt/cryptex
    if docker compose pull --ignore-buildable 2>&1 | tee -a "$LOG" | grep -q "Downloaded newer image"; then
        docker compose up -d --remove-orphans >> "$LOG" 2>&1 && ok "docker containers (new images)" || fail "docker compose up -d"
    else
        skip "docker containers (no new images)"
    fi
    # Restart any registry-pulled container still running a stale digest
    while IFS= read -r cname; do
        running_img=$(docker inspect "$cname" --format '{{.Image}}' 2>/dev/null)
        img_tag=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null)
        has_remote=$(docker inspect "$img_tag" --format '{{len .RepoDigests}}' 2>/dev/null)
        [ "${has_remote:-0}" -eq 0 ] && continue  # skip locally-built images
        latest_img=$(docker inspect "$img_tag" --format '{{.Id}}' 2>/dev/null)
        if [ -n "$running_img" ] && [ -n "$latest_img" ] && [ "$running_img" != "$latest_img" ]; then
            svc="${cname#cryptex-}"
            docker compose up -d "$svc" >> "$LOG" 2>&1 \
                && ok "$cname restarted (stale digest: $img_tag)" \
                || fail "restart $cname"
        fi
    done < <(docker ps --format '{{.Names}}')
fi

# ── 2. apt ────────────────────────────────────────────────────────────────────
hdr "2/10  apt packages"
if [ $DRY_RUN -eq 1 ]; then
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -vc "Listing")
    dry "apt upgrade ($UPGRADABLE packages upgradable)"
else
    BEFORE=$(dpkg -l | wc -l)
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1
    AFTER=$(dpkg -l | wc -l)
    [ "$AFTER" -ge "$BEFORE" ] && ok "apt packages" || fail "apt upgrade"
fi

# ── 3. npm globals (auto-discovered) ─────────────────────────────────────────
hdr "3/10  npm globals"
NPM_BIN=$(sudo -u "$REAL_USER" which npm 2>/dev/null || which npm 2>/dev/null || echo "/usr/bin/npm")
# Always run as the real user, never root
_npm() { sudo -u "$REAL_USER" "$NPM_BIN" "$@" 2>/dev/null; }

GLOBALS=$(_npm list -g --depth=0 --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for name in d.get('dependencies',{}).keys():
    print(name)
" 2>/dev/null)

if [ -z "$GLOBALS" ]; then
    fail "npm globals (could not read list — check $NPM_BIN exists)"
else
    for pkg in $GLOBALS; do
        CURRENT=$(_npm list -g --depth=0 --json 2>/dev/null | python3 -c "
import json,sys,os
d=json.load(sys.stdin)
print(d.get('dependencies',{}).get(os.environ['PKG'],{}).get('version',''))
" PKG="$pkg" 2>/dev/null)
        LATEST=$(_npm view "$pkg" version 2>/dev/null)
        if [ -z "$LATEST" ]; then
            fail "npm $pkg (registry unreachable)"
            continue
        fi
        if [ "$CURRENT" = "$LATEST" ]; then
            skip "npm $pkg@$CURRENT"
        elif [ $DRY_RUN -eq 1 ]; then
            dry "npm $pkg $CURRENT → $LATEST"
        else
            sudo -u "$REAL_USER" "$NPM_BIN" install -g "${pkg}@latest" >> "$LOG" 2>&1 \
                && ok "npm $pkg $CURRENT → $LATEST" || fail "npm $pkg"
        fi
    done
fi

# ── 4. pip --user (auto-discovered) ──────────────────────────────────────────
hdr "4/10  pip --user packages"
OUTDATED=$(pip list --user --outdated --format=json 2>/dev/null)
COUNT=$(echo "$OUTDATED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [ "$COUNT" -eq 0 ]; then
    skip "pip packages (all up to date)"
elif [ $DRY_RUN -eq 1 ]; then
    echo "$OUTDATED" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    print(f'  ~ [dry-run] pip {p[\"name\"]} {p[\"version\"]} → {p[\"latest_version\"]}')
" 2>/dev/null
else
    PKGS=$(echo "$OUTDATED" | python3 -c "import json,sys; print(' '.join(p['name'] for p in json.load(sys.stdin)))" 2>/dev/null)
    sudo -u "$REAL_USER" pip install --user --upgrade $PKGS >> "$LOG" 2>&1 && ok "pip: $COUNT packages updated" || fail "pip upgrade"
fi

# ── 5. Standalone binaries (manifest-driven) ─────────────────────────────────
hdr "5/10  Standalone binaries (/usr/local/bin)"
MANIFEST="$SCRIPT_DIR/standalone-tools.json"
TMPDIR_BIN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BIN"' EXIT

python3 - "$MANIFEST" "$DRY_RUN" <<'PYEOF'
import json, re, subprocess, sys, os, tarfile, zipfile, shutil, urllib.request, tempfile

manifest_path = sys.argv[1]
dry = sys.argv[2] == "1"
tools = json.load(open(manifest_path))
tmpdir = os.environ.get("TMPDIR_BIN", tempfile.mkdtemp())

GRN="\033[32m"; RED="\033[31m"; CYN="\033[36m"; YEL="\033[33m"; RST="\033[0m"

def gh_latest(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "update-script"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
            return data.get("tag_name","").lstrip("v"), data.get("assets",[])
    except Exception as e:
        return None, []

def current_ver(tool):
    try:
        out = subprocess.check_output(tool["version_cmd"].split(), stderr=subprocess.STDOUT, timeout=5).decode()
        line = out.strip().splitlines()[0]
        ver = line.replace(tool.get("version_strip",""), "").split()[0].lstrip("v")
        return ver
    except:
        return None

for t in tools:
    name = t["name"]
    note = t.get("note","")
    cur = current_ver(t)
    latest, assets = gh_latest(t["repo"])

    if not latest:
        print(f"  {RED}✗{RST} {name}: GitHub API unreachable")
        continue

    if cur and cur.lstrip("v") == latest.lstrip("v"):
        print(f"  {CYN}·{RST} {name}@{cur} (up to date)")
        continue

    pattern = t["asset_pattern"]
    asset = next((a for a in assets if re.search(pattern, a["name"])), None)
    if not asset:
        print(f"  {RED}✗{RST} {name}: no asset matching '{pattern}' in {t['repo']} {latest}")
        continue

    if dry:
        print(f"  {YEL}~{RST} [dry-run] {name} {cur or '?'} → {latest}")
        continue

    # Download
    dl_path = os.path.join(tmpdir, asset["name"])
    print(f"  ↓ {name} {cur or '?'} → {latest} ...", end="", flush=True)
    try:
        urllib.request.urlretrieve(asset["browser_download_url"], dl_path)
    except Exception as e:
        print(f"\n  {RED}✗{RST} {name}: download failed: {e}")
        continue

    # Extract
    binary_name = t["binary_in_archive"]
    extract_dir = os.path.join(tmpdir, name)
    os.makedirs(extract_dir, exist_ok=True)
    try:
        if dl_path.endswith(".zip"):
            with zipfile.ZipFile(dl_path) as z:
                for member in z.namelist():
                    if member.endswith(f"/{binary_name}") or member == binary_name:
                        z.extract(member, extract_dir)
                        break
        else:
            with tarfile.open(dl_path) as tf:
                for member in tf.getmembers():
                    if member.name.endswith(f"/{binary_name}") or member.name == binary_name:
                        member.name = os.path.basename(member.name)
                        tf.extract(member, extract_dir)
                        break
    except Exception as e:
        print(f"\n  {RED}✗{RST} {name}: extract failed: {e}")
        continue

    # Install
    extracted = os.path.join(extract_dir, binary_name.split("/")[-1])
    install_path = t["install_path"]
    try:
        os.chmod(extracted, 0o755)
        shutil.copy2(extracted, install_path)
        print(f" {GRN}✓{RST}")
        if note:
            print(f"    {note}")
    except PermissionError:
        # Try sudo cp
        r = subprocess.run(["sudo", "install", "-m", "755", extracted, install_path], capture_output=True)
        if r.returncode == 0:
            print(f" {GRN}✓{RST} (via sudo)")
            if note:
                print(f"    {note}")
        else:
            print(f"\n  {RED}✗{RST} {name}: install failed (permission denied)")
PYEOF

# ── 6. Native claude ──────────────────────────────────────────────────────────
hdr "6/10  Native claude (claude update)"
NATIVE_CLAUDE=$(ls "$REAL_HOME/.local/bin/claude" 2>/dev/null || echo "")
if [ -n "$NATIVE_CLAUDE" ]; then
    if [ $DRY_RUN -eq 1 ]; then
        dry "claude update"
    else
        sudo -u "$REAL_USER" "$REAL_HOME/.local/bin/claude" update >> "$LOG" 2>&1 \
            && ok "native claude" || skip "native claude (already latest)"
    fi
else
    skip "native claude (not installed — npm version only)"
fi

# ── 7. uv ─────────────────────────────────────────────────────────────────────
hdr "7/10  uv"
if command -v uv >/dev/null 2>&1; then
    BEFORE=$(uv --version 2>/dev/null)
    if [ $DRY_RUN -eq 1 ]; then
        dry "uv self update (current: $BEFORE)"
    else
        uv self update >> "$LOG" 2>&1
        AFTER=$(uv --version 2>/dev/null)
        [ "$BEFORE" != "$AFTER" ] && ok "uv $BEFORE → $AFTER" || skip "uv ($BEFORE)"
    fi
else
    skip "uv (not installed)"
fi

# ── 8. Pinned container tags (flag only) ──────────────────────────────────────
hdr "8/10  Pinned container tags"
echo "  Checking for pinned tags that have newer upstream versions..."
PINNED=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -v ':latest' | grep -v '@sha256:')
if [ -z "$PINNED" ]; then
    skip "no pinned-tag containers found"
else
    echo "$PINNED" | while IFS=' ' read -r cname image; do
        LOCAL=$(docker inspect --format '{{index .RepoDigests 0}}' "$cname" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
        [ -z "$LOCAL" ] && continue
        REMOTE=$(docker manifest inspect "$image" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if 'manifests' in d:
        for m in d['manifests']:
            if m.get('platform',{}).get('architecture')=='arm64':
                print(m['digest']); break
        else: print(d['manifests'][0]['digest'])
    elif 'config' in d: print(d['config']['digest'])
except: pass
" 2>/dev/null)
        if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
            echo "  ${YEL}!${RST} $cname ($image) has a newer upstream — edit tag in docker-compose.yml to update"
        else
            echo "  ${CYN}·${RST} $cname ($image) — current"
        fi
    done
fi

# ── 9. Claude plugin marketplaces ─────────────────────────────────────────────
hdr "9/10  Claude plugin marketplaces"
MKTPLACES_DIR="$REAL_HOME/.claude/plugins/marketplaces"
if [ -d "$MKTPLACES_DIR" ]; then
    for mdir in "$MKTPLACES_DIR"/*/; do
        mname=$(basename "$mdir")
        if [ -d "$mdir/.git" ]; then
            BEFORE=$(git -C "$mdir" rev-parse HEAD 2>/dev/null)
            if [ $DRY_RUN -eq 1 ]; then
                REMOTE=$(git -C "$mdir" ls-remote origin HEAD 2>/dev/null | cut -f1)
                [ "$BEFORE" != "$REMOTE" ] && dry "$mname has updates" || skip "$mname (up to date)"
            else
                git -C "$mdir" pull --quiet >> "$LOG" 2>&1
                AFTER=$(git -C "$mdir" rev-parse HEAD 2>/dev/null)
                [ "$BEFORE" != "$AFTER" ] && ok "$mname updated" || skip "$mname (up to date)"
            fi
        fi
    done
else
    skip "no plugin marketplace directory found"
fi

# ── 10. Docker cleanup ────────────────────────────────────────────────────────
hdr "10/10  Docker cleanup"
if [ $DRY_RUN -eq 1 ]; then
    DANGLING=$(docker images -f dangling=true -q 2>/dev/null | wc -l)
    CACHE_SIZE=$(docker system df --format '{{.BuildCacheSize}}' 2>/dev/null || echo "?")
    dry "docker image prune ($DANGLING dangling images) + builder prune (cache: $CACHE_SIZE)"
else
    IMG_FREED=$(docker image prune -f 2>/dev/null | grep "reclaimed" | grep -oP '[\d.]+ \w+B')
    BUILD_FREED=$(docker builder prune -f 2>/dev/null | grep "reclaimed" | grep -oP '[\d.]+ \w+B')
    FREED=""
    [ -n "$IMG_FREED" ]   && FREED+="images: $IMG_FREED"
    [ -n "$BUILD_FREED" ] && FREED+="${FREED:+, }cache: $BUILD_FREED"
    [ -n "$FREED" ] && ok "docker cleanup ($FREED)" || skip "docker cleanup (nothing to remove)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "${BLD}─────────────────────────────────────────────────${RST}"
echo "${BLD}Update summary${RST}"
echo "  ${GRN}Updated:${RST}  ${#UPDATED[@]} — ${UPDATED[*]:-none}"
echo "  ${CYN}Skipped:${RST}  ${#SKIPPED[@]} (already current)"
[ ${#FAILED[@]} -gt 0 ] && echo "  ${RED}Failed:${RST}   ${#FAILED[@]} — ${FAILED[*]}"
echo ""
log "=== update-all-channels complete: ${#UPDATED[@]} updated, ${#SKIPPED[@]} skipped, ${#FAILED[@]} failed ==="

# Notify n8n if anything failed
if [ ${#FAILED[@]} -gt 0 ]; then
    curl -sf --max-time 5 -X POST "http://172.18.0.8:5678/webhook/health-alert" \
        -H "Content-Type: application/json" \
        -d "{\"pass\":0,\"warn\":0,\"fail\":${#FAILED[@]},\"failed\":\"update-all-channels: ${FAILED[*]}\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >/dev/null 2>&1 || true
fi
