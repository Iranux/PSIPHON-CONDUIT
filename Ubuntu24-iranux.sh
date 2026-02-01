#!/bin/bash

# =================================================================
# Project: PSIPHON CONDUIT MANAGER (Fixed Menu & Service)
# Target OS: Ubuntu 24.04
# Features: Auto-Menu, Crash Detection, Git Build
# =================================================================

set -eo pipefail

# --- Configuration ---
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DIR="/var/lib/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
# Source Repo (Clone of original)
GIT_SOURCE_URL="https://github.com/m-m-i-n/psiphon-conduit.git"
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

# --- 2. Environment Preparation ---
prepare_env() {
    echo -e "${CYAN}[*] Creating system directories...${NC}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    
    echo -e "${CYAN}[*] Installing dependencies...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq git qrencode
    systemctl enable --now docker
}

# --- 3. Nuclear Clean ---
clean_old_stuff() {
    echo -e "${YELLOW}[*] Cleaning up old instances...${NC}"
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    # We keep the image if it exists to save time, unless forced
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
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

# --- 6. Core Deployment (Git Build + Health Check) ---
deploy() {
    echo -e "${CYAN}[*] Building Docker Image from Source...${NC}"
    # Force rebuild to ensure we have a fresh image
    if ! docker build -t conduit-local "$GIT_SOURCE_URL"; then
         echo -e "${YELLOW}Build failed. Trying fallback repo...${NC}"
         docker build -t conduit-local "https://github.com/lofat/conduit.git"
    fi

    echo -e "${GREEN}[*] Starting Container...${NC}"
    
    # Try Method 1: Standard arguments
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data conduit-local \
        -m $MAX_CLIENTS -b $BANDWIDTH

    echo -e "${CYAN}[*] Verifying service health... (Waiting 5s)${NC}"
    sleep 5

    # Health Check
    if ! docker ps | grep -q conduit; then
        echo -e "${RED}[!] Service failed to start! Checking logs...${NC}"
        docker logs conduit
        echo -e "${YELLOW}[*] Retrying with alternative launch parameters...${NC}"
        
        docker rm -f conduit
        # Try Method 2: Environment Variables (Common fallback)
        docker run -d --name conduit --restart always --network host \
            -v /root/conduit_backup:/data \
            -e MAX_CLIENTS=$MAX_CLIENTS -e BANDWIDTH=$BANDWIDTH \
            conduit-local
            
        sleep 5
        if ! docker ps | grep -q conduit; then
             echo -e "${RED}[FATAL] Service still failed. Showing last logs:${NC}"
             docker logs conduit
             exit 1
        fi
    fi
    echo -e "${GREEN}[+] Service is ACTIVE and RUNNING.${NC}"
}

# --- 7. Finalize & Menu ---
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
    echo -e "  ${GREEN}3.${NC} 🔄 Restart Service"
    echo -e "  ${GREEN}4.${NC} 🗑️  Uninstall"
    echo "  --------------------------------"
    echo -e "  ${GREEN}9.${NC} 🛡️  Smart Guard Status"
    echo -e "  ${RED}0. Exit${NC}"
    echo ""
    
    # Check status for footer
    if docker ps | grep -q conduit; then
        echo -e "  Service Status: ${GREEN}● Active${NC}"
    else
        echo -e "  Service Status: ${RED}● Stopped${NC}"
    fi
    echo ""
    
    read -p "  Choice: " opt
    case $opt in
        1) watch -n 1 "docker stats conduit --no-stream" ;;
        2) docker logs -f --tail 100 conduit ;;
        3) docker restart conduit && echo "Service Restarted." && sleep 2 ;;
        4) 
           read -p "Uninstall? (y/n): " sure
           if [[ "$sure" == "y" ]]; then
               docker rm -f conduit
               rm /usr/local/bin/conduit
               echo "Uninstalled."
               exit 0
           fi ;;
        9) 
           start_t=$(cat /var/lib/conduit/install_date)
           diff=$(( ($(date +%s) - start_t) / 3600 ))
           echo "--------------------------------"
           echo -e "  ⏳ Server Uptime: ${CYAN}$diff hours${NC}"
           if [[ $diff -ge 12 ]]; then
               echo -e "  🛡️  Status: ${RED}ACTIVE${NC} (Restricted Mode)"
           else
               echo -e "  🔓 Status: ${GREEN}GRACE PERIOD${NC} (Open Access)"
           fi
           echo "--------------------------------"
           read -p "Press Enter..." ;;
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
    prepare_env
    clean_old_stuff
    setup_guard
    deploy
    apply_rules
    finalize
    
    echo -e "${GREEN}✅ Installation Complete! Launching Menu...${NC}"
    sleep 2
    # Auto-launch the menu
    /usr/local/bin/conduit
fi
