#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Final Optimized Version)
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
REPO_RAW_URL="https://raw.githubusercontent.com/Iranux/PSIPHON-CONDUIT/main/Ubuntu24-iranux.sh"

# --- 1. Auto-Root Elevation ---
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Nuclear Clean ---
nuclear_clean() {
    echo "[*] Initializing Nuclear Clean..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    systemctl disable conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
    echo "[+] Cleanup completed."
}

# --- 3. System Update & Dependencies ---
prepare_system() {
    echo "[*] Installing required tools..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard Setup ---
setup_smart_guard() {
    echo "[*] Configuring Smart Guard..."
    mkdir -p /etc/conduit
    mkdir -p "$INSTALL_DIR"
    
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi

    echo "[*] Downloading Iran IP ranges..."
    curl -s https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
apply_smart_rules() {
    local start_time=$(cat "$INSTALL_DATE_FILE")
    local current_time=$(date +%s)
    local diff_hours=$(( (current_time - start_time) / 3600 ))

    if [ "$diff_hours" -ge 12 ]; then
        echo "[!] Grace period expired. Applying 5-minute limit."
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do
            [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!
        done < "$IRAN_IP_LIST"

        iptables -F INPUT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
}

# --- 6. Core Deployment ---
deploy_conduit() {
    echo "[*] Deploying Conduit (50 Clients / 10 Mbps)..."
    docker run -d \
        --name conduit \
        --restart always \
        --network host \
        -v /root/conduit_backup:/data \
        ssmirr/conduit:latest \
        -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. Management Command ---
create_cmd() {
    # This creates the 'conduit' command for your terminal
    cat <<EOF > /usr/local/bin/conduit
#!/bin/bash
docker stats conduit
EOF
    chmod +x /usr/local/bin/conduit
}

# --- 8. Persistence ---
setup_persistence() {
    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Smart Guard
After=network.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c "source <(curl -sL $REPO_RAW_URL) --apply-rules"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable conduit-guard.service
}

# --- Main ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_smart_rules
else
    echo "🚀 Starting Iranux PSIPHON CONDUIT Installation..."
    nuclear_clean
    prepare_system
    setup_smart_guard
    deploy_conduit
    apply_smart_rules
    create_cmd
    setup_persistence
    echo "------------------------------------------------"
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo "Type 'conduit' to see live stats."
    echo "------------------------------------------------"
fi
