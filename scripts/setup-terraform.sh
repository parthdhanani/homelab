#!/bin/bash
# CRYPTEX — Interactive Terraform Setup
# Checks for + installs required tools, then generates terraform.tfvars
# Run from local Mac: cd ~/cryptex-rebuild && ./scripts/setup-terraform.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
TFVARS_FILE="${TF_DIR}/terraform.tfvars"
OCI_CONFIG="${HOME}/.oci/config"

# ────────────────────────────────────────
# Helpers
# ────────────────────────────────────────

prompt() {
    local var_name="$1" prompt_text="$2" default="$3"
    local value
    if [ -n "$default" ]; then
        read -rp "  ${prompt_text} [${default}]: " value
        printf -v "$var_name" '%s' "${value:-$default}"
    else
        read -rp "  ${prompt_text}: " value
        printf -v "$var_name" '%s' "$value"
    fi
}

check_or_install() {
    local tool="$1"        # binary name to check
    local brew_pkg="$2"    # homebrew package name (may differ from binary)
    local version_flag="${3:---version}"

    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ✓ ${tool} already installed: $($tool $version_flag 2>&1 | head -1)"
        return 0
    fi

    echo "  ✗ ${tool} not found."

    # Try Homebrew (macOS)
    if command -v brew >/dev/null 2>&1; then
        echo "    Installing via Homebrew: brew install ${brew_pkg}..."
        brew install "$brew_pkg"
        echo "    ✓ ${tool} installed."
        return 0
    fi

    # Homebrew itself not found
    echo ""
    echo "  Homebrew not found. Installing Homebrew first..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add brew to PATH for this session (Apple Silicon path)
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    echo "    Installing via Homebrew: brew install ${brew_pkg}..."
    brew install "$brew_pkg"
    echo "    ✓ ${tool} installed."
}

# ────────────────────────────────────────
# 1. Tool checks + installs
# ────────────────────────────────────────

echo ""
echo "CRYPTEX — Terraform Setup"
echo "────────────────────────────"
echo ""
echo "Checking required tools..."
echo ""

check_or_install "terraform" "terraform" "version"
check_or_install "oci"       "oci-cli"   "--version"
check_or_install "ssh-keygen" "openssh"  "-V"

echo ""

# ────────────────────────────────────────
# 2. OCI CLI config — set up if missing
# ────────────────────────────────────────

if [ ! -f "$OCI_CONFIG" ]; then
    echo "── OCI CLI Config ──"
    echo "  ~/.oci/config not found. Running 'oci setup config'..."
    echo "  This generates your API key pair and ~/.oci/config."
    echo ""
    echo "  After setup, upload the PUBLIC key to:"
    echo "  OCI Console → Profile (top right) → API Keys → Add API Key → Paste public key"
    echo ""
    read -rp "  Run oci setup config now? [Y/n]: " run_oci_setup
    if [[ "$run_oci_setup" != "n" && "$run_oci_setup" != "N" ]]; then
        oci setup config
        echo ""
        echo "  ✓ OCI config created at ~/.oci/config"
        echo "  Remember to upload the public key to OCI Console before terraform apply."
    fi
    echo ""
