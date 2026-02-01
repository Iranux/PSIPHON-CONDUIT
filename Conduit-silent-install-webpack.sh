#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v2.5 (SMART TRAFFIC SHAPER)         ║
# ║                                                                   ║
# ║  • SMART: Allows Iran IPs fully (Unlimited)                       ║
# ║  • CLEVER: Throttles Non-Iran IPs (Allows Trackers, Blocks Users) ║
# ║  • SAFE: Guarantees Node Discovery by Psiphon Network             ║
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

export DEBIAN_FRONTEND=noninteractive
set -e

CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"

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
}

#═══════════════════════════════════════════════════════════════════════
# SYSTEM REPAIR & INSTALL
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "System Check..."
    killall apt apt-get dpkg 2>/dev/null || true
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get install -f -y >/dev/null 2>&1 || true
    fi
    rm -f /usr/local/bin/conduit
}

install_dependencies() {
    log_info "Installing dependencies..."
    # 'ipset' is critical for this version
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode ipset"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs >/dev/null 2>&1 || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode ipset >/dev/null 2>&1 || true
    fi
}

install_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker..."
        if [ "$PKG_MANAGER" = "alpine" ]; then
            apk add --no-cache docker docker-cli-compose >/dev/null 2>&1 || true
            service docker start >/dev/null 2>&1 || true
        else
            curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || apt-get install -y docker.io >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
            systemctl enable docker >/dev/null 2>&1 || true
        fi
    fi
}

check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    docker volume create conduit-data >/dev/null 2>&1 || true
    docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json" >/dev/null 2>&1 || true
}

run_conduit() {
    log_info "Configuring Conduit..."
    docker rm -f conduit 2>/dev/null || true
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
        log_success "Service Started."
    else
        log_error "Failed to start service."
        exit 1
    fi
}

save_conf() {
    mkdir -p "$INSTALL_DIR"
    echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
    echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"
    echo "CONTAINER_COUNT=1" >> "$INSTALL_DIR/settings.conf"
}

setup_autostart() {
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
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit.service 2>/dev/null || true
        systemctl start conduit.service 2>/dev/null || true
    fi
}

#═══════════════════════════════════════════════════════════════════════
# SMART FIREWALL LOGIC (The "Smart" Part)
#═══════════════════════════════════════════════════════════════════════

setup_firewall_script() {
    local fw_script="$INSTALL_DIR/firewall.sh"
    
    cat << 'EOF' > "$fw_script"
#!/bin/bash
CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

IP_LIST_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
IPSET_NAME="iran_ips"

enable_smart_firewall() {
    echo -e "${CYAN}--- Enabling Smart Filter (Iran + Scanners) ---${NC}"
    
    if ! command -v ipset &>/dev/null; then
        echo -e "${RED}Error: ipset missing.${NC}"
        return
    fi

    echo "1. Fetching Iran IPs..."
    curl -sL "$IP_LIST_URL" -o /tmp/ir.cidr
    if [ ! -s /tmp/ir.cidr ]; then
        echo -e "${RED}Download failed. Aborting.${NC}"
        return
    fi

    echo "2. Building IPSet..."
    ipset create $IPSET_NAME hash:net -exist
    ipset flush $IPSET_NAME
    while read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        ipset add $IPSET_NAME "$line" -exist
    done < /tmp/ir.cidr
    
    echo "3. Applying Smart Rules..."
    iptables -F INPUT
    
    # 1. ALLOW Local & Established
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # 2. ALLOW SSH (Always)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # 3. ALLOW Iran IPs (Unlimited)
    iptables -A INPUT -m set --match-set $IPSET_NAME src -j ACCEPT
    
    # 4. SMART GATE: Allow Non-Iran IPs BUT Limit Connections
    #    (Allows Trackers to check port, Blocks Users who need persistent streams)
    #    Limit: 3 new connections per 60 seconds.
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    
    # 5. If they pass the limit (Scanners), Accept them.
    iptables -A INPUT -j ACCEPT
    
    echo -e "${GREEN}SMART FILTER ACTIVE:${NC}"
    echo -e "  - Iran IPs:  ${GREEN}UNLIMITED${NC}"
    echo -e "  - Scanners:  ${GREEN}ALLOWED (Low Rate)${NC}"
    echo -e "  - Outsiders: ${RED}THROTTLED (Unusable for streaming)${NC}"
}

disable_firewall() {
    echo -e "${CYAN}--- Disabling Filter ---${NC}"
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    echo -e "${GREEN}Firewall DISABLED.${NC}"
}

case "$1" in
    enable) enable_smart_firewall ;;
    disable) disable_firewall ;;
esac
EOF
    chmod +x "$fw_script"
}

#═══════════════════════════════════════════════════════════════════════
# MENU
#═══════════════════════════════════════════════════════════════════════

create_custom_menu() {
    log_info "Installing Menu..."
    local menu_path="$INSTALL_DIR/conduit"
    setup_firewall_script
    
    cat << 'EOF' > "$menu_path"
#!/bin/bash
FW_SCRIPT="/opt/conduit/firewall.sh"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         🚀 CONDUIT MANAGER v2.5 (SMART FILTER)             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if docker ps | grep -q conduit; then
        echo -e "  SERVICE:  ${GREEN}RUNNING${NC}"
    else
        echo -e "  SERVICE:  ${RED}STOPPED${NC}"
    fi
    
    # Check firewall logic
    if iptables -L INPUT | grep -q "match-set iran_ips"; then
         echo -e "  FILTER:   ${GREEN}SMART IRAN ONLY (Active)${NC}"
    else
         echo -e "  FILTER:   ${YELLOW}OPEN TO WORLD (Default)${NC}"
    fi
    
    echo ""
    echo "  [1] 👥 Check Active Users"
    echo "  [2] 📄 View Logs"
    echo "  [3] 🔄 Restart Service"
    echo "  [4] 🛑 Stop Service"
    echo "  -----------------------"
    echo "  [5] 🧠 Enable Smart Filter (Iran Unlimited / World Throttled)"
    echo "  [6] 🔓 Disable Filter (Allow All)"
    echo "  -----------------------"
    echo "  [0] 🚪 Exit"
    echo ""
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo -e "\n${CYAN}--- Active Connections (One-time) ---${NC}"
            connections=$(ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 10)
            if [ -z "$connections" ]; then echo "No users found."; else echo "$connections"; fi
            echo ""
            read -p "Press Enter..."
            ;;
        2) 
            docker logs --tail 50 conduit
            read -p "Press Enter..."
            ;;
        3)
            docker restart conduit
            sleep 1
            ;;
        4)
            docker stop conduit
            sleep 1
            ;;
        5)
            bash "$FW_SCRIPT" enable
            read -p "Press Enter..."
            ;;
        6)
            bash "$FW_SCRIPT" disable
            read -p "Press Enter..."
            ;;
        0) 
            clear
            exit 0 
            ;;
        *) ;;
    esac
done
EOF
    chmod +x "$menu_path"
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN
#═══════════════════════════════════════════════════════════════════════

detect_os
deep_clean_system
install_dependencies
install_docker
check_restore
run_conduit
save_conf
setup_autostart
create_custom_menu

echo ""
log_success "INSTALLATION COMPLETE."
echo "--------------------------------------------------------"
echo -e " To open menu: ${YELLOW}conduit${NC}"
echo "--------------------------------------------------------"
sleep 2

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit menu
fi
