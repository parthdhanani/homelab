#!/bin/bash
# Daily container update check — reports registry-pinned images whose upstream digest moved.
# Added to cron by infra-cleanup-2026-05-17. Rewritten 2026-07-25 (WP1 of the alerting plan,
# AI_Space/docs/plans/2026-07-25-alerting-architecture.md).
#
# Run `container-update-notify.sh --selftest` to exercise the pure functions with no Docker.
set +e

TO="${ADMIN_EMAIL:-admin@${DOMAIN:-yourdomain.com}}"
LOG=/var/log/cryptex-updates.log

# debt: flat-file dedup mirroring ops.sh last-warnings.txt. Replace with the `alert`
# gateway's SQLite state (WP2/WP3) — this file goes away when producers migrate.
STATE_FILE=/var/lib/cryptex-alerts/last-container-updates.txt

# sha256 of empty input — what `sha256sum` yields when a command printed nothing. Any
# derivation producing this means the upstream lookup failed, never that a digest matched.
EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

log() { echo "$(date '+%Y-%m-%d %H:%M') update-notify: $*" >> "$LOG"; }

# ── Pure functions (selftest-covered, no Docker) ─────────────────────────────

# A container started from a bare image ID has no registry reference to query. Docker
# prints these as 12- or 64-char hex. `cryptex-portfolio` (rollback/portfolio:prev) hit
# this and produced a permanent false positive from 2026-07-09 until this rewrite.
is_bare_image_id() {
    [[ "$1" =~ ^[0-9a-f]{12}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

# Strip the tag to get the repository, leaving digest refs and registry host:port alone
# (a colon after the last slash is a tag; a colon before it is a port).
image_repo() {
    local ref="$1"
    [[ "$ref" == *"@"* ]] && { printf '%s' "${ref%%@*}"; return; }
    if [[ "${ref##*/}" == *:* ]]; then printf '%s' "${ref%:*}"; else printf '%s' "$ref"; fi
}

# Choose the RepoDigests entry belonging to this image's own repository. An image can
# carry several, or one inherited from a different repo entirely — cryptex-portfolio's
# sole RepoDigest is `nginx@sha256:…`, which must never be compared against it. The
# previous version took `{{index .RepoDigests 0}}` unconditionally, so it did exactly that.
# stdin: newline-separated RepoDigests. $1: repo to match.
pick_repo_digest() {
    local repo="$1" line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "${line%%@*}" = "$repo" ]; then printf '%s' "${line#*@}"; return 0; fi
    done
    return 1
}

# Read the manifest-list digest from `docker buildx imagetools inspect` output. This is
# the authoritative value and is directly comparable to RepoDigests. Supersedes the
# previous `--raw | sha256sum` reconstruction — that computed the right answer on success,
# but on failure hashed an empty string into a plausible-looking digest.
parse_remote_digest() {
    local d
    d=$(grep -m1 -oE '^Digest:[[:space:]]+sha256:[0-9a-f]{64}' | grep -oE 'sha256:[0-9a-f]{64}')
    [ -z "$d" ] && return 1
    [ "$d" = "sha256:${EMPTY_SHA256}" ] && return 1
    printf '%s' "$d"
}

# ── Selftest ──────────────────────────────────────────────────────────────────
selftest() {
    local fail=0
    t() { # t <desc> <expected> <actual>
        if [ "$2" = "$3" ]; then echo "  ok   $1"
        else echo "  FAIL $1: expected '$2' got '$3'"; fail=1; fi
    }
    b() { # b <desc> <expect y|n> <cmd...>
        local desc="$1" want="$2"; shift 2
        if "$@"; then t "$desc" "$want" y; else t "$desc" "$want" n; fi
    }

    echo "is_bare_image_id:"
    b "12-char hex is bare"    y is_bare_image_id "92271ec46f10"
    b "64-char hex is bare"    y is_bare_image_id "$(printf 'a%.0s' {1..64})"
    b "tagged ref not bare"    n is_bare_image_id "redis:8-alpine"
    b "local name not bare"    n is_bare_image_id "cryptex-moodle"
    b "short hex word not bare" n is_bare_image_id "decade"

    echo "image_repo:"
    t "strips tag"          "redis"                  "$(image_repo redis:8-alpine)"
    t "keeps untagged"      "cryptex-moodle"         "$(image_repo cryptex-moodle)"
    t "keeps registry port" "reg.example.com:5000/x" "$(image_repo reg.example.com:5000/x:v1)"
    t "port, no tag"        "reg.example.com:5000/x" "$(image_repo reg.example.com:5000/x)"
    t "digest ref"          "redis"                  "$(image_repo redis@sha256:abc)"
    t "namespaced"          "pgvector/pgvector"      "$(image_repo pgvector/pgvector:pg16)"

    echo "pick_repo_digest:"
    t "matches own repo"        "sha256:aaa" "$(printf 'redis@sha256:aaa\n' | pick_repo_digest redis)"
    t "picks correct of several" "sha256:bbb" "$(printf 'nginx@sha256:aaa\nredis@sha256:bbb\n' | pick_repo_digest redis)"
    t "rejects foreign repo"    ""           "$(printf 'nginx@sha256:aaa\n' | pick_repo_digest rollback/portfolio)"
    t "rejects empty"           ""           "$(printf '' | pick_repo_digest redis)"

    echo "parse_remote_digest:"
    t "reads Digest line" "sha256:8096655e437712b07503796fb64d81359256cfcff0ab29d95a7da72863786efb" \
        "$(printf 'Name:      docker.io/library/redis:8-alpine\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    sha256:8096655e437712b07503796fb64d81359256cfcff0ab29d95a7da72863786efb\n' | parse_remote_digest)"
    t "empty input yields nothing"   "" "$(printf '' | parse_remote_digest)"
    t "error output yields nothing"  "" "$(printf 'ERROR: pull access denied, repository does not exist\n' | parse_remote_digest)"
    t "rejects empty-string hash"    "" "$(printf 'Digest:    sha256:%s\n' "$EMPTY_SHA256" | parse_remote_digest)"

    echo
    [ $fail -eq 0 ] && { echo "selftest: PASS"; return 0; }
    echo "selftest: FAIL"; return 1
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ── Scan ──────────────────────────────────────────────────────────────────────
UPDATES=()
SKIPPED=0

while IFS=' ' read -r CNAME IMAGE; do
    [ -z "$CNAME" ] && continue

    # Digest-pinned: cannot drift by definition.
    [[ "$IMAGE" == *"@sha256:"* ]] && continue
    # :latest is unpinned — Dockhand surfaces these visually; chasing them here is noise.
    [[ "$IMAGE" == *":latest"* ]] && continue
    # Locally-built images referenced by ID: no registry to ask.
    if is_bare_image_id "$IMAGE"; then SKIPPED=$((SKIPPED+1)); continue; fi

    REPO=$(image_repo "$IMAGE")

    LOCAL_DIGEST=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null \
        | pick_repo_digest "$REPO")
    # No digest for this repo => never pulled from a registry under this name (locally built).
    if [ -z "$LOCAL_DIGEST" ]; then SKIPPED=$((SKIPPED+1)); continue; fi

    # Guard on exit status, not on the shape of the output. The previous version tested
    # the derived string against "sha256:", which never matched because a failed lookup
    # produced "sha256:<empty-string-hash>" instead — so every unreachable image was
    # reported as an available update, every day, forever.
    RAW=$(docker buildx imagetools inspect "$IMAGE" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$RAW" ]; then SKIPPED=$((SKIPPED+1)); continue; fi

    REMOTE_DIGEST=$(printf '%s\n' "$RAW" | parse_remote_digest)
    if [ -z "$REMOTE_DIGEST" ]; then SKIPPED=$((SKIPPED+1)); continue; fi

    [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ] && UPDATES+=("  $CNAME  →  $IMAGE")
done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)

# Cron runs this as root; manual runs and --selftest are ubuntu. The state dir is
# setgid root:ubuntu, so umask 002 keeps a recreated state file group-writable and both
# callers can maintain it. Without this a root-created 644 file would silently force
# every later ubuntu run to fail open and re-notify.
umask 002
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

if [ ${#UPDATES[@]} -eq 0 ]; then
    # Clear state so a re-appearing update notifies again rather than staying suppressed.
    : > "$STATE_FILE"
    log "0 update(s), $SKIPPED image(s) not registry-comparable, no email"
    exit 0
fi

# ── Dedup ─────────────────────────────────────────────────────────────────────
# Only notify about updates not already reported. Order-independent, and a missing or
# unreadable state file fails OPEN (treat everything as new) rather than going silent.
CURRENT=$(printf '%s\n' "${UPDATES[@]}" | sort)
NEW="$CURRENT"
if [ -r "$STATE_FILE" ]; then
    NEW=$(comm -13 "$STATE_FILE" <(printf '%s\n' "$CURRENT"))
fi
printf '%s\n' "$CURRENT" > "$STATE_FILE" || log "WARN: could not write $STATE_FILE — next run fails open"

if [ -z "$NEW" ]; then
    log "${#UPDATES[@]} update(s) pending, all previously reported — no email"
    exit 0
fi

NEW_COUNT=$(printf '%s\n' "$NEW" | grep -c .)
BODY=$(
    echo "New since last report:"
    echo ""
    printf '%s\n' "$NEW" | sed 's/^  */- /'
    echo ""
    echo "All pending (${#UPDATES[@]}):"
    echo ""
    printf '%s\n' "$CURRENT" | sed 's/^  */- /'
    echo ""
    echo "Review at https://docker.${DOMAIN:-yourdomain.com}"
    echo "Run update: bash /opt/cryptex/update.sh"
)
/home/ubuntu/.claude/scripts/notify.sh "Container updates available ($(date +%Y-%m-%d))" "$BODY" warning

log "$NEW_COUNT new of ${#UPDATES[@]} pending, $SKIPPED not comparable, email sent"
