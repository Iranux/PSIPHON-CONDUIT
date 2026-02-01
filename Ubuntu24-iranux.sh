#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER v1.2 (IRANUX PATCHED)            ║
# ║                                                                   ║
# ║  • Base: Original Full Code Structure                             ║
# ║  • Fixes: Smart Guard, Nuclear Clean, Auto-Input Fix              ║
# ╚═══════════════════════════════════════════════════════════════════╝

set -eo pipefail

# --- IRANUX CONFIGURATION ---
# We override the prompts with your fixed settings
MAX_CLIENTS=50
BANDWIDTH=10
CONTAINER_COUNT=1
# Using the working public mirror (Fixes 'Access Denied' on ssmirr)
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
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          🚀 PSIPHON CONDUIT MANAGER (IRANUX)                  ║"
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

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    case "$OS" in
        ubuntu|debian|linuxmint|kali) PKG_MANAGER="apt" ;;
        centos|fedora|rhel|almalinux) PKG_MANAGER="yum" ;;
        *) PKG_MANAGER="apt" ;;
    esac
}

install_package() {
    local package="$1"
    if ! command -v "$package" &>/dev/null; then
        log_info "Installing $package..."
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -q 2>/dev/null
            apt-get install -y -q "$package"
        else
            yum install -y "$package"
        fi
    fi
}

check_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    install_package curl
    install_package jq
    install_package ipset
    install_package iptables
    
    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
}

#═══════════════════════════════════════════════════════════════════════
# IRANUX FEATURES: Nuclear Clean & Smart Guard
#═══════════════════════════════════════════════════════════════════════

nuclear_clean() {
    log_warn "Performing Nuclear Clean..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    # Clean scaled containers
    for i in {2..5}; do
        docker stop "conduit-$i" 2>/dev/null || true
        docker rm -f "conduit-$i" 2>/dev/null || true
    done
    
    systemctl stop conduit 2>/dev/null || true
    systemctl disable conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    rm -f /etc/systemd/system/conduit-guard.service
    rm -f /usr/local/bin/conduit
    
    systemctl daemon-reload 2>/dev/null || true
    log_success "System wiped clean."
}

setup_smart_guard() {
    log_info "Configuring Smart Guard..."
    mkdir -p "$INSTALL_DIR"
    
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    
    # Download Iran IP list
    if [ ! -f "$IRAN_IP_LIST" ]; then
        log_info "Downloading Iran IP database..."
        curl -sL "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr" -o "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    fi
    
    # Create Guard Script
    cat > "$INSTALL_DIR/smart_guard.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="$INSTALL_DIR/iran_ips.txt"
sleep 10
if [ -f "$INSTALL_DATE_FILE" ]; then
    START_TIME=$(cat "$INSTALL_DATE_FILE")
    CURRENT_TIME=$(date +%s)
    DIFF_HOURS=$(( (CURRENT_TIME - START_TIME) / 3600 ))
    
    # Reset Rules
    iptables -D INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true
    ipset destroy iran_ips 2>/dev/null || true

    if [ "$DIFF_HOURS" -ge 12 ]; then
        ipset create iran_ips hash:net
        while read line; do ipset add iran_ips "$line" -!; done < "$IRAN_IP_LIST"
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
fi
EOF
    chmod +x "$INSTALL_DIR/smart_guard.sh"
    
    cat > /etc/systemd/system/conduit-guard.service << EOF
[Unit]
Description=Conduit Smart Guard
After=docker.service
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
# Installation Core
#═══════════════════════════════════════════════════════════════════════

run_conduit() {
    log_info "Deploying Conduit..."
    
    # Use fallback image if primary fails
    docker pull "$CONDUIT_IMAGE" || CONDUIT_IMAGE="ghcr.io/lofat/conduit:latest"
    
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
        log_success "Conduit Started! (Limit: $MAX_CLIENTS users, $BANDWIDTH Mbps)"
    else
        log_error "Conduit failed to start. Logs:"
        docker logs conduit 2>&1 | tail -5
        exit 1
    fi
}

setup_autostart() {
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
# Management Script (MODIFIED ORIGINAL MENU)
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

# Original Dashboard Function (Restored)
show_dashboard() {
    watch -n 2 "docker stats conduit --no-stream"
}

show_logs() {
    docker logs -f --tail 50 conduit | grep -v "\[STATS\]"
}

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║            🚀 PSIPHON CONDUIT MANAGER (IRANUX)                    ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
        echo -e "${CYAN}  MAIN MENU${NC}"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
        echo -e "  1. 📈 View status dashboard (Live)"
        echo -e "  2. 📊 Live connection stats"
        echo -e "  3. 📋 View logs"
        echo ""
        echo -e "  5. ▶️  Start Conduit"
        echo -e "  6. ⏹️  Stop Conduit"
        echo -e "  7. 🔁 Restart Conduit"
        echo ""
        echo -e "  9. 🛡️  Smart Guard Status (New)"
        echo -e "  0. 🚪 Exit"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
        echo ""
        
        if docker ps | grep -q conduit; then
            echo -e "  Status: ${GREEN}● Running${NC}"
        else
            echo -e "  Status: ${RED}● Stopped${NC}"
        fi
        echo ""

        # FIX FOR FLASHING: Read from /dev/tty to ignore pipe input
        read -p "  Enter choice: " choice < /dev/tty || exit 0

        case "$choice" in
            1) show_dashboard ;;
            2) docker logs -f --tail 20 conduit | grep "STATS" ;;
            3) show_logs ;;
            5) docker start conduit; echo "Started."; sleep 1 ;;
            6) docker stop conduit; echo "Stopped."; sleep 1 ;;
            7) docker restart conduit; echo "Restarted."; sleep 1 ;;
            9) 
               start=$(cat /opt/conduit/install_date 2>/dev/null || echo 0)
               diff=$(( ($(date +%s) - start) / 3600 ))
               echo ""
               echo -e "  ${CYAN}--- Smart Guard Status ---${NC}"
               echo "  Server Uptime: $diff hours"
               if [[ $diff -ge 12 ]]; then 
                   echo -e "  Mode: ${RED}RESTRICTED${NC} (Non-Iran IPs limited to 5m)"
               else 
                   echo -e "  Mode: ${GREEN}GRACE PERIOD${NC} (Open Access for $((12-diff))h more)"
               fi
               echo ""
               read -n 1 -s -r -p "Press any key to return..." < /dev/tty ;;
            0) exit 0 ;;
            *) echo "Invalid choice" ;;
        esac
    done
}

show_menu
EOF
    chmod +x /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════
main() {
    print_header
    check_root
    detect_os
    
    # 1. Clean
    nuclear_clean
    
    # 2. Deps
    check_dependencies
    
    # 3. Smart Guard
    setup_smart_guard
    
    # 4. Deploy (Hardcoded settings applied inside)
    run_conduit
    
    # 5. Persistence
    setup_autostart
    
    # 6. Menu
    create_management_script
    
    echo ""
    echo -e "${GREEN}✅ INSTALLATION SUCCESSFUL!${NC}"
    echo -e "Type ${BOLD}conduit${NC} to open the menu."
    
    # Attempt to open menu (requires TTY)
    if [ -t 0 ]; then
        sleep 2
        /usr/local/bin/conduit
    fi
}

main "$@"
