#!/bin/bash
# CRYPTEX — Transfer files to VPS from local Mac
# Usage: ./scripts/transfer-to-vps.sh [VPS_IP]

set -euo pipefail

SSH_KEY="${HOME}/.ssh/cryptex_vps"
SSH_USER="ubuntu"
REMOTE_DIR="/opt/cryptex"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Get VPS IP
if [ -n "${1:-}" ]; then
    VPS_IP="$1"
elif command -v terraform >/dev/null 2>&1 && [ -d "${LOCAL_DIR}/terraform" ]; then
    VPS_IP=$(cd "${LOCAL_DIR}/terraform" && terraform output -raw instance_public_ip 2>/dev/null || true)
fi

if [ -z "${VPS_IP:-}" ]; then
    echo "Usage: $0 <VPS_IP>"
    echo "  or run terraform apply first for auto-detection"
    exit 1
fi

echo ""
echo "CRYPTEX — Transfer to VPS"
echo "────────────────────────────"
echo "Target: ${SSH_USER}@${VPS_IP}:${REMOTE_DIR}"
echo "SSH key: ${SSH_KEY}"
echo ""

if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    echo "Generate: ssh-keygen -t ed25519 -f ${SSH_KEY}"
    exit 1
fi

# ControlMaster: one SSH connection, one passphrase prompt for all commands
CONTROL_PATH="/tmp/cryptex-ssh-%r@%h:%p"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=${CONTROL_PATH} -o ControlPersist=60"

# Ensure remote directory exists and is writable by ubuntu
# Only chown the dirs we write to — never database dirs (postgres=999, n8n=1000, etc.)
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "
    sudo mkdir -p ${REMOTE_DIR} && \
    sudo chown ${SSH_USER}:${SSH_USER} ${REMOTE_DIR} && \
    sudo mkdir -p \
        ${REMOTE_DIR}/data/portfolio \
        ${REMOTE_DIR}/data/aquasoul \
        ${REMOTE_DIR}/data/workstation/claude \
        ${REMOTE_DIR}/data/workstation/workspace \
        ${REMOTE_DIR}/data/workstation/vault \
        ${REMOTE_DIR}/data/moodle-uploads && \
    sudo chown -R ${SSH_USER}:${SSH_USER} \
        ${REMOTE_DIR}/data/portfolio \
        ${REMOTE_DIR}/data/aquasoul \
        ${REMOTE_DIR}/data/workstation/claude \
        ${REMOTE_DIR}/data/workstation/workspace \
        ${REMOTE_DIR}/data/workstation/vault \
        ${REMOTE_DIR}/data/moodle-uploads
"

# Transfer files
echo "Transferring project files..."
# shellcheck disable=SC2086
scp ${SSH_OPTS} -r \
    "${LOCAL_DIR}/docker-compose.yml" \
    "${LOCAL_DIR}/.env.example" \
    "${LOCAL_DIR}/configs" \
    "${LOCAL_DIR}/scripts" \
    "${LOCAL_DIR}/dockerfiles" \
    "${SSH_USER}@${VPS_IP}:${REMOTE_DIR}/"

# Transfer n8n workflow templates
echo "Transferring n8n workflow templates..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "mkdir -p ${REMOTE_DIR}/configs/n8n-workflows"
# shellcheck disable=SC2086
scp ${SSH_OPTS} "${LOCAL_DIR}"/configs/n8n-workflows/*.json "${SSH_USER}@${VPS_IP}:${REMOTE_DIR}/configs/n8n-workflows/"

# Make scripts executable
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "chmod +x ${REMOTE_DIR}/scripts/*.sh"

# Transfer Claude Code config (mounted as /root/.claude in workstation container)
# Source priority: project data/workstation/claude/ first, then ~/.claude fallback
CLAUDE_DEST="${REMOTE_DIR}/data/workstation/claude"
PROJECT_CLAUDE="${LOCAL_DIR}/data/workstation/claude"
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "mkdir -p ${CLAUDE_DEST}"

if [ -d "${PROJECT_CLAUDE}" ] && [ "$(ls -A "${PROJECT_CLAUDE}" 2>/dev/null)" ]; then
    # Use project-local claude config (version-controlled with the project)
    echo "Transferring Claude Code config (from project)..."
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} -r "${PROJECT_CLAUDE}/"* "${SSH_USER}@${VPS_IP}:${CLAUDE_DEST}/"
    echo "  Claude Code config transferred from data/workstation/claude/"
else
    # Fall back to ~/.claude on local Mac
    CLAUDE_SRC="${HOME}/.claude"
    echo "Transferring Claude Code config (from ~/.claude)..."
    for item in CLAUDE.md settings.json commands skills hooks templates; do
        if [ -e "${CLAUDE_SRC}/${item}" ]; then
            # shellcheck disable=SC2086
            scp ${SSH_OPTS} -r "${CLAUDE_SRC}/${item}" "${SSH_USER}@${VPS_IP}:${CLAUDE_DEST}/"
        fi
    done
    echo "  Claude Code config transferred (CLAUDE.md, settings.json, commands, skills, hooks, templates)"
fi

# Transfer portfolio site (data/portfolio/ in project)
PORTFOLIO_SRC="${LOCAL_DIR}/data/portfolio"
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "mkdir -p ${REMOTE_DIR}/data/portfolio"
if [ -d "$PORTFOLIO_SRC" ] && [ "$(ls -A "$PORTFOLIO_SRC" 2>/dev/null)" ]; then
    echo "Transferring portfolio..."
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} -r "${PORTFOLIO_SRC}/"* "${SSH_USER}@${VPS_IP}:${REMOTE_DIR}/data/portfolio/"
    echo "  Portfolio transferred ($(ls "$PORTFOLIO_SRC" | wc -l | tr -d ' ') files)"
else
    echo "SKIP: data/portfolio/ is empty — add your site files there"
fi

# Transfer AquaSoul Studio site (data/aquasoul/ in project)
AQUASOUL_SRC="${LOCAL_DIR}/data/aquasoul"
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "mkdir -p ${REMOTE_DIR}/data/aquasoul"
if [ -d "$AQUASOUL_SRC" ] && [ "$(ls -A "$AQUASOUL_SRC" 2>/dev/null)" ]; then
    echo "Transferring AquaSoul Studio site..."
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} -r "${AQUASOUL_SRC}/"* "${SSH_USER}@${VPS_IP}:${REMOTE_DIR}/data/aquasoul/"
    echo "  AquaSoul transferred ($(ls "$AQUASOUL_SRC" | wc -l | tr -d ' ') files)"
else
    echo "SKIP: data/aquasoul/ is empty — add your site files there"
fi

# Transfer SCORM import script (optional — only if it exists locally)
SCORM_SCRIPT="${LOCAL_DIR}/configs/moodle-scripts/scorm-import.php"
if [ -f "$SCORM_SCRIPT" ]; then
    echo "Transferring SCORM import script..."
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${VPS_IP}" "mkdir -p ${REMOTE_DIR}/data/moodle-uploads"
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "$SCORM_SCRIPT" "${SSH_USER}@${VPS_IP}:${REMOTE_DIR}/data/moodle-uploads/scorm-import.php"
    echo "  scorm-import.php → /opt/cryptex/data/moodle-uploads/"
fi

echo ""
echo "Transfer complete."
echo ""
echo "Next steps (SSH into VPS):"
echo "  ssh ${SSH_OPTS} ${SSH_USER}@${VPS_IP}"
echo "  cd ${REMOTE_DIR}"
echo "  ./scripts/setup-env.sh"
echo "  ./scripts/deploy.sh"
