#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (No-Flicker Edition)
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

# --- 2. Maintenance & Nuclear Clean ---
clean_old_stuff() {
    echo "[*] Cleaning up existing containers..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 3. Directory & Environment Preparation ---
prepare_env() {
    echo "[*] Creating system directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq
    systemctl enable --now docker
}

# --- 4. Smart Guard Setup ---
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Fetching Iran IP database..."
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
deploy() {
    echo "[*] Pulling and deploying Conduit..."
    # Using a reliable public mirror of ssmirr version
    IMAGE="ghcr.io/m-m-i-n/psiphon-conduit:latest"
    docker pull $IMAGE
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data $IMAGE \
        -m $MAX_CLIENTS -b $BANDWIDTH
}

# --- 7. Management CLI (Fixed No-Flicker Menu) ---
finalize() {
    cat <<'EOF' > /usr/local/bin/conduit
#!/bin/bash
show_menu() {
    clear
    echo "======================================"
    echo "      IRANUX CONDUIT MANAGER"
    echo "======================================"
    echo "1) View Live Stats (Press Q to exit stats)"
    echo "2) Restart Service"
    echo "3) View Smart Guard Status"
    echo "4) Exit"
    echo "======================================"
    read -p "Select an option: " opt
    case $opt in
        1) docker stats conduit ;;
        2) docker restart conduit && echo "Restarted." && sleep 2 ;;
        3) 
           start_t=$(cat /var/lib/conduit/install_date)
           diff=$(( ($(date +%s) - start_t) / 3600 ))
           echo "Uptime: $diff hours"
           [[ $diff -ge 12 ]] && echo "Status: Smart Guard ACTIVE" || echo "Status: Grace Period"
           read -p "Press Enter..." ;;
        4) exit 0 ;;
    esac
}
show_menu
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

# --- Main Flow ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo "🚀 Starting Optimized Installation..."
    clean_old_stuff
    prepare_env
    setup_guard
    deploy
    apply_rules
    finalize
    echo "✅ Installation Success! Type 'conduit' to manage."
fi
