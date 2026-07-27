#!/bin/bash
# Publishes new /opt/cryptex commits to the PUBLIC parthdhanani/homelab repo as a
# pull request — never as a direct push to master. A human merges.
#
# The public repo is not a separate sanitized copy: it is this same git history,
# pushed to a second remote. Secrets stay out via .gitignore (.env, secrets/, *.key)
# and the gitleaks gate below, not via a filter that could fall behind new file types.
#
# Two independent gates, deliberately redundant:
#   1. this script scans the exact commit range before pushing anything
#   2. core.hooksPath pre-push re-scans on the push itself
# Gate 1 exists because a PR branch on a public repo is already published — a gate
# that only ran at merge time would be too late.
#
# Run `homelab-sync.sh --selftest` to exercise the pure functions with no network.
set -uo pipefail

REPO=/opt/cryptex
REMOTE=github-public
SLUG=parthdhanani/homelab
BASE=master
LOG=/var/log/cryptex-homelab-sync.log
GITLEAKS_CONFIG=/home/ubuntu/.git-hooks/gitleaks-shared.toml

# Runs as ubuntu, which cannot create files in /var/log. The file is pre-created
# owned by ubuntu; this fallback covers a rotation that recreates it root-owned,
# where every log line would otherwise vanish into a failed redirect.
touch "$LOG" 2>/dev/null || LOG=/tmp/cryptex-homelab-sync.log

log() { echo "$(date '+%Y-%m-%d %H:%M') homelab-sync: $*" >> "$LOG"; }

# ── Pure functions (selftest-covered, no network) ────────────────────────────

# The github-public remote is configured with an SSH URL, but this box has no SSH key
# registered with GitHub (verified: `ssh -T git@github.com` → Permission denied).
# Unattended auth goes through the gh credential helper over HTTPS, so rewrite the
# scheme rather than editing the remote and breaking interactive use.
https_url() {
    local url="$1"
    case "$url" in
        git@github.com:*) printf 'https://github.com/%s' "${url#git@github.com:}" ;;
        ssh://git@github.com/*) printf 'https://github.com/%s' "${url#ssh://git@github.com/}" ;;
        *) printf '%s' "$url" ;;
    esac
}

# A sync branch is disposable and named for the day it was cut. Re-running on the same
# day must reuse the name so a second run updates the open PR instead of opening a
# second one against an identical diff.
branch_name() { printf 'sync/%s' "$(date -u '+%Y-%m-%d')"; }

# Subject line carries the count so the mail is readable without opening the PR.
pr_title() {
    local n="$1"
    if [ "$n" -eq 1 ]; then printf 'Sync 1 commit from cryptex'
    else printf 'Sync %s commits from cryptex' "$n"; fi
}

# GitHub does not notify you about your own actions, so an unannounced PR is the same
# end state as no sync at all: it sits open and the public repo stays stale. Called only
# when a NEW PR was opened — re-runs that merely update an existing branch return before
# this point, so a stack of commits over a week produces one mail, not seven.
# debt: sixth mail producer. Folds into the alert gateway at WP3 as severity=info,
# per AI_Space/docs/plans/2026-07-25-alerting-architecture.md.
notify_pr_opened() {
    local count="$1" url="$2" range="$3"
    local to="${ADMIN_EMAIL:-admin@${DOMAIN:-yourdomain.com}}"
    {
        printf 'To: %s\n' "$to"
        printf 'From: %s\n' "$to"
        printf 'Subject: [Cryptex] homelab PR ready to review (%s commits)\n' "$count"
        printf 'Content-Type: text/plain\n\n'
        printf '%s\n\n' "$url"
        printf 'Merging publishes these commits to the PUBLIC repo. gitleaks passed\n'
        printf 'before the branch was pushed, but read the diff: the gate catches\n'
        printf 'secret patterns, not something merely unwise to publish.\n\n'
        git log --oneline "$range" | head -50
    } | msmtp --from=default "$to" 2>/dev/null \
        || log "WARNING: PR opened at $url but notification email failed"
}

