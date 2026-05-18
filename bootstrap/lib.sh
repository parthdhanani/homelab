# shellcheck shell=bash
# Shared helpers for bootstrap/*.sh
# Source this file: . "$(dirname "$0")/lib.sh"
# All helpers are idempotent and safe to re-run.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/cryptex}"
LOG_DIR="${LOG_DIR:-/var/log/cryptex-bootstrap}"
sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR" 2>/dev/null || true

# ---------- logging ----------
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()   { printf '\033[1;34m[%s] %s\033[0m\n' "$(_ts)" "$*" >&2; }
ok()    { printf '\033[1;32m[%s] OK %s\033[0m\n' "$(_ts)" "$*" >&2; }
skip()  { printf '\033[1;33m[%s] -- %s\033[0m\n' "$(_ts)" "$*" >&2; }
warn()  { printf '\033[1;33m[%s] WARN %s\033[0m\n' "$(_ts)" "$*" >&2; }
fail()  { printf '\033[1;31m[%s] FAIL %s\033[0m\n' "$(_ts)" "$*" >&2; exit 1; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    fail "must be run as root (use sudo)"
  fi
}

require_user() {
  if [ "$EUID" -eq 0 ]; then
    fail "must NOT be run as root; run as the ubuntu user"
  fi
}

# ---------- idempotent primitives ----------

# Install apt package only if not present.
ensure_apt() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    skip "apt: $pkg already installed"
  else
    log "apt install: $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null
    ok "apt installed: $pkg"
  fi
}

# Install a list of apt packages, batched.
ensure_apt_batch() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    skip "apt batch: all ${#@} packages already installed"
    return
  fi
  log "apt install (batch): ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  ok "apt batch installed: ${#missing[@]} package(s)"
}

# Copy file with check-before-write, preserve mode/owner from src dir.
# install_file <src> <dst> [mode] [owner]
install_file() {
  local src="$1" dst="$2" mode="${3:-}" owner="${4:-}"
  [ -f "$src" ] || fail "install_file: source missing: $src"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    skip "file: $dst up to date"
  else
    local dstdir
    dstdir="$(dirname "$dst")"
    mkdir -p "$dstdir"
    cp "$src" "$dst"
    [ -n "$mode" ] && chmod "$mode" "$dst"
    [ -n "$owner" ] && chown "$owner" "$dst"
    ok "file: installed $dst"
  fi
}

# Ensure a line exists in a file (append if absent).
ensure_line() {
  local line="$1" file="$2"
  if [ -f "$file" ] && grep -qF -- "$line" "$file"; then
    skip "line: present in $file"
  else
    echo "$line" | tee -a "$file" >/dev/null
    ok "line: appended to $file"
  fi
}

# Ensure a systemd unit is installed AND enabled.
ensure_systemd_unit() {
  local unit="$1"
  local src="$REPO_ROOT/system/systemd/$unit"
  local dst="/etc/systemd/system/$unit"
  [ -f "$src" ] || fail "ensure_systemd_unit: missing $src"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    skip "systemd: $unit unchanged"
  else
    install -m 644 "$src" "$dst"
    systemctl daemon-reload
    ok "systemd: installed $unit"
  fi
  # Enable if it's a service or timer (not socket etc.)
  case "$unit" in
    *.service|*.timer)
      if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        skip "systemd: $unit already enabled"
      else
        systemctl enable --quiet "$unit"
        ok "systemd: enabled $unit"
      fi
      # Start if not running (timers + services)
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        skip "systemd: $unit already active"
      else
        systemctl start "$unit" || warn "systemd: failed to start $unit (will retry on next boot)"
      fi
      ;;
  esac
}

# Ensure a crontab block is installed for a given user.
# install_cron <user> <source-crontab-file>
install_cron() {
  local user="$1" src="$2"
  [ -f "$src" ] || fail "install_cron: missing $src"
  local current new
  current="$(crontab -u "$user" -l 2>/dev/null || true)"
  new="$(cat "$src")"
  if [ "$current" = "$new" ]; then
    skip "cron: $user crontab unchanged"
  else
    echo "$new" | crontab -u "$user" -
    ok "cron: installed for $user"
  fi
}

# Ensure a directory exists with owner.
ensure_dir() {
  local d="$1" owner="${2:-}"
  if [ -d "$d" ]; then
    skip "dir: $d exists"
  else
    mkdir -p "$d"
    ok "dir: created $d"
  fi
  [ -n "$owner" ] && chown "$owner" "$d" 2>/dev/null || true
}

# Ensure a symlink points where we want.
ensure_symlink() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skip "symlink: $dst -> $src"
  else
    [ -e "$dst" ] && [ ! -L "$dst" ] && fail "symlink: $dst exists and is not a symlink"
    ln -snf "$src" "$dst"
    ok "symlink: $dst -> $src"
  fi
}

# Confirm a container is running.
container_healthy() {
  local name="$1"
  docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null | grep -q healthy
}

container_running() {
  local name="$1"
  docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null | grep -q true
}

wait_for_container() {
  local name="$1" timeout="${2:-120}"
  log "waiting up to ${timeout}s for $name..."
  for ((i=0; i<timeout; i+=2)); do
    if container_healthy "$name" || container_running "$name"; then
      ok "$name up"
      return 0
    fi
    sleep 2
  done
  warn "$name did not become ready within ${timeout}s"
  return 1
}
