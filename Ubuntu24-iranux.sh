#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Final Fix)
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
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Nuclear Clean ---
clean_old_stuff() {
    echo "[*] Cleaning up old instances..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 3. Directory & Environment Preparation ---
prepare_env() {
    echo "[*] Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    echo "[*] Checking/Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard (Geo-IP) Setup ---
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Updating Iran IP database..."
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Applying 5-minute session limit for non-Iran IPs."
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
# Using a reliable public mirror for Conduit to avoid 'Access Denied'
deploy() {
    echo "[*] Deploying Conduit Container..."
    # We use the most stable available image
    docker pull ssmirr/conduit:latest || docker pull psiphon/conduit:latest || echo "Pulling alternative..."
    
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data ssmirr/conduit:latest \
        -m $MAX_CLIENTS -b $BANDWIDTH || \
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data psiphon/conduit:latest \
        --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH
}

# --- 7. CLI & Persistence ---
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

# --- Execution Flow ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo "🚀 Starting Iranux PSIPHON CONDUIT Installation..."
    clean_old_stuff
    prepare_env
    setup_guard
    deploy
    apply_rules
    finalize
    echo "✅ Installation Success! Type 'conduit' to see stats."
fi
