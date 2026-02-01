#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER v1.2 (IRANUX EDITION)            ║
# ║                                                                   ║
# ║  • Hardcoded Settings: 50 Users / 10Mbps                          ║
# ║  • Smart Guard: 12h Grace Period + Geo-IP Filtering               ║
# ║  • Nuclear Clean Installation                                     ║
# ║                                                                   ║
# ╚═══════════════════════════════════════════════════════════════════╝

set -eo pipefail

# --- HARDCODED SETTINGS (As requested) ---
MAX_CLIENTS=50
BANDWIDTH=10
CONTAINER_COUNT=1
# Switched to public mirror to fix "Password Required" error
CONDUIT_IMAGE="lofat/conduit:latest" 

VERSION="1.2"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="$INSTALL_DIR/iran_ips.txt"
FORCE_REINSTALL=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# 1. Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          🚀 PSIPHON CONDUIT MANAGER (IRANUX EDIT)             ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Settings: 50 Clients | 10 Mbps | Smart Guard Active          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Elevating to root..."
        exec sudo bash "$0" "$@"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# 2. Nuclear Clean (Added)
#═══════════════════════════════════════════════════════════════════════

nuclear_clean() {
    log_warn "Performing Nuclear Clean (Wiping old instances)..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    # Remove scaled containers if any
    for i in {2..5}; do
        docker stop "conduit-$i" 2>/dev/null || true
        docker rm -f "conduit-$i" 2>/dev/null || true
    done
    
    # Remove services
    systemctl stop conduit 2>/dev/null || true
    systemctl disable conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    rm -f /etc/systemd/system/conduit-guard.service
    rm -f /usr/local/bin/conduit
    
    # Clear old data but preserve backup keys if needed (optional)
    # rm -rf "$INSTALL_DIR" 
    
    systemctl daemon-reload 2>/dev/null || true
    log_success "Cleanup complete."
}

#═══════════════════════════════════════════════════════════════════════
# 3. Dependencies & OS (Modified to include ipset)
#═══════════════════════════════════════════════════════════════════════

check_dependencies() {
    log_info "Installing dependencies (Docker, ipset, curl)..."
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt-get &>/dev/null; then
        apt-get update -q
        apt-get install -y -q curl docker.io ipset iptables jq
    elif command -v yum &>/dev/null; then
        yum install -y curl docker ipset iptables jq
    fi
    
    systemctl enable --now docker 2>/dev/null || true
}

#═══════════════════════════════════════════════════════════════════════
# 4. Smart Guard Logic (Added)
#═══════════════════════════════════════════════════════════════════════

setup_smart_guard() {
    log_info "Configuring Smart Guard (Geo-Filtering)..."
    mkdir -p "$INSTALL_DIR"
    
    # 1. Set Install Date if missing
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    
    # 2. Download Iran IP List
    if [ ! -f "$IRAN_IP_LIST" ] || [ ! -s "$IRAN_IP_LIST" ]; then
        log_info "Downloading Iran IP database..."
        curl -sL "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr" -o "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    fi
    
    # 3. Create Guard Script (Persistence)
    cat > "$INSTALL_DIR/smart_guard.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="$INSTALL_DIR/iran_ips.txt"

# Wait for docker network
sleep 10

if [ -f "$INSTALL_DATE_FILE" ]; then
    START_TIME=$(cat "$INSTALL_DATE_FILE")
    CURRENT_TIME=$(date +%s)
    DIFF_HOURS=$(( (CURRENT_TIME - START_TIME) / 3600 ))
    
    # Clean previous rules to avoid duplication
    iptables -D INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true
    ipset destroy iran_ips 2>/dev/null || true

    if [ "$DIFF_HOURS" -ge 12 ]; then
        echo "Smart Guard: Active (Restricting non-Iran IPs)"
        ipset create iran_ips hash:net
        while read line; do ipset add iran_ips "$line" -!; done < "$IRAN_IP_LIST"
        
        # 1. Allow Iran IPs unconditionally
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        # 2. Limit others to 5 mins (300s)
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    else
        echo "Smart Guard: Grace Period ($DIFF_HOURS/12h)"
    fi
fi
EOF
    chmod +x "$INSTALL_DIR/smart_guard.sh"
    
    # 4. Create Systemd Service for Guard
    cat > /etc/systemd/system/conduit-guard.service << EOF
[Unit]
Description=Conduit Smart Guard Firewall
After=network.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_DIR/smart_guard.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable conduit-guard.service
    systemctl start conduit-guard.service
}

