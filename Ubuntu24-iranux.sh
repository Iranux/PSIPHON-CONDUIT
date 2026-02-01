#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Final Public Edition)
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
REPO_RAW_URL="https://raw.githubusercontent.com/iranux/PSIPHON-CONDUIT/main/Ubuntu24-iranux.sh"

# --- 1. Root Check ---
# Automatically ensures the script runs with high privileges.
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Nuclear Clean ---
# Wipes all previous failed or existing conduit instances.
clean_old_stuff() {
    echo "[*] Cleaning up old instances..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 3. Directory & Environment Preparation ---
# Creates necessary system paths before any file operations.
prepare_env() {
    echo "[*] Creating system directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    echo "[*] Updating system and tools..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard (Geo-IP) Setup ---
# Downloads the Iran CIDR list and initializes the 12h grace period.
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Downloading fresh Iran IP database..."
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
# Implements the 12-hour open access followed by 300s session limits for non-Iran IPs.
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Grace period expired. Applying 5-minute limit for non-Iran IPs."
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
# Deploys the Conduit container using a public-accessible image.
deploy() {
    echo "[*] Pulling and deploying Conduit..."
    # Using a reliable public alternative image for Psiphon Conduit
    docker pull ghcr.io/m-m-i-n/psiphon-conduit:latest || docker pull lofat/conduit:latest
    
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data ghcr.io/m-m-i-n/psiphon-conduit:latest \
        -m $MAX_CLIENTS -b $BANDWIDTH || \
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data lofat/conduit:latest \
        -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. CLI & Persistence ---
# Creates the 'conduit' management command and the persistence systemd service.
finalize() {
    cat <<EOF > /usr/local/bin/conduit
#!/bin/bash
echo "--- Conduit Status ---"
docker ps -f name=conduit
echo "--- Real-time Stats ---"
docker stats conduit --no-stream
EOF
    chmod +x /usr/local/bin/conduit

    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Smart Guard Persistence
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

# --- Execution Flow ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo "🚀 Starting Optimized Iranux Conduit Install..."
    clean_old_stuff
    prepare_env
    setup_guard
    deploy
    apply_rules
    finalize
    echo "✅ Installation Success! Type 'conduit' to see live stats."
fi
