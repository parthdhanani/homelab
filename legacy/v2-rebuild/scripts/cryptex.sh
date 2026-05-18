#!/bin/bash
# CRYPTEX — Master Setup Script
# One script to provision, transfer, and deploy everything.
# Run from local Mac: cd ~/cryptex-rebuild && ./scripts/cryptex.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo "CRYPTEX — Full Deployment"
echo "════════════════════════════════════════════════════"
echo ""
echo "  Step 1: Terraform (provision VPS)"
echo "  Step 2: Wait for cloud-init (~5 min)"
echo "  Step 3: Transfer files to VPS"
echo "  Step 4: SSH → setup-env.sh → deploy.sh"
echo ""

read -rp "Start from which step? (1/2/3/4) [1]: " step

# ── Helper: Get VPS IP from terraform ──

get_vps_ip() {
    if [ -n "${VPS_IP:-}" ]; then
        return
    fi
    if command -v terraform >/dev/null 2>&1 && [ -d "${PROJECT_DIR}/terraform" ]; then
        VPS_IP=$(cd "${PROJECT_DIR}/terraform" && terraform output -raw instance_public_ip 2>/dev/null || true)
    fi
    if [ -z "${VPS_IP:-}" ]; then
        read -rp "VPS IP address: " VPS_IP
    fi
}

# ── Step functions ──

do_step1() {
    echo ""
    echo "── Step 1: Provision VPS ──"
    echo ""
    "${SCRIPT_DIR}/setup-terraform.sh" || true

    # If terraform wasn't run by setup-terraform.sh, offer to run it now
    if ! cd "${PROJECT_DIR}/terraform" && terraform output -raw instance_public_ip >/dev/null 2>&1; then
        echo ""
        read -rp "Run 'terraform apply' now? (Y/n): " run_tf
        if [[ "${run_tf}" != "n" && "${run_tf}" != "N" ]]; then
            cd "${PROJECT_DIR}/terraform"
            terraform init -input=false 2>/dev/null || true
            terraform apply
        fi
    fi
    cd "${PROJECT_DIR}"

    # Get IP from terraform output
    get_vps_ip
    echo ""
    echo "VPS IP: ${VPS_IP}"
    echo ""
    echo "── Step 2: Waiting for cloud-init ──"
    echo ""
    echo "The VPS needs ~5 minutes to install Docker, configure firewall, etc."
    echo "Cloud-init will reboot the VPS when done."
    echo ""
    read -rp "Wait 5 minutes automatically? (Y/n): " do_wait
    if [[ "${do_wait}" != "n" && "${do_wait}" != "N" ]]; then
        for i in $(seq 300 -30 0); do
            printf "\r  Waiting... %d seconds remaining  " "$i"
            sleep 30
        done
        echo ""
        echo ""
        echo "Checking if VPS is reachable..."
        for i in $(seq 1 10); do
            if ssh -i ~/.ssh/cryptex_vps -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${VPS_IP}" "echo ok" >/dev/null 2>&1; then
                echo "  VPS is up."
                break
            fi
            if [ "$i" -eq 10 ]; then
                echo "  VPS not reachable yet. It may still be rebooting."
                echo "  Try again in a minute or proceed to step 3."
            fi
            sleep 10
        done
    fi
    # Continue to step 3
    do_step3
}

do_step3() {
    echo ""
    echo "── Step 3: Transfer files ──"
    echo ""
    get_vps_ip
    "${SCRIPT_DIR}/transfer-to-vps.sh" "$VPS_IP"
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "Files transferred. SSH in and complete setup:"
    echo ""
    echo "  ssh -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP}"
    echo "  cd /opt/cryptex"
    echo "  ./scripts/setup-env.sh"
    echo "  ./scripts/deploy.sh"
    echo "════════════════════════════════════════════════════"
}

case ${step:-1} in
    1)
        do_step1
        ;;
    2)
        echo ""
        echo "── Step 2: Wait for cloud-init ──"
        get_vps_ip
        echo "Waiting 5 minutes for cloud-init on ${VPS_IP}..."
        sleep 300
        echo "Done waiting. Proceeding to step 3..."
        do_step3
        ;;
    3)
        do_step3
        ;;
    4)
        echo ""
        echo "── Step 4: Remote setup ──"
        get_vps_ip
        echo ""
        echo "SSH into VPS and run:"
        echo "  ssh -i ~/.ssh/cryptex_vps ubuntu@${VPS_IP}"
        echo "  cd /opt/cryptex"
        echo "  ./scripts/setup-env.sh"
        echo "  ./scripts/deploy.sh"
        ;;
    *)
        echo "Invalid step. Choose 1-4."
        exit 1
        ;;
esac
