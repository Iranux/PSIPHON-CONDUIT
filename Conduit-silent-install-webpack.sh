#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v4.2 (STABLE BASE + SMART FEATURES) ║
# ║                                                                   ║
# ║  • BASE: v1.8 (Deep Clean & Fresh Install)                        ║
# ║  • ADDED: Smart Firewall (Iran VIP)                               ║
# ║  • ADDED: Auto-Start (Systemd)                                    ║
# ║  • MENU: 100% Static (No Flicker, No Auto-Refresh)                ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- AUTO ELEVATE TO ROOT ---
if [ "$EUID" -ne 0 ]; then
    if [ -f "$0" ]; then
        echo "Requesting root privileges..."
        exec sudo bash "$0" "$@"
    else
        echo "Error: This script needs root."
        echo "Please run with sudo:  curl ... | sudo bash"
        exit 1
    fi
fi

# Stop apt from asking questions
export DEBIAN_FRONTEND=noninteractive

# Exit on critical errors
set -e

VERSION="4.2"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Helpers
#═══════════════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

detect_os() {
    OS="unknown"
    PKG_MANAGER="unknown"
    if [ -f /etc/os-release ]; then . /etc/os-release; OS="$ID"; else OS=$(uname -s); fi
    
    case "$OS" in
        ubuntu|debian|linuxmint|kali) PKG_MANAGER="apt" ;;
        centos|rhel|fedora|almalinux) PKG_MANAGER="dnf" ;;
        alpine) PKG_MANAGER="apk" ;;
        *) PKG_MANAGER="unknown" ;;
    esac
    log_info "Detected OS: $OS ($PKG_MANAGER)"
}

#═══════════════════════════════════════════════════════════════════════
# 1. DEEP CLEAN & REPAIR SYSTEM (From v1.8)
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "Starting Deep Clean & System Repair..."

    # 1. Kill stuck package managers
    log_info "Killing stuck apt/dpkg processes..."
    killall apt apt-get dpkg 2>/dev/null || true
    sleep 2

    # 2. Fix APT/DPKG specifics
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*

        log_info "Repairing dpkg database..."
        dpkg --configure -a || true
        
        log_info "Fixing broken dependencies..."
        apt-get install -f -y || true
        
        log_info "Cleaning apt cache..."
        apt-get clean || true
        apt-get update -q -y >/dev/null 2>&1 || true
    fi

    # 3. Wipe previous Conduit Installation
    log_info "Wiping previous Conduit installation..."
    if command -v docker &>/dev/null; then
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true
        docker stop $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
        docker rm $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
        
        rm -f /usr/local/bin/conduit
    fi
    
    log_success "System cleaned."
}

#═══════════════════════════════════════════════════════════════════════
# 2. INSTALLATION
#═══════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_info "Installing dependencies..."
    # Added 'ipset' here for the firewall logic
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode ipset"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode ipset || true
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is present."
        return 0
    fi
    log_info "Installing Docker..."
    if [ "$PKG_MANAGER" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose || true
        service docker start || true
    else
        if ! curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
             log_warn "Docker script failed, trying fallback..."
             if [ "$PKG_MANAGER" = "apt" ]; then apt-get install -y docker.io || true; fi
        fi
        systemctl start docker >/dev/null 2>&1 || true
        systemctl enable docker >/dev/null 2>&1 || true
    fi
}

check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    
    log_info "Found backup. Restoring Identity..."
    docker volume create conduit-data >/dev/null 2>&1 || true
    if docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"; then
        log_success "Identity restored."
    fi
}

run_conduit() {
    log_info "Starting Conduit..."
    
    docker volume create conduit-data >/dev/null 2>&1 || true
    docker run --rm -v conduit-data:/data alpine chown -R 1000:1000 /data >/dev/null 2>&1 || true

    if docker run -d \
        --name conduit \
        --restart unless-stopped \
        --log-opt max-size=10m \
        -v conduit-data:/home/conduit/data \
        --network host \
        "$CONDUIT_IMAGE" \
        start --max-clients 50 --bandwidth 5 --stats-file >/dev/null; then
        log_success "Conduit Started."
    else
        log_error "Failed to start container."
        exit 1
    fi
}

save_conf() {
    mkdir -p "$INSTALL_DIR"
    echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
    echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"
    echo "CONTAINER_COUNT=1" >> "$INSTALL_DIR/settings.conf"
}

