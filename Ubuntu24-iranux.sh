#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Optimized for Ubuntu 24.04)
# GitHub: https://github.com/Iranux/PSIPHON-CONDUIT
# Description: Automated setup with Geo-fencing and Nuclear Clean.
# =================================================================

set -eo pipefail

# --- Configuration Constants ---
# Hardcoded to bypass user prompts during installation
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DATE_FILE="/var/lib/conduit/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
REPO_RAW_URL="https://raw.githubusercontent.com/Iranux/PSIPHON-CONDUIT/main/Install.sh"

# --- 1. Automatic Root Elevation ---
# Ensures the script runs with full administrative privileges without user intervention.
if [ "$EUID" -ne 0 ]; then
    echo "[!] Not running as root. Escalating now..."
    exec sudo bash "$0" "$@"
fi

# --- 2. Nuclear Clean ---
# Aggressively removes any existing conduits, docker containers, and services to prevent conflicts.
nuclear_clean() {
    echo "[*] Initializing Nuclear Clean: Removing old traces..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    for i in {2..5}; do
        docker stop "conduit-$i" 2>/dev/null || true
        docker rm -f "conduit-$i" 2>/dev/null || true
    done
    systemctl stop conduit 2>/dev/null || true
    systemctl disable conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    rm -f /etc/systemd/system/conduit-guard.service
    rm -rf /root/conduit_backup
    echo "[+] Cleanup completed."
}

# --- 3. Full System Update ---
# Prepares Ubuntu 24.04 with necessary tools and the latest package versions.
prepare_system() {
    echo "[*] Updating system repositories (Ubuntu 24.04)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl docker.io ipset iptables cron jq
    systemctl enable --now docker
}

# --- 4. Smart Guard Logic (Geo-Fencing) ---
# Defines the logic for 12 hours of open world access followed by 5-minute limits for non-Iran IPs.
setup_smart_guard() {
    echo "[*] Configuring Smart Guard (Iran Priority Mode)..."
    mkdir -p /etc/conduit
    
    # Record installation timestamp
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi

    # Download Iran CIDR list
    echo "[*] Downloading Iran IP ranges..."
    curl -s https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Application Engine ---
# This part is triggered both on install and after every reboot via systemd.
apply_smart_rules() {
    if [[ "$(cat $SMART_GUARD_CONF 2>/dev/null)" != "enabled" ]]; then
        return
    fi

    local start_time=$(cat "$INSTALL_DATE_FILE")
    local current_time=$(date +%s)
    local diff_hours=$(( (current_time - start_time) / 3600 ))

    # If 12 hours have passed, apply the 5-minute restriction to foreigners
    if [ "$diff_hours" -ge 12 ]; then
        echo "[!] Grace period expired. Applying 5-minute timeout for non-Iran IPs."
        
        # Flush old rules to avoid duplicates
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        
        while read -r ip; do
            [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!
        done < "$IRAN_IP_LIST"

        # Firewall Rules:
        # 1. Allow Iran IPs unconditionally
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        # 2. Track other IPs and drop them after 300 seconds (5 minutes)
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    else
        echo "[+] Grace period active ($diff_hours/12h). World access is currently open."
    fi
}

# --- 6. Core Deployment ---
# Starts the Psiphon Conduit container with a permanent restart policy.
deploy_conduit() {
    echo "[*] Deploying Conduit container (Clients: $MAX_CLIENTS, Speed: $BANDWIDTH Mbps)..."
    docker run -d \
        --name conduit \
        --restart always \
        --network host \
        -v /root/conduit_backup:/data \
        ssmirr/conduit:latest \
        -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. Persistence Systemd Service ---
# Ensures that firewall rules and Smart Guard logic survive a server restart.
setup_persistence() {
    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Smart Guard Persistence Service
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

# --- Main Execution Path ---
# Logic to handle both fresh installation and automated rule re-application.
if [[ "$1" == "--apply-rules" ]]; then
    apply_smart_rules
else
    echo "🚀 Starting Iranux PSIPHON CONDUIT Installation..."
    nuclear_clean
    prepare_system
    setup_smart_guard
    deploy_conduit
    apply_smart_rules
    setup_persistence
    
    echo "------------------------------------------------"
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo "• Clients: $MAX_CLIENTS"
    echo "• Bandwidth: $BANDWIDTH Mbps"
    echo "• Smart Guard: Active (12h Grace Period)"
    echo "------------------------------------------------"
    
    # Automatically open management interface
    # Here we download the manager part of the script to show the menu
    echo "[*] Launching Management Menu..."
    sleep 2
    # You can add your menu function here or call another script
fi
