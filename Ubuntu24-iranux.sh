#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER v1.2 (IRANUX MODIFIED)           ║
# ║                                                                   ║
# ║  • Base: Original Working Script                                  ║
# ║  • Hardcoded: 50 Clients / 10 Mbps                                ║
# ║  • Features: Smart Guard + Nuclear Clean                          ║
# ╚═══════════════════════════════════════════════════════════════════╝

set -eo pipefail

# --- HARDCODED SETTINGS (IRANUX) ---
# Overriding interactive prompts
MAX_CLIENTS=50
BANDWIDTH=10
CONTAINER_COUNT=1
# Using the EXACT image from your original working file:
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"

VERSION="1.2"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
# Smart Guard Paths
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
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    # Keep original OS detection logic
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            PKG_MANAGER="apt" ;;
        centos|fedora|rhel|rocky|almalinux)
            PKG_MANAGER="yum" ;;
        *)
            PKG_MANAGER="apt" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# 2. Nuclear Clean (Added Feature)
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
    
    systemctl daemon-reload 2>/dev/null || true
    log_success "Cleanup complete."
}

#═══════════════════════════════════════════════════════════════════════
# 3. Dependencies
#═══════════════════════════════════════════════════════════════════════
check_dependencies() {
    log_info "Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update -q
        apt-get install -y -q curl docker.io ipset iptables jq
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y curl docker ipset iptables jq
    fi
    
    systemctl enable --now docker 2>/dev/null || true
}

#═══════════════════════════════════════════════════════════════════════
# 4. Smart Guard Logic (Added Feature)
#═══════════════════════════════════════════════════════════════════════
setup_smart_guard() {
    log_info "Configuring Smart Guard (Geo-Filtering)..."
    mkdir -p "$INSTALL_DIR"
    
    # 1. Set Install Date if missing
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    
    # 2. Download Iran IP List
    log_info "Downloading Iran IP database..."
    curl -sL "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr" -o "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    
    # 3. Create Guard Script
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
    
    # Clean previous rules
    iptables -D INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true
    ipset destroy iran_ips 2>/dev/null || true

    if [ "$DIFF_HOURS" -ge 12 ]; then
        echo "Smart Guard: Active"
        ipset create iran_ips hash:net
        while read line; do ipset add iran_ips "$line" -!; done < "$IRAN_IP_LIST"
        
        # Allow Iran IPs
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        # Limit others (5 min)
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
fi
EOF
    chmod +x "$INSTALL_DIR/smart_guard.sh"
    
    # 4. Service
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
# 5. Installation Core (Original Method)
#═══════════════════════════════════════════════════════════════════════
run_conduit() {
    log_info "Deploying Conduit Container..."
    
    # Using the EXACT image from your working file
    # We add a fallback just in case GHCR is blocked, but prioritize your image
    if ! docker pull "$CONDUIT_IMAGE"; then
        log_warn "Standard pull failed. Trying fallback local build..."
        # Fallback to local binary if image pull fails (Your original code idea)
        docker run -d --name conduit --restart unless-stopped --network host \
            -v conduit-data:/home/conduit/data \
            ubuntu:24.04 bash -c "apt update && apt install -y wget unzip && \
            wget -qO conduit.zip https://github.com/Psiphon-Inc/psiphon-conduit/releases/latest/download/psiphon-conduit-linux-x86_64.zip && \
            unzip conduit.zip && chmod +x psiphon-conduit-linux-x86_64 && \
            ./psiphon-conduit-linux-x86_64 start --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH --stats-file"
    else
        docker run -d \
            --name conduit \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --network host \
            -v conduit-data:/home/conduit/data \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file
    fi

    sleep 3
    if docker ps | grep -q conduit; then
        log_success "Conduit is RUNNING (Clients: $MAX_CLIENTS, BW: ${BANDWIDTH}Mbps)"
    else
        log_error "Conduit failed to start. Logs:"
        docker logs conduit 2>&1 | tail -10
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
# 6. Management Script (Original UI + Smart Guard Option)
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
    echo -e "  1. 📈 Live Stats"
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
# Main Execution Flow
#═══════════════════════════════════════════════════════════════════════
main() {
    print_header
    check_root
    detect_os
    
    # 1. Clean old installations
    nuclear_clean
    
    # 2. Dependencies
    check_dependencies
    
    # 3. Setup Smart Guard (Your custom feature)
    setup_smart_guard
    
    # 4. Deploy Container (Using Original Image)
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
    /usr/local/bin/conduit
}

main "$@"