#═══════════════════════════════════════════════════════════════════════
# 3. NEW FEATURES (AUTO START + FIREWALL)
#═══════════════════════════════════════════════════════════════════════

setup_autostart() {
    log_info "Enabling Auto-Start Service..."
    cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable conduit.service >/dev/null 2>&1 || true
        systemctl start conduit.service >/dev/null 2>&1 || true
    fi
}

setup_firewall_script() {
    log_info "Configuring Smart Firewall Script..."
    cat << 'EOF' > "$FW_SCRIPT"
#!/bin/bash
IP_LIST="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
IPSET="iran_ips"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
NC='\033[0m'

do_enable() {
    echo -e "${CYAN}Downloading Iran IP List...${NC}"
    if ! curl -sL "$IP_LIST" -o /tmp/ir.cidr; then echo "Download failed"; return; fi
    
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done < /tmp/ir.cidr
    
    iptables -F INPUT
    # 1. Essential
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # 2. Iran VIP (Unlimited)
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    
    # 3. World (Throttled for Scanners/Trackers)
    # Limit: 3 new connections per 60 seconds
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    
    echo -e "${GREEN}SMART FIREWALL ENABLED.${NC}"
}

do_disable() {
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    echo -e "${GREEN}FIREWALL DISABLED.${NC}"
}

case "$1" in
    enable) do_enable ;;
    disable) do_disable ;;
esac
EOF
    chmod +x "$FW_SCRIPT"
}

create_static_menu() {
    log_info "Creating Static Menu (v4.2)..."
    
    cat << 'EOF' > "$MENU_SCRIPT"
#!/bin/bash
FW="/opt/conduit/firewall.sh"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      🚀 CONDUIT MANAGER v4.2 (STABLE & STATIC)             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Status Checks (Single run, no loop)
    if docker ps | grep -q conduit; then
        echo -e "  SERVICE:  ${GREEN}RUNNING${NC}"
    else
        echo -e "  SERVICE:  ${RED}STOPPED${NC}"
    fi

    if iptables -L INPUT 2>/dev/null | grep -q "match-set iran_ips"; then
        echo -e "  FILTER:   ${GREEN}SMART (Iran Unlimited / World Throttled)${NC}"
    else
        echo -e "  FILTER:   ${YELLOW}OPEN (No Restrictions)${NC}"
    fi

    echo ""
    echo "  [1] 👥 Active Users (Snapshot)"
    echo "  [2] 📄 View Logs"
    echo "  [3] 🔄 Restart Service"
    echo "  [4] 🛑 Stop Service"
    echo "  -----------------------"
    echo "  [5] 🧠 Enable Smart Filter"
    echo "  [6] 🔓 Disable Filter"
    echo "  -----------------------"
    echo "  [0] 🚪 Exit"
    echo ""
    
    # WAITS HERE FOREVER. NO FLICKER.
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo -e "\n${CYAN}--- USERS SNAPSHOT ---${NC}"
            ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
            echo ""
            read -p "Press Enter to return..."
            ;;
        2) 
            echo -e "\n${CYAN}--- LOGS (Ctrl+C to exit) ---${NC}"
            docker logs -f --tail 50 conduit
            ;;
        3)
            echo "Restarting..."
            docker restart conduit
            sleep 1
            ;;
        4)
            echo "Stopping..."
            docker stop conduit
            sleep 1
            ;;
        5)
            bash "$FW" enable
            read -p "Press Enter to return..."
            ;;
        6)
            bash "$FW" disable
            read -p "Press Enter to return..."
            ;;
        0) 
            clear
            exit 0 
            ;;
        *) ;;
    esac
done
EOF
    chmod +x "$MENU_SCRIPT"
    rm -f /usr/local/bin/conduit
    ln -s "$MENU_SCRIPT" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
#═══════════════════════════════════════════════════════════════════════

detect_os
deep_clean_system
install_dependencies
install_docker
check_restore
run_conduit
save_conf

# NEW STEPS
setup_autostart
setup_firewall_script
create_static_menu

echo ""
log_success "FRESH INSTALLATION COMPLETE."
echo "------------------------------------------------"
echo -e " To open menu: ${YELLOW}conduit${NC}"
echo "------------------------------------------------"
sleep 3

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit
fi
