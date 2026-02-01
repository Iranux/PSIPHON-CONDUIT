#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT (ORIGINAL METHOD RESTRUCTRED)
# Target OS: Ubuntu 24.04
# Logic: Direct Binary Download + Local Build (No Password Required)
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 1. Root Check ---
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. PRE-INSTALLATION CLEANUP (Deleted Everything Old) ---
clean_old_stuff() {
    echo -e "${YELLOW}[*] Nuclear Clean: Removing old containers and files...${NC}"
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    # Remove old images to force fresh build
    docker rmi conduit-local 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
    rm -rf /tmp/conduit_build
}

# --- 3. Environment Preparation ---
prepare_env() {
    echo -e "${CYAN}[*] Creating system directories...${NC}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    mkdir -p "/tmp/conduit_build"
    
    echo -e "${CYAN}[*] Installing dependencies (Wget, Unzip, Docker)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq unzip wget
    systemctl enable --now docker
}

# --- 4. Smart Guard Setup ---
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo -e "${GREEN}[*] Fetching Iran IP database...${NC}"
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!; done < "$IRAN_IP_LIST"

        iptables -F INPUT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
}

# --- 6. Core Deployment (THE ORIGINAL METHOD) ---
deploy() {
    echo -e "${CYAN}[*] Downloading Official Psiphon Binary (No Auth Required)...${NC}"
    cd /tmp/conduit_build
    
    # Direct download link for the binary (Bypassing Docker Hub issues)
    wget -qO conduit.zip "https://github.com/Psiphon-Inc/psiphon-conduit/releases/latest/download/psiphon-conduit-linux-x86_64.zip"
    
    echo -e "${CYAN}[*] Extracting binary...${NC}"
    unzip -o conduit.zip
    # Find and rename the binary accurately
    find . -type f -name "psiphon-conduit*" ! -name "*.zip" -exec mv {} conduit \;
    chmod +x conduit

    echo -e "${GREEN}[*] Building Local Docker Image...${NC}"
    # Creating a lightweight Dockerfile on the fly
    cat <<EOF > Dockerfile
FROM ubuntu:24.04
COPY conduit /usr/local/bin/conduit
RUN chmod +x /usr/local/bin/conduit
ENTRYPOINT ["/usr/local/bin/conduit"]
EOF
    
    # Build image locally tagged as 'conduit-local'
    docker build -t conduit-local .

    echo -e "${GREEN}[*] Starting Container...${NC}"
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data conduit-local \
        --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH
}

# --- 7. Original Menu & Finalize ---
finalize() {
    cat <<'EOF' > /usr/local/bin/conduit
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            🚀 PSIPHON CONDUIT MANAGER (IRANUX ULTIMATE)           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 📈 Dashboard (Live)"
    echo -e "  ${GREEN}2.${NC} 📋 Logs"
    echo -e "  ${GREEN}3.${NC} ⚙️  Settings (Restart with Defaults)"
    echo -e "  ${GREEN}4.${NC} 📱 Telegram Setup (Managed via config)"
    echo -e "  ${GREEN}5.${NC} 🔄 Restart Service"
    echo -e "  ${GREEN}6.${NC} 🔑 Show config"
    echo -e "  ${GREEN}7.${NC} 🛡️  Smart Guard Status"
    echo -e "  ${GREEN}8.${NC} 🗑️  Uninstall"
    echo -e "  ${RED}0. Exit${NC}"
    echo ""
    
    # Check Service Status
    if docker ps | grep -q conduit; then
        echo -e "  Status: ${GREEN}● RUNNING${NC}"
    else
        echo -e "  Status: ${RED}● STOPPED${NC}"
    fi
    echo ""

    read -p "  Choice: " opt
    case $opt in
        1) watch -n 1 "docker stats conduit --no-stream" ;;
        2) docker logs -f --tail 100 conduit ;;
        3) docker restart conduit && echo "Restarted." && sleep 2 ;;
        4) echo "Config is in /root/conduit_backup"; read -p "Press Enter..." ;;
        5) docker restart conduit && echo "Service Restarted." && sleep 2 ;;
        6) 
           docker logs conduit 2>&1 | grep -i "server config" | tail -n 1
           read -p "Press Enter..." ;;
        7) 
           start_t=$(cat /var/lib/conduit/install_date)
           diff=$(( ($(date +%s) - start_t) / 3600 ))
           echo "--------------------------------"
           echo -e "  ⏳ Server Uptime: ${CYAN}$diff hours${NC}"
           if [[ $diff -ge 12 ]]; then
               echo -e "  🛡️  Status: ${RED}ACTIVE${NC} (Non-Iran IPs restricted)"
           else
               echo -e "  🔓 Status: ${GREEN}GRACE PERIOD${NC} (Open Access)"
           fi
           echo "--------------------------------"
           read -p "Press Enter..." ;;
        8) 
           read -p "Are you sure? (y/n): " sure
           if [[ "$sure" == "y" ]]; then
               docker rm -f conduit
               rm /usr/local/bin/conduit
               echo "Uninstalled."
               exit 0
           fi ;;
        0) exit 0 ;;
        *) echo "Invalid option." && sleep 1 ;;
    esac
done
EOF
    chmod +x /usr/local/bin/conduit

    # Persistence Service
    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Guard
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

# --- Execution ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo -e "${GREEN}🚀 Starting Installation...${NC}"
    # 1. Clean FIRST
    clean_old_stuff
    # 2. Prepare Environment
    prepare_env
    # 3. Setup Logic
    setup_guard
    # 4. Deploy (Original Method)
    deploy
    # 5. Apply Rules
    apply_rules
    # 6. Finalize UI
    finalize
    
    echo -e "${GREEN}✅ Installation Complete! Launching Menu...${NC}"
    sleep 2
    /usr/local/bin/conduit
fi