else
    echo "  ✓ OCI config found at ~/.oci/config"

    # Parse existing config for defaults
    EXISTING_TENANCY=$(grep '^tenancy=' "$OCI_CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | xargs || true)
    EXISTING_USER=$(grep '^user=' "$OCI_CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | xargs || true)
    EXISTING_FINGERPRINT=$(grep '^fingerprint=' "$OCI_CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | xargs || true)
    EXISTING_KEY_FILE=$(grep '^key_file=' "$OCI_CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | xargs || true)
    EXISTING_REGION=$(grep '^region=' "$OCI_CONFIG" 2>/dev/null | head -1 | cut -d= -f2 | xargs || true)

    if [ -n "$EXISTING_TENANCY" ]; then
        echo "    Auto-detected credentials from ~/.oci/config"
    fi
fi

# ────────────────────────────────────────
# 3. Existing tfvars check
# ────────────────────────────────────────

if [ -f "$TFVARS_FILE" ]; then
    echo ""
    echo "WARNING: terraform.tfvars already exists."
    read -rp "  Overwrite? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0
fi

# ────────────────────────────────────────
# 4. Gather OCI credentials
#    Pre-fill from ~/.oci/config where available
# ────────────────────────────────────────

echo ""
echo "── Oracle Cloud Credentials ──"
echo "  (Pre-filled from ~/.oci/config where available)"
echo ""

prompt TENANCY_OCID  "Tenancy OCID"       "${EXISTING_TENANCY:-}"
prompt USER_OCID     "User OCID"          "${EXISTING_USER:-}"
prompt FINGERPRINT   "API Key Fingerprint" "${EXISTING_FINGERPRINT:-}"
prompt API_KEY_PATH  "API Key Path"        "${EXISTING_KEY_FILE:-${HOME}/.oci/oci_api_key.pem}"
prompt REGION        "Region"             "${EXISTING_REGION:-ap-mumbai-1}"
prompt COMPARTMENT_OCID "Compartment OCID (same as tenancy for root)" "${TENANCY_OCID}"

if [ ! -f "$API_KEY_PATH" ]; then
    echo ""
    echo "  WARNING: API key not found at ${API_KEY_PATH}"
    echo "  Upload your OCI API private key to that path before running terraform apply."
fi

# ────────────────────────────────────────
# 5. Availability Domain — auto-detect or prompt
# ────────────────────────────────────────

echo ""
echo "── Availability Domain ──"

AD_DEFAULT="eHVA:AP-MUMBAI-1-AD-1"
if command -v oci >/dev/null 2>&1 && [ -f "$OCI_CONFIG" ]; then
    echo "  Fetching availability domains from OCI..."
    AD_LIST=$(oci iam availability-domain list \
        --compartment-id "${TENANCY_OCID}" \
        --query 'data[*].name' \
        --raw-output 2>/dev/null || true)

    if [ -n "$AD_LIST" ]; then
        echo "  Available domains:"
        echo "$AD_LIST" | python3 -c "
import sys, json
ads = json.load(sys.stdin)
for i, ad in enumerate(ads):
    print(f'    [{i+1}] {ad}')
" 2>/dev/null || echo "    $AD_LIST"
        AD_DEFAULT=$(echo "$AD_LIST" | python3 -c "import sys,json; ads=json.load(sys.stdin); print(ads[0])" 2>/dev/null || echo "$AD_DEFAULT")
    else
        echo "  Could not auto-fetch (API key may not be uploaded to OCI yet)."
        echo "  Find it: OCI Console → Compute → Instances → Create Instance → AD dropdown"
    fi
fi

prompt AD_NAME "Availability Domain" "$AD_DEFAULT"

# ────────────────────────────────────────
# 6. SSH Key — generate if missing
# ────────────────────────────────────────

echo ""
echo "── SSH Key ──"
SSH_KEY_DEFAULT="${HOME}/.ssh/cryptex_vps.pub"
prompt SSH_KEY_PATH "SSH Public Key Path" "$SSH_KEY_DEFAULT"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo ""
    echo "  SSH key not found at ${SSH_KEY_PATH}"
    read -rp "  Generate a new ed25519 key pair now? [Y/n]: " gen_key
    if [[ "$gen_key" != "n" && "$gen_key" != "N" ]]; then
        PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
        ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -C "cryptex-vps" -N ""
        echo "  ✓ Generated: ${PRIVATE_KEY} (private) + ${SSH_KEY_PATH} (public)"
    fi
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "ERROR: SSH public key not found. Cannot continue."
    exit 1
fi

SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH")

# ────────────────────────────────────────
# 7. Instance config
# ────────────────────────────────────────

echo ""
echo "── Instance Config (Oracle Free Tier maximums: 4 OCPU, 24GB, 200GB) ──"
prompt DISPLAY_NAME "Display Name"  "cryptex-vps"
prompt OCPUS        "OCPUs"         "4"
prompt MEMORY_GB    "Memory GB"     "24"
prompt DISK_GB      "Disk GB"       "100"

# ────────────────────────────────────────
# 8. Write terraform.tfvars
# ────────────────────────────────────────

mkdir -p "$TF_DIR"

cat > "$TFVARS_FILE" <<EOF
# CRYPTEX — Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# DO NOT commit this file

tenancy_ocid     = "${TENANCY_OCID}"
user_ocid        = "${USER_OCID}"
fingerprint      = "${FINGERPRINT}"
private_key_path = "${API_KEY_PATH}"
region           = "${REGION}"
compartment_id   = "${COMPARTMENT_OCID}"

availability_domain = "${AD_NAME}"

ssh_public_key = "${SSH_KEY_CONTENT}"

instance_display_name   = "${DISPLAY_NAME}"
instance_ocpus          = ${OCPUS}
instance_memory_in_gbs  = ${MEMORY_GB}
boot_volume_size_in_gbs = ${DISK_GB}
EOF

echo ""
echo "────────────────────────────"
echo "✓ Written: ${TFVARS_FILE}"
echo ""
echo "  Region : ${REGION}"
echo "  AD     : ${AD_NAME}"
echo "  Shape  : VM.Standard.A1.Flex (${OCPUS} OCPU, ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk)"
echo "  SSH    : ${SSH_KEY_PATH}"
echo ""

# ────────────────────────────────────────
# 9. Offer to run terraform
# ────────────────────────────────────────

read -rp "Run 'terraform init && terraform apply' now? [Y/n]: " run_tf
if [[ "$run_tf" != "n" && "$run_tf" != "N" ]]; then
    cd "$TF_DIR"
    echo ""
    echo "Running terraform init..."
    terraform init -upgrade
    echo ""
    echo "Running terraform apply..."
    terraform apply
else
    echo ""
    echo "Next steps:"
    echo "  cd ${TF_DIR}"
    echo "  terraform init -upgrade"
    echo "  terraform apply"
fi
