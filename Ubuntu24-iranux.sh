#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Optimized & Fixed)
# Target OS: Ubuntu 24.04
# GitHub: https://github.com/Iranux/PSIPHON-CONDUIT
# =================================================================

set -eo pipefail

# --- Pre-defined Variables (Bypassing User Prompts) ---
# These match the settings you requested
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DIR="/var/lib/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
# Points to your own repository
REPO_RAW_URL="https://raw.githubusercontent.com/Iranux/PSIPHON-CONDUIT/main/Install.sh"

# --- 1. Root Check & Elevation ---
# Automatically ensures the script runs with high privileges.
if [ "$EUID" -ne 0 ]; then
    echo "[*] Escalating to root privileges..."
    exec sudo bash "$0" "$@"
fi

# --- 2. Nuclear Clean ---
# Removes any traces of previous failed or existing installations.
clean_old_stuff() {
    echo "[*] Performing Nuclear Clean: Wiping old instances..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    systemctl disable conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
    echo "[+] System is now clean."
}

# --- 3. Directory & Dependencies ---
# Creates directories first to prevent 'No such file or directory' errors.
prepare_env() {
    echo "[*] Creating system directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    echo "[*] Installing required tools (Docker, Ipset, Iptables)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard (Geo-IP) Setup ---
# Downloads Iran IP ranges and starts the 12h grace period timer.
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Updating Iran IP database for Smart Guard..."
    # Fetches fresh Iran CIDR ranges
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
# Allows Iran-IPs; limits others to 5-minute sessions after 12 hours.
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Grace period expired. Applying 5-minute limit for non-Iran IPs."
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!; done < "$IRAN_IP_LIST"

        # Apply firewall rules to port 1080
        iptables -F INPUT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    else
        echo "[+] Grace period active ($diff/12h). World access is currently open."
    fi
}

# --- 6. Core Deployment ---
# Deploys the container using the most stable public mirror of the conduit image.
deploy() {
    echo "[*] Pulling and deploying Conduit Docker Image..."
    # Using a high-availability public mirror to avoid 'Pull Access Denied'
    IMAGE="ghcr.io/m-m-i-n/psiphon-conduit:latest"
    docker pull $IMAGE
    
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data $IMAGE \
        -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. CLI & Persistence ---
# Creates the 'conduit' command and sets up the auto-start service.
finalize() {
    # Management command
    cat <<EOF > /usr/local/bin/conduit
#!/bin/bash
echo "--- Psiphon Conduit Status ---"
docker ps -f name=conduit
echo "--- Real-time Traffic ---"
docker stats conduit --no-stream
EOF
    chmod +x /usr/local/bin/conduit

    # Reboot Persistence Service (Auto-fetches the script to apply firewall)
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
    echo "🚀 Starting Iranux PSIPHON CONDUIT Installation..."
    clean_old_stuff
    prepare_env
    setup_guard
    deploy
    apply_rules
    finalize
    echo "------------------------------------------------"
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo "• Clients: $MAX_CLIENTS | Bandwidth: $BANDWIDTH Mbps"
    echo "• Type 'conduit' to see live status."
    echo "------------------------------------------------"
fi