if [ "${1:-}" = "--selftest" ]; then
    fail=0
    check() { [ "$2" = "$3" ] || { echo "FAIL: $1 — got '$2' want '$3'"; fail=1; }; }
    check "ssh scp-form"  "$(https_url 'git@github.com:parthdhanani/homelab.git')" 'https://github.com/parthdhanani/homelab.git'
    check "ssh url-form"  "$(https_url 'ssh://git@github.com/parthdhanani/homelab.git')" 'https://github.com/parthdhanani/homelab.git'
    check "https passes"  "$(https_url 'https://github.com/parthdhanani/homelab.git')" 'https://github.com/parthdhanani/homelab.git'
    check "other host"    "$(https_url 'git@gitlab.com:x/y.git')" 'git@gitlab.com:x/y.git'
    check "branch shape"  "$(branch_name)" "sync/$(date -u '+%Y-%m-%d')"
    check "title 1"       "$(pr_title 1)"  'Sync 1 commit from cryptex'
    check "title 40"      "$(pr_title 40)" 'Sync 40 commits from cryptex'

    # Exercise the mail body without sending: shadow msmtp and log so notify_pr_opened
    # runs end to end against a stub. Catches the failure that matters here, which is a
    # mail that goes out addressed to the .env default because ADMIN_EMAIL was unset.
    msmtp() { cat > "$STUB_OUT"; }
    log() { :; }
    # git too: a live run is always inside $REPO, but --selftest can be invoked from
    # anywhere, and a bare `git log` there prints "not a git repository" to stderr.
    # Harmless, but it reads like a failure in cron mail.
    git() { echo "0000000 stub commit"; }
    STUB_OUT=$(mktemp)
    ADMIN_EMAIL=someone@example.com notify_pr_opened 3 'https://example.invalid/pull/1' 'HEAD..HEAD'
    grep -q '^To: someone@example.com$' "$STUB_OUT" || { echo "FAIL: notify honours ADMIN_EMAIL"; fail=1; }
    grep -q 'Subject: \[Cryptex\] homelab PR ready to review (3 commits)' "$STUB_OUT" || { echo "FAIL: notify subject/count"; fail=1; }
    grep -q 'https://example.invalid/pull/1' "$STUB_OUT" || { echo "FAIL: notify body carries PR url"; fail=1; }
    grep -q 'PUBLIC repo' "$STUB_OUT" || { echo "FAIL: notify body carries the public-repo warning"; fail=1; }
    DOMAIN=example.org ADMIN_EMAIL='' notify_pr_opened 1 'https://example.invalid/pull/2' 'HEAD..HEAD'
    grep -q '^To: admin@example.org$' "$STUB_OUT" || { echo "FAIL: notify falls back to DOMAIN"; fail=1; }
    rm -f "$STUB_OUT"

    [ $fail -eq 0 ] && echo "selftest: all assertions passed"
    exit $fail
fi

# ── Live run ─────────────────────────────────────────────────────────────────

# cron has a bare env; ADMIN_EMAIL/DOMAIN live in the stack .env (same pattern as
# cron-notify.sh). Without this any notification would go to admin@yourdomain.com.
set -a
source /opt/cryptex/.env 2>/dev/null || true
set +a

cd "$REPO" || { log "ERROR: $REPO unreachable"; exit 1; }

if ! command -v gitleaks >/dev/null 2>&1; then
    log "ERROR: gitleaks not installed — refusing to publish unscanned commits"
    echo "homelab-sync: gitleaks missing, refusing to push to a public repo" >&2
    exit 1
fi

git fetch -q "$REMOTE" 2>/dev/null || { log "ERROR: fetch $REMOTE failed"; exit 1; }

RANGE="$REMOTE/$BASE..$BASE"
COUNT=$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)

if [ "$COUNT" -eq 0 ]; then
    log "0 new commits, nothing to publish"
    exit 0
fi

# Divergence means someone committed on the public repo directly. Fast-forward is the
# only shape this script understands; anything else is a human's problem, not a cron's.
if ! git merge-base --is-ancestor "$REMOTE/$BASE" "$BASE"; then
    log "ERROR: $REMOTE/$BASE is not an ancestor of $BASE — diverged, needs a human"
    echo "homelab-sync: public repo has diverged from local $BASE. Not syncing." >&2
    exit 1
fi

if ! LEAKS=$(gitleaks git -c "$GITLEAKS_CONFIG" --log-opts "$RANGE" -v 2>&1); then
    log "BLOCKED: gitleaks found findings in $RANGE — nothing pushed"
    echo "homelab-sync BLOCKED: gitleaks flagged commits staged for the PUBLIC repo."
    echo "Range: $RANGE"
    echo
    echo "$LEAKS"
    exit 1
fi

BRANCH=$(branch_name)
URL=$(https_url "$(git remote get-url "$REMOTE")")

if ! PUSH_ERR=$(git push -q --force-with-lease "$URL" "$BASE:refs/heads/$BRANCH" 2>&1); then
    log "ERROR: push of $BRANCH failed"
    echo "homelab-sync: push failed"; echo "$PUSH_ERR"
    exit 1
fi

EXISTING=$(gh pr list --repo "$SLUG" --head "$BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null)

if [ -n "$EXISTING" ]; then
    log "$COUNT commit(s) pushed to $BRANCH, updated existing PR $EXISTING"
    echo "homelab-sync: updated $EXISTING with $COUNT commit(s)."
    exit 0
fi

BODY=$(printf 'Automated sync from `/opt/cryptex`. %s commit(s) since the last publish.\n\nScanned with gitleaks before the branch was pushed; no findings. Review the diff for anything that should not be public, then merge.\n\n```\n%s\n```\n' \
    "$COUNT" "$(git log --oneline "$RANGE" | head -50)")

if ! PR_URL=$(gh pr create --repo "$SLUG" --base "$BASE" --head "$BRANCH" \
        --title "$(pr_title "$COUNT")" --body "$BODY" 2>&1); then
    log "ERROR: branch $BRANCH pushed but PR creation failed"
    echo "homelab-sync: branch pushed, PR creation failed"; echo "$PR_URL"
    exit 1
fi

log "$COUNT commit(s) published as $BRANCH, PR opened: $PR_URL"
echo "homelab-sync: $COUNT commit(s) ready for review."
echo "$PR_URL"

notify_pr_opened "$COUNT" "$PR_URL" "$RANGE"