#═══════════════════════════════════════════════════════════════════════
# 5. Installation Core
#═══════════════════════════════════════════════════════════════════════

run_conduit() {
    log_info "Deploying Conduit Container..."
    
    # Pull the PUBLIC image (Fixes password issue)
    docker pull "$CONDUIT_IMAGE" || log_warn "Pull failed, trying local run..."

    docker run -d \
        --name conduit \
        --restart unless-stopped \
        --log-opt max-size=15m \
        --network host \
        -v conduit-data:/home/conduit/data \
        "$CONDUIT_IMAGE" \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file

    sleep 3
    if docker ps | grep -q conduit; then
        log_success "Conduit is RUNNING (Clients: $MAX_CLIENTS, BW: ${BANDWIDTH}Mbps)"
    else
        log_error "Conduit failed to start. Logs:"
        docker logs conduit
        exit 1
    fi
}

setup_autostart() {
    # Main Conduit Service
    cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable conduit
}

#═══════════════════════════════════════════════════════════════════════
# 6. Management Script (Modified for Smart Guard)
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    cat > "/usr/local/bin/conduit" << 'EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'
INSTALL_DIR="/opt/conduit"

while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            🚀 PSIPHON CONDUIT MANAGER (IRANUX)                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  1. 📈 Live Stats (No Flicker)"
    echo -e "  2. 📋 View Logs"
    echo -e "  3. 🔄 Restart Service"
    echo -e "  4. 🗑️  Uninstall"
    echo -e "  --------------------------------"
    echo -e "  9. 🛡️  Smart Guard Status"
    echo -e "  0. Exit"
    echo ""
    
    if docker ps | grep -q conduit; then
        echo -e "  Status: ${GREEN}● Running${NC}"
    else
        echo -e "  Status: ${RED}● Stopped${NC}"
    fi
    echo ""
    
    read -p "  Choice: " opt
    case $opt in
        1) watch -n 2 "docker stats conduit --no-stream" ;;
        2) docker logs -f --tail 100 conduit ;;
        3) docker restart conduit && echo "Restarted." && sleep 2 ;;
        4) 
           docker rm -f conduit
           rm -f /usr/local/bin/conduit
           echo "Uninstalled."
           exit 0 ;;
        9) 
           if [ -f "$INSTALL_DIR/install_date" ]; then
               start_t=$(cat "$INSTALL_DIR/install_date")
               diff=$(( ($(date +%s) - start_t) / 3600 ))
               echo "--------------------------------"
               echo -e "  ⏳ Server Uptime: ${CYAN}$diff hours${NC}"
               if [[ $diff -ge 12 ]]; then
                   echo -e "  🛡️  Guard: ${RED}ACTIVE${NC} (Non-Iran IPs limited to 5m)"
               else
                   echo -e "  🔓 Guard: ${GREEN}GRACE PERIOD${NC} (Open Access)"
               fi
               echo "--------------------------------"
           else
               echo "Install date not found."
           fi
           read -p "Press Enter..." ;;
        0) exit 0 ;;
        *) echo "Invalid option." && sleep 1 ;;
    esac
done
EOF
    chmod +x /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════

main() {
    print_header
    check_root
    
    # 1. Clean old mess
    nuclear_clean
    
    # 2. Dependencies
    check_dependencies
    
    # 3. Setup Smart Guard (GeoIP)
    setup_smart_guard
    
    # 4. Deploy Container
    run_conduit
    
    # 5. Persistence
    setup_autostart
    
    # 6. Create Menu
    create_management_script
    
    echo ""
    echo -e "${GREEN}✅ INSTALLATION SUCCESSFUL!${NC}"
    echo -e "Type ${BOLD}conduit${NC} to open the menu."
    echo ""
    sleep 2
    # Auto-open menu
    /usr/local/bin/conduit
}

main "$@"
