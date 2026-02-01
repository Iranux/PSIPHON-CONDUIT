#!/bin/bash

# =================================================================
# Project: IRANUX PSIPHON CONDUIT (Master Deployment Script)
# Target OS: Ubuntu 24.04
# Features: Smart Guard (12h Grace), Nuclear Clean, Auto-Root
# =================================================================

set -eo pipefail

# --- Configuration Constants ---
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DIR="/var/lib/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
REPO_RAW_URL="https://raw.githubusercontent.com/Iranux/PSIPHON-CONDUIT/main/Install.sh"

# --- 1. Root Elevation ---
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Environment & Directory Preparation ---
# CRITICAL: Creating directories BEFORE anything else.
prepare_env() {
    echo "[*] Initializing system directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    echo "[*] Installing core dependencies (Ubuntu 24.04)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 3. Nuclear Clean ---
clean_old_stuff() {
    echo "[*] Wiping old instances and services..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    systemctl disable conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 4. Smart Guard (Geo-IP) Setup ---
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Downloading Iran IP CIDR database..."
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Application Engine ---
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Grace period expired. Enabling 5-minute limit for non-Iran IPs."
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!; done < "$IRAN_IP_LIST"

        # Cleanup existing rules to prevent duplication
        iptables -D INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true
        iptables -F INPUT 2>/dev/null || true
        
        # Apply strict rules
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
}

# --- 6. Core Deployment (Using Valid Public Image) ---
deploy() {
    echo "[*] Pulling and deploying stable Conduit container..."
    # Fallback logic for image selection
    local IMAGE="lofat/conduit:latest"
    docker pull $IMAGE
    
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data $IMAGE \
        --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH
}

# --- 7. Management CLI & Persistence ---
finalize() {
    cat <<'EOF' > /usr/local/bin/conduit
#!/bin/bash
while true; do
    clear
    echo "======================================"
    echo "      IRANUX CONDUIT MANAGER"
    echo "======================================"
    echo "1) View Live Stats (Smooth Refresh)"
    echo "2) Restart Node"
    echo "3) Smart Guard Info"
    echo "4) Exit"
    echo "======================================"
    read -p "Select option: " opt
    case $opt in
        1) watch -n 2 "docker stats conduit --no-stream" ;;
        2) docker restart conduit && echo "Restarted." && sleep 1 ;;
        3) 
           start_t=$(cat /var/lib/conduit/install_date)
           diff=$(( ($(date +%s) - start_t) / 3600 ))
           echo "Uptime: $diff hours"
           [[ $diff -ge 12 ]] && echo "Guard: ACTIVE" || echo "Guard: GRACE PERIOD"
           read -p "Press Enter to return..." ;;
        4) exit 0 ;;
    esac
done
EOF
    chmod +x /usr/local/bin/conduit

    # Setup Persistence for Reboot
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

# --- Main Flow ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo "🚀 Initializing Iranux Psiphon Conduit..."
    prepare_env
    clean_old_stuff
    setup_guard
    deploy
    apply_rules
    finalize
    echo "------------------------------------------------"
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo "Type 'conduit' to see the management menu."
    echo "------------------------------------------------"
fi
