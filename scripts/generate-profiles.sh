#!/bin/bash
# CRYPTEX — Generate Apple DNS profiles (.mobileconfig)
# Creates DoH profiles for macOS and iOS
# Usage: ./scripts/generate-profiles.sh [domain]

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
PROFILE_DIR="${COMPOSE_DIR}/configs/profiles"

# Get domain from argument, .env, or prompt
if [ -n "${1:-}" ]; then
    DOMAIN="$1"
elif [ -f "${COMPOSE_DIR}/.env" ]; then
    # shellcheck disable=SC1090
    source "${COMPOSE_DIR}/.env"
    DOMAIN="${DOMAIN:-}"
fi

if [ -z "${DOMAIN:-}" ]; then
    echo "Usage: $0 <domain>"
    echo "   or: set DOMAIN in .env"
    exit 1
fi

mkdir -p "$PROFILE_DIR"

# Generate UUIDs
ROOT_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
DOH_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

echo ""
echo "CRYPTEX DNS Profile Generator"
echo "────────────────────────────"
echo "Domain: ${DOMAIN}"
echo ""

# ── DNS-over-HTTPS profile (works everywhere via Cloudflare Tunnel) ──

cat > "${PROFILE_DIR}/cryptex-doh.mobileconfig" << PROFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>HTTPS</string>
                <key>ServerURL</key>
                <string>https://dns.${DOMAIN}/dns-query</string>
            </dict>
            <key>OnDemandRules</key>
            <array>
                <dict>
                    <key>Action</key>
                    <string>EvaluateConnection</string>
                    <key>ActionParameters</key>
                    <array>
                        <dict>
                            <key>DomainAction</key>
                            <string>NeverConnect</string>
                            <key>Domains</key>
                            <array>
                                <string>${DOMAIN}</string>
                                <string>dns.${DOMAIN}</string>
                            </array>
                        </dict>
                    </array>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Connect</string>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Routes all DNS queries through CRYPTEX AdGuard Home via Cloudflare Tunnel (DoH)</string>
            <key>PayloadDisplayName</key>
            <string>CRYPTEX DNS (DoH)</string>
            <key>PayloadIdentifier</key>
            <string>com.${DOMAIN}.dns.doh</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>${DOH_UUID}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>CRYPTEX DNS-over-HTTPS — All DNS queries routed through AdGuard Home via Cloudflare Tunnel. Install on macOS or iOS.</string>
    <key>PayloadDisplayName</key>
    <string>CRYPTEX DNS</string>
    <key>PayloadIdentifier</key>
    <string>com.${DOMAIN}.dns</string>
    <key>PayloadOrganization</key>
    <string>CRYPTEX</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${ROOT_UUID}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
PROFILE

echo "Generated: ${PROFILE_DIR}/cryptex-doh.mobileconfig"
echo ""
echo "────────────────────────────"
echo "INSTALLATION:"
echo ""
echo "  macOS: Double-click the .mobileconfig file → System Settings → Profiles → Install"
echo "  iOS:   AirDrop or email the file → Settings → General → VPN & Device Management → Install"
echo ""
echo "PREREQUISITES:"
echo ""
echo "  1. AdGuard Home running at dns.${DOMAIN}"
echo "  2. Cloudflare Tunnel route: dns.${DOMAIN} → http://cryptex-adguard:80"
echo "  3. In Cloudflare Zero Trust, create a bypass policy for dns.${DOMAIN}/dns-query"
echo "     (DoH clients can't do browser auth)"
echo ""
echo "CLOUDFLARE ZERO TRUST CONFIG:"
echo ""
echo "  Application: dns.${DOMAIN}"
echo "  Policy 1 (Bypass): Path = /dns-query* → Action: Bypass"
echo "  Policy 2 (Protect): Everything else → Action: Allow (email/SSO auth)"
echo "  This protects the admin UI while allowing DoH queries through."
echo ""
echo "TAILSCALE DNS (ALTERNATIVE):"
echo ""
echo "  If using Tailscale on all devices:"
echo "  1. Approve subnet route 172.18.0.0/16 in Tailscale admin"
echo "  2. Go to DNS → Add nameserver → 172.18.0.12 → Override local DNS"
echo "  3. All Tailscale-connected devices automatically use AdGuard"
echo "  4. No .mobileconfig needed — DNS is encrypted via WireGuard"
echo ""
