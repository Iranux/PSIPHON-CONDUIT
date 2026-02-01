#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Ultra-Light & Automated)
# Target OS: Ubuntu 24.04
# GitHub: https://github.com/Iranux/PSIPHON-CONDUIT
# =================================================================

set -eo pipefail

# --- Configuration ---
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DIR="/var/lib/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
# URL for the script itself to use in persistence
REPO_RAW_URL="https://raw.githubusercontent.com/iranux/PSIPHON-CONDUIT/main/Ubuntu24-iranux.sh"

# --- 1. Root Check ---
# Automated elevation to root to ensure all commands execute properly
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Maintenance & Nuclear Clean ---
# Forces removal of all previous traces to ensure a clean slate
clean_old_stuff() {
    echo "[*] Initializing Nuclear Clean..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    systemctl disable conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 3. Directory & Environment Preparation ---
# Fixes the 'No such file or directory' error by creating paths first
prepare_env() {
    echo "[*] Preparing environment and directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard & Geo-IP Setup ---
# Downloads the Iran IP database for the 5-minute session limit logic
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Updating Iran IP database..."
    # Fetching fresh CIDR ranges for Iran
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
# Implements the 12-hour grace period and subsequent 300s session limit
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Grace period over. Applying 5-min limit for non-Iran IPs."
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!; done < "$IRAN_IP_LIST"

        iptables -F INPUT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
}

# --- 6. Core Deployment ---
# Deploys the Conduit container with 'restart always' for persistence
deploy() {
    echo "[*] Deploying Conduit (50 Clients / 10 Mbps)..."
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data ssmirr/conduit:latest -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. CLI & Persistence ---
# Creates the 'conduit' command and systemd service for re-applying rules on boot
finalize() {
    # Management CLI command
    cat <<EOF > /usr/local/bin/conduit
#!/bin/bash
echo "--- Conduit Status ---"
docker ps -f name=conduit
echo "--- Real-time Stats ---"
docker stats conduit --no-stream
EOF
    chmod +x /usr/local/bin/conduit

    # Persistence Service (re-fetches the script without cache on boot)
    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Smart Guard
After=network.target docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c "source <(curl -sL -H 'Cache-Control: no-cache' $REPO_RAW_URL) --apply-rules"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable conduit-guard.service
}

# --- Main Execution Flow ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    clean_old_stuff
    prepare_env
    setup_guard
    deploy
    apply_rules
    finalize
    echo "✅ Installation Success! Type 'conduit' to manage."
fi
